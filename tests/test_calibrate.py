# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""calibrate.py signal path: the click generator and the peak detector that
the microphone sync calibration stands on. A detector that fires on noise —
or misses a real click — turns into a wrong per-device delay in the user's
config, so both directions are pinned here."""
import ast
import math
import os
import pathlib
import shutil
import struct
import subprocess
import tempfile
import types
import wave

import pytest

UI_DIR = pathlib.Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"


@pytest.fixture(scope="session")
def calib():
    """Pure functions lifted from calibrate.py via AST (it runs main() at
    import and would try to record from a microphone)."""
    src = (UI_DIR / "calibrate.py").read_text()
    tree = ast.parse(src)
    wanted = [n for n in tree.body
              if isinstance(n, (ast.FunctionDef, ast.Assign, ast.AnnAssign))]
    # Keep constants (RATE, thresholds) and functions; drop the main() CALL
    # subprocess is here so the teardown and pactl helpers are callable at
    # all: without it their except-clauses raise NameError before the branch
    # under test is ever reached. Tests that want to watch what they run
    # swap this entry for a stand-in.
    ns = {"math": math, "os": os, "shutil": shutil, "struct": struct,
          "subprocess": subprocess, "tempfile": tempfile, "wave": wave}
    body = [n for n in wanted
            if not (isinstance(n, ast.FunctionDef) and n.name == "main")]
    exec(compile(ast.Module(body=body, type_ignores=[]), str(UI_DIR / "calibrate.py"), "exec"), ns)
    return ns


def write_wav(path, samples, rate):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))


def test_make_click_is_leader_then_burst(calib, tmp_path):
    p = tmp_path / "click.wav"
    calib["make_click"](str(p))
    rate = calib["RATE"]
    with wave.open(str(p), "rb") as w:
        assert w.getframerate() == rate
        assert w.getnchannels() == 1
        n = w.getnframes()
        raw = w.readframes(n)
    total = int(rate * (calib["LEADER_SECONDS"] + calib["LEADER_GAP_SECONDS"] + 0.010))
    assert n == total
    samples = [struct.unpack_from("<h", raw, i * 2)[0] for i in range(n)]
    # The wake-up hum stays far below the burst and below the peak gate —
    # it must never be mistaken for the moment being measured.
    leader_peak = max(abs(s) for s in samples[:int(rate * calib["LEADER_SECONDS"])])
    assert leader_peak <= calib["LEADER_AMP"]
    burst_peak = max(abs(s) for s in samples[-int(rate * 0.010):])
    assert 10000 < burst_peak <= 24000  # audible but never clipping


def inject_click(samples, rate, at, amp):
    for i in range(int(rate * 0.01)):
        env = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / int(rate * 0.01)))
        samples[int(at * rate) + i] = int(amp * env
                                          * math.sin(2.0 * math.pi * 2200.0 * i / rate))


def test_peak_of_finds_a_click_where_it_is(calib, tmp_path):
    rate = calib["RATE"]
    skip = calib["ANALYSIS_SKIP"]
    at = 0.9  # seconds — safely past the skipped warm-up window
    samples = [0] * int(rate * 1.5)
    inject_click(samples, rate, at, 20000)
    p = tmp_path / "rec.wav"
    write_wav(p, samples, rate)
    got = calib["peak_of"](str(p))
    assert got is not None
    t, amp, clipped = got
    assert abs(t - at) < 0.01
    assert t > skip  # the AGC-pop window must never win
    assert 18000 < amp <= 20000  # the peak's own height rides along
    assert clipped is False


def lcg_noise(n, sd, seed=12345):
    """Deterministic pseudo-noise — the matched-filter tests must not flake."""
    x = seed
    out = []
    for _ in range(n):
        x = (1103515245 * x + 12345) % (1 << 31)
        out.append(int((x % (4 * sd + 1)) - 2 * sd))
    return out


def test_matched_filter_holds_still_in_noise(calib, tmp_path):
    # The bare amplitude argmax wandered by whole samples between runs in
    # room noise; the matched filter integrates over the full burst and
    # must pin the arrival to well under a millisecond.
    rate = calib["RATE"]
    tpl = calib["click_template"]()
    at = 0.9
    # The detector reports the burst PEAK (like the old argmax did), not the
    # burst start — the truth reference carries the template's own peak.
    truth = at + max(range(len(tpl)), key=lambda i: abs(tpl[i])) / rate
    for k, seed in enumerate((1, 99)):
        samples = lcg_noise(int(rate * 1.5), 1000, seed)
        inject_click(samples, rate, at, 20000)
        p = tmp_path / ("noisy%d.wav" % k)
        write_wav(p, samples, rate)
        got = calib["peak_of"](str(p), tpl)
        assert got is not None
        assert abs(got[0] - truth) < 0.0005  # < half a millisecond off truth


def test_matched_filter_survives_inverted_polarity(calib, tmp_path):
    # A mic/speaker chain that flips the waveform's sign must not move the
    # measured arrival — the filter correlates on magnitude.
    rate = calib["RATE"]
    tpl = calib["click_template"]()
    times = []
    for k, amp in enumerate((20000, -20000)):
        samples = [0] * int(rate * 1.5)
        inject_click(samples, rate, 0.9, amp)
        p = tmp_path / ("pol%d.wav" % k)
        write_wav(p, samples, rate)
        got = calib["peak_of"](str(p), tpl)
        assert got is not None
        times.append(got[0])
    assert abs(times[0] - times[1]) < 0.0005


def test_peak_of_flags_mic_saturation(calib, tmp_path):
    # A burst flattened against the int16 rail still times fine, but its
    # amplitude is the microphone's ceiling, not the speaker's loudness —
    # the flag keeps it out of the level matching.
    rate = calib["RATE"]
    samples = [0] * int(rate * 1.5)
    n = int(rate * 0.01)
    at = int(0.9 * rate)
    for i in range(n):
        env = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / n))
        v = int(80000 * env * math.sin(2.0 * math.pi * 2200.0 * i / rate))
        samples[at + i] = max(-32768, min(32767, v))
    p = tmp_path / "clip.wav"
    write_wav(p, samples, rate)
    got = calib["peak_of"](str(p))
    assert got is not None
    assert got[2] is True


def test_peak_of_survives_a_truncated_recording(calib, tmp_path):
    # A recorder killed mid-header used to escape as wave.Error and abort
    # the WHOLE run — it must read as one failed measurement instead.
    p = tmp_path / "trunc.wav"
    p.write_bytes(b"RIFF\x24\x00\x00\x00WAVEfmt ")
    assert calib["peak_of"](str(p)) is None


def test_find_arrivals_separates_and_fuses(calib, tmp_path):
    rate = calib["RATE"]
    tpl = calib["click_template"]()
    # Two speakers 50 ms apart: two arrivals, spread ≈ 50 ms.
    samples = [0] * int(rate * 1.5)
    inject_click(samples, rate, 0.9, 20000)
    inject_click(samples, rate, 0.95, 15000)
    arr = calib["find_arrivals"](samples, tpl, 4)
    assert len(arr) == 2
    assert abs((arr[1] - arr[0]) - 0.05) < 0.002
    # Two speakers 3 ms apart fuse into one peak — reads as "together".
    samples = [0] * int(rate * 1.5)
    inject_click(samples, rate, 0.9, 20000)
    inject_click(samples, rate, 0.903, 15000)
    assert len(calib["find_arrivals"](samples, tpl, 4)) == 1


def test_find_arrivals_fixed_window_resists_anchor_creep(calib, tmp_path):
    # A rising chain of arrivals used to drag the running merge anchor
    # along and fuse everything into one peak. With the fixed ±8 ms
    # neighbourhood, arrivals 12 ms apart with a dip between them stay
    # two arrivals and the spread is honest.
    rate = calib["RATE"]
    tpl = calib["click_template"]()
    samples = [0] * int(rate * 1.5)
    inject_click(samples, rate, 0.9, 16000)
    inject_click(samples, rate, 0.912, 20000)   # louder one LATER: the creep case
    arr = calib["find_arrivals"](samples, tpl, 4)
    assert len(arr) == 2
    assert abs((arr[1] - arr[0]) - 0.012) < 0.002


def test_peak_of_amplitudes_keep_their_ratio(calib, tmp_path):
    # The loudness matching stands on this: a speaker heard at half the
    # amplitude must MEASURE at half the amplitude.
    rate = calib["RATE"]
    amps = []
    for k, target in enumerate((24000, 12000)):
        samples = [0] * int(rate * 1.5)
        inject_click(samples, rate, 0.9, target)
        p = tmp_path / ("rec%d.wav" % k)
        write_wav(p, samples, rate)
        got = calib["peak_of"](str(p))
        assert got is not None
        amps.append(got[1])
    assert abs(amps[1] / amps[0] - 0.5) < 0.02


def test_peak_of_rejects_silence(calib, tmp_path):
    p = tmp_path / "silence.wav"
    write_wav(p, [0] * calib["RATE"], calib["RATE"])
    assert calib["peak_of"](str(p)) is None


def test_peak_of_rejects_steady_noise(calib, tmp_path):
    # Loud but NOT impulsive — a click must stand far above the noise floor,
    # otherwise music/room noise would measure as a click.
    rate = calib["RATE"]
    samples = [int(8000 * math.sin(2.0 * math.pi * 300.0 * i / rate))
               for i in range(rate)]
    p = tmp_path / "noise.wav"
    write_wav(p, samples, rate)
    assert calib["peak_of"](str(p)) is None


def test_peak_of_gate_is_relative_to_the_pre_click_floor(calib, tmp_path):
    # Webcam AGC ducks the gain after a loud speaker: the next speaker's
    # click AND the noise floor shrink together. The gate must compare the
    # click against the concurrent floor, not an absolute bar — an AGC-
    # quieted click at 1500 over a floor of ~100 is a real click.
    rate = calib["RATE"]
    samples = [(100 if i % 3 else -100) for i in range(int(rate * 1.5))]
    inject_click(samples, rate, 0.9, 1500)
    p = tmp_path / "ducked.wav"
    write_wav(p, samples, rate)
    got = calib["peak_of"](str(p))
    assert got is not None
    assert abs(got[0] - 0.9) < 0.01
    # ...but the same click drowning in steady noise of its own size is
    # nothing click-like.
    samples = [(1000 if i % 2 else -1000) for i in range(int(rate * 1.5))]
    inject_click(samples, rate, 0.9, 1500)
    p2 = tmp_path / "buried.wav"
    write_wav(p2, samples, rate)
    assert calib["peak_of"](str(p2)) is None


def test_peak_of_rejects_too_short_recording(calib, tmp_path):
    p = tmp_path / "short.wav"
    write_wav(p, [0] * int(calib["RATE"] * 0.1), calib["RATE"])
    assert calib["peak_of"](str(p)) is None


def test_median_takes_the_middle(calib):
    assert calib["median"]([3.0, 1.0, 2.0]) == 2.0
    # Between the middle two on an even count. It used to take the upper of
    # the pair, which biased every even-length run the same way instead of
    # letting the error cancel — and CLICK_REPEATS is 2, so the runs this
    # sits on are even by design.
    assert calib["median"]([5.0, 1.0]) == 3.0


def test_recorder_prefers_pw_record(calib, monkeypatch):
    monkeypatch.setitem(calib, "shutil",
                        types.SimpleNamespace(which=lambda n: "/usr/bin/" + n))
    args = calib["recorder_args"]("mic1", "/tmp/rec.wav")
    assert args[0] == "pw-record"
    assert args[args.index("--target") + 1] == "mic1"
    assert args[-1] == "/tmp/rec.wav"


def test_recorder_falls_back_to_parecord(calib, monkeypatch):
    # Plain PulseAudio has no pw-record; parecord ships with paplay, and the
    # sample format must be pinned there because peak_of only reads 16-bit.
    monkeypatch.setitem(calib, "shutil",
                        types.SimpleNamespace(which=lambda n: None))
    args = calib["recorder_args"]("", "/tmp/rec.wav")
    assert args[0] == "parecord"
    assert "--file-format=wav" in args
    assert "--format=s16le" in args
    assert not any(a.startswith("--device=") for a in args)  # no mic given
    assert args[-1] == "/tmp/rec.wav"


def test_recorder_parecord_takes_the_mic(calib, monkeypatch):
    monkeypatch.setitem(calib, "shutil",
                        types.SimpleNamespace(which=lambda n: None))
    assert "--device=alsa_input.usb" in calib["recorder_args"]("alsa_input.usb", "/x.wav")


def test_strong_template_match_lowers_the_amplitude_bar(calib, tmp_path):
    # A fan-loud room with a sensitive mic: floor ~600, click at ~3500 —
    # under the 8x-the-floor bar, but the matched filter recognizes the
    # burst unmistakably (measured live: match 0.65 at 7.9x the floor).
    # With the template in hand the strong shape verdict buys the amplitude
    # bar down to 4x; without it the full bar still stands.
    import random
    rate = calib["RATE"]
    rng = random.Random(7)
    samples = [rng.randint(-1200, 1200) for i in range(int(rate * 1.5))]
    inject_click(samples, rate, 0.9, 3500)
    p = tmp_path / "noisyroom.wav"
    write_wav(p, samples, rate)
    tpl = calib["click_template"]()
    got = calib["peak_of"](str(p), tpl)
    assert got is not None
    assert abs(got[0] - 0.9) < 0.01
    # The template-less path keeps the old, stricter bar.
    assert calib["peak_of"](str(p)) is None


def test_a_thump_in_noise_is_still_not_a_click(calib, tmp_path):
    # The relaxed bar leans on the SHAPE verdict — a low-frequency thump at
    # the same amplitude must not ride in through the lowered gate.
    import random
    rate = calib["RATE"]
    rng = random.Random(11)
    samples = [rng.randint(-1200, 1200) for i in range(int(rate * 1.5))]
    n = int(rate * 0.01)
    for i in range(n):
        env = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / n))
        samples[int(0.9 * rate) + i] += int(3500 * env
                                            * math.sin(2.0 * math.pi * 150.0 * i / rate))
    p = tmp_path / "thump.wav"
    write_wav(p, [max(-32768, min(32767, s)) for s in samples], rate)
    assert calib["peak_of"](str(p), calib["click_template"]()) is None


def test_agreement_window_matches_the_measured_repeatability(calib):
    # Deployed-path arrivals repeat within ~50 ms (measured); the agreement
    # window is 60 ms so chance alignments of room noise across a ~3 s
    # capture stay rare. 150 ms let roughly a third of pure-noise runs
    # fabricate an "arrival" that then fed the residual back into the lags.
    assert calib["_two_that_agree"]([1.00, 1.05]) is not None
    assert calib["_two_that_agree"]([1.00, 1.10]) is None
    assert calib["_two_that_agree"]([1.00, 1.30, 1.34]) is not None


def test_dead_capture_is_exact_zero_not_quiet(calib):
    # A hardware-muted mic (the Yeti's own touch button) delivers EXACT
    # zeros; a live ADC in a silent room still shows a few LSBs. The line
    # between them is what turns "forty seconds of futile clicks" into an
    # instant, specific verdict.
    assert calib["_is_dead_capture"]([])
    assert calib["_is_dead_capture"]([0] * 48000)
    assert calib["_is_dead_capture"]([0, 2, -3, 1])
    assert not calib["_is_dead_capture"]([0, 0, 5, 0])


def test_monitors_are_not_microphones(calib):
    assert not calib["_usable_mic_name"]("")
    assert not calib["_usable_mic_name"]("alsa_output.usb-X.analog-stereo.monitor")
    assert calib["_usable_mic_name"]("alsa_input.usb-Blue_Yeti.analog-stereo")


def test_hearing_score_prefers_the_ear_with_the_better_ratio(calib, tmp_path):
    """Loudness alone must not decide which microphone a room is measured
    with: a webcam's own gain can make it read louder than a studio mic while
    hearing far less. The score is the burst over that microphone's noise."""
    import random
    tpl = calib["click_template"]()
    rate = calib["RATE"]

    def capture(noise_amp, click_amp, path):
        rnd = random.Random(7)
        s = [int(rnd.uniform(-noise_amp, noise_amp))
             for _ in range(int(rate * calib["PLAY_DELAY"]))]
        s += [int(click_amp * v) for v in tpl]
        s += [int(rnd.uniform(-noise_amp, noise_amp)) for _ in range(int(rate * 0.2))]
        write_wav(path, s, rate)

    quiet_mic = tmp_path / "quiet.wav"
    noisy_mic = tmp_path / "noisy.wav"
    # The noisy one is LOUDER in absolute terms and still the worse ear.
    capture(40, 6000, quiet_mic)
    capture(1800, 9000, noisy_mic)
    good = calib["_hearing_score"](str(quiet_mic), tpl)
    bad = calib["_hearing_score"](str(noisy_mic), tpl)
    assert good > bad > 0

    # An unreadable capture scores zero rather than throwing.
    empty = tmp_path / "empty.wav"
    empty.write_bytes(b"")
    assert calib["_hearing_score"](str(empty), tpl) == 0.0


