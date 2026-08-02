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
    # A chain that carries the inaudible band: the sweep the widget played
    # comes back, at the same place the click would have.
    ultra = os.environ.get("ONAIR_TEST_ULTRA", "") == "1"
    # The shared round hands every member its own slice of ONE capture, so a
    # fake microphone that answered with a single sweep would leave every
    # member but the first reading as deaf. One sweep per slot, and a capture
    # long enough to hold them — only in the ultra tests, because lengthening
    # every capture in here would buy nothing and cost the whole suite.
    slot = float(os.environ.get("ONAIR_TEST_SLOT", "0"))
    slots = 3 if (ultra and slot > 0) else 1
    click_at = int(rate * 0.75)  # past ANALYSIS_SKIP and the early-noise filter
    n = int(rate * max(1.2, 0.75 + slots * slot + 0.5))
    with_click = (not is_dead) and click_played()
    # A room with its own loud impulse in EVERY capture, click or not — a
    # TV left playing. Sits at a fixed spot so it looks arrival-like.
    loud_room = os.environ.get("ONAIR_TEST_ROOMLOUD", "") == "1"
    room_at = int(rate * 0.9)
    # A microphone whose own floor is high — a webcam with its gain wound
    # up. It still HEARS the click, just badly, which is exactly the case
    # a picker has to get right: loudest is not the same as clearest.
    noisy = target in [d for d in os.environ.get("ONAIR_TEST_NOISY", "").split(",") if d]
    frames = bytearray()
    for i in range(n):
        # Dead mic = bit-exact zero; a live mic idles at a low floor.
        v = 0 if is_dead else (40 if (i % 2) else -40)
        if noisy and not is_dead:
            v = 3000 if (i % 2) else -3000
        if loud_room and not is_dead:
            k = i - room_at
            if 0 <= k < int(rate * 0.01):
                v = int(15000 * math.sin(2.0 * math.pi * 900.0 * k / rate))
        if with_click:
            j = i - click_at
            if 0 <= j < int(rate * 0.01):
                env = 0.5 * (1.0 - math.cos(2.0 * math.pi * j / int(rate * 0.01)))
                v = int(20000 * env * math.sin(2.0 * math.pi * 2200.0 * j / rate))
            if ultra:
                # The sweep, in whatever band the shipped file is set to —
                # the stub used to hard-code 18-21 kHz, and when the ceiling
                # came down to 19 kHz it went on playing a sweep the detector
                # no longer watches, failing three tests for the wrong reason.
                lo = float(os.environ.get("ONAIR_TEST_ULTRA_LO", "18000"))
                hi = float(os.environ.get("ONAIR_TEST_ULTRA_HI", "19000"))
                secs = float(os.environ.get("ONAIR_TEST_ULTRA_SECONDS", "0.06"))
                u = int(rate * secs)
                for k in range(slots):
                    jj = j - int(k * slot * rate)
                    if 0 <= jj < u:
                        tt = jj / rate
                        ph = 2.0 * math.pi * (lo * tt + (hi - lo) * tt * tt / (2.0 * secs))
                        ev = min(1.0, jj / (rate * 0.004), (u - jj) / (rate * 0.004))
                        v = int(9000 * ev * math.sin(ph))
                        break
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
import array, os, sys, time, wave
if any("wedge" in a for a in sys.argv):
    time.sleep(30)   # a dying sink holding paplay hostage — no click reaches air
else:
    mark = os.environ.get("ONAIR_TEST_PLAYMARK", "")
    if mark:
        try:
            open(mark, "w").write(str(time.time()))   # a click really played
        except Exception:
            pass
    # What reached the room, in the one number an ear cares about: how often
    # the waveform changes sign. The click file (a 180 Hz leader and a 2.2 kHz
    # burst) lands near 400 Hz by this measure; the inaudible file is up in
    # the thousands. Enough to let a test say "nothing audible was played"
    # without owning a spectrum analyser.
    log = os.environ.get("ONAIR_TEST_PLAYLOG", "")
    if log:
        try:
            with wave.open(sys.argv[-1], "rb") as w:
                rate, n = w.getframerate(), w.getnframes()
                data = array.array("h")
                data.frombytes(w.readframes(n))
            cross = sum(1 for i in range(1, len(data))
                        if (data[i - 1] < 0) != (data[i] < 0))
            hz = cross * rate / (2.0 * len(data)) if len(data) > 1 else 0.0
            with open(log, "a") as f:
                f.write("%.0f\\n" % hz)
        except Exception:
            pass
