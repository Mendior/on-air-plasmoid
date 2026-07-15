# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""calibrate.py signal path: the click generator and the peak detector that
the microphone sync calibration stands on. A detector that fires on noise —
or misses a real click — turns into a wrong per-device delay in the user's
config, so both directions are pinned here."""
import ast
import math
import pathlib
import shutil
import struct
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
    ns = {"math": math, "shutil": shutil, "struct": struct, "wave": wave}
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


def test_make_click_is_short_and_bounded(calib, tmp_path):
    p = tmp_path / "click.wav"
    calib["make_click"](str(p))
    with wave.open(str(p), "rb") as w:
        assert w.getframerate() == calib["RATE"]
        assert w.getnchannels() == 1
        n = w.getnframes()
        raw = w.readframes(n)
    assert n == int(calib["RATE"] * 0.010)
    peak = max(abs(struct.unpack_from("<h", raw, i * 2)[0]) for i in range(n))
    assert 10000 < peak <= 24000  # audible but never clipping


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


def test_peak_of_rejects_too_short_recording(calib, tmp_path):
    p = tmp_path / "short.wav"
    write_wav(p, [0] * int(calib["RATE"] * 0.1), calib["RATE"])
    assert calib["peak_of"](str(p)) is None


def test_median_takes_the_middle(calib):
    assert calib["median"]([3.0, 1.0, 2.0]) == 2.0
    assert calib["median"]([5.0, 1.0]) == 5.0  # upper-middle on even counts


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
