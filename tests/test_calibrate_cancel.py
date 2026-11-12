# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Cancel against a measurement that is still getting ready.

The calibration is one shell command: it asks every speaker for its level,
parks it at 55 %, raises the balance-trimmed loopbacks to full, and only then
starts calibrate.py and writes the pid down. Cancel read that pid file once.
Driven on 2026-11-11 with the first level query held back: at Cancel there
was no pid file, nothing was signalled, and the shell went on to park all
three speakers and start the measurement that had been called off.

The commands are the engine's own. One test of tst_syncengine.qml prints what
SyncEngine.qml hands to the shell, and that text runs here under sh as
main.qml's exec() would send it. pactl and python3 are stand-ins: the shells
get a PATH of two folders made here, so nothing in this file can reach a
sound server, and no speaker's level is anything but a file under tmp_path.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

# Each case starts shells that wait on each other, and the module starts
# qmltestrunner once.
pytestmark = pytest.mark.slow

REPO = Path(__file__).resolve().parent.parent
QMLTESTRUNNER = os.environ.get("QMLTESTRUNNER", "/usr/lib/qt6/bin/qmltestrunner")
PRINTER = (
    "SyncEngine::test_the_measurement_and_its_cancel_go_out_as_the_dry_run_reads_them"
)
# What the two commands and the stand-ins call by name.
TOOLS = ("sh", "cat", "grep", "tr", "sleep", "timeout", "awk", "head")

# Two channels each and no two alike, so a restore that lost the balance or
# crossed two speakers shows.
LEVELS = ("70% 40%", "62% 62%", "35% 90%")
# The combined sink's own level, which the check after a calibration lifts.
MASTER = "80% 80%"

PACTL = r"""#!/bin/sh
# Keeps each sink's level in a file and writes every call down. A level
# query waits for as long as the test holds it.
echo "$*" >> "$ONAIR_RIG/pactl.log"
key() { printf %s "$1" | tr -c 'A-Za-z0-9' '_'; }
case "$1" in
get-sink-volume)
    n=$(grep -c '^get-sink-volume' "$ONAIR_RIG/pactl.log")
    : > "$ONAIR_RIG/query-$n-entered"
    i=0
    while [ -e "$ONAIR_RIG/hold-query-$n" ] && [ "$i" -lt 1500 ]; do
        sleep 0.02; i=$((i + 1))
    done
    set -- $(cat "$ONAIR_RIG/vol-$(key "$2")")
    echo "Volume: front-left: 45875 /  $1 / -9.29 dB,   front-right: 26214 /  $2 / -23.88 dB"
    ;;
set-sink-volume)
    f="$ONAIR_RIG/vol-$(key "$2")"
    shift 2
    [ $# -eq 1 ] && set -- "$1" "$1"
    echo "$*" > "$f"
    ;;
list)
    [ "$2" = sink-inputs ] && printf 'Sink Input #51\n\tOwner Module: 101\nSink Input #52\n\tOwner Module: 102\n'
    ;;
esac
exit 0
"""

PYTHON = r"""#!/bin/sh
# The measurement: it starts, says so, and runs until the test lets it go or
# somebody ends it.
echo "start" >> "$ONAIR_RIG/python.log"
i=0
while [ ! -e "$ONAIR_RIG/python-release" ] && [ "$i" -lt 1500 ]; do
    sleep 0.02; i=$((i + 1))
done
echo "end" >> "$ONAIR_RIG/python.log"
echo "CALIB_FAIL stand-in"
"""

# The launch ends by removing its pid file, and nothing else removes it. A
# measurement that is ended a millisecond after it was started may never get
# to say "start", so this is how a launch is seen for certain: by the tidying
# up that only a launch does.
RM = r"""#!/bin/sh
echo "$*" >> "$ONAIR_RIG/rm.log"
exec %s "$@"
"""