"""



PACTL_STUB = """#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if args[:1] == ["get-default-source"]:
    print("stub_mic")
elif args[:2] == ["list", "sources"]:
    import os
    print("Source #0")
    print("\\tName: sink_x.monitor")
    print("\\tDescription: Monitor of Sink X")
    print("Source #1")
    print("\\tName: stub_mic")
    print("\\tDescription: Stub Desk Microphone")
    if os.environ.get("ONAIR_TEST_ONEMIC", "") != "1":
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
        # LEVEL_REPEATS stays at the shipped 2: the extras' settle rule
        # needs a PAIR of clicks to agree, and a single-capture world would
        # make every extra unmeasurable here while production always plays
        # two. Costs one extra stub capture per extras test.
        (r"^LEVEL_REPEATS = \d+", "LEVEL_REPEATS = 2"),
        (r"^RECORD_SECONDS = [\d.]+", "RECORD_SECONDS = 0.6"),
        (r"^PLAY_DELAY = [\d.]+", "PLAY_DELAY = 0.1"),
        # Every paplay timeout: the per-member measurement's and the one the
        # mic-picking click rides. The shared round's player left this list
        # when it stopped blocking at all — a wedged sink used to hold its
        # run() for the full timeout and push every later member out of its
        # slot, so the plays are fired with Popen and reaped at round end.
        # The exact count is still the point: it catches any new blocking
        # player call the day it is written.
        (r"timeout=5,", "timeout=1,", 2),
        # The passive fallback's listening window. Only the ROAD taken is
        # under test here, not the correlator's verdict, so the wait is
        # pointless wall-clock.
        (r"^DRIFT_SECONDS = [\d.]+", "DRIFT_SECONDS = 1.0"),
        # The sweep captures the calibration now takes. Seven of them at the
        # shipped 2.0 s would add a quarter minute to every run in here, and
        # what is under test is which ROAD answered, not how long its
        # recorder listened.
        (r"^ULTRA_DIRECT_SECONDS = [\d.]+", "ULTRA_DIRECT_SECONDS = 0.3"),
        # The shared round sleeps through a slot per member, so the shipped
        # 1.8 s would put four drift tests on the clock for no reason. It
        # cannot go below LEADER_SECONDS + ULTRA_GAP_SECONDS (0.6) — a slot
        # shorter than the stimulus cannot hold a sweep, and every member
        # would read as deaf.
        (r"^ULTRA_SLOT_SECONDS = [\d.]+", "ULTRA_SLOT_SECONDS = 0.8"),
    ]
    for sub in subs:
        pattern, repl = sub[0], sub[1]
        want = sub[2] if len(sub) > 2 else 1
        src, count = re.subn(pattern, repl, src, flags=re.M)
        assert count == want, "calibrate.py no longer matches %r (%d, wanted %d)" % (
            pattern, count, want)
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
    # And a per-run record of WHAT was played, one pitch per line — cleared
    # for the same reason.
    playlog = bindir.parent / "playlog"
    try:
        playlog.unlink()
    except FileNotFoundError:
        pass
    env["ONAIR_TEST_PLAYLOG"] = str(playlog)
    # The stub speaker plays the band the shipped file watches. Read from the
    # source rather than repeated here, so moving the ceiling moves the fake
    # speaker with it instead of silently failing every sweep test.
    shipped = (UI_DIR / "calibrate.py").read_text()
    for key, const in (("ONAIR_TEST_ULTRA_LO", "ULTRA_LOW_HZ"),
                       ("ONAIR_TEST_ULTRA_HI", "ULTRA_HIGH_HZ"),
                       ("ONAIR_TEST_ULTRA_SECONDS", "ULTRA_SECONDS")):
        m = re.search(r"^%s = ([\d.]+)" % const, shipped, re.MULTILINE)
        assert m, const + " is no longer a plain literal in calibrate.py"
        env[key] = m.group(1)
    # The shared round gives every member its own slice of ONE capture, so the
    # fake microphone has to put a sweep in each. Read from the SCRIPT UNDER
    # TEST and not from the shipped file: the fixture shrinks this one, and a
    # stub that spaced its sweeps by the shipped 1.8 s would drop them outside
    # every window the run actually looks in.
    under_test = script.read_text()
    for key, const in (("ONAIR_TEST_SLOT", "ULTRA_SLOT_SECONDS"),
                       ("ONAIR_TEST_PLAY_DELAY", "PLAY_DELAY")):
        m = re.search(r"^%s = ([\d.]+)" % const, under_test, re.MULTILINE)
        assert m, const + " is no longer a plain literal in calibrate.py"
        env[key] = m.group(1)
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


