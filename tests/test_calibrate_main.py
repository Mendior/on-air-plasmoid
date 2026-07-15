# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""calibrate.py main() end to end, with stub pw-record/paplay binaries.

The AST-based tests next door cover the pure functions; main()'s control
flow — the argv contract, the extras loop, the CALIB_LVL output, the
dedup, and the containment of a wedged paplay — ran uncovered until a
wedged extra sink was found to abort whole calibrations. The runs here
execute the shipped main() verbatim; only the timing constants (repeat
counts, record/playback windows) are shrunk on a copy so the suite stays
fast — they don't participate in any decision being tested.
"""
import os
import pathlib
import re
import stat
import subprocess
import sys

import pytest

UI_DIR = pathlib.Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"

PW_RECORD_STUB = """#!/usr/bin/env python3
import math, struct, sys, time, wave
rate = 48000
out = sys.argv[-1]
n = int(rate * 1.2)
click_at = int(rate * 0.75)  # past ANALYSIS_SKIP and the impossible-early noise filter
frames = bytearray()
for i in range(n):
    v = 0
    j = i - click_at
    if 0 <= j < int(rate * 0.01):
        env = 0.5 * (1.0 - math.cos(2.0 * math.pi * j / int(rate * 0.01)))
        v = int(20000 * env * math.sin(2.0 * math.pi * 2200.0 * j / rate))
    frames += struct.pack("<h", v)
with wave.open(out, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(bytes(frames))
time.sleep(60)   # calibrate.py terminates us; the file is already complete
"""

PAPLAY_STUB = """#!/usr/bin/env python3
import sys, time
if any("wedge" in a for a in sys.argv):
    time.sleep(30)   # a dying sink holding paplay hostage
"""


@pytest.fixture(scope="module")
def fast_calibrate(tmp_path_factory):
    """A copy of the shipped calibrate.py with only timing constants shrunk,
    plus a stub bin dir. Every substitution is asserted so the copy can
    never silently drift from the real file."""
    root = tmp_path_factory.mktemp("calib")
    src = (UI_DIR / "calibrate.py").read_text()
    subs = [
        (r"^CLICK_REPEATS = \d+", "CLICK_REPEATS = 2"),
        (r"^LEVEL_REPEATS = \d+", "LEVEL_REPEATS = 1"),
        (r"^RECORD_SECONDS = [\d.]+", "RECORD_SECONDS = 0.6"),
        (r"^PLAY_DELAY = [\d.]+", "PLAY_DELAY = 0.1"),
        (r"timeout=5,", "timeout=1,"),
    ]
    for pattern, repl in subs:
        src, count = re.subn(pattern, repl, src, flags=re.M)
        assert count == 1, "calibrate.py no longer matches %r" % pattern
    script = root / "calibrate.py"
    script.write_text(src)
    bindir = root / "bin"
    bindir.mkdir()
    for name, body in (("pw-record", PW_RECORD_STUB), ("paplay", PAPLAY_STUB)):
        p = bindir / name
        p.write_text(body)
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    return script, bindir


def run_calibrate(fast_calibrate, argv):
    script, bindir = fast_calibrate
    env = dict(os.environ)
    env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
    proc = subprocess.run([sys.executable, str(script)] + argv,
                          capture_output=True, text=True, timeout=120, env=env)
    return proc


def test_happy_path_reports_lag_and_all_levels(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", "", "extra_sink"])
    assert proc.returncode == 0
    lines = proc.stdout.strip().splitlines()
    lvl_sinks = [ln.split()[1] for ln in lines if ln.startswith("CALIB_LVL ")]
    assert sorted(lvl_sinks) == ["bt_sink", "extra_sink", "wired_sink"]
    ok = [ln for ln in lines if ln.startswith("CALIB_OK ")]
    assert len(ok) == 1
    # Identical stub arrivals on both sinks: the measured lag must be ~0.
    assert int(ok[0].split()[1]) <= 50


def test_wedged_extra_sink_cannot_abort_the_run(fast_calibrate):
    # The regression this file exists for: paplay hanging on a level-only
    # extra sink used to escape as TimeoutExpired and turn an already
    # successful timing verdict into CALIB_FAIL.
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", "", "wedge_sink"])
    assert proc.returncode == 0
    assert "CALIB_FAIL" not in proc.stdout
    assert "CALIB_OK" in proc.stdout


def test_extras_repeating_the_timing_pair_are_measured_once(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", "", "wired_sink"])
    lines = proc.stdout.strip().splitlines()
    wired_lvls = [ln for ln in lines if ln.startswith("CALIB_LVL wired_sink ")]
    assert len(wired_lvls) == 1


def test_missing_argv_is_a_sentinel_not_a_crash(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["only_one"])
    assert proc.returncode == 0
    assert proc.stdout.strip() == "CALIB_FAIL usage"


def test_extras_get_their_own_lag_line(fast_calibrate):
    # The clicks that measure an extra sink's loudness are timed anyway —
    # a USB DAC or HDMI TV in the group reports its real lag against the
    # wired reference (CALIB_XLAG) instead of an assumed zero.
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", "", "extra_sink"])
    xlag = [ln for ln in proc.stdout.splitlines() if ln.startswith("CALIB_XLAG extra_sink ")]
    assert len(xlag) == 1
    # Identical stub arrivals everywhere: the extra's lag must be ~0.
    assert abs(int(xlag[0].split()[2])) <= 50


def test_verify_reports_the_room_spread(fast_calibrate):
    # Presence clicks hear every member (the stub always records a click),
    # then one fused arrival in the combined pass = everyone together —
    # the verify must call that a spread of (near) zero.
    proc = run_calibrate(fast_calibrate,
                         ["verify", "combined_sink", "", "wired_sink", "bt_sink"])
    assert proc.returncode == 0
    assert "VERIFY_PARTIAL" not in proc.stdout
    ok = [ln for ln in proc.stdout.splitlines() if ln.startswith("VERIFY_OK ")]
    assert len(ok) == 1
    assert int(ok[0].split()[1]) <= 10


def test_verify_usage_is_a_sentinel(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["verify"])
    assert proc.returncode == 0
    assert proc.stdout.strip() == "VERIFY_FAIL usage"