# cat is how the measurement looks at the cancel mark. This one counts the
# looks, and after the look a test names it runs the cancel: the mark lands
# when the shell has just been told there is none.
CAT = r"""#!/bin/sh
%s "$@"
rc=$?
case "$*" in *onair_calib_*.off*) ;; *) exit $rc ;; esac
echo look >> "$ONAIR_RIG/looks.log"
n=$(grep -c look "$ONAIR_RIG/looks.log")
if [ -e "$ONAIR_RIG/cancel-after-look-$n" ]; then
    [ -e "$ONAIR_RIG/python.log" ] || : > "$ONAIR_RIG/cancelled-before-the-start"
    sh "$ONAIR_RIG/cancel.sh" >/dev/null 2>&1
    : > "$ONAIR_RIG/cancel-fired"
fi
exit $rc
"""


def _commands() -> dict:
    done = subprocess.run(
        [
            QMLTESTRUNNER,
            "-input",
            str(REPO / "tests" / "qml" / "tst_syncengine.qml"),
            PRINTER,
        ],
        capture_output=True,
        text=True,
        timeout=120,
        env=dict(os.environ, QT_QPA_PLATFORM="offscreen"),
    )
    for line in (done.stdout + done.stderr).splitlines():
        at = line.find("ONAIR_CALIB_DRYRUN ")
        if at >= 0:
            return json.loads(line[at + len("ONAIR_CALIB_DRYRUN ") :])
    raise AssertionError("the engine printed no commands:\n" + done.stdout[-2000:])


@pytest.fixture(scope="module")
def commands() -> dict:
    if not os.path.exists(QMLTESTRUNNER):
        pytest.skip("Qt 6 qmltestrunner is not installed")
    return _commands()