# ── The inaudible stimulus ──────────────────────────────────────────────
# The sweep the calibration plays instead of a click: nobody hears it, and
# the band it lives in is acoustically empty, so it is EASIER to find than
# the click was. Everything below drives the pure detector with synthetic
# audio — no speaker, no microphone, no room.

def _sine(hz, secs, rate, amp):
    n = int(rate * secs)
    return [amp * math.sin(2.0 * math.pi * hz * i / rate) for i in range(n)]


def _noise(n, amp, seed=1):
    """Deterministic pseudo-noise — a test that flakes is worse than none."""
    out, x = [], seed
    for _ in range(n):
        x = (1103515245 * x + 12345) & 0x7FFFFFFF
        out.append(amp * ((x / 0x3FFFFFFF) - 1.0))
    return out


def _room(calib, delay_s, sweep_amp, noise_amp=120.0, total_s=1.4, seed=1):
    """A recording: room noise for the whole take, with the sweep arriving
    at `delay_s`. sweep_amp 0 = the speaker never carried the band."""
    rate = calib["RATE"]
    n = int(rate * total_s)
    buf = _noise(n, noise_amp, seed)
    if sweep_amp > 0:
        chirp = calib["ultra_chirp"]()
        at = int(rate * delay_s)
        for i, v in enumerate(chirp):
            if at + i < n:
                buf[at + i] += sweep_amp * v
    return [int(max(-32767, min(32767, s))) for s in buf]


def test_ultra_chirp_is_inaudible_and_does_not_click(calib):
    rate = calib["RATE"]
    c = calib["ultra_chirp"]()
    assert len(c) == int(rate * calib["ULTRA_SECONDS"])
    assert max(abs(v) for v in c) <= 1.0
    # Raised-cosine edges: an abrupt start would put a broadband transient
    # into the AUDIBLE band and undo the whole point of the sweep.
    assert abs(c[0]) < 0.05 and abs(c[-1]) < 0.05
    # Everything it carries sits above hearing. Compare in-band energy
    # against a spread of audible probes.
    inband = calib["ultra_band_energy"](c, rate)
    for hz in (500.0, 1000.0, 4000.0, 8000.0, 12000.0, 15000.0):
        assert calib["_goertzel_mag"](c, hz, rate) < inband / 8.0, hz


def test_ultra_band_energy_ignores_the_audible_world(calib):
    rate = calib["RATE"]
    speech = _sine(700.0, 0.05, rate, 9000.0)
    music = _sine(3000.0, 0.05, rate, 9000.0)
    sweep = [6000.0 * v for v in calib["ultra_chirp"]()]
    quiet = calib["ultra_band_energy"](speech, rate) + calib["ultra_band_energy"](music, rate)
    assert calib["ultra_band_energy"](sweep, rate) > quiet * 20


def test_ultra_arrival_finds_a_known_delay(calib):
    rate = calib["RATE"]
    for delay in (0.55, 0.70, 0.95, 1.10):
        got = calib["ultra_arrival"](_room(calib, delay, 5000.0), rate)
        assert got is not None, delay
        found, peak, floor = got
        # Within one analysis window of the truth — the lag maths works to
        # a 60 ms agreement, so this is an order of magnitude finer.
        assert abs(found - delay) <= 0.012, (delay, found)
        assert peak > floor


def test_ultra_arrival_survives_a_noisy_room(calib):
    rate = calib["RATE"]
    for noise in (200.0, 600.0, 1500.0):
        got = calib["ultra_arrival"](_room(calib, 0.8, 5000.0, noise_amp=noise), rate)
        assert got is not None, noise
        assert abs(got[0] - 0.8) <= 0.015, noise


