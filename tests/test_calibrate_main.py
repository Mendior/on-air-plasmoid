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

# A physically faithful microphone: it ALWAYS carries a small noise floor
# (a real mic is never bit-exact silent — that is how the liveness probe
# tells a live mic from a hardware-muted one), and it carries a loud CLICK
# only when a paplay actually played one DURING this capture. The stub
# writes its WAV on SIGTERM (as pw-record finalizes on real hardware), so
# it can look back and see whether the click was truly played — letting a
# stimulus-free capture (the room-quiet pre-check, mic-liveness) correctly
# read as quiet-but-alive instead of forging a click nobody played.
PW_RECORD_STUB = """#!/usr/bin/env python3
import math, os, signal, struct, sys, time, wave
rate = 48000
out = sys.argv[-1]
target = ""
if "--target" in sys.argv:
    target = sys.argv[sys.argv.index("--target") + 1]
dead = [d for d in os.environ.get("ONAIR_TEST_DEAD", "").split(",") if d]
is_dead = ("DEFAULT" in dead and target == "") or (target in dead)
mark = os.environ.get("ONAIR_TEST_PLAYMARK", "")
start = time.time()
def click_played():
    try:
        return float(open(mark).read()) >= start - 0.05
    except Exception:
        return False
def finish(*_a):
    n = int(rate * 1.2)
    click_at = int(rate * 0.75)  # past ANALYSIS_SKIP and the early-noise filter
    with_click = (not is_dead) and click_played()
    # A room with its own loud impulse in EVERY capture, click or not — a
    # TV left playing. Sits at a fixed spot so it looks arrival-like.
    loud_room = os.environ.get("ONAIR_TEST_ROOMLOUD", "") == "1"
    room_at = int(rate * 0.9)
    frames = bytearray()
    for i in range(n):
        # Dead mic = bit-exact zero; a live mic idles at a low floor.
        v = 0 if is_dead else (40 if (i % 2) else -40)
        if loud_room and not is_dead:
            k = i - room_at
            if 0 <= k < int(rate * 0.01):
                v = int(15000 * math.sin(2.0 * math.pi * 900.0 * k / rate))
        if with_click:
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
    sys.exit(0)
signal.signal(signal.SIGTERM, finish)
time.sleep(60)   # calibrate.py terminates us; finish() writes the WAV then
finish()         # (unreached in practice) belt-and-braces if never signalled
"""

PAPLAY_STUB = """#!/usr/bin/env python3
import os, sys, time
if any("wedge" in a for a in sys.argv):
    time.sleep(30)   # a dying sink holding paplay hostage — no click reaches air
else:
    mark = os.environ.get("ONAIR_TEST_PLAYMARK", "")
    if mark:
        try:
            open(mark, "w").write(str(time.time()))   # a click really played
        except Exception:
            pass
"""



PACTL_STUB = """#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if args[:1] == ["get-default-source"]:
    print("stub_mic")
elif args[:2] == ["list", "sources"]:
    print("Source #0")
    print("\\tName: sink_x.monitor")
    print("\\tDescription: Monitor of Sink X")
    print("Source #1")
    print("\\tName: stub_mic")
    print("\\tDescription: Stub Desk Microphone")
    print("Source #2")
    print("\\tName: cam_mic")
    print("\\tDescription: Stub Webcam Microphone")
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
    for name, body in (("pw-record", PW_RECORD_STUB), ("paplay", PAPLAY_STUB),
                       ("pactl", PACTL_STUB)):
        p = bindir / name
        p.write_text(body)
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    return script, bindir


def run_calibrate(fast_calibrate, argv, extra_env=None):
    script, bindir = fast_calibrate
    env = dict(os.environ)
    env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
    # A per-run "a click was just played" marker shared by the paplay and
    # pw-record stubs — cleared first so a previous run's clicks can't leak.
    mark = bindir.parent / "playmark"
    try:
        mark.unlink()
    except FileNotFoundError:
        pass
    env["ONAIR_TEST_PLAYMARK"] = str(mark)
    if extra_env:
        env.update(extra_env)
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
    # Each member's click is heard through the isolated combined pass, all at
    # the same stub arrival — the verify must call that a spread of near zero.
    proc = run_calibrate(fast_calibrate,
                         ["verify", "combined_sink", "", "wired_sink", "bt_sink"])
    assert proc.returncode == 0
    assert "VERIFY_PARTIAL" not in proc.stdout
    ok = [ln for ln in proc.stdout.splitlines() if ln.startswith("VERIFY_OK ")]
    assert len(ok) == 1
    assert int(ok[0].split()[1]) <= 10


def test_verify_refuses_a_loud_room(fast_calibrate):
    # A room with its own loud transient in every capture would let noise
    # pose as an arrival and store a fabricated residual — the verify must
    # bail with the honest verdict before a single click is measured.
    proc = run_calibrate(fast_calibrate,
                         ["verify", "combined_sink", "", "wired_sink", "bt_sink"],
                         extra_env={"ONAIR_TEST_ROOMLOUD": "1"})
    assert proc.returncode == 0
    assert proc.stdout.strip() == "VERIFY_FAIL room not quiet"


def test_verify_usage_is_a_sentinel(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["verify"])
    assert proc.returncode == 0
    assert proc.stdout.strip() == "VERIFY_FAIL usage"


def test_dead_default_mic_hands_over_to_a_live_one(fast_calibrate):
    # The Yeti disease, measured live: the mic's own touch-mute delivers
    # exact zeros while every software flag says "not muted". The run must
    # notice before spending forty seconds of clicks, skip the monitor in
    # the source list, and hand the measurement to the webcam next to it.
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_TEST_DEAD": "DEFAULT,stub_mic"})
    assert proc.returncode == 0
    assert "CALIB_MIC Stub Webcam Microphone" in proc.stdout
    assert "Monitor of Sink X" not in proc.stdout
    assert "CALIB_OK" in proc.stdout
    assert "no click heard" not in proc.stdout


def test_every_mic_dead_fails_fast_and_specifically(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_TEST_DEAD": "DEFAULT,stub_mic,cam_mic"})
    assert proc.returncode == 0
    assert proc.stdout.strip() == "CALIB_FAIL microphone silent"


def test_verify_with_dead_mics_says_so(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["verify", "combined", "", "wired_sink"],
                         extra_env={"ONAIR_TEST_DEAD": "DEFAULT,stub_mic,cam_mic"})
    assert proc.returncode == 0
    assert proc.stdout.strip() == "VERIFY_FAIL microphone silent"
