# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The number in front of every MPRIS command.

The widget obeys a command once and never twice, and it reads the number to
know which is which. A bridge that starts counting at one again hands the
widget numbers it has already passed: after the bridge is restarted (and from
2026-09-22 the widget restarts it whenever it finds it gone) the first few
media-key presses would land on a widget that quietly drops them. A clock
instead of a counter also dates the command, so one left in the file by a
crashed session can never be obeyed minutes or hours later.

The moment is asked for with --ms-seq, and only the widget that reads it as
a moment asks. 2026.39 keeps the number in a 32-bit int, where a moment
wraps and every line reads as new, and that widget goes on running between
an update landing on disk and the next plasmashell start; switching its
media keys off and on in that window starts this bridge from disk.
"""
from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
MPRIS = ROOT / "package" / "contents" / "ui" / "mpris.py"


LAUNCHER = ROOT / "package" / "contents" / "ui" / "start-mpris.sh"


def _lifted(name: str):
    """One top-level function out of mpris.py, without importing dbus or gi."""
    src = MPRIS.read_text(encoding="utf-8")
    start = src.index("def %s(" % name)
    end = src.index("\ndef ", start + 1)
    end = min(end, src.index("\nclass ", start)) if "\nclass " in src[start:] else end
    ns: dict = {}
    exec(compile("import time\n" + src[start:end], "mpris_" + name, "exec"), ns)
    return ns[name]


def _seq_fn():
    """next_seq() in the mode the current widget asks for."""
    next_seq = _lifted("next_seq")
    return lambda last: next_seq(last, True)


def test_the_number_is_a_moment_not_a_count():
    next_seq = _seq_fn()
    a = next_seq(0)
    b = next_seq(a)
    assert b > a, "two commands in a row must not share a number"
    # A moment, in milliseconds: within a second of the clock the widget reads.
    assert abs(a - int(time.time() * 1000)) < 1000, (
        "the number is not the wall clock the widget compares against")


def test_a_fresh_bridge_never_hands_back_a_number_already_used():
    """The whole point: the widget's filter is `seq > last seen`, and a bridge
    that counted from one again was invisible until it caught up."""
    next_seq = _seq_fn()
    highest_before_restart = next_seq(0)
    fresh_bridge_first = next_seq(0)          # a new process, its own counter at zero
    assert fresh_bridge_first >= highest_before_restart


def test_two_commands_inside_one_millisecond_still_differ():
    next_seq = _seq_fn()
    seen = []
    last = 0
    for _ in range(50):
        last = next_seq(last)
        seen.append(last)
    assert seen == sorted(seen) and len(set(seen)) == len(seen), (
        "a burst of commands must keep a strict order")


def test_without_the_flag_the_bridge_counts_as_2026_39_expects():
    """The widget of 2026.39 filters on `seq <= _mprisCmdSeq` with an int."""
    next_seq = _lifted("next_seq")
    seen = []
    last = 0
    for _ in range(5):
        last = next_seq(last, False)
        seen.append(last)
    assert seen == [1, 2, 3, 4, 5]
    assert last < 2**31 - 1


def test_the_bridge_uses_it_for_the_line_it_writes():
    src = MPRIS.read_text(encoding="utf-8")
    assert "self.cmd_seq = next_seq(self.cmd_seq, self.ms_seq)" in src, (
        "the command line is numbered by something else again")
    assert "self.cmd_seq += 1" not in src, "a counter outside next_seq is back"
    assert "MPRISBridge(bus_name, state_path, cmd_path, ms_seq)" in src, (
        "the bridge is built without the mode its command line asked for")


@pytest.mark.parametrize("argv, want", [
    (["s.json", "c.txt", "123", "--ms-seq"], ("s.json", "c.txt", 123, True)),
    (["s.json", "c.txt", "123"], ("s.json", "c.txt", 123, False)),
    (["s.json", "c.txt"], ("s.json", "c.txt", 0, False)),
    (["s.json", "c.txt", "--ms-seq"], ("s.json", "c.txt", 0, True)),
    (["s.json", "c.txt", "abc"], ("s.json", "c.txt", 0, False)),
    (["s.json"], None),
    ([], None),
])
def test_the_command_line_names_the_files_the_host_and_the_mode(argv, want):
    assert _lifted("bridge_args")(argv) == want


def _launch(tmp_path: Path, *extra: str) -> list[str]:
    """Run start-mpris.sh with python3 and setsid stubbed out and return the
    argument list the daemon would have been started with."""
    stubs = tmp_path / "bin"
    stubs.mkdir()
    record = tmp_path / "launched.txt"
    (stubs / "python3").write_text("#!/bin/sh\nexit 0\n")
    (stubs / "setsid").write_text(
        '#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done > "$RECORD"\n')
    for f in stubs.iterdir():
        f.chmod(0o755)
    run = tmp_path / "run"
    run.mkdir()
    env = dict(os.environ, PATH="%s:%s" % (stubs, os.environ.get("PATH", "")),
               RECORD=str(record))
    subprocess.run(["bash", str(LAUNCHER), str(run / "arp-mpris-state-7.json"),
                    str(run / "arp-mpris-cmd-7.txt"), *extra],
                   env=env, check=True, timeout=20, capture_output=True)
    return record.read_text().splitlines()


def test_the_launcher_hands_the_flag_on(tmp_path):
    args = _launch(tmp_path, "--ms-seq")
    assert args[:2] == ["-f", "python3"] and args[2].endswith("mpris.py")
    assert args[-1] == "--ms-seq", args


def test_a_2026_39_launch_gets_the_counter(tmp_path):
    """2026.39 calls the launcher with the two files and nothing else."""
    args = _launch(tmp_path)
    assert "--ms-seq" not in args, args
    assert len(args) == 6, args          # -f python3 mpris.py state cmd host


def test_the_launcher_passes_nothing_else_through(tmp_path):
    args = _launch(tmp_path, "--something")
    assert "--something" not in args and "--ms-seq" not in args, args