def test_ultra_arrival_is_silent_when_the_band_is(calib):
    """A speaker whose codec cuts at 16 kHz never carries the sweep. The
    honest answer is None — the caller's cue to fall back to the click."""
    rate = calib["RATE"]
    assert calib["ultra_arrival"](_room(calib, 0.8, 0.0), rate) is None
    assert calib["ultra_arrival"]([], rate) is None
    assert calib["ultra_arrival"]([0] * 100, rate) is None


def test_ultra_arrival_ignores_a_loud_audible_room(calib):
    """Music and speech left playing must not read as an arrival: they are
    loud, but they are not up there."""
    rate = calib["RATE"]
    n = int(rate * 1.4)
    loud = _noise(n, 400.0)
    for hz in (300.0, 900.0, 2500.0, 6000.0):
        for i, v in enumerate(_sine(hz, 1.4, rate, 7000.0)):
            if i < n:
                loud[i] += v
    samples = [int(max(-32767, min(32767, s))) for s in loud]
    assert calib["ultra_arrival"](samples, rate) is None


def test_ultra_arrival_takes_the_direct_sound_not_the_loudest_echo(calib):
    """A room's first reflection can be LOUDER than the direct sound. The
    lag is about when the sound first arrived, not when it was loudest."""
    rate = calib["RATE"]
    n = int(rate * 1.4)
    buf = _noise(n, 120.0)
    chirp = calib["ultra_chirp"]()
    for at, amp in ((int(rate * 0.70), 3000.0), (int(rate * 0.76), 9000.0)):
        for i, v in enumerate(chirp):
            if at + i < n:
                buf[at + i] += amp * v
    samples = [int(max(-32767, min(32767, s))) for s in buf]
    got = calib["ultra_arrival"](samples, rate)
    assert got is not None
    assert abs(got[0] - 0.70) <= 0.015, got[0]


def test_ultra_arrival_skips_the_recorders_opening_pop(calib):
    """Every capture opens with a mic/AGC pop. It is broadband, so it lands
    in the sweep's band too — and it must not be read as the arrival."""
    rate = calib["RATE"]
    n = int(rate * 1.4)
    buf = _noise(n, 120.0)
    for i in range(int(rate * 0.05)):      # the pop, inside ANALYSIS_SKIP
        buf[i] += 20000.0 * math.sin(2.0 * math.pi * 19000.0 * i / rate)
    chirp = calib["ultra_chirp"]()
    at = int(rate * 0.9)
    for i, v in enumerate(chirp):
        if at + i < n:
            buf[at + i] += 5000.0 * v
    samples = [int(max(-32767, min(32767, s))) for s in buf]
    got = calib["ultra_arrival"](samples, rate)
    assert got is not None
    assert abs(got[0] - 0.9) <= 0.015, got[0]


def test_ultra_arrival_needs_real_margin_over_the_floor(calib):
    """A sweep barely above the band's own noise is not a measurement. The
    ratio gate refuses it rather than storing a guess as a device lag."""
    rate = calib["RATE"]
    assert calib["ultra_arrival"](_room(calib, 0.8, 60.0, noise_amp=300.0), rate) is None


def test_ultra_two_speakers_keep_their_difference(calib):
    """What the calibration actually asks: how much later did the second
    speaker arrive. Both measured the same way, the difference is what is
    stored — so it must survive different levels and different noise."""
    rate = calib["RATE"]
    a = calib["ultra_arrival"](_room(calib, 0.60, 7000.0, noise_amp=150.0, seed=3), rate)
    b = calib["ultra_arrival"](_room(calib, 0.83, 2500.0, noise_amp=800.0, seed=9), rate)
    assert a is not None and b is not None
    lag_ms = (b[0] - a[0]) * 1000.0
    assert abs(lag_ms - 230.0) <= 20.0, lag_ms


def test_two_captures_that_disagree_average_nothing(calib, monkeypatch):
    """A speaker heard twice out of three, the readings 170 ms apart — the
    shape a Bluetooth link waking mid-stimulus leaves behind. The old gate
    asked only for len >= 2 and took the median, and the median of two
    values is their mean: half the outlier's error walked straight into the
    stored lag. Disagreement this size is not an answer, and the run's own
    captures come back so the refusal can be read afterwards."""
    feeds = {"w": [1.0, 1.000, 1.002, 1.001], "b": [1.150, None, 1.320]}
    monkeypatch.setitem(calib, "_raw_arrival_ultra",
                        lambda sink, wav, mic, seconds=None, trim=None: feeds[sink].pop(0))
    raw = {}
    assert calib["_ultra_pair_lag"]("w", "b", "sweep.wav", "mic", raw) is None
    assert raw["w"] == [1.000, 1.002, 1.001]
    assert raw["b"] == [1.150, 1.320]


def test_agreeing_captures_still_time_the_pair(calib, monkeypatch):
    """The settle rule must not eat healthy rounds: three captures per
    speaker inside a few milliseconds still time the pair. The feeds keep
    every gap distinct so no tie-breaking choice inside _two_that_agree can
    move the answer."""
    feeds = {"w": [1.0, 1.000, 1.001, 1.005], "b": [1.150, 1.152, 1.147]}
    monkeypatch.setitem(calib, "_raw_arrival_ultra",
                        lambda sink, wav, mic, seconds=None, trim=None: feeds[sink].pop(0))
    lag = calib["_ultra_pair_lag"]("w", "b", "sweep.wav", "mic")
    assert lag == pytest.approx(150.5, abs=0.1), lag


def test_a_hair_below_zero_stores_zero_and_a_transient_stores_nothing(calib):
    """The map cannot deploy a negative pair, and the old clamp turned every
    settled negative into a silent 0. Inside the 25 ms in-step bar that IS
    the honest number — a simultaneous pair rounded down by capture noise
    must stay calibratable. Past the bar it is a transient (a flushed
    Bluetooth buffer once measured 149 ms ahead) that has to be remeasured,
    not stored as a confident zero."""
    stored = calib["_stored_pair_ms"]
    assert stored(150.4) == 150
    assert stored(0.0) == 0
    assert stored(-6.0) == 0
    assert stored(-24.9) == 0
    assert stored(-25.0) is None
    assert stored(-80.0) is None


def test_two_that_agree_takes_the_closest_pair(calib):
    """Three captures of a Bluetooth chain, two of them nearly identical and
    a third 55 ms away. Taking the first pair that merely fitted inside the
    tolerance let list order pick the loosest reading available."""
    agree = calib["_two_that_agree"]
    got = agree([1.000, 1.055, 1.003], tol=0.06)
    assert got == pytest.approx(1.0015, abs=1e-6), got
    # Nothing within tolerance is still None — the caller needs that.
    assert agree([1.0, 1.2, 1.4], tol=0.06) is None
    assert agree([1.0], tol=0.06) is None


def test_median_of_an_even_run_sits_between_the_middle_two(calib):
    """The click runs are even by design (CLICK_REPEATS is an even count),
    and taking the upper of the middle pair biased every one of them the
    same way."""
    med = calib["median"]
    assert med([0.10, 0.20]) == pytest.approx(0.15)
    assert med([0.10, 0.20, 0.30]) == pytest.approx(0.20)
    assert med([0.30, 0.10, 0.25, 0.15]) == pytest.approx(0.20)


def _rendered(calib, cutoff_hz=None, gain=1.0, wake_s=0.0):
    """The whole stimulus as ONE speaker renders it.

    A codec is modelled the way the measured one behaves: it passes the band
    until the sweep climbs past its cut and then passes nothing, and a leader
    sitting above that cut never leaves the speaker at all. Measured on a JBL
    Flip 7: 18.5 kHz at full strength, sixty decibels down by 19.5.
    """
    rate = calib["RATE"]
    lo, hi = calib["ULTRA_LOW_HZ"], calib["ULTRA_HIGH_HZ"]
    out = []
    ramp = rate * 0.05
    leader_heard = cutoff_hz is None or calib["ULTRA_LEADER_HZ"] <= cutoff_hz
    for i in range(int(rate * calib["LEADER_SECONDS"])):
        env = min(1.0, i / ramp)
        # wake_s: a Bluetooth link that comes alive partway through the
        # leader. Everything before that never left the speaker.
        silent = (not leader_heard) or i < int(wake_s * rate)
        out.append(0.0 if silent else
                   gain * calib["ULTRA_AMP"] * 0.35 * env
                   * math.sin(2.0 * math.pi * calib["ULTRA_LEADER_HZ"] * i / rate))
    out += [0.0] * int(rate * calib["ULTRA_GAP_SECONDS"])
    secs = calib["ULTRA_SECONDS"]
    for i, v in enumerate(calib["ultra_chirp"]()):
        instant = lo + (hi - lo) * (i / rate) / secs
        out.append(0.0 if (cutoff_hz is not None and instant > cutoff_hz)
                   else gain * calib["ULTRA_AMP"] * v)
    return out


def _room_playing(calib, rendered, delay_s=0.5, noise_amp=120.0,
                  total_s=1.8, seed=1):
    rate = calib["RATE"]
    n = int(rate * total_s)
    buf = _noise(n, noise_amp, seed)
    at = int(rate * delay_s)
    for i, v in enumerate(rendered):
        if at + i < n:
            buf[at + i] += v
    return [int(max(-32767, min(32767, s))) for s in buf]


def _sweep_at(calib, delay_s=0.5):
    return delay_s + calib["LEADER_SECONDS"] + calib["ULTRA_GAP_SECONDS"]


def _reverberant(calib, rendered, rt60_s, taps=12, seed=5):
    """The same stimulus with a room's tail on it.

    Every bench before this one was anechoic, which is why the leader and the
    sweep always arrived as two clean events there. A real room keeps ringing:
    the leader is 350 ms of steady level inside the measured band, and its
    decay is what has to die away before the sweep starts.
    """
    rate = calib["RATE"]
    x = seed
    out = list(rendered) + [0.0] * int(rate * (rt60_s + 0.2))
    for k in range(1, taps + 1):
        t = k * rt60_s / taps
        off = int(rate * t)
        amp = 10 ** (-3.0 * t / rt60_s)          # -60 dB by rt60
        x = (1103515245 * x + 12345) % (1 << 31)
        jitter = 0.6 + 0.4 * (x % 1000) / 1000.0
        for i, v in enumerate(rendered):
            if off + i < len(out):
                out[off + i] += amp * jitter * v
    return out


