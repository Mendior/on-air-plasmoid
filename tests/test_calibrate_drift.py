# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The passive drift estimator, fed synthetic 'program material'.

A monitor capture (what was sent) and a mic capture (what the room
played) are built from the same transient pattern; the mic hears each
speaker as a delayed copy. Two speakers in sync merge into one
correlation peak (drift 0); drifted apart they split, and the split is
the inter-speaker error regardless of capture start skew.
"""

import importlib.util
import math
import pathlib
import random

SPEC = importlib.util.spec_from_file_location(
    "calibrate",
    pathlib.Path(__file__).resolve().parent.parent
    / "package" / "contents" / "ui" / "calibrate.py")
calibrate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(calibrate)

RATE = 8000  # a lighter rate keeps the synthetic arrays small; the
             # estimator only cares about ms, not the sample rate itself


def _program(seconds, seed=7):
    """Transient-rich fake music: bursts on a noise floor."""
    rng = random.Random(seed)
    n = int(seconds * RATE)
    out = [int(rng.gauss(0, 30)) for _ in range(n)]
    t = int(0.3 * RATE)
    while t < n - int(0.1 * RATE):
        for j in range(int(0.02 * RATE)):
            out[t + j] += int(12000 * math.exp(-j / (0.004 * RATE)))
        t += int((0.35 + rng.random() * 0.4) * RATE)
    return out


def _delayed(src, delay_ms, gain=1.0):
    d = int(delay_ms * RATE / 1000.0)
    return [0] * d + [int(v * gain) for v in src[:len(src) - d]]


def _mix(a, b):
    return [x + y for x, y in zip(a, b)]


def test_split_arrivals_read_as_drift():
    mon = _program(8.0)
    # Speaker A at 120 ms total, speaker B at 200 ms: 80 ms apart.
    mic = _mix(_delayed(mon, 120), _delayed(mon, 200, 0.8))
    verdict = calibrate._drift_estimate(mic, mon, RATE)
    kind, ms = verdict.split()
    assert kind == "DRIFT_EST"
    assert abs(int(ms) - 80) <= 8, verdict


def test_merged_arrivals_read_as_zero():
    mon = _program(8.0)
    mic = _mix(_delayed(mon, 150), _delayed(mon, 158, 0.8))  # inside fusion
    verdict = calibrate._drift_estimate(mic, mon, RATE)
    assert verdict == "DRIFT_EST 0", verdict


def test_silence_and_dead_mic_stay_quiet():
    mon = _program(8.0)
    assert calibrate._drift_estimate([0] * (8 * RATE), mon, RATE) == "DRIFT_QUIET"
    assert calibrate._drift_estimate([1] * 100, mon, RATE) == "DRIFT_QUIET"


def _metronome(seconds, period_s=0.5):
    """Strictly periodic bursts — the envelope self-similarity trap."""
    n = int(seconds * RATE)
    out = [0] * n
    t = int(0.1 * RATE)
    while t < n - int(0.1 * RATE):
        for j in range(int(0.02 * RATE)):
            out[t + j] += int(12000 * math.exp(-j / (0.004 * RATE)))
        t += int(period_s * RATE)
    return out


def test_rhythmic_material_does_not_fake_a_split():
    # One speaker path only, in perfect sync — but a 120 BPM metronome.
    # The beat paints a second correlation peak one period away; the
    # rhythm guard must refuse to read it as a 500 ms drift (a live run
    # did exactly that before the guard existed).
    mon = _metronome(8.0)
    mic = _delayed(mon, 150)
    verdict = calibrate._drift_estimate(mic, mon, RATE)
    assert verdict in ("DRIFT_NOSIG", "DRIFT_EST 0"), verdict


def test_aperiodic_split_still_reads_through_the_rhythm_guard():
    # The guard must not blind the estimator on honest material: random
    # inter-burst gaps carry no self-similarity at the split distance.
    mon = _program(8.0)
    mic = _mix(_delayed(mon, 120), _delayed(mon, 200, 0.8))
    verdict = calibrate._drift_estimate(mic, mon, RATE)
    kind, ms = verdict.split()
    assert kind == "DRIFT_EST" and abs(int(ms) - 80) <= 8, verdict


def test_unrelated_noise_gives_no_signal():
    mon = _program(8.0, seed=7)
    rng = random.Random(99)
    mic = [int(rng.gauss(0, 800)) for _ in range(8 * RATE)]
    verdict = calibrate._drift_estimate(mic, mon, RATE)
    assert verdict in ("DRIFT_NOSIG", "DRIFT_EST 0"), verdict


def test_monitor_recorder_targets_the_sink_itself_on_pipewire(monkeypatch):
    # "<sink>.monitor" is a pulse-layer name only — pw-record given an
    # unresolvable --target falls back to the default SOURCE, and both
    # drift recorders end up on the microphone (verified live: pw-dump
    # lists no *.monitor node, and the fallback linked to the mic ports).
    # Native capture must target the sink node with stream.capture.sink.
    monkeypatch.setattr(calibrate.shutil, "which",
                        lambda name: "/usr/bin/" + name)
    args = calibrate.monitor_recorder_args("onair_combined_7", "/tmp/x.wav")
    assert args[0] == "pw-record"
    assert "onair_combined_7" in args
    assert "onair_combined_7.monitor" not in args
    p = args.index("-P")
    assert "stream.capture.sink = true" in args[p + 1]


def test_monitor_recorder_keeps_the_pulse_monitor_device_as_fallback(monkeypatch):
    # In the pulse compatibility layer the .monitor source genuinely
    # exists — parecord keeps it.
    monkeypatch.setattr(calibrate.shutil, "which", lambda name: None)
    args = calibrate.monitor_recorder_args("onair_combined_7", "/tmp/x.wav")
    assert args[0] == "parecord"
    assert "--device=onair_combined_7.monitor" in args


def test_drift_runs_under_the_sigterm_conversion_with_a_sentinel_net():
    # The guard runs the probe under `timeout 20`; a SIGTERM that skipped
    # the finally blocks would orphan two recorder children holding the
    # microphone open. The conversion must be installed BEFORE the drift
    # dispatch, and a crash inside it must print a sentinel, not a
    # traceback — the caller reads sentinels only.
    src = pathlib.Path(SPEC.origin).read_text()
    main_body = src.split("def main():", 1)[1]
    assert main_body.index("signal.signal(signal.SIGTERM") \
        < main_body.index('== "drift"')
    drift_branch = main_body.split('== "drift"', 1)[1]
    assert drift_branch.index("except Exception") \
        < drift_branch.index('== "verify"')
    assert 'print("DRIFT_NOSIG")' in drift_branch.split('== "verify"')[0]
