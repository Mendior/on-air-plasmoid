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


def test_unrelated_noise_gives_no_signal():
    mon = _program(8.0, seed=7)
    rng = random.Random(99)
    mic = [int(rng.gauss(0, 800)) for _ in range(8 * RATE)]
    verdict = calibrate._drift_estimate(mic, mon, RATE)
    assert verdict in ("DRIFT_NOSIG", "DRIFT_EST 0"), verdict