def test_ultra_arrival_times_the_sweep_in_a_room_that_rings(calib):
    """The leader must not still be holding the gate when the sweep starts.

    Measured live on the deployed path before this was pinned: the reading
    sat on the leader's edge and the true sweep, 400 ms later, came back as a
    repeatable "outlier" that two captures agreed on — so the agreement rule
    blessed the wrong one. Offline the failure appears the moment the room's
    tail reaches ~160 ms with the old 50 ms gap, and the gap is what fixes
    it: at 250 ms the arrival holds within a few milliseconds of truth from
    anechoic to a full second of decay.
    """
    rate = calib["RATE"]
    for rt60 in (0.0, 0.12, 0.2, 0.3, 0.5, 1.0):
        rendered = _rendered(calib)
        if rt60 > 0:
            rendered = _reverberant(calib, rendered, rt60)
        room = _room_playing(calib, rendered, delay_s=0.5,
                             total_s=0.5 + len(rendered) / rate + 0.3)
        got = calib["ultra_arrival"](room, rate)
        assert got is not None, "rt60=%.2f: refused a stimulus it can hear" % rt60
        err = (got[0] - _sweep_at(calib)) * 1000.0
        # The leader starts a full LEADER+GAP earlier; anything near that is
        # the detector timing the wrong part of its own stimulus.
        assert abs(err) < 25.0, "rt60=%.2f: %.1f ms off the sweep" % (rt60, err)


def test_ultra_arrival_times_a_codec_limited_speaker_like_any_other(calib):
    """The one that mattered in the room: a Bluetooth speaker whose codec
    stops mid-band must be timed the same as a speaker with no limit, because
    the number this file exists to produce is the DIFFERENCE between two
    speakers. Before events were classified by duration, the band-limited one
    came back 32 ms off — a third of a real room's error, invented."""
    rate = calib["RATE"]
    wide = calib["ultra_arrival"](_room_playing(calib, _rendered(calib)), rate)
    assert wide is not None
    assert abs(wide[0] - _sweep_at(calib)) <= 0.012, wide[0]
    # 19.2 kHz is where the measured JBL Flip 7 stops; 18.7 kHz is harsher
    # still and costs the speaker the top probe outright.
    for cutoff in (19200.0, 18700.0):
        other = calib["ultra_arrival"](
            _room_playing(calib, _rendered(calib, cutoff_hz=cutoff)), rate)
        assert other is not None, cutoff
        assert abs(other[0] - wide[0]) <= 0.006, (cutoff, wide[0], other[0])


def test_ultra_arrival_is_not_fooled_by_half_a_leader(calib):
    """A Bluetooth link waking partway through the leader leaves a remnant of
    any length — and one of those lengths must not be timed as the sweep.

    This is what the leader exists for in the first place (a cold link
    swallows what it is sent), so it is not a corner case. Judged by duration
    alone the remnant read as a sweep up to 350 ms early, and the error
    repeats run to run, so the agreement check waves it through and the whole
    room is corrected by it.
    """
    rate = calib["RATE"]
    truth = _sweep_at(calib)
    for wake_ms in (0, 100, 150, 160, 200, 250, 300, 330, 349):
        got = calib["ultra_arrival"](
            _room_playing(calib, _rendered(calib, wake_s=wake_ms / 1000.0)), rate)
        assert got is not None, wake_ms
        assert abs(got[0] - truth) <= 0.012, (wake_ms, got[0], truth)


def test_ultra_arrival_is_blind_to_how_loud_the_speaker_is(calib):
    """The stimulus rides whatever volume the group happens to sit at, so the
    same speaker arrives at very different strengths from run to run. Timing
    off half of the event's OWN peak is what keeps the answer still."""
    rate = calib["RATE"]
    seen = []
    for gain in (1.0, 0.5, 0.2, 0.1):
        got = calib["ultra_arrival"](
            _room_playing(calib, _rendered(calib, gain=gain)), rate)
        assert got is not None, gain
        seen.append(got[0])
    assert (max(seen) - min(seen)) <= 0.004, seen


def test_ultra_arrival_refuses_a_leader_whose_sweep_never_came(calib):
    """A link that woke up behind a speaker that cannot carry the rest. The
    leader alone would answer — with a number that slides with loudness — so
    the honest reply is none at all."""
    rate = calib["RATE"]
    rendered = _rendered(calib)
    sweep_from = int(rate * (calib["LEADER_SECONDS"] + calib["ULTRA_GAP_SECONDS"]))
    only_leader = rendered[:sweep_from] + [0.0] * (len(rendered) - sweep_from)
    assert calib["ultra_arrival"](_room_playing(calib, only_leader), rate) is None


def test_ultra_arrival_ignores_a_bang_as_long_as_the_sweep(calib):
    """A door or a dropped book is broadband and reaches this band. Duration
    is what separates it from the sweep, so the rejection has to hold for a
    transient far longer than a click — 40 ms of broadband noise here."""
    rate = calib["RATE"]
    n = int(rate * 1.8)
    buf = _noise(n, 120.0)
    bang = _noise(int(rate * 0.040), 9000.0, seed=5)
    at = int(rate * 0.9)
    for i, v in enumerate(bang):
        decay = 1.0 - i / float(len(bang))
        buf[at + i] += v * decay
    samples = [int(max(-32767, min(32767, s))) for s in buf]
    assert calib["ultra_arrival"](samples, rate) is None


def test_ultra_arrival_bridges_the_bands_own_ripple(calib):
    """Three probes across the band means the summed energy dips as the sweep
    passes between them, and in a loud room those dips cross the gate: one
    real sweep measured as runs of 8, 2, 7 and 11 windows, split by a single
    window each. Bridged, it is one event again."""
    rate = calib["RATE"]
    got = calib["ultra_arrival"](
        _room_playing(calib, _rendered(calib, gain=0.4), noise_amp=800.0, seed=9),
        rate)
    assert got is not None
    assert abs(got[0] - _sweep_at(calib)) <= 0.012, got[0]


def test_make_ultra_is_leader_then_sweep_and_stays_inaudible(calib, tmp_path):
    """The stimulus the automatic check plays. Nothing in it may fall into
    the audible band — including the wake-up leader, which is a 180 Hz hum
    in the click's version and would give the whole thing away."""
    p = tmp_path / "ultra.wav"
    calib["make_ultra"](str(p))
    rate = calib["RATE"]
    with wave.open(str(p), "rb") as w:
        assert w.getframerate() == rate and w.getnchannels() == 1
        n = w.getnframes()
        raw = w.readframes(n)
    expected = int(rate * (calib["LEADER_SECONDS"] + calib["ULTRA_GAP_SECONDS"]
                           + calib["ULTRA_SECONDS"]))
    assert abs(n - expected) <= 2
    samples = [struct.unpack_from("<h", raw, i * 2)[0] for i in range(n)]
    assert max(abs(s) for s in samples) <= calib["ULTRA_AMP"] + 1
    # Every audible probe must find far less than the sweep band does.
    band = calib["ultra_band_energy"](samples[-int(rate * calib["ULTRA_SECONDS"]):], rate)
    for hz in (180.0, 500.0, 2200.0, 8000.0, 14000.0):
        assert calib["_goertzel_mag"](samples, hz, rate) < band / 5.0, hz