def test_the_run_names_the_speaker_everything_was_measured_against(fast_calibrate):
    """CALIB_OK and every CALIB_XLAG are DIFFERENCES, and a difference is
    meaningless without saying what it was subtracted from. The wired sink
    is that zero, and the widget needs its name to clear whatever that
    speaker was carrying from an older measurement — a stale lag left under
    a fresh one cancels the compensation without a word."""
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", "", "extra_sink"])
    assert proc.returncode == 0
    refs = [ln.split(None, 1)[1] for ln in proc.stdout.splitlines()
            if ln.startswith("CALIB_REF ")]
    assert refs == ["wired_sink"], proc.stdout
    # The reference never doubles as its own extra: a speaker cannot be
    # 0 ms away from itself AND carry a lag line.
    xlag_sinks = [ln.split()[1] for ln in proc.stdout.splitlines()
                  if ln.startswith("CALIB_XLAG ")]
    assert "wired_sink" not in xlag_sinks, proc.stdout


def test_the_timing_comes_off_the_sweep_when_the_chain_carries_it(fast_calibrate):
    """The number that lands in the fine-tune field is the one the clicks
    kept getting wrong: measured on real hardware, three click runs on the
    same pair gave a flat failure, a 58 and a 153, where eight sweep runs
    sat between 146 and 164. So the sweep times the pair whenever the chain
    carries it, and says so.

    This stub's capture puts the sweep exactly where the click would be, so
    the click detector finds nothing it recognizes — which is also the real
    failure being fixed: a Bluetooth speaker that never answers a burst used
    to end the whole run with no verdict at all."""
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_TEST_ULTRA": "1"})
    assert proc.returncode == 0
    assert "CALIB_BY sweep" in proc.stdout, proc.stdout
    assert "CALIB_REF wired_sink" in proc.stdout, proc.stdout
    ok = [ln for ln in proc.stdout.splitlines() if ln.startswith("CALIB_OK ")]
    assert len(ok) == 1, proc.stdout
    # The stub's two speakers answer together, so the honest lag is ~0.
    assert int(ok[0].split()[1]) <= 50, proc.stdout
    # The verdict travels with its evidence: which build measured, and the
    # raw capture behind each sink's arrival. The 44 ms mis-credit of
    # 2026-07-28 was unexplainable precisely because neither existed.
    assert "CALIB_SRC " in proc.stdout, proc.stdout
    raw_sinks = {ln.split()[2] for ln in proc.stdout.splitlines()
                 if ln.startswith("CALIB_RAW sweep ")}
    assert raw_sinks == {"wired_sink", "bt_sink"}, proc.stdout


def test_the_clicks_still_time_the_pair_when_the_sweep_is_off(fast_calibrate):
    """An owner who turned the sweep off for a pet keeps a working
    calibration — the clicks go back to being the timing road, not just the
    loudness one. And the run names that road: this branch used to print no
    marker at all, which is how the 2026-07-28 run left a wrong number
    whose stimulus nobody could establish afterwards."""
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_NO_ULTRA": "1"})
    assert proc.returncode == 0
    assert "CALIB_BY clicks" in proc.stdout, proc.stdout
    assert "CALIB_BY sweep" not in proc.stdout, proc.stdout
    assert "CALIB_OK" in proc.stdout, proc.stdout
    assert "CALIB_REF wired_sink" in proc.stdout, proc.stdout
    raw_sinks = {ln.split()[2] for ln in proc.stdout.splitlines()
                 if ln.startswith("CALIB_RAW clicks ")}
    assert raw_sinks == {"wired_sink", "bt_sink"}, proc.stdout


def test_a_failed_run_names_no_reference(fast_calibrate):
    """The reference line re-anchors the whole stored frame, so it must ride
    ONLY on a run that actually produced one. A failure that named a zero
    would wipe a good speaker's lag and leave nothing in its place."""
    proc = run_calibrate(fast_calibrate, ["wired_sink", "wedge_bt_sink", ""])
    assert proc.returncode == 0
    assert "CALIB_OK" not in proc.stdout, proc.stdout
    assert "CALIB_REF" not in proc.stdout, proc.stdout