class Room:
    """Three speakers that are files, and the engine's commands for them."""

    def __init__(self, tmp: Path, cmd: dict) -> None:
        tmp.mkdir(exist_ok=True)
        self.cmd = cmd
        self.rig = tmp / "rig"
        self.run_dir = tmp / "run o'neil"
        self.stubs = tmp / "stubs"
        tools = tmp / "tools"
        for d in (self.rig, self.run_dir, self.stubs, tools):
            d.mkdir()
        self.run_dir.chmod(0o700)
        for name in TOOLS:
            found = shutil.which(name)
            assert found, name
            (tools / name).symlink_to(found)
        self._stub("pactl", PACTL)
        self._stub("python3", PYTHON)
        self._stub("rm", RM % shutil.which("rm"))
        self.path = "%s:%s" % (self.stubs, tools)
        self.shells: list[subprocess.Popen[str]] = []
        # What the last shell that was waited for wrote to stderr.
        self.complaints = ""
        for sink, level in zip(cmd["sinks"], LEVELS, strict=True):
            self._level_file(sink).write_text(level + "\n")
        self._level_file(cmd["master"]).write_text(MASTER + "\n")

    def _stub(self, name: str, body: str) -> None:
        path = self.stubs / name
        path.write_text(body)
        path.chmod(0o755)

    def _level_file(self, sink: str) -> Path:
        return self.rig / ("vol-" + re.sub(r"[^A-Za-z0-9]", "_", sink))

    def _env(self, runtime: bool | Path = True) -> dict[str, str]:
        """True is the room's own runtime folder, False none at all, and a
        path is that folder, whether it is there or not."""
        env = {"PATH": self.path, "ONAIR_RIG": str(self.rig), "HOME": str(self.rig)}
        if runtime is True:
            env["XDG_RUNTIME_DIR"] = str(self.run_dir)
        elif runtime:
            env["XDG_RUNTIME_DIR"] = str(runtime)
        return env

    def shell(self, cmd: str, runtime: bool | Path = True) -> subprocess.Popen[str]:
        head = re.match(r":[^;]*;\s*", cmd)
        assert head, "not one of the engine's commands: " + cmd[:60]
        env = self._env(runtime)
        proc = subprocess.Popen(
            [
                "sh",
                "-c",
                head.group(0) + "export LC_ALL=C LANGUAGE=C; " + cmd[head.end() :],
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.shells.append(proc)
        return proc

    def cancel(self, kill: str = "kill") -> None:
        assert self.shell(self.cmd[kill]).wait(timeout=20) == 0

    def park_file(self) -> Path:
        return self.run_dir / "onair_park_7.sh"

    def replay(self, script: Path) -> None:
        """What the next session does with a park file it finds: runs it."""
        done = subprocess.run(["sh", str(script)], env=self._env(), timeout=20)
        assert done.returncode == 0

    def master(self) -> str:
        return self._level_file(self.cmd["master"]).read_text().strip()

    def cancel_after_look(self, n: int) -> None:
        """The cancel lands right after the measurement's n-th look at the
        mark has told it there is none."""
        (self.rig / "cancel.sh").write_text(self.cmd["kill"] + "\n")
        (self.rig / ("cancel-after-look-%d" % n)).touch()
        self._stub("cat", CAT % shutil.which("cat"))

    def has(self, name: str) -> bool:
        return (self.rig / name).exists()

    def hold_query(self, n: int) -> None:
        (self.rig / ("hold-query-%d" % n)).touch()

    def release_query(self, n: int) -> None:
        (self.rig / ("hold-query-%d" % n)).unlink()

    def wait_for(self, name: str, within: float = 15.0) -> None:
        end = time.monotonic() + within
        while not (self.rig / name).exists():
            assert time.monotonic() < end, "never happened: " + name
            time.sleep(0.01)

    def let_python_go(self) -> None:
        (self.rig / "python-release").touch()

    def ended(self, shell: subprocess.Popen[str], within: float = 15.0) -> str:
        """What the shell said. A failure when it is still running: the
        stand-in measurement only ends when it is let go or killed."""
        try:
            out, self.complaints = shell.communicate(timeout=within)
        except subprocess.TimeoutExpired:
            raise AssertionError("the measurement shell is still running") from None
        return out

    def begins(self, shell: subprocess.Popen[str], within: float = 15.0) -> None:
        """The measurement starts. A shell that ends before it does has left
        the room as it stands, and the failure says how."""
        end = time.monotonic() + within
        while not self.has("python.log"):
            assert shell.poll() is None, (
                "the shell ended before it measured, with the levels at %s"
                % (self.levels(),)
            )
            assert time.monotonic() < end, "never happened: python.log"
            time.sleep(0.01)

    def called_off(self, shell: subprocess.Popen[str], within: float = 15.0) -> None:
        """The shell ends by itself and no measurement was ever started."""
        end = time.monotonic() + within
        while shell.poll() is None:
            assert not self.has("python.log"), (
                "the measurement started after it was called off"
            )
            assert time.monotonic() < end, "the measurement shell is still running"
            time.sleep(0.01)
        assert not self.has("python.log"), (
            "the measurement started after it was called off"
        )
        assert not self.launched(), "a measurement was launched after it was called off"

    def launched(self) -> bool:
        """Whether the shell got as far as starting calibrate.py at all."""
        log = self.rig / "rm.log"
        if not log.exists():
            return False
        return any(line.endswith(".pid") for line in log.read_text().splitlines())

    def started(self) -> bool:
        log = self.rig / "python.log"
        return log.exists() and "start" in log.read_text()

    def ran_to_its_end(self) -> bool:
        log = self.rig / "python.log"
        return log.exists() and "end" in log.read_text()

    def levels(self) -> tuple[str, ...]:
        return tuple(self._level_file(s).read_text().strip() for s in self.cmd["sinks"])

    def calls(self, word: str) -> list[str]:
        log = self.rig / "pactl.log"
        if not log.exists():
            return []
        return [line for line in log.read_text().splitlines() if line.startswith(word)]

    def left_in_runtime(self) -> list[str]:
        """What is still in the runtime folder, the cancel mark aside."""
        return sorted(
            p.name for p in self.run_dir.iterdir() if not p.name.endswith(".off")
        )

    def close(self) -> None:
        for proc in self.shells:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=10)


@pytest.fixture
def room(tmp_path: Path, commands: dict) -> Iterator[Room]:
    r = Room(tmp_path, commands)
    yield r
    r.close()


def test_an_uncancelled_measurement_parks_runs_and_puts_every_level_back(
    room: Room,
) -> None:
    """The room the other cases are read against: the stand-ins do see a
    measurement start, and do see the park."""
    shell = room.shell(room.cmd["run"])
    room.wait_for("python.log")
    assert room.levels() == ("55% 55%", "55% 55%", "55% 55%")
    assert room.calls("set-sink-input-volume") == ["set-sink-input-volume 51 100%"]
    assert "onair_calib_7.pid" in room.left_in_runtime()
    room.let_python_go()
    out = room.ended(shell)
    assert room.ran_to_its_end() and room.launched()
    assert room.levels() == LEVELS
    assert room.calls("set-sink-input-volume")[-1] == "set-sink-input-volume 51 50%"
    assert "CALIBVOL " + room.cmd["sinks"][0] + " 70% 40%" in out
    assert room.left_in_runtime() == []


def test_cancel_before_the_first_query_leaves_the_room_untouched(room: Room) -> None:
    room.cancel()
    shell = room.shell(room.cmd["run"])
    room.called_off(shell)
    assert room.calls("get-sink-volume") == []
    assert room.calls("set-sink-volume") == []
    assert room.calls("set-sink-input-volume") == []
    assert room.levels() == LEVELS
    assert room.left_in_runtime() == []


def test_cancel_during_the_first_query_parks_nothing_and_starts_nothing(
    room: Room,
) -> None:
    room.hold_query(1)
    shell = room.shell(room.cmd["run"])
    room.wait_for("query-1-entered")
    room.cancel()
    room.release_query(1)
    room.called_off(shell)
    # The speaker that was being asked answers; the others are not asked.
    assert len(room.calls("get-sink-volume")) == 1
    assert room.calls("set-sink-volume") == []
    assert room.calls("set-sink-input-volume") == []
    assert room.levels() == LEVELS
    assert room.left_in_runtime() == []


def test_cancel_after_one_speaker_was_parked_puts_that_one_back_and_touches_no_other(
    room: Room,
) -> None:
    room.hold_query(2)
    shell = room.shell(room.cmd["run"])
    room.wait_for("query-2-entered")
    assert room.levels() == ("55% 55%",) + LEVELS[1:]
    room.cancel()
    room.release_query(2)
    room.called_off(shell)
    assert room.levels() == LEVELS
    wired = room.cmd["sinks"][0]
    assert room.calls("set-sink-volume") == [
        "set-sink-volume %s 55%%" % wired,
        "set-sink-volume %s 70%% 40%%" % wired,
    ]
    assert room.calls("set-sink-input-volume") == []
    assert room.left_in_runtime() == []


def test_cancel_once_the_pid_is_written_ends_the_measurement_and_restores(
    room: Room,
) -> None:
    shell = room.shell(room.cmd["run"])
    room.wait_for("python.log")
    room.cancel()
    room.ended(shell)
    assert room.started() and not room.ran_to_its_end()
    assert room.levels() == LEVELS
    assert room.calls("set-sink-input-volume")[-1] == "set-sink-input-volume 51 50%"
    assert room.left_in_runtime() == []


def test_a_cancel_landing_right_after_any_look_at_the_mark_is_still_obeyed(
    tmp_path: Path, commands: dict
) -> None:
    """The narrowest place is between the last look before the start and the
    pid being written: the shell has just been told there is no mark, and the
    cancel finds no pid to kill. So the cancel is dropped in right after the
    first look, then the second, and so on through every look the shell
    makes; each time the measurement must be off and the levels back."""
    narrow = False
    for k in range(1, 40):
        room = Room(tmp_path / ("look-%d" % k), commands)
        try:
            room.cancel_after_look(k)
            shell = room.shell(room.cmd["run"])
            end = time.monotonic() + 15
            while shell.poll() is None and not room.has("python.log"):
                assert time.monotonic() < end, "look %d: neither started nor ended" % k
                time.sleep(0.01)
            if shell.poll() is None and not room.has("cancel-fired"):
                # Started with no cancel yet: either the look after the pid
                # is the k-th and fires in a moment, or there is no k-th.
                end = time.monotonic() + 1.5
                while (
                    shell.poll() is None
                    and not room.has("cancel-fired")
                    and time.monotonic() < end
                ):
                    time.sleep(0.01)
                if not room.has("cancel-fired"):
                    room.let_python_go()
                    room.ended(shell)
                    break
            room.ended(shell, within=8)
            assert not room.ran_to_its_end(), "look %d" % k
            assert room.levels() == LEVELS, "look %d" % k
            assert room.left_in_runtime() == [], "look %d" % k
            narrow = narrow or (
                room.started() and room.has("cancelled-before-the-start")
            )
        finally:
            room.close()
    else:
        raise AssertionError("the shell never ran out of looks")
    assert k > 2, "the measurement never looked at the mark"
    assert narrow, "no cancel landed between the last look and the start"


def test_the_next_measurement_is_not_stopped_by_the_last_ones_cancel(
    room: Room,
) -> None:
    room.cancel()
    shell = room.shell(room.cmd["next"])
    room.wait_for("python.log")
    assert room.levels() == ("55% 55%", "55% 55%", "55% 55%")
    room.let_python_go()
    room.ended(shell)
    assert room.ran_to_its_end()
    assert room.levels() == LEVELS


@pytest.mark.parametrize(
    "mark",
    [
        "",
        "\n",
        "1",
        "no such run",
        "x" * 200000,
        "'; : > \"$ONAIR_RIG/owned\"; '",
        None,
    ],
    ids=[
        "empty",
        "newline",
        "a-bare-number",
        "words",
        "very-long",
        "shell-text",
        "a-folder",
    ],
)
def test_a_mark_that_is_not_this_runs_stops_nothing(
    room: Room, mark: str | None
) -> None:
    """Whatever an earlier session, another widget or a full disk left where
    the mark lives, only this run's own token calls it off."""
    path = room.run_dir / "onair_calib_7.off"
    if mark is None:
        path.mkdir()
    else:
        path.write_text(mark)
    shell = room.shell(room.cmd["run"])
    room.wait_for("python.log")
    room.let_python_go()
    room.ended(shell)
    assert room.ran_to_its_end()
    assert room.levels() == LEVELS
    assert not (room.rig / "owned").exists()


@pytest.mark.parametrize("which", ["run", "check"])
def test_without_a_runtime_folder_the_measurement_still_runs_and_restores(
    room: Room, which: str
) -> None:
    """No runtime folder means no pid file, no mark and no park file, as
    before: the run cannot be called off, and it must not be taken for one
    that was. With the variable unset the park file's path would be
    /onair_park_7.sh, and nothing may be sent there: the shell does not
    even try, so it has nothing to say about it."""
    shell = room.shell(room.cmd[which], runtime=False)
    room.begins(shell)
    assert room.levels() == ("55% 55%", "55% 55%", "55% 55%")
    kill = "kill" if which == "run" else "checkKill"
    assert room.shell(room.cmd[kill], runtime=False).wait(timeout=20) == 0
    room.let_python_go()
    room.ended(shell)
    assert room.ran_to_its_end()
    assert room.levels() == LEVELS
    assert room.master() == MASTER
    assert "onair_park" not in room.complaints
    assert room.left_in_runtime() == []


def test_the_check_after_a_calibration_runs_and_puts_every_level_back(
    room: Room,
) -> None:
    """The check's own room to read against: it parks the members and lifts
    the combined sink, and all of it comes back."""
    shell = room.shell(room.cmd["check"])
    room.wait_for("python.log")
    assert room.levels() == ("55% 55%", "55% 55%", "55% 55%")
    assert room.master() == "100% 100%"
    room.let_python_go()
    room.ended(shell)
    assert room.ran_to_its_end()
    assert room.levels() == LEVELS
    assert room.master() == MASTER
    assert room.left_in_runtime() == []


@pytest.mark.parametrize(
    "query", [1, 2, 4], ids=["the-master", "the-first-member", "the-last-member"]
)
def test_a_check_called_off_while_it_reads_the_levels_never_starts(
    room: Room, query: int
) -> None:
    room.hold_query(query)
    shell = room.shell(room.cmd["check"])
    room.wait_for("query-%d-entered" % query)
    room.cancel("checkKill")
    room.release_query(query)
    room.called_off(shell)
    assert room.levels() == LEVELS
    assert room.master() == MASTER
    assert room.left_in_runtime() == []


def test_a_check_called_off_once_its_pid_is_written_ends_and_restores(
    room: Room,
) -> None:
    shell = room.shell(room.cmd["check"])
    room.wait_for("python.log")
    room.cancel("checkKill")
    room.ended(shell)
    assert room.started() and not room.ran_to_its_end()
    assert room.levels() == LEVELS
    assert room.master() == MASTER
    assert room.left_in_runtime() == []


def test_a_shell_that_dies_with_the_room_parked_leaves_the_levels_written_down(
    room: Room,
) -> None:
    """What the park file is for. A logout ends the shell with every speaker
    at the measuring level and its restore lines unrun; the file holds what
    each speaker was at, and the next session plays it back."""
    shell = room.shell(room.cmd["run"])
    room.wait_for("python.log")
    lines = [line.rstrip() for line in room.park_file().read_text().splitlines()]
    assert lines == [
        "pactl set-sink-volume '%s' %s" % (sink, level)
        for sink, level in zip(room.cmd["sinks"], LEVELS, strict=True)
    ]
    os.killpg(shell.pid, signal.SIGKILL)
    shell.wait(timeout=10)
    assert room.levels() == ("55% 55%", "55% 55%", "55% 55%")
    room.replay(room.park_file())
    assert room.levels() == LEVELS


def test_the_checks_park_file_holds_the_master_the_members_and_their_mutes(
    room: Room,
) -> None:
    shell = room.shell(room.cmd["check"])
    room.wait_for("python.log")
    lines = [line.rstrip() for line in room.park_file().read_text().splitlines()]
    want = ["pactl set-sink-volume '%s' 80%%" % room.cmd["master"]]
    for sink, level in zip(room.cmd["sinks"], LEVELS, strict=True):
        want.append("pactl set-sink-volume '%s' %s" % (sink, level))
        want.append("pactl set-sink-mute '%s' 0" % sink)
    assert lines == want
    room.let_python_go()
    room.ended(shell)
    assert room.left_in_runtime() == []


@pytest.mark.parametrize("which", ["run", "check"])
def test_a_runtime_folder_that_is_not_there_costs_the_park_file_and_not_the_levels(
    room: Room, which: str
) -> None:
    """The variable can name a folder that is gone. The shell then cannot
    start its park file, and it used to end right there: `: > file` is a
    special builtin with a redirection that fails, and a POSIX shell exits on
    that. Seen with the engine's own command: every speaker left at 55 %,
    nothing measured, nothing put back. The park file is insurance for the
    way back, so losing it must not cost the way back itself."""
    gone = room.rig / "no such folder"
    shell = room.shell(room.cmd[which], runtime=gone)
    room.begins(shell)
    assert room.levels() == ("55% 55%", "55% 55%", "55% 55%")
    # A cancel has nowhere to leave its mark and no pid to read. It must not
    # fail over that, and the run goes on to its end.
    kill = "kill" if which == "run" else "checkKill"
    assert room.shell(room.cmd[kill], runtime=gone).wait(timeout=20) == 0
    room.let_python_go()
    room.ended(shell)
    assert shell.returncode == 0
    assert room.ran_to_its_end()
    assert room.levels() == LEVELS
    assert room.master() == MASTER
    assert not gone.exists()
    # The shell says once that the file could not be started, and does not
    # try a single line of it after that.
    assert room.complaints.count("onair_park_7.sh") == 1, room.complaints


@pytest.mark.parametrize("which", ["run", "check"])
def test_a_park_file_that_cannot_be_started_is_not_written_to_and_stops_nothing(
    room: Room, which: str
) -> None:
    """The folder is fine and the file is not: something else sits where it
    should go. Nothing is added to that, the measurement runs, and a cancel
    works as it always does, since the pid and the mark have their folder."""
    blocked = room.park_file()
    blocked.mkdir()
    (blocked / "not ours").write_text("keep")
    shell = room.shell(room.cmd[which])
    room.begins(shell)
    assert room.levels() == ("55% 55%", "55% 55%", "55% 55%")
    room.cancel("kill" if which == "run" else "checkKill")
    room.ended(shell)
    assert room.started() and not room.ran_to_its_end()
    assert room.levels() == LEVELS
    assert room.master() == MASTER
    assert [p.name for p in blocked.iterdir()] == ["not ours"]
