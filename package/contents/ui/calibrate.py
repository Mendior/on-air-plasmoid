# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Microphone sync calibration for On Air.

Measures how far a Bluetooth speaker trails a wired reference by playing a
short click through each sink and timing, with the computer's microphone,
when the sound actually arrives. Two one-sink measurements are taken with
identical plumbing, so every constant (mic path, recording start, paplay
spawn) cancels in the difference — only the speakers' real acoustic lag
remains.

Every click's peak AMPLITUDE at the microphone is measured along with its
arrival time — with all sinks parked at the same volume for the run, the
amplitude ratio between speakers is their real loudness difference at the
listening position, which the widget turns into per-speaker balance trims
(the same trick Sonos sells as Trueplay level matching). Extra sinks beyond
the two timed ones are clicked briefly for their level alone.

Usage: calibrate.py <wired_sink_name> <bt_sink_name> [mic_source] [extra_sink...]
Prints: CALIB_LVL <sink> <amp>   per sink that was heard (peak, int16 scale)
        CALIB_OK <ms>            on success (ms = how much the BT sink trails)
        CALIB_FAIL <reason>
Always exits 0 — a failure is a sentinel, not a crash.
"""
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave

RATE = 48000
CLICK_HZ = 2200.0
CLICK_SECONDS = 0.010
CLICK_REPEATS = 4          # median over several clicks rejects room noise
LEVEL_REPEATS = 2          # extra sinks get two clicks — level AND timing
MAX_EXTRA_SINKS = 6        # keeps the whole run inside the widget's guard
RECORD_SECONDS = 1.9
PLAY_DELAY = 0.6           # recording warm-up before the click is played
ANALYSIS_SKIP = 0.4        # recording start carries a loud mic/AGC pop —
                           # found empirically, it decays for ~0.3 s and
                           # otherwise wins the peak search every time
MIN_SANE_MS = -100.0       # BT ahead of wired by >100 ms means a bad measure
MAX_SANE_MS = 900.0
CLIP_LEVEL = 32000         # |sample| at the int16 rail: the mic is saturating
CLIP_COUNT = 4             # one grazed rail can be honest; a run of them lies
LEADER_SECONDS = 0.35      # quiet hum before the burst: wakes a sleeping
LEADER_HZ = 180.0          # Bluetooth link and opens the speaker's own noise
LEADER_AMP = 900           # gate BEFORE the moment being measured — a JBL
                           # measured cold swallowed clicks whole or shifted
                           # them by hundreds of ms while the link spun up
LEADER_GAP_SECONDS = 0.05


def click_template():
    """The burst's unit-amplitude shape, shared by the WAV writer and the
    matched filter — the filter must correlate against exactly what was
    played, or its sub-sample precision is fiction."""
    n = int(RATE * CLICK_SECONDS)
    return [0.5 * (1.0 - math.cos(2.0 * math.pi * i / n))
            * math.sin(2.0 * math.pi * CLICK_HZ * i / RATE)
            for i in range(n)]


def make_click(path):
    """The measurement stimulus: a third of a second of quiet 180 Hz hum, a
    beat of silence, then the 10 ms raised-cosine burst at 2.2 kHz — sharp
    but speaker-safe. Only the burst is measured; the hum is far too quiet
    (and the wrong shape) to move the matched filter or the peak gate, it
    exists so the sound PATH is already awake when the burst rides it."""
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        ramp = RATE * 0.05  # soft ramp-in, no pop of its own
        for i in range(int(RATE * LEADER_SECONDS)):
            env = min(1.0, i / ramp)
            frames += struct.pack("<h", int(LEADER_AMP * env
                                            * math.sin(2.0 * math.pi * LEADER_HZ * i / RATE)))
        frames += b"\x00\x00" * int(RATE * LEADER_GAP_SECONDS)
        for v in click_template():
            frames += struct.pack("<h", int(24000 * v))
        w.writeframes(bytes(frames))


def read_mono(path):
    with wave.open(path, "rb") as w:
        ch, sw, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    if sw != 2:
        return None, rate
    total = len(raw) // (2 * ch)
    samples = [0] * total
    for i in range(total):
        samples[i] = struct.unpack_from("<h", raw, (i * ch) * 2)[0]
    return samples, rate


def _xcorr_refine(window, coarse_i, tpl, half_s=0.015):
    """Sub-sample click arrival via a matched filter around the coarse peak.

    Correlates the recording with the KNOWN burst shape in a ±half_s
    neighbourhood of the amplitude peak and takes the correlation maximum,
    plus a parabolic fit between neighbouring lags for the sub-sample
    fraction. The magnitude is used so a polarity-inverting mic/speaker
    chain cannot flip the answer. The bare amplitude argmax used to wander
    by whole samples between runs in room noise; the filter integrates over
    all 480 template samples (~22x processing gain) and holds still.
    Returns (float sample index in `window`'s frame — aligned to the burst
    peak so the number means what the old detector's did — and the
    correlation peak's ratio over the window's median correlation: a true
    burst towers over it, a random thump does not).
    """
    half = int(half_s * RATE)
    tn = len(tpl)
    lo = max(0, coarse_i - tn - half)
    hi = min(len(window) - tn, coarse_i + half)
    if hi <= lo:
        return float(coarse_i), 0.0
    corr = [0.0] * (hi - lo + 1)
    best_l, best_c = lo, -1.0
    for lag in range(lo, hi + 1):
        acc = 0.0
        for k in range(tn):
            acc += window[lag + k] * tpl[k]
        c = abs(acc)
        corr[lag - lo] = c
        if c > best_c:
            best_c, best_l = c, lag
    if best_c <= 0.0:
        return float(coarse_i), 0.0
    ci = best_l - lo
    cm = corr[ci - 1] if ci > 0 else 0.0
    cp = corr[ci + 1] if ci + 1 < len(corr) else 0.0
    denom = cm - 2.0 * best_c + cp
    frac = 0.0 if denom == 0.0 else max(-1.0, min(1.0, 0.5 * (cm - cp) / denom))
    tpl_peak = max(range(tn), key=lambda i: abs(tpl[i]))
    corr_med = sorted(corr)[len(corr) // 2]
    snr = best_c / corr_med if corr_med > 0 else 0.0
    return best_l + frac + tpl_peak, snr


def peak_of(path, tpl=None):
    """(seconds from start, peak amplitude, clipped?) of the click's arrival.

    Returns None when nothing click-like was heard — including when the
    recording itself is truncated or unreadable: one bad capture is one
    failed measurement, never a reason to abort the whole run (an escaped
    wave.Error used to do exactly that from an extra, level-only sink).

    The impulsiveness gate is unchanged from the shipped detector; when a
    template is given, the matched filter then refines WHERE the click sits
    to sub-sample precision. `clipped` reports mic saturation: a rail-flat
    burst still times fine, but its amplitude is a lie and must not feed
    the loudness matching.
    """
    try:
        samples, rate = read_mono(path)
    except Exception:
        return None
    if not samples:
        return None
    start = int(ANALYSIS_SKIP * rate)
    if start >= len(samples):
        return None
    window = samples[start:]
    best, best_i = 0, -1
    clipped = 0
    for i, s in enumerate(window):
        a = abs(s)
        if a >= CLIP_LEVEL:
            clipped += 1
        if a > best:
            best, best_i = a, i
    # A click is impulsive: it must stand far above the noise floor. The
    # floor is the MEDIAN |sample| of the window's opening stretch — before
    # the stimulus arrives — because webcam AGC scales the noise and the
    # click together: a mean over the whole window drifted with the leader
    # hum and an absolute-only threshold silently dropped every click from
    # the quieter speaker after a loud one had ducked the mic's gain.
    if best_i < 0:
        return None
    pos, snr = (float(best_i), 0.0)
    if tpl is not None:
        pos, snr = _xcorr_refine(window, best_i, tpl)
    # The noise floor is measured strictly BEFORE the stimulus began — the
    # burst position minus the leader hum and a margin — so neither the hum
    # nor the burst can inflate it. A recorder that started late (cold
    # spawn) can push the stimulus to the window's edge and leave no
    # pre-roll at all; the floor then falls back to the clamp.
    pre_end = best_i - int((LEADER_SECONDS + LEADER_GAP_SECONDS + 0.05) * rate)
    head = sorted(abs(s) for s in window[:pre_end]) if pre_end >= int(0.05 * rate) else []
    floor = head[len(head) // 2] if head else 60
    med_all = sorted(abs(s) for s in window)[len(window) // 2]
    # Measured on real hardware: after a loud speaker's series, webcam AGC
    # ducks the gain ~10x and the next speaker's clicks land around 800 —
    # 37x above their concurrent floor, unmistakably clicks. The absolute
    # bar only needs to reject quiet garbage in true silence; the ratios
    # carry the discrimination (the whole-window median guards against
    # steady noise when the pre-roll is missing).
    # A click through the DEPLOYED path is attenuated by the master volume
    # and can land under the absolute bar while being unmistakable to the
    # matched filter — a correlation peak towering over the window's median
    # (measured live: a real burst scores 15+, a random thump 2-3) vouches
    # for what raw amplitude cannot.
    if best < 600 and snr < 6.0:
        return None
    if best < 8 * max(floor, 60) or best < 4 * max(med_all, 1):
        return None
    return (start + pos) / rate, best, clipped >= CLIP_COUNT


def recorder_args(mic, rec):
    """The microphone capture command line.

    pw-record where PipeWire is native; parecord on plain PulseAudio — it
    ships in the same package as the paplay already used for the clicks, so
    the fallback costs no new dependency. Both finalize the WAV header on
    SIGTERM. parecord gets the sample format pinned because its default
    follows the device, and peak_of only reads 16-bit.
    """
    if shutil.which("pw-record"):
        args = ["pw-record", "--rate", str(RATE), "--channels", "1"]
        if mic:
            args += ["--target", mic]
        return args + [rec]
    args = ["parecord", "--rate=%d" % RATE, "--channels=1",
            "--format=s16le", "--file-format=wav"]
    if mic:
        args += ["--device=" + mic]
    return args + [rec]


def _record_one(sink, click, mic, rec, seconds=None):
    """One click through `sink` while the mic records into `rec` — the
    shared plumbing under both the calibration and the verify pass. The
    verify listens longer: a click riding the full deployed path (loopback
    buffering plus a Bluetooth link) can arrive most of a second after a
    direct one, and the default window cut its tail off."""
    rp = subprocess.Popen(recorder_args(mic, rec), stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
    try:
        time.sleep(PLAY_DELAY)
        t_play = time.monotonic()
        try:
            subprocess.run(["paplay", "--device", sink,
                            "--volume", "65536", click],
                           timeout=5, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            # A dying sink can hold paplay past its timeout. That is one
            # FAILED measurement of one sink ("nothing click-like heard"),
            # not a reason to abort the run — letting this escape used to
            # throw away an already-successful timing verdict because one
            # extra, level-only speaker wedged.
            pass
        window = RECORD_SECONDS if seconds is None else seconds
        time.sleep(max(0.0, window - (time.monotonic() - t_play)))
    finally:
        rp.terminate()
        try:
            rp.wait(timeout=2)
        except subprocess.TimeoutExpired:
            rp.kill()


def measure_once(sink, click, mic, tpl=None, seconds=None):
    """One click through `sink`, recorded from `mic`.

    Returns (arrival_seconds, peak_amplitude, clipped) or None when nothing
    click-like was heard.
    """
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        _record_one(sink, click, mic, rec, seconds)
        # Seconds between "told the sink to play" and "mic heard it". The
        # recording started PLAY_DELAY earlier, which is part of the constant
        # that cancels between the two sinks.
        return peak_of(rec, tpl)
    finally:
        try:
            os.unlink(rec)
        except OSError:
            pass


def median(values):
    s = sorted(values)
    return s[len(s) // 2]


def find_arrivals(window, tpl, max_peaks):
    """Distinct click arrivals in one recording, seconds within `window`.

    A 1 ms envelope pass finds candidate bursts (≥25 % of the loudest);
    a candidate must be the maximum of its FIXED ±8 ms neighbourhood —
    the old running-reference merge let a rising chain of small steps
    drag the anchor along and fuse spread-out arrivals into one, under-
    reporting the spread. The matched filter then refines each candidate
    and near-duplicates within 8 ms collapse. Arrivals closer than ~8 ms
    still fuse (bounded by the 10 ms burst), which for a sync check reads
    as 'together' — that is exactly why counting peaks can never prove
    every speaker played, and the verify pass checks presence separately.
    """
    block = int(RATE * 0.001)
    if len(window) < block * 2:
        return []
    env = []
    for b in range(0, len(window) - block, block):
        m = 0
        for i in range(b, b + block):
            a = abs(window[i])
            if a > m:
                m = a
        env.append(m)
    top = max(env)
    if top < 1200:
        return []
    thresh = max(1200, top * 0.25)
    cands = []
    n = len(env)
    for i, v in enumerate(env):
        if v < thresh:
            continue
        lo = max(0, i - 8)
        hi = min(n, i + 9)
        if v < max(env[lo:hi]):
            continue
        cands.append(i)
    cands = sorted(sorted(cands, key=lambda i: -env[i])[:max_peaks])
    out = []
    for i in cands:
        coarse = i * block
        lo2 = max(0, coarse - block)
        hi2 = min(len(window), coarse + 2 * block)
        ci = max(range(lo2, hi2), key=lambda k: abs(window[k]))
        # Tight refine window: the candidate is already sample-accurate,
        # and the default ±15 ms would reach a LOUDER neighbouring burst —
        # both candidates then refine onto the same arrival and the spread
        # collapses to zero.
        out.append(_xcorr_refine(window, ci, tpl, 0.003)[0] / RATE)
    out.sort()
    dedup = []
    for t in out:
        if dedup and (t - dedup[-1]) < 0.008:
            continue
        dedup.append(t)
    return dedup


def _set_mutes(sinks, muted):
    """Best-effort hardware mute for the verify's isolation — a missing
    pactl (test rig) just means the isolation is skipped."""
    for s in sinks:
        try:
            subprocess.run(["pactl", "set-sink-mute", s, "1" if muted else "0"],
                           timeout=3, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except Exception:
            pass


def cmd_verify(argv):
    """calibrate.py verify <combined_sink> <mic> <sink…> — the check-measure.

    Each speaker is measured ALONE, but through the LIVE combined sink —
    the others hardware-muted for two seconds — so every click rides the
    full deployed path: null sink, loopback delay, the device's own
    buffering, the Bluetooth link, the air. This is the path music takes
    and the one the listener's ears grade.

    The earlier design listened for overlapping arrivals in one shared
    recording, and it was optimistically blind twice over: in-sync
    arrivals fuse (uncountable), and a speaker much quieter at the mic
    slipped under the envelope threshold entirely — its arrival vanished
    and the spread read zero no matter how far out of step it really was.
    Field case: a Bluetooth speaker whose loopback buffering never showed
    up in the direct-click calibration read "spread 0" while trailing
    audibly. Sequential isolation has no such blind spot, and the
    recorder's spawn clock is stable enough to compare across consecutive
    captures (measured: ±1 ms over four spawns after the warm-up).

    Prints VERIFY_LAG <sink> <ms> per speaker (offset against the first),
    then VERIFY_OK <spread_ms>; VERIFY_PARTIAL <sink> when a speaker was
    not heard through the path (muted, off, dead route — the room is NOT
    confirmed); VERIFY_FAIL <reason> otherwise; always returns.
    """
    try:
        if len(argv) < 3:
            print("VERIFY_FAIL usage")
            return
        sink, mic = argv[0], argv[1]
        sinks = argv[2:2 + 8]
        click = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
        try:
            make_click(click)
            tpl = click_template()
            # The session's first recorder spawn starts capturing late and
            # would shift the first speaker's clock against the others.
            measure_once(sink, click, mic, tpl)
            arrivals = {}
            for member in sinks:
                others = [s for s in sinks if s != member]
                _set_mutes(others, True)
                try:
                    time.sleep(0.3)  # let the mutes land before the click
                    times = []
                    for _ in range(2):
                        m = measure_once(sink, click, mic, tpl, seconds=3.2)
                        if m is not None:
                            times.append(m[0])
                finally:
                    _set_mutes(others, False)
                if not times:
                    print("VERIFY_PARTIAL %s" % member)
                    return
                arrivals[member] = sum(times) / len(times)
            base = min(arrivals.values())
            for member in sinks:
                print("VERIFY_LAG %s %d" % (member,
                                            round((arrivals[member] - base) * 1000.0)))
            spread = (max(arrivals.values()) - base) * 1000.0
            print("VERIFY_OK %d" % max(0, round(spread)))
        finally:
            try:
                os.unlink(click)
            except OSError:
                pass
    except Exception as exc:  # a failure must be a sentinel, never a crash
        print("VERIFY_FAIL %s" % str(exc)[:120])


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "verify":
        cmd_verify(sys.argv[2:])
        return
    if len(sys.argv) < 3:
        print("CALIB_FAIL usage")
        return
    wired, bt = sys.argv[1], sys.argv[2]
    mic = sys.argv[3] if len(sys.argv) > 3 else ""
    extras = sys.argv[4:4 + MAX_EXTRA_SINKS]
    click = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        make_click(click)
        tpl = click_template()
        wired_times, bt_times = [], []
        amps = {wired: [], bt: []}
        clipped_sinks = {}

        def note(sink, m, times):
            if m is None:
                return
            t, amp, clipped = m
            if times is not None:
                times.append(t)
            # A saturated burst still times fine, but its amplitude is the
            # microphone's rail, not the speaker's loudness — it must never
            # feed the level matching.
            if clipped:
                clipped_sinks[sink] = True
            else:
                amps.setdefault(sink, []).append(amp)

        # One throwaway click before anything counts: the session's very
        # first recorder spawn starts capturing late (half a second observed
        # on real hardware) and would shift one measurement's clock against
        # every other. Then each sink is measured as a BURST — all its
        # clicks back to back — so a Bluetooth link stays in one power state
        # across the repeats instead of drifting through sniff-mode between
        # interleaved turns.
        measure_once(wired, click, mic, tpl)
        for _ in range(CLICK_REPEATS):
            note(wired, measure_once(wired, click, mic, tpl), wired_times)
        for _ in range(CLICK_REPEATS):
            note(bt, measure_once(bt, click, mic, tpl), bt_times)
        if len(wired_times) < 2:
            print("CALIB_FAIL no click heard from the wired speaker")
            return
        if len(bt_times) < 2:
            print("CALIB_FAIL no click heard from the Bluetooth speaker")
            return
        lag_ms = (median(bt_times) - median(wired_times)) * 1000.0
        if not (MIN_SANE_MS < lag_ms < MAX_SANE_MS):
            print("CALIB_FAIL implausible result %.0f ms" % lag_ms)
            return
        # Extra speakers get a couple of clicks each — and since every click
        # is timed anyway, their lag against the wired reference rides along
        # as CALIB_XLAG: a USB DAC or an HDMI TV in the group is off by its
        # own real amount, not by an assumed zero. One that stays silent
        # simply gets no lines; the timing verdict above is already in the
        # bag either way.
        wired_ref = median(wired_times)
        extra_times = {}
        for sink in extras:
            if sink in amps or sink in extra_times:
                continue
            extra_times[sink] = []
            for _ in range(LEVEL_REPEATS):
                note(sink, measure_once(sink, click, mic, tpl), extra_times[sink])
        for sink, vals in amps.items():
            if vals:
                print("CALIB_LVL %s %d" % (sink, median(vals)))
        for sink in clipped_sinks:
            if not amps.get(sink):
                # Every burst from this sink saturated the mic — no honest
                # level was measured. The widget keeps the old balance and
                # can tell the user to back the volume off.
                print("CALIB_CLIP %s" % sink)
        for sink, ts in extra_times.items():
            if len(ts) < LEVEL_REPEATS:
                continue
            # Two samples: the plain mean is the fair middle (median of an
            # even count picks the upper value).
            x_ms = (sum(ts) / len(ts) - wired_ref) * 1000.0
            if MIN_SANE_MS < x_ms < MAX_SANE_MS:
                print("CALIB_XLAG %s %d" % (sink, round(x_ms)))
        print("CALIB_OK %d" % max(0, round(lag_ms)))
    except FileNotFoundError as exc:
        print("CALIB_FAIL missing tool: %s" % exc)
    except Exception as exc:  # a failure must be a sentinel, never a crash
        print("CALIB_FAIL %s" % str(exc)[:120])
    finally:
        try:
            os.unlink(click)
        except OSError:
            pass


main()