def test_the_leader_does_not_click_when_it_stops(calib, tmp_path):
    """A tone that stops at full level is a step, and a step is heard.

    The test above probes single frequencies across the whole file, which is
    how this got through: a 20 microsecond edge is broadband but thin, so no
    narrow probe averaged over 660 ms ever saw it. What gave it away was a
    listener — a short high tick on every play of a stimulus that promises
    none. Measured on the file itself, the leader used to end at 1475 of its
    own 2100 and the audible band peaked at -34.9 dBFS there; with the fall
    it ends at 8 and the peak is back at the file's floor.
    """
    p = tmp_path / "ultra.wav"
    calib["make_ultra"](str(p))
    rate = calib["RATE"]
    with wave.open(str(p), "rb") as w:
        n = w.getnframes()
        raw = w.readframes(n)
    samples = [struct.unpack_from("<h", raw, i * 2)[0] for i in range(n)]
    n_lead = int(rate * calib["LEADER_SECONDS"])
    amp = calib["ULTRA_AMP"] * 0.35
    # Phase-proof: the last quarter-millisecond, not the last sample, which
    # could sit on a zero crossing by luck and pass a leader with no fall.
    tail = max(abs(s) for s in samples[n_lead - int(rate * 0.00025):n_lead])
    assert tail < 0.15 * amp, tail
    # And it still has to BE a leader — a fall that swallowed the whole tone
    # would pass the line above and wake no Bluetooth link.
    middle = max(abs(s) for s in samples[n_lead // 2:n_lead // 2 + int(rate * 0.01)])
    assert middle > 0.9 * amp, middle


def test_the_whole_stimulus_round_trips_through_a_wav(calib, tmp_path):
    """End to end on the pure path: write the real stimulus, place it in a
    synthetic recording at a known delay, and let the detector find it —
    the same code the verify runs, minus the speaker and the room."""
    rate = calib["RATE"]
    p = tmp_path / "ultra.wav"
    calib["make_ultra"](str(p))
    with wave.open(str(p), "rb") as w:
        raw = w.readframes(w.getnframes())
    stim = [struct.unpack_from("<h", raw, i * 2)[0] for i in range(len(raw) // 2)]
    # Only the sweep is measured; the leader is played before it.
    sweep = stim[-int(rate * calib["ULTRA_SECONDS"]):]
    n = int(rate * 2.2)
    buf = _noise(n, 150.0, seed=5)
    at = int(rate * 1.05)
    for i, v in enumerate(sweep):
        if at + i < n:
            buf[at + i] += v * 0.35          # a room away, well attenuated
    samples = [int(max(-32767, min(32767, s))) for s in buf]
    got = calib["ultra_arrival"](samples, rate)
    assert got is not None
    assert abs(got[0] - 1.05) <= 0.015, got[0]


def test_a_slam_does_not_pose_as_the_sweep(calib):
    """A door, a clap, a chair: broadband, so it DOES reach 18-21 kHz. It
    lasts a millisecond or two; the sweep runs sixty. Duration is what
    tells them apart, and this is the case the verify's stub room found."""
    rate = calib["RATE"]
    n = int(rate * 1.4)
    buf = _noise(n, 120.0)
    at = int(rate * 0.9)
    for i in range(int(rate * 0.0015)):        # 1.5 ms of broadband bang
        if at + i < n:
            buf[at + i] += 26000.0 * ((i % 2) * 2 - 1)
    samples = [int(max(-32767, min(32767, s))) for s in buf]
    assert calib["ultra_arrival"](samples, rate) is None


def test_a_slam_beside_the_sweep_does_not_steal_the_arrival(calib):
    """Both in one capture: the bang lands first and louder, the sweep
    after it. The sweep is the measurement — the bang must not become it."""
    rate = calib["RATE"]
    n = int(rate * 1.6)
    buf = _noise(n, 120.0)
    bang = int(rate * 0.55)
    for i in range(int(rate * 0.0015)):
        if bang + i < n:
            buf[bang + i] += 30000.0 * ((i % 2) * 2 - 1)
    at = int(rate * 0.95)
    for i, v in enumerate(calib["ultra_chirp"]()):
        if at + i < n:
            buf[at + i] += 5000.0 * v
    samples = [int(max(-32767, min(32767, s))) for s in buf]
    got = calib["ultra_arrival"](samples, rate)
    assert got is not None
    assert abs(got[0] - 0.95) <= 0.02, got[0]


# ── The automatic check's inaudible road ────────────────────────────────────
# The periodic check used to be passive on purpose — an audible click every
# six minutes was unthinkable — so it correlated whatever the music carried
# and gave up on flat material. That is where "too quiet to tell" came from,
# and it is measured behaviour, not a hypothetical: a live check on talk
# radio reported it. Nobody hears the sweep, so the check now plays its own
# signal. These pin the arithmetic that turns per-speaker arrivals into one
# drift number, and the refusals that must NOT turn into a confident answer.

def _stimulus_samples(calib):
    """The REAL stimulus make_ultra writes, as int16 samples."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as fh:
        path = fh.name
    calib["make_ultra"](path)
    with wave.open(path, "rb") as w:
        raw = w.readframes(w.getnframes())
    os.unlink(path)
    return [struct.unpack_from("<h", raw, i * 2)[0] for i in range(len(raw) // 2)]


def _capture_with_stimuli(calib, rate, plays, gains, seconds, seed=7):
    """One capture with the real stimulus dropped in at known moments."""
    n = int(rate * seconds)
    buf = _noise(n, 120.0, seed=seed)
    stim = _stimulus_samples(calib)
    for t, g in zip(plays, gains):
        if g <= 0:
            continue
        at = int(t * rate)
        for i, v in enumerate(stim):
            if at + i < n:
                buf[at + i] += v * g
    return buf


def test_slots_find_every_stimulus_in_one_capture(calib):
    """Both members inside a single recording, each in its own slot."""
    rate, slot = calib["RATE"], calib["ULTRA_SLOT_SECONDS"]
    plays = [0.6, 0.6 + slot]
    cap = _capture_with_stimuli(calib, rate, plays, [0.5, 0.5], plays[-1] + slot)
    got = calib["ultra_arrivals_in_slots"](cap, rate, plays, slot)
    sweep_at = calib["LEADER_SECONDS"] + calib["ULTRA_GAP_SECONDS"]
    assert len(got) == 2
    # Measured from EACH member's own play, never from the start of the
    # capture. Absolute times would carry the slot spacing into the
    # difference between two members: with the answer taken as a difference,
    # a room in perfect tune reported itself 800 ms out — which is exactly
    # what the end-to-end test caught the day this was written.
    for t0, a in zip(plays, got):
        assert a is not None, (t0, got)
        assert abs(a - sweep_at) < 0.020, (t0, a)
    # Said plainly, because it is the whole contract: two speakers that are
    # actually together must read as together, however far apart their slots.
    assert abs(got[0] - got[1]) < 0.005, got


def test_a_silent_slot_is_not_given_its_neighbours_arrival(calib):
    """The windows come from the SCHEDULE, not from where the last member was
    found. Chained off the previous arrival, one silent speaker would slide
    the next window and its neighbour's sweep would be credited to it — which
    reads as a huge, confident, entirely invented drift."""
    rate, slot = calib["RATE"], calib["ULTRA_SLOT_SECONDS"]
    plays = [0.6, 0.6 + slot]
    cap = _capture_with_stimuli(calib, rate, plays, [0.0, 0.5], plays[-1] + slot)
    got = calib["ultra_arrivals_in_slots"](cap, rate, plays, slot)
    assert got[0] is None, got
    assert got[1] is not None
    sweep_at = calib["LEADER_SECONDS"] + calib["ULTRA_GAP_SECONDS"]
    assert abs(got[1] - sweep_at) < 0.020, got


def test_a_slot_past_the_end_of_the_capture_says_nothing(calib):
    rate, slot = calib["RATE"], calib["ULTRA_SLOT_SECONDS"]
    plays = [0.6, 0.6 + slot]
    cap = _capture_with_stimuli(calib, rate, [0.6], [0.5], 1.6)
    got = calib["ultra_arrivals_in_slots"](cap, rate, plays, slot)
    assert got[1] is None, got


def test_a_shared_capture_cancels_the_microphones_own_start(calib):
    """This is the whole reason the road was rebuilt.

    The number it produces is a DIFFERENCE, and the capture's start time is
    unknown: measured on this desk, eight back-to-back captures of one speaker
    put the sink monitor at 1212.9 ms fourteen times out of sixteen while the
    microphone scattered over 45-68 ms. Inside ONE capture that unknown is
    shared by every member, so it has to fall out of the answer.
    """
    verdict = calib["ultra_rounds_verdict"]
    base = [0.50, 0.62]
    for jitter in (0.0, 0.045, -0.068, 0.113):
        shifted = [x + jitter for x in base]
        got = verdict([shifted, shifted, shifted], [0, 0], 25.0)
        assert got is not None, jitter
        _landings, spread = got
        assert abs(spread - 120.0) < 0.001, (jitter, spread)


def test_two_rounds_are_never_mixed_into_one_verdict(calib):
    """Member A heard only in round 1, member B only in round 2. Their
    arrivals carry two different unknown capture starts, so their difference
    is the very noise this design removes — wearing a number's clothes."""
    assert calib["ultra_rounds_verdict"]([[0.50, None], [None, 0.62]],
                                         [0, 0], 25.0) is None


def test_two_rounds_that_disagree_get_no_verdict(calib):
    """Two is a pair or it is nothing: with no third reading there is no
    middle to take, and picking either one would be picking at random."""
    assert calib["ultra_rounds_verdict"]([[0.50, 0.62], [0.50, 0.70]],
                                         [0, 0], 25.0) is None


def test_two_rounds_are_never_enough_however_well_they_agree(calib):
    """Agreement is not proof, and this one was paid for: measured live with
    a webcam, two readings that were BOTH wrong agreed inside 22 ms and
    published 145 ms in a room that measured 46. A middle needs three, and
    there is deliberately no quicker path."""
    same = [0.50, 0.62]
    assert calib["ultra_rounds_verdict"]([same, same], [0, 0], 25.0) is None
    assert calib["ultra_rounds_verdict"]([same], [0, 0], 25.0) is None
    # Three of the same is a verdict, so the refusal above is about the
    # COUNT and not about the numbers.
    assert calib["ultra_rounds_verdict"]([same, same, same], [0, 0], 25.0) is not None


def test_three_rounds_that_agree_with_nobody_still_have_a_middle(calib):
    """Requiring two rounds to agree was measured to be what shuts ordinary
    hardware out. Round-to-round scatter here runs 10-20 ms against a 25 ms
    window, so which microphone succeeds is luck: head to head in the same
    room the studio microphone scattered 63.8 ms over four rounds while the
    webcam scattered 22.3, and an earlier sample had said the opposite. Three
    readings that agree with nobody still have a middle, and the middle is an
    answer."""
    v = calib["ultra_rounds_verdict"](
        [[0.50, 0.60], [0.50, 0.63], [0.50, 0.665]], [0, 0], 25.0)
    assert v is not None
    _landings, spread = v
    # 100, 130 and 165 ms apart: no two of them are within the window of each
    # other, and all three sit around 130.
    assert abs(spread - 130.0) < 0.001, spread


def test_the_middle_is_a_median_so_one_wild_round_cannot_carry_it(calib):
    """A mean would hand the flyer a third of the answer."""
    v = calib["ultra_rounds_verdict"](
        [[0.50, 0.60], [0.50, 0.63], [0.50, 1.40]], [0, 0], 25.0)
    assert v is not None
    _landings, spread = v
    # 100, 130 and 900 ms apart: no two agree, the middle is 130, and a mean
    # would have answered 377.
    assert abs(spread - 130.0) < 0.001, spread


def test_three_rounds_that_gather_nowhere_are_unsteady_not_an_answer(calib):
    """A middle is only an answer when the readings gather around it. 120,
    220 and 320 has a middle too, and it is not a room."""
    assert calib["ultra_rounds_verdict"](
        [[0.50, 0.62], [0.50, 0.72], [0.50, 0.82]], [0, 0], 25.0) is None


def test_a_round_holding_one_member_has_no_difference_in_it(calib):
    assert calib["ultra_rounds_verdict"]([[0.50, None], [0.50, None]],
                                         [0, 0], 25.0) is None


def test_rounds_verdict_counts_the_delay_each_member_is_played_with(calib):
    """arrival + the delay it is ALREADY played with is where the ear hears
    it. A speaker 150 ms ahead in hardware, held back by 150, is in tune."""
    got = calib["ultra_rounds_verdict"](
        [[0.50, 0.35], [0.50, 0.35], [0.50, 0.35]], [0, 150], 25.0)
    assert got is not None
    _landings, spread = got
    assert abs(spread) < 0.001, spread


def test_drift_by_ultra_reports_the_spread_between_speakers(calib, monkeypatch):
    seen = []

    def fake(members, wav, mic, trim, slot_seconds=None):
        seen.append([m[0] for m in members])
        return [0.50, 0.62]

    monkeypatch.setitem(calib, "_shared_round", fake)
    ms = calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)], "mic")
    assert ms is not None
    assert abs(ms - 120.0) < 1.0, ms
    # Every member measured inside the SAME capture, every round.
    assert seen and all(r == ["wired", "bt"] for r in seen), seen


def test_drift_by_ultra_calls_a_synced_room_zero(calib, monkeypatch):
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [0.4321, 0.4321])
    assert calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)],
                                    "mic") == 0.0