def _pitches_played(fast_calibrate):
    """Every sound this run put into the room, as a rough pitch in Hz."""
    _script, bindir = fast_calibrate
    log = bindir.parent / "playlog"
    if not log.exists():
        return []
    return [float(ln) for ln in log.read_text().split() if ln]


def test_asking_for_silence_keeps_the_microphone_pick_silent_too(fast_calibrate):
    """Two microphones and the sweep-only setting on: not one sound the ear
    can follow may reach the room.

    The pick used to play its click regardless — full volume, 2.2 kHz, ahead
    of a run that promises silence. It hid because it only fires where there
    is more than one microphone to choose between, and the desk this was
    written on has one. Heard on a desk with three.
    """
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_TEST_ULTRA": "1",
                                    "ONAIR_ULTRA_ONLY": "1",
                                    "ONAIR_TEST_NOISY": "stub_mic"})
    assert proc.returncode == 0
    assert "CALIB_OK" in proc.stdout, proc.stdout
    played = _pitches_played(fast_calibrate)
    assert played, "nothing was played at all — the run cannot have measured"
    assert all(hz > 8000 for hz in played), played
    # The pick still happened, and still on the merits: the noisy microphone
    # is not the one that came back.
    picked = [ln.split(None, 1)[1] for ln in proc.stdout.splitlines()
              if ln.startswith("CALIB_MICNAME ")]
    assert picked == ["cam_mic"], proc.stdout


def test_the_click_road_still_plays_a_click(fast_calibrate):
    """The other half of the promise, so the test above cannot pass by
    measuring nothing: with the sweep off, an audible burst does reach the
    room — that road is supposed to click."""
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_NO_ULTRA": "1"})
    assert proc.returncode == 0
    played = _pitches_played(fast_calibrate)
    assert any(hz < 8000 for hz in played), played


def test_the_measurement_picks_the_microphone_that_hears_best(fast_calibrate):
    """Two microphones in the machine, and the SYSTEM DEFAULT is the worse
    one — a webcam with its gain wound up, loud but noisy. The room is not
    the desktop's routing preference to decide, so the run listens on both
    at once and keeps the clearer ear, then says which one by name so later
    checks use the same."""
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_TEST_NOISY": "stub_mic"})
    assert proc.returncode == 0
    picked = [ln.split(None, 1)[1] for ln in proc.stdout.splitlines()
              if ln.startswith("CALIB_MICNAME ")]
    assert picked == ["cam_mic"], proc.stdout
    assert "CALIB_OK" in proc.stdout


def test_one_microphone_alone_is_used_without_a_picking_click(fast_calibrate):
    """With nothing to choose between, the picker must not spend a click:
    the run costs exactly what it did before this feature existed."""
    proc = run_calibrate(fast_calibrate, ["wired_sink", "bt_sink", ""],
                         extra_env={"ONAIR_TEST_ONEMIC": "1"})
    assert proc.returncode == 0
    assert "CALIB_MICNAME stub_mic" in proc.stdout
    assert "CALIB_OK" in proc.stdout


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
    assert len(xlag) == 1, proc.stdout
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


def test_verify_refuses_a_loud_room_on_the_audible_road(fast_calibrate):
    # The audible click has to stand above the room, so a room with its own
    # loud transient in every capture would let noise pose as an arrival and
    # store a fabricated residual — that road still bails honestly.
    #
    # The stub's chain carries nothing at 18-21 kHz, so the verify falls
    # back to the click and this gate is the one that answers. A chain that
    # DOES carry the sweep never reaches it: see the test below.
    proc = run_calibrate(fast_calibrate,
                         ["verify", "combined_sink", "", "wired_sink", "bt_sink"],
                         extra_env={"ONAIR_TEST_ROOMLOUD": "1"})
    assert proc.returncode == 0
    assert proc.stdout.strip() == "VERIFY_FAIL room not quiet"


