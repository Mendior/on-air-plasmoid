# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""calibrate.py signal path: the click generator and the peak detector that
the microphone sync calibration stands on. A detector that fires on noise —
or misses a real click — turns into a wrong per-device delay in the user's
config, so both directions are pinned here."""
import ast
import math
import pathlib
import struct
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
    ns = {"math": math, "struct": struct, "wave": wave}
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


def test_peak_time_finds_a_click_where_it_is(calib, tmp_path):
    rate = calib["RATE"]
    skip = calib["ANALYSIS_SKIP"]
    at = 0.9  # seconds — safely past the skipped warm-up window
    samples = [0] * int(rate * 1.5)
    for i in range(int(rate * 0.01)):
        env = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / int(rate * 0.01)))
        samples[int(at * rate) + i] = int(20000 * env
                                          * math.sin(2.0 * math.pi * 2200.0 * i / rate))
    p = tmp_path / "rec.wav"
    write_wav(p, samples, rate)
    t = calib["peak_time"](str(p))
    assert t is not None
    assert abs(t - at) < 0.01
    assert t > skip  # the AGC-pop window must never win


def test_peak_time_rejects_silence(calib, tmp_path):
    p = tmp_path / "silence.wav"
    write_wav(p, [0] * calib["RATE"], calib["RATE"])
    assert calib["peak_time"](str(p)) is None


def test_peak_time_rejects_steady_noise(calib, tmp_path):
    # Loud but NOT impulsive — a click must stand far above the noise floor,
    # otherwise music/room noise would measure as a click.
    rate = calib["RATE"]
    samples = [int(8000 * math.sin(2.0 * math.pi * 300.0 * i / rate))
               for i in range(rate)]
    p = tmp_path / "noise.wav"
    write_wav(p, samples, rate)
    assert calib["peak_time"](str(p)) is None


def test_peak_time_rejects_too_short_recording(calib, tmp_path):
    p = tmp_path / "short.wav"
    write_wav(p, [0] * int(calib["RATE"] * 0.1), calib["RATE"])
    assert calib["peak_time"](str(p)) is None


def test_median_takes_the_middle(calib):
    assert calib["median"]([3.0, 1.0, 2.0]) == 2.0
    assert calib["median"]([5.0, 1.0]) == 5.0  # upper-middle on even counts