def test_drift_by_ultra_measures_the_speakers_that_can_still_hear_it(calib, monkeypatch, capsys):
    # A speaker whose codec stops before 18 kHz must not cost the sweep the
    # ones that DO carry it.
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [0.50, 0.42, None])
    ms = calib["_drift_by_ultra"](
        "combined", [("wired", 0), ("bt", 100), ("deaf", 0)], "mic")
    assert ms is not None
    assert abs(ms - 20.0) < 1.0, ms
    out = capsys.readouterr().out
    # And it says so rather than passing off a partial room as a whole one.
    assert "DRIFT_PARTIAL 1" in out
    assert "DRIFT_DEAF deaf" in out


def test_a_round_that_missed_somebody_is_retried_louder(calib, monkeypatch):
    """One level cannot serve a Bluetooth speaker at 98 % and a wired one at
    60 %. The ladder is climbed by the ROUND, never by one member: a verdict
    built from two members heard in two different captures would carry two
    different capture starts."""
    levels = []

    def fake(members, wav, mic, trim, slot_seconds=None):
        levels.append(trim)
        if trim <= calib["ULTRA_LEVEL_STEPS"][0]:
            return [None, 0.62]
        return [0.50, 0.62]

    monkeypatch.setitem(calib, "_shared_round", fake)
    ms = calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)], "mic")
    assert ms is not None and abs(ms - 120.0) < 1.0, ms
    assert levels[0] == calib["ULTRA_LEVEL_STEPS"][0], levels
    assert levels[1] > levels[0], levels


def test_rounds_that_never_settle_say_unsteady_not_deaf(calib, monkeypatch, capsys):
    """Heard every time, never twice the same. DEAF shelves a speaker for the
    life of the group; unsteady is a property of the moment and must not."""
    seq = [[0.50, 0.62], [0.50, 0.72], [0.50, 0.82], [0.50, 0.92]]
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: seq.pop(0))
    assert calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)],
                                    "mic") is None
    out = capsys.readouterr().out
    assert "DRIFT_UNSTEADY" in out
    assert "DRIFT_DEAF" not in out


def test_a_stalled_player_costs_its_slot_not_the_schedule(calib, monkeypatch):
    """A wedged sink used to hold a blocking paplay for its full 5 s timeout,
    pushing every later member ~3 s past its own slot while the extractor
    kept searching on schedule: the stalled member's NEIGHBOURS were the ones
    that went unheard, and in a two-speaker room that shelved the healthy one
    and retired the whole check. The plays are fired, not waited on — the
    schedule belongs to the clock, never to the sinks."""
    class Clock:
        def __init__(self):
            self.t = 1000.0

        def monotonic(self):
            return self.t

        def sleep(self, s):
            self.t += max(0.0, s)

    clock = Clock()
    launches, procs = [], []

    class Proc:
        def __init__(self):
            self.dead = False

        def poll(self):
            return 0 if self.dead else None

        def kill(self):
            self.dead = True

        def terminate(self):
            self.dead = True

        def send_signal(self, sig):
            self.dead = True

        def wait(self, timeout=None):
            self.dead = True
            return 0

    class Sub:
        DEVNULL = -3
        PIPE = -1

        class TimeoutExpired(Exception):
            pass

        def Popen(self, argv, **kw):
            p = Proc()
            procs.append(p)
            if argv and argv[0] == "paplay":
                launches.append(clock.t)   # this player never exits
            return p

        def run(self, argv, **kw):
            class R:
                stdout = ""
                stderr = ""
                returncode = 1
            return R()

    monkeypatch.setitem(calib, "time", clock)
    monkeypatch.setitem(calib, "subprocess", Sub())
    got = calib["_shared_round"]([("wedged", 0), ("healthy", 0)],
                                 "u.wav", "mic", 0.1)
    slot = calib["ULTRA_SLOT_SECONDS"]
    want = [calib["PLAY_DELAY"], calib["PLAY_DELAY"] + slot]
    assert [round(t - 1000.0, 3) for t in launches] \
        == [round(w, 3) for w in want], launches
    # The capture holds nothing, but nobody's slot moved.
    assert got == [None, None]
    # And every player is reaped, wedged or not.
    assert all(p.dead for p in procs)


def test_a_member_short_of_rounds_is_not_deaf(calib, monkeypatch, capsys):
    """DEAF shelves a speaker for the life of the group, so it means "never
    heard in ANY round" — not "short of the three steady readings a verdict
    needs". The quiet-first ladder makes that gap ordinary: a member that
    wants the louder rung misses round one and answers every round after,
    holding two readings when the steady pair verdicts and the loop breaks."""
    seq = [[0.50, 0.62, None], [0.50, 0.62, 0.55],
           [0.50, 0.62, 0.55], [0.50, 0.62, 0.55]]
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: seq.pop(0))
    ms = calib["_drift_by_ultra"](
        "combined", [("wired", 0), ("bt", 0), ("late", 0)], "mic")
    assert ms is not None
    out = capsys.readouterr().out
    assert "DRIFT_DEAF" not in out
    # Outside the verdict is still outside the measurement, and says so.
    assert "DRIFT_PARTIAL 1" in out


def test_a_round_that_heard_nobody_blames_nobody(calib, monkeypatch, capsys):
    """Every speaker silent at once is the CAPTURE's testimony, not the
    room's: a microphone whose processing rolls off before 18 kHz reads
    exactly like both speakers going deaf together, and shelving them on
    that evidence killed the check for the session — passive road included,
    because the caller stops probing below two hearing members."""
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [None, None])
    assert calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)],
                                    "mic") is None
    out = capsys.readouterr().out
    assert "DRIFT_DEAF" not in out
    assert "DRIFT_UNSTEADY" not in out


def test_a_muted_member_sits_the_check_out(calib, monkeypatch):
    """A muted speaker comes back as silence however healthy it is, and
    silence reads as deafness — the life-of-the-group shelf. The listener
    who mutes one leg for a phone call keeps both legs watched: the check
    just waits for a room it can actually hear."""
    monkeypatch.setitem(calib, "_mute_states", lambda sinks: {"bt": True})
    called = []
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None:
                        called.append(1) or [0.5, 0.6])
    assert calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)],
                                    "mic") is None
    assert not called


def test_a_mute_landing_mid_probe_is_not_deafness(calib, monkeypatch, capsys):
    """The entry check clears a member muted BEFORE the probe, but a mute
    landing seconds into the ~20 s measurement leaves the same total
    silence — and the shelf it used to earn lasts the life of the group.
    The verdict reads the mutes again before convicting: muted now explains
    silent throughout."""
    calls = []

    def mutes(sinks):
        calls.append(list(sinks))
        return {} if len(calls) == 1 else {"bt": True}
    monkeypatch.setitem(calib, "_mute_states", mutes)
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [0.5, None])
    assert calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)],
                                    "mic") is None
    out = capsys.readouterr().out
    assert "DRIFT_DEAF" not in out, out
    assert len(calls) >= 2, calls          # the second look actually happened


def test_the_verdict_road_takes_the_same_second_look(calib, monkeypatch, capsys):
    """Same rule where a verdict DID form: the member the pair left behind
    is only deaf if it is not simply muted right now."""
    calls = []

    def mutes(sinks):
        calls.append(list(sinks))
        return {} if len(calls) == 1 else {"late": True}
    monkeypatch.setitem(calib, "_mute_states", mutes)
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [0.50, 0.62, None])
    ms = calib["_drift_by_ultra"]("combined",
                                  [("wired", 0), ("bt", 0), ("late", 0)], "mic")
    assert ms is not None
    out = capsys.readouterr().out
    assert "DRIFT_DEAF" not in out, out
    # Outside the measurement is still outside the measurement.
    assert "DRIFT_PARTIAL 1" in out


def test_verify_names_the_muted_and_refuses_a_one_speaker_verdict(calib, monkeypatch, capsys):
    """A muted member's silence through the deployed path reads exactly like
    a dead route, and PARTIAL under the sweep is the life-of-the-group
    shelf. The verify sits it out by name — and with one survivor there is
    nothing left to compare, which is not a verdict."""
    monkeypatch.setitem(calib, "signal",
                        types.SimpleNamespace(signal=lambda *a: None, SIGTERM=15))
    monkeypatch.setitem(calib, "_start_leash", lambda: None)
    monkeypatch.setitem(calib, "_mute_states", lambda sinks: {"bt": True})
    calib["cmd_verify"](["combined", "mic", "wired", "bt"])
    out = capsys.readouterr().out
    assert "VERIFY_MUTED bt" in out, out
    assert "VERIFY_FAIL members muted" in out, out
    assert "VERIFY_PARTIAL" not in out, out


def test_verify_measures_only_the_members_that_can_answer(calib, monkeypatch, capsys):
    """With enough speakers left the check runs END TO END without the muted
    one: it is named, never measured, never filed as PARTIAL — and it stays
    inside the isolation, so a mute lifted mid-run cannot leak its late copy
    of the stimulus into everyone else's capture."""
    monkeypatch.setitem(calib, "signal",
                        types.SimpleNamespace(signal=lambda *a: None, SIGTERM=15))
    monkeypatch.setitem(calib, "_start_leash", lambda: None)
    monkeypatch.setitem(calib, "time", types.SimpleNamespace(sleep=lambda s: None))
    monkeypatch.setitem(calib, "_mute_states", lambda sinks: {"bt": True})
    monkeypatch.setitem(calib, "_resolve_mic", lambda m: (m, ""))
    monkeypatch.setitem(calib, "make_ultra", lambda p: None)
    monkeypatch.setitem(calib, "make_click", lambda p: None)
    monkeypatch.setitem(calib, "click_template", lambda: None)
    monkeypatch.setitem(calib, "_ultra_allowed", lambda: True)
    monkeypatch.setitem(calib, "_raw_arrival_ultra",
                        lambda s, w, mic, seconds=None, trim=None: 0.5)
    muted_sets = []
    monkeypatch.setitem(calib, "_set_mutes",
                        lambda sinks, muted: muted_sets.append((list(sinks), muted)))
    calib["cmd_verify"](["combined", "mic", "wired", "bt", "aux"])
    out = capsys.readouterr().out
    assert "VERIFY_MUTED bt" in out, out
    assert "VERIFY_OK" in out, out
    assert "VERIFY_PARTIAL" not in out, out
    assert "VERIFY_LAG bt" not in out, out
    assert "VERIFY_LAG wired 0" in out, out
    # Every isolation round re-asserts the sat-out member's silence.
    isolations = [s for s, muted in muted_sets if muted and len(s) > 1]
    assert isolations, muted_sets
    assert all("bt" in s for s in isolations), muted_sets