def test_verify_measures_a_busy_room_when_the_sweep_carries(fast_calibrate):
    # The point of the inaudible sweep: music and speech do not live at
    # 18-21 kHz, so a room that is busy to the EAR is silent to this
    # measurement and the check simply runs. The stub plays the real
    # stimulus back, so the sweep is there to be found.
    proc = run_calibrate(fast_calibrate,
                         ["verify", "combined_sink", "", "wired_sink", "bt_sink"],
                         extra_env={"ONAIR_TEST_ULTRA": "1", "ONAIR_TEST_ROOMLOUD": "1"})
    assert proc.returncode == 0
    assert "VERIFY_FAIL room not quiet" not in proc.stdout
    ok = [ln for ln in proc.stdout.splitlines() if ln.startswith("VERIFY_OK ")]
    assert len(ok) == 1, proc.stdout


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
    lines = proc.stdout.strip().splitlines()
    assert lines[-1] == "CALIB_FAIL microphone silent", proc.stdout
    # The only other line a dead-mic run may print is which build refused —
    # the identity rides on every run, failures most of all.
    assert all(ln.startswith("CALIB_SRC ") for ln in lines[:-1]), proc.stdout


def test_verify_with_dead_mics_says_so(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["verify", "combined", "", "wired_sink"],
                         extra_env={"ONAIR_TEST_DEAD": "DEFAULT,stub_mic,cam_mic"})
    assert proc.returncode == 0
    assert proc.stdout.strip() == "VERIFY_FAIL microphone silent"


# ── The automatic check's road ──────────────────────────────────────────────
# The periodic check has two roads now. The inaudible sweep MEASURES each
# speaker; the older passive correlation only listens to whatever the music
# happens to carry and answers "too quiet to tell" whenever the material is
# flat. Which road a run takes is the whole difference between an answer and
# a shrug, so it is pinned here rather than left to the ear. The tell is the
# play marker: the sweep road puts a signal into the room, the passive one
# never plays anything at all.

def _played_anything(fast_calibrate):
    _script, bindir = fast_calibrate
    return (bindir.parent / "playmark").exists()


def test_drift_measures_each_speaker_with_the_inaudible_sweep(fast_calibrate):
    proc = run_calibrate(fast_calibrate, ["drift", "combined", "", "wired_sink", "0", "bt_sink", "0"],
                         extra_env={"ONAIR_TEST_ULTRA": "1"})
    assert proc.returncode == 0
    lines = proc.stdout.strip().splitlines()
    # A real number, not a shrug — and the stub's speakers arrive together,
    # so the honest answer is nought.
    assert lines[-1] == "DRIFT_EST 0", proc.stdout
    # And WHERE each one landed, because the spread above is unsigned and a
    # correction needs a direction. Without these the widget can only say
    # "18 ms out", never "come down by 18".
    ears = {ln.split()[1]: int(ln.split()[2])
            for ln in lines if ln.startswith("DRIFT_EAR ")}
    assert set(ears) == {"wired_sink", "bt_sink"}, proc.stdout
    assert abs(ears["wired_sink"] - ears["bt_sink"]) == 0, ears
    assert _played_anything(fast_calibrate)


def test_drift_stays_silent_when_the_sweep_is_switched_off(fast_calibrate):
    # Same chain, same capable speakers — only the setting differs. Nothing
    # may reach the room: an owner who turned the sweep off because of a pet
    # must not get it back through the automatic check's side door.
    proc = run_calibrate(fast_calibrate, ["drift", "combined", "", "wired_sink", "0", "bt_sink", "0"],
                         extra_env={"ONAIR_TEST_ULTRA": "1", "ONAIR_NO_ULTRA": "1"})
    assert proc.returncode == 0
    assert not _played_anything(fast_calibrate)
    assert not proc.stdout.strip().startswith("DRIFT_EST "), proc.stdout


def test_drift_without_named_members_keeps_the_old_passive_road(fast_calibrate):
    # The call shape the widget used before it started naming the group's
    # members. It must still run and still stay silent.
    proc = run_calibrate(fast_calibrate, ["drift", "combined", ""],
                         extra_env={"ONAIR_TEST_ULTRA": "1"})
    assert proc.returncode == 0
    assert not _played_anything(fast_calibrate)
    assert proc.stdout.strip().startswith("DRIFT_"), proc.stdout


def test_drift_needs_a_real_microphone(fast_calibrate):
    # The mic discipline the passive road already had must survive on the
    # sweep road too: a dead default source is "quiet", never a measurement.
    proc = run_calibrate(fast_calibrate, ["drift", "combined", "", "wired_sink", "0", "bt_sink", "0"],
                         extra_env={"ONAIR_TEST_ULTRA": "1",
                                    "ONAIR_TEST_DEAD": "stub_mic,cam_mic,DEFAULT"})
    assert proc.returncode == 0
    assert proc.stdout.strip() == "DRIFT_QUIET", proc.stdout