def test_verify_asks_again_before_convicting_a_mid_run_mute(calib, monkeypatch, capsys):
    """The entry check cannot see a mute that lands during the ~half-minute
    a member's own measurement takes. Total silence then read as PARTIAL —
    the life-of-the-group shelf — for a speaker whose only fault was a
    phone call. The conviction site now asks the mutes again: the member
    sits out by name and the rest of the room still gets its verdict."""
    monkeypatch.setitem(calib, "signal",
                        types.SimpleNamespace(signal=lambda *a: None, SIGTERM=15))
    monkeypatch.setitem(calib, "_start_leash", lambda: None)
    monkeypatch.setitem(calib, "time", types.SimpleNamespace(sleep=lambda s: None))
    monkeypatch.setitem(calib, "_resolve_mic", lambda m: (m, ""))
    monkeypatch.setitem(calib, "make_ultra", lambda p: None)
    monkeypatch.setitem(calib, "make_click", lambda p: None)
    monkeypatch.setitem(calib, "click_template", lambda: None)
    monkeypatch.setitem(calib, "_ultra_allowed", lambda: True)
    # Nobody muted at entry; "bt" goes silent right after.
    entry = {"seen": False}

    def mutes(sinks):
        if not entry["seen"]:
            entry["seen"] = True
            return {}
        return {"bt": True}
    monkeypatch.setitem(calib, "_mute_states", mutes)
    state = {"member": None}

    def set_mutes(sinks, muted):
        if muted and len(sinks) > 1:
            state["member"] = ({"wired", "bt", "aux"} - set(sinks)).pop()
    monkeypatch.setitem(calib, "_set_mutes", set_mutes)
    monkeypatch.setitem(calib, "_raw_arrival_ultra",
                        lambda s, w, mic, seconds=None, trim=None:
                        None if state["member"] == "bt" else 0.5)
    calib["cmd_verify"](["combined", "mic", "wired", "bt", "aux"])
    out = capsys.readouterr().out
    assert "VERIFY_MUTED bt" in out, out
    assert "VERIFY_PARTIAL" not in out, out
    assert "VERIFY_OK" in out, out
    assert "VERIFY_LAG bt" not in out, out


def test_a_leaked_isolation_mute_is_repaired_not_blamed_on_the_listener(calib, monkeypatch, capsys):
    """_set_mutes is best-effort: a pactl wedged on a drowsy sink can leave
    OUR isolation mute standing. Convicting that as the listener's mute
    would keep the speaker silenced past every safety net — the last state
    the listener's hand showed tells the two stories apart."""
    monkeypatch.setitem(calib, "signal",
                        types.SimpleNamespace(signal=lambda *a: None, SIGTERM=15))
    monkeypatch.setitem(calib, "_start_leash", lambda: None)
    monkeypatch.setitem(calib, "time", types.SimpleNamespace(sleep=lambda s: None))
    monkeypatch.setitem(calib, "_resolve_mic", lambda m: (m, ""))
    monkeypatch.setitem(calib, "make_ultra", lambda p: None)
    monkeypatch.setitem(calib, "make_click", lambda p: None)
    monkeypatch.setitem(calib, "click_template", lambda: None)
    monkeypatch.setitem(calib, "_ultra_allowed", lambda: True)

    # The listener never muted anything: the entry read and every
    # isolation read say unmuted. Only the conviction-time read of the
    # lone member shows the mute our restore failed to lift.
    def mutes(sinks):
        return {"bt": True} if list(sinks) == ["bt"] else {}
    monkeypatch.setitem(calib, "_mute_states", mutes)
    state = {"member": None}
    repairs = []

    def set_mutes(sinks, muted):
        if muted and len(sinks) > 1:
            state["member"] = ({"wired", "bt", "aux"} - set(sinks)).pop()
        if not muted:
            repairs.append(list(sinks))
    monkeypatch.setitem(calib, "_set_mutes", set_mutes)
    monkeypatch.setitem(calib, "_raw_arrival_ultra",
                        lambda s, w, mic, seconds=None, trim=None:
                        None if state["member"] == "bt" else 0.5)
    calib["cmd_verify"](["combined", "mic", "wired", "bt", "aux"])
    out = capsys.readouterr().out
    assert "VERIFY_UNSTEADY bt" in out, out
    assert "VERIFY_MUTED" not in out, out
    assert ["bt"] in repairs, repairs


def test_one_speaker_answering_alone_is_never_called_deaf(calib, monkeypatch, capsys):
    """A round needs TWO members to hold a difference, so a room where only
    one answers produces no usable round at all — and reading deafness off
    the usable rounds then called the speaker that answered every single time
    deaf as well. One DRIFT_DEAF shelves a speaker for the life of the group,
    which is the whole automatic road gone for the one output that works.

    This case had a test before the shared capture was written and lost it in
    the rewrite; the defect walked straight through the gate behind it.
    """
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [0.5, None])
    assert calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)],
                                    "mic") is None
    out = capsys.readouterr().out
    assert "DRIFT_DEAF bt" in out, out
    assert "DRIFT_DEAF wired" not in out, out
    # Nor unsteady: there was nothing to be unsteady against.
    assert "DRIFT_UNSTEADY" not in out, out


def test_the_check_spends_a_bounded_number_of_captures(calib, monkeypatch):
    """Every capture is time the guard has to have budgeted for."""
    spent = []
    monkeypatch.setitem(
        calib, "_shared_round",
        lambda m, w, mic, trim, slot_seconds=None: spent.append(1) or [None, None])
    calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 0)], "mic")
    assert len(spent) <= calib["ULTRA_ROUND_TRIES"], len(spent)


def test_drift_by_ultra_needs_two_speakers_to_have_a_spread(calib, monkeypatch):
    called = []
    monkeypatch.setitem(
        calib, "_shared_round",
        lambda m, w, mic, trim, slot_seconds=None: called.append(1) or [0.5])
    assert calib["_drift_by_ultra"]("combined", [("only_one", 0)], "mic") is None
    # And it did not bother the microphone to find that out.
    assert called == []



def test_ultra_allowed_follows_the_settings_switch(calib, monkeypatch):
    monkeypatch.delenv("ONAIR_NO_ULTRA", raising=False)
    assert calib["_ultra_allowed"] is not None
    assert calib["_ultra_allowed"]() is True
    monkeypatch.setenv("ONAIR_NO_ULTRA", "1")
    assert calib["_ultra_allowed"]() is False
    # Anything other than the exact opt-out leaves the sweep on: a stray
    # empty value must not silently turn measurement audible again.
    monkeypatch.setenv("ONAIR_NO_ULTRA", "")
    assert calib["_ultra_allowed"]() is True


def test_drift_by_ultra_calls_a_COMPENSATED_room_in_tune(calib, monkeypatch):
    # The sweep is aimed straight at the member sink, so it goes round the
    # loopback that carries the compensation and times the bare hardware.
    # A room in perfect tune therefore shows the FULL spread the
    # calibration exists to cancel, and reporting that as drift would set
    # an automatic re-verify going every six minutes on a room with
    # nothing wrong with it.
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [0.50, 0.35])
    # The Bluetooth speaker lands 150 ms AHEAD of the wired one in
    # hardware, which is precisely why the calibration holds it back by
    # 150 — so the two reach the ear together and the drift is nil.
    ms = calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 150)], "mic")
    assert ms is not None
    assert abs(ms) < 1.0, ms


def test_drift_by_ultra_sees_a_speaker_that_has_since_wandered(calib, monkeypatch):
    # Same room, same stored lag, but the Bluetooth link now buffers 40 ms
    # more than it did at calibration time. THAT is drift, and it is what
    # the check exists to catch.
    monkeypatch.setitem(calib, "_shared_round",
                        lambda m, w, mic, trim, slot_seconds=None: [0.50, 0.39])
    ms = calib["_drift_by_ultra"]("combined", [("wired", 0), ("bt", 150)], "mic")
    assert abs(ms - 40.0) < 1.0, ms


def test_drift_members_pairs_sinks_with_their_lags(calib):
    assert calib["_drift_members"](["a", "0", "b", "150"]) == [("a", 0.0), ("b", 150.0)]
    # A negative lag is legitimate — the verify's corrections can push one.
    assert calib["_drift_members"](["a", "-20"]) == [("a", -20.0)]
    # Anything malformed yields nothing, which drops the probe onto the
    # passive road rather than letting it do arithmetic on a guess.
    assert calib["_drift_members"](["a", "0", "b"]) == []
    assert calib["_drift_members"](["a", "not-a-number"]) == []
    assert calib["_drift_members"]([]) == []

def test_ultra_arrival_times_the_sweep_not_the_wake_up_leader(calib, tmp_path):
    """The stimulus is a 350 ms wake-up tone, a beat of silence, then the
    60 ms sweep. Both live in the same band, so timing the FIRST thing that
    crosses the gate times the leader — and the leader fades in over 50 ms,
    which makes the moment it crosses depend on how loud it arrived. That
    slide went straight into the stored per-speaker delay: the quieter
    speaker was credited with lag it did not have. Measured before the fix,
    the reported arrival moved 46 ms across the levels a wired speaker and a
    Bluetooth one really differ by; the sweep's own 4 ms edge moves 10."""
    rate = calib["RATE"]
    lead_n = int(rate * calib["LEADER_SECONDS"])
    gap_n = int(rate * calib["ULTRA_GAP_SECONDS"])
    chirp = calib["ultra_chirp"]()
    ramp = rate * 0.05
    at = 0.6

    def capture(scale, path):
        s = [0] * int(rate * at)
        for i in range(lead_n):
            env = min(1.0, i / ramp)
            s.append(int(calib["ULTRA_AMP"] * 0.35 * env * scale
                         * math.sin(2.0 * math.pi * calib["ULTRA_LEADER_HZ"]
                                    * i / rate)))
        s += [0] * gap_n
        s += [int(calib["ULTRA_AMP"] * scale * v) for v in chirp]
        s += [0] * int(rate * 1.2)
        write_wav(path, [max(-32768, min(32767, v)) for v in s], rate)
        return path

    sweep_at = at + calib["LEADER_SECONDS"] + calib["ULTRA_GAP_SECONDS"]
    seen = []
    for scale in (1.0, 0.5, 0.25, 0.12, 0.06):
        p = capture(scale, tmp_path / ("u%s.wav" % scale))
        got = calib["ultra_arrival"](*calib["read_mono"](str(p)))
        assert got is not None, "the sweep must be found at scale %s" % scale
        # The sweep, not the leader 400 ms earlier.
        assert abs(got[0] - sweep_at) < 0.05, (scale, got[0], sweep_at)
        seen.append(got[0])
    # And the answer must barely move with level — that is the whole point.
    assert (max(seen) - min(seen)) < 0.020, seen

    # Faint but still there: the detector now reaches a sweep twenty-five
    # times quieter than the loudest one above, and it times it in the same
    # place rather than sliding toward the leader.
    p = capture(0.04, tmp_path / "u_faint.wav")
    faint = calib["ultra_arrival"](*calib["read_mono"](str(p)))
    assert faint is not None
    assert abs(faint[0] - sweep_at) < 0.02, faint[0]

    # Below the band's absolute floor there is nothing to measure, and a
    # guess would go straight into a stored delay. Saying nothing is the
    # honest result.
    p = capture(0.005, tmp_path / "u_gone.wav")
    assert calib["ultra_arrival"](*calib["read_mono"](str(p))) is None


def test_ultra_play_volume_compensates_for_a_quiet_group(calib):
    """The sweep is played into the group's null sink, so whatever that
    sink's volume leaves behind is all the loopbacks can carry. Measured
    through a group left at 35 %: the check failed twice on speakers that
    carry the band perfectly when addressed directly."""
    vol = calib["ultra_play_volume"]
    amp = calib["ULTRA_AMP"] / 32767.0
    trim = calib["ULTRA_LEVEL_TRIM"]

    def acoustic(fraction):
        """What actually leaves the speaker: the stream gain and the sink's
        own gain are both CUBIC, and they multiply."""
        return amp * (vol(fraction) / 65536.0) ** 3 * fraction ** 3

    # The whole point of compensating: the same sound leaves the speaker
    # whatever the listener has the room at. Anything the cap does not bind.
    for fraction in (2.0, 1.0, 0.9, 0.6, 0.4):
        assert abs(acoustic(fraction) - amp * trim) < 1e-4, fraction
    # And that level is a TENTH of what the detector was tuned at. Measured
    # with a microphone in the room it was tuned in: the stimulus arrived at
    # -11 dBFS against that band's own floor of -71 and the listener's music
    # at -29 — sixty decibels of margin where ULTRA_MIN_RATIO asks for six,
    # and eighteen decibels louder than the programme. That is why an
    # 18 kHz tone got heard at all.
    assert abs(acoustic(1.0) - amp / 10.0) < 1e-4
    # Below that the anti-clipping cap takes over and the level DOES fall —
    # a very quiet sink cannot be compensated without pushing the rail.
    assert acoustic(0.2) < amp * trim
    # Nothing readable: assume the worst and play at the cap.
    assert vol(None) == calib["ULTRA_PLAY_MAX"]
    assert vol(0) == calib["ULTRA_PLAY_MAX"]
    # The cap has to leave room for the MUSIC, not merely clear the rail on
    # its own. This line used to read "< 1.0", which the old 112000 passed at
    # 0.914 — and then the programme it plays over put it through the rail:
    # measured off this desk's sink monitor, music peaked at 0.31 and the
    # stimulus periods pinned 153 samples at 32768. What a listener heard was
    # not the stimulus but its clipping folded back down (48000 - 3*18050 =
    # 6.15 kHz, at -25 dBFS against the music's own 1 kHz at -60).
    loudest = (calib["ULTRA_PLAY_MAX"] / 65536.0) ** 3 * (calib["ULTRA_AMP"] / 32767.0)
    assert loudest <= calib["ULTRA_PLAY_CEILING"] + 1e-3, loudest
    assert loudest + 0.31 < 1.0, loudest
    # Cubic, and derived from ULTRA_AMP — a PA number typed by hand drifts
    # silently the moment the stimulus amplitude moves.
    assert calib["ULTRA_PLAY_MAX"] != 112000


def test_the_level_ladder_starts_quiet_and_has_somewhere_to_climb(calib):
    """One level cannot serve every speaker in a room, and the failure is
    not symmetric: too loud is heard, too quiet SHELVES a speaker for the
    life of the group. Measured here through the live group with music
    playing — 0.1 lost the wired output in 2 runs of 4, 0.3 and 1.0 in none
    of seven — so the check starts quiet and climbs only for a member that
    did not answer.
    """
    steps = calib["ULTRA_LEVEL_STEPS"]
    vol = calib["ultra_play_volume"]
    # Quietest first: a member that answers at once never gets louder.
    assert steps[0] == calib["ULTRA_LEVEL_TRIM"]
    assert list(steps) == sorted(steps), steps
    assert len(steps) >= 2, "a ladder with one rung cannot climb"
    # It has to reach the level the detector was originally tuned at, or a
    # speaker that needs it stays unheard however many retries it gets.
    assert steps[-1] == 1.0
    # The retries it rides are what bounds the guard budget: as many rungs
    # as tries, so a silent member costs no more plays than it used to.
    assert len(steps) <= calib["ULTRA_REPEATS"]
    # The decision "can this chain carry 18 kHz at all" is NOT taken at the
    # quietest rung — that is how a room that measures fine got refused.
    assert calib["ULTRA_LEVEL_WARMUP"] > steps[0]
    assert calib["ULTRA_LEVEL_WARMUP"] in steps
    # Louder rung, louder stream, and the anti-clipping cap still holds.
    assert vol(1.0, steps[0]) < vol(1.0, steps[-1])
    for s in steps:
        assert vol(0.05, s) <= calib["ULTRA_PLAY_MAX"], s


class _FakeRecorder:
    """Stands in for a pw-record Popen: records what was asked of it, and can
    refuse to die on the first ask the way a wedged capture does."""

    def __init__(self, wedged=False):
        self.wedged = wedged
        self.terminated = False
        self.killed = False
        self.waits = 0

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        self.waits += 1
        if self.wedged and not self.killed:
            raise subprocess.TimeoutExpired("pw-record", timeout or 0)
        return 0


def test_a_recorder_is_always_stopped_and_always_reaped(calib):
    """A recorder left running holds the microphone for the rest of the
    session, and one killed without a wait leaves a zombie per capture."""
    stop = calib["_stop_recorder"]

    rp = _FakeRecorder()
    stop(rp)
    assert rp.terminated
    assert rp.waits == 1
    assert not rp.killed

    wedged = _FakeRecorder(wedged=True)
    stop(wedged)
    assert wedged.terminated
    assert wedged.killed
    # Twice: the ask that timed out, and the reap after the kill.
    assert wedged.waits == 2

    # Called from a finally that never got as far as spawning anything.
    stop(None)


def test_every_capture_stops_its_recorder_from_a_finally(calib):
    """The leash's SIGTERM lands as SystemExit on whatever line is running,
    and these functions spend most of their lives asleep waiting for a
    recording to fill. Stopping the recorder only on the happy path left
    `pw-record` holding the microphone after a killed run — the leash covers
    the python, never its children.

    Structural on purpose: the bug was not in what the teardown DID, it was
    in which paths reached it."""
    src = (UI_DIR / "calibrate.py").read_text()
    tree = ast.parse(src)
    wanted = {"_capture_alive", "_room_is_loud", "_record_one", "_pick_best_mic"}
    found = set()
    for node in ast.walk(tree):
        if not (isinstance(node, ast.FunctionDef) and node.name in wanted):
            continue
        for inner in ast.walk(node):
            if not isinstance(inner, ast.Try):
                continue
            for stmt in inner.finalbody:
                for call in ast.walk(stmt):
                    if (isinstance(call, ast.Call)
                            and isinstance(call.func, ast.Name)
                            and call.func.id == "_stop_recorder"):
                        found.add(node.name)
    assert found == wanted, "no finally-time _stop_recorder in: %s" % (wanted - found)


def test_the_isolation_gives_back_the_mutes_it_borrowed(calib, monkeypatch):
    """Unmuting everything at the end is only right if nothing was muted to
    begin with. A speaker the listener had silenced on purpose came back on
    after a check it had no part in."""
    state = {"tv": True, "desk": False}
    calls = []

    class _Result:
        def __init__(self, out):
            self.stdout = out

    def fake_run(argv, **kw):
        calls.append(list(argv))
        if argv[1] == "get-sink-mute":
            return _Result("Mute: %s\n" % ("yes" if state[argv[2]] else "no"))
        if argv[1] == "set-sink-mute":
            state[argv[2]] = argv[3] == "1"
        return _Result("")

    monkeypatch.setitem(calib, "subprocess",
                        types.SimpleNamespace(run=fake_run,
                                              DEVNULL=subprocess.DEVNULL,
                                              TimeoutExpired=subprocess.TimeoutExpired))
    sinks = ["tv", "desk"]
    was = calib["_mute_states"](sinks)
    assert was == {"tv": True, "desk": False}
    calib["_set_mutes"](sinks, True)
    assert state == {"tv": True, "desk": True}
    calib["_restore_mutes"](was)
    assert state == {"tv": True, "desk": False}


def test_a_sink_whose_mute_cannot_be_read_is_left_alone(calib, monkeypatch):
    """Absent from the map means absent from the restore — the one answer
    that cannot be wrong about a sink nobody could ask."""
    class _Result:
        stdout = "Failure: No such entity\n"

    monkeypatch.setitem(calib, "subprocess",
                        types.SimpleNamespace(run=lambda *a, **k: _Result(),
                                              TimeoutExpired=subprocess.TimeoutExpired))
    assert calib["_mute_states"](["ghost"]) == {}
