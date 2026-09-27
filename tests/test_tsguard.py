# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The buffer writer's guard and the startup sweep, run against real processes.

Found on the bench 2026-09-23: kill the widget's host without a teardown and
the relay writer (sh, timeout, curl, ffmpeg -t 3600) lived on under the user's
systemd, copying a FLAC station at ~128 KiB/s into a file nobody would read,
for up to an hour. The next start did not look for it either.

Nothing here touches the network or a real ffmpeg. A "writer" is a python
sleeper whose argv carries the buffer path the way ffmpeg's -y does, because
that path is exactly what the sweep checks before it kills anything.
"""

import os
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "package" / "contents" / "ui" / "tsguard.sh"
TICK = "0.2"


def _gone(pid: int) -> bool:
    """True once the pid is dead or a zombie waiting for its parent."""
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (FileNotFoundError, ProcessLookupError, IndexError):
        return True
    return state == "Z"


def _wait_gone(pid: int, secs: float) -> bool:
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if _gone(pid):
            return True
        time.sleep(0.05)
    return _gone(pid)


def _read_int(path: Path, secs: float = 5.0) -> int:
    end = time.monotonic() + secs
    while time.monotonic() < end:
        try:
            text = path.read_text().strip()
        except FileNotFoundError:
            text = ""
        if text:
            return int(text)
        time.sleep(0.02)
    raise AssertionError("%s never appeared" % path)


def _writer_argv(buf: Path, secs: float = 60.0) -> list[str]:
    # The handler is ffmpeg's habit, and it matters: a background job of a
    # non-interactive shell starts with SIGINT ignored, and ffmpeg installs
    # its own handler over that (term_init) — python only does when it finds
    # SIGINT at its default, so without this line the fake would shrug off
    # the very signal the real writer obeys.
    code = (
        "import signal, sys, time; "
        "signal.signal(signal.SIGINT, lambda *_: sys.exit(0)); time.sleep(%s)" % secs
    )
    return [sys.executable, "-c", code, "-y", str(buf)]


def _catches_sigint(pid: int, secs: float = 5.0) -> None:
    """Wait until the fake writer has its handler in, or has already ended.

    Until then a writer started with SIGINT ignored (any job a script puts
    in the background, and everything under it) drops the stop on the floor.
    The sweep tests sent it a few milliseconds after the start. In the
    foreground the default action mostly killed the fake before its handler
    existed, so the tests passed without asking it; from a background job
    the stop was lost and two sweep tests failed every time (measured
    2026-09-23: 5 of 5 background runs red, 1 of 11 foreground runs red with
    the failing test not recorded; with the wait, 15 foreground and 3
    background runs green).
    """
    bit = 1 << (signal.SIGINT - 1)
    end = time.monotonic() + secs
    while time.monotonic() < end:
        try:
            status = Path(f"/proc/{pid}/status").read_text()
        except (FileNotFoundError, ProcessLookupError):
            return
        caught = next(
            (ln.split()[1] for ln in status.splitlines() if ln.startswith("SigCgt:")),
            "0",
        )
        if int(caught, 16) & bit or _gone(pid):
            return
        time.sleep(0.01)
    raise AssertionError("the fake writer %d never put its SIGINT handler in" % pid)


class Family:
    """A fake host, the TS_RUN-shaped shell under it, and the writer the shell
    waits on, with the guard started the way the real run command starts it."""

    def __init__(self, tmp: Path, writer_secs: float = 60.0):
        self.tmp = tmp
        shell = tmp / "shell.sh"
        shell.write_text(
            textwrap.dedent("""\
            "$@" 2>/dev/null &
            pid=$!
            bash "$GUARD" watch "$$" "$PPID" "$pid" "$TICK" >/dev/null 2>&1 &
            echo $! > "$DIR/guard.pid"
            echo "$$" > "$DIR/shell.pid"
            echo "$pid" > "$DIR/writer.pid"
            wait "$pid"
            echo done > "$DIR/shell.done"
            """)
        )
        env = {**os.environ, "GUARD": str(GUARD), "TICK": TICK, "DIR": str(tmp)}
        # The host is a shell that waits on the TS_RUN shell, so killing the
        # host leaves that shell to be taken in by whoever adopts orphans.
        argv = ["bash", "-c", 'sh "$0" "$@"; :', str(shell)] + _writer_argv(
            tmp / "buffer-1.ogg", writer_secs
        )
        self.host = subprocess.Popen(
            argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        self.writer = _read_int(tmp / "writer.pid")
        _catches_sigint(self.writer)
        self.shell = _read_int(tmp / "shell.pid")
        self.guard = _read_int(tmp / "guard.pid")

    def cleanup(self) -> None:
        for pid in (self.writer, self.guard, self.shell):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.host.poll() is None:
            self.host.kill()
        self.host.wait(timeout=5)


def test_a_writer_whose_host_dies_is_stopped(tmp_path):
    fam = Family(tmp_path)
    try:
        assert not _gone(fam.writer)
        fam.host.kill()
        fam.host.wait(timeout=5)
        assert _wait_gone(fam.writer, 3.0), (
            "the host died and the writer kept running — this is the orphan "
            "that copied a FLAC station into the cache for an hour"
        )
        assert _wait_gone(fam.guard, 3.0), "the guard outlived the writer it stopped"
    finally:
        fam.cleanup()


def test_a_writer_whose_shell_is_killed_is_stopped(tmp_path):
    # QProcess kills the process it started when it is destroyed, and not
    # that process's children: on a host that exits cleanly but too fast for
    # the teardown's stop, the shell can go while the pipeline under it stays.
    fam = Family(tmp_path)
    try:
        os.kill(fam.shell, signal.SIGKILL)
        assert _wait_gone(fam.writer, 3.0), (
            "the shell is gone and nobody stopped its writer"
        )
    finally:
        fam.cleanup()


def test_a_living_host_keeps_its_writer(tmp_path):
    fam = Family(tmp_path)
    try:
        time.sleep(1.2)  # six of the guard's ticks
        assert not _gone(fam.writer), "the guard stopped a writer whose host is alive"
        assert not _gone(fam.guard), "the guard left while its writer still runs"
    finally:
        fam.cleanup()


def test_the_guard_leaves_with_a_writer_that_ends_on_its_own(tmp_path):
    fam = Family(tmp_path, writer_secs=0.3)
    try:
        assert _wait_gone(fam.writer, 3.0)
        assert _wait_gone(fam.guard, 2.0), (
            "the writer finished and its guard is still running — one idle "
            "guard per station change would pile up for the whole session"
        )
        assert (tmp_path / "shell.done").exists(), "the shell never saw its writer end"
    finally:
        fam.cleanup()


def test_the_guard_refuses_to_guess_without_its_arguments(tmp_path):
    p = subprocess.run(
        ["bash", str(GUARD), "watch"], capture_output=True, text=True, timeout=10
    )
    assert p.returncode != 0


# ---------------------------------------------------------------- the sweep


def _dead_pid() -> int:
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


def _touch(path: Path, age_s: float = 0.0, body: str = "x") -> Path:
    path.write_text(body)
    if age_s:
        t = time.time() - age_s
        os.utime(path, (t, t))
    return path


def _sweep(d: Path, since: int) -> str:
    p = subprocess.run(
        ["bash", str(GUARD), "sweep", str(d), str(since)],
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert p.returncode == 0, p.stderr
    return p.stdout


class Sweepable:
    """Two instance directories and every kind of thing the sweep meets."""

    def __init__(self, tmp: Path):
        self.a = tmp / "onair-timeshift-1"
        self.b = tmp / "onair-timeshift-2"
        self.a.mkdir()
        self.b.mkdir()
        self.procs: list[subprocess.Popen] = []
        self.since = int(time.time()) - 60
        me, my_parent, dead = os.getpid(), os.getppid(), _dead_pid()
        # Seq 5 in A: the crashed session's writer. Its shell is alive but no
        # longer the child of the host it recorded — the reparented shape.
        self.orphan = self._writer(self.a / "buffer-5.ogg")
        _touch(self.a / "writer-5.pid", body="%d %d %d\n" % (self.orphan.pid, me, dead))
        for name in ("url-5.cfg", "serve-5.pid", "serve-5.port"):
            _touch(self.a / name, age_s=600)
        _touch(self.a / "buffer-5.ogg")
        # Seq 7 in A: a writer whose recorded shell still sits under its
        # recorded host. Old files, on purpose: age alone must not doom it.
        self.living = self._writer(self.a / "buffer-7.ogg")
        _touch(
            self.a / "writer-7.pid",
            age_s=3600,
            body="%d %d %d\n" % (self.living.pid, me, my_parent),
        )
        _touch(self.a / "url-7.cfg", age_s=3600)
        _touch(self.a / "buffer-7.ogg", age_s=3600)
        # Seq 9 in A: the pid file points at a process that is not our
        # writer (the number went to someone else).
        self.stranger = subprocess.Popen(["sleep", "30"])
        self.procs.append(self.stranger)
        _touch(
            self.a / "writer-9.pid", body="%d %d %d\n" % (self.stranger.pid, me, dead)
        )
        _touch(self.a / "buffer-9.ogg", age_s=600)
        # Seq 13 in A: a pid file from before the owner was written down.
        self.old_style = self._writer(self.a / "buffer-13.mka")
        _touch(self.a / "writer-13.pid", body="%d\n" % self.old_style.pid)
        # Leftovers with no writer at all: older than the session, and fresh
        # (an arm of THIS session between its url write and its launch).
        _touch(self.a / "buffer-3.ogg", age_s=7200)
        _touch(self.a / "url-3.cfg", age_s=7200)
        _touch(self.a / "serve-3.port.tmp", age_s=7200)
        _touch(self.a / "url-11.cfg")
        _touch(self.a / "notes.txt", age_s=7200)
        # B is another widget. Its writer even LOOKS orphaned; A's sweep has
        # no business in B at all.
        self.other = self._writer(self.b / "buffer-5.ogg")
        _touch(self.b / "writer-5.pid", body="%d %d %d\n" % (self.other.pid, me, dead))
        _touch(self.b / "url-5.cfg", age_s=7200)
        _touch(self.b / "buffer-5.ogg", age_s=7200)

    def _writer(self, buf: Path) -> subprocess.Popen:
        p = subprocess.Popen(
            _writer_argv(buf), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        self.procs.append(p)
        _catches_sigint(p.pid)
        return p

    def names(self, d: Path) -> set[str]:
        return {p.name for p in d.iterdir()}

    def cleanup(self) -> None:
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait(timeout=5)


def _dies(p: subprocess.Popen, secs: float = 5.0) -> bool:
    try:
        p.wait(timeout=secs)
    except subprocess.TimeoutExpired:
        return False
    return True


def test_the_sweep_stops_the_crashed_sessions_writer_and_clears_its_files(tmp_path):
    s = Sweepable(tmp_path)
    try:
        out = _sweep(s.a, s.since)
        assert _dies(s.orphan), (
            "the crashed session's writer is still running after the sweep"
        )
        left = s.names(s.a)
        for name in (
            "writer-5.pid",
            "url-5.cfg",
            "buffer-5.ogg",
            "serve-5.pid",
            "serve-5.port",
        ):
            assert name not in left, "%s outlived the writer it belonged to" % name
        assert "__TS_SWEEP__ stopped=2 " in out, out
    finally:
        s.cleanup()


def test_the_sweep_leaves_a_living_writer_alone(tmp_path):
    s = Sweepable(tmp_path)
    try:
        _sweep(s.a, s.since)
        assert not _dies(s.living, 0.5), (
            "the sweep stopped a writer whose host is alive"
        )
        assert {"writer-7.pid", "url-7.cfg", "buffer-7.ogg"} <= s.names(s.a), (
            "a living writer's files went, old as they were"
        )
    finally:
        s.cleanup()


def test_the_sweep_never_reaches_into_another_widgets_directory(tmp_path):
    s = Sweepable(tmp_path)
    try:
        _sweep(s.a, s.since)
        assert not _dies(s.other, 0.5), (
            "sweeping one widget stopped another widget's writer"
        )
        assert s.names(s.b) == {"writer-5.pid", "url-5.cfg", "buffer-5.ogg"}
    finally:
        s.cleanup()


def test_a_pid_that_went_to_someone_else_is_not_killed(tmp_path):
    s = Sweepable(tmp_path)
    try:
        _sweep(s.a, s.since)
        assert not _dies(s.stranger, 0.5), (
            "the sweep killed a process that was never our writer"
        )
        assert not {"writer-9.pid", "buffer-9.ogg"} & s.names(s.a)
    finally:
        s.cleanup()


def test_a_writer_from_before_the_owner_was_recorded_is_stopped(tmp_path):
    s = Sweepable(tmp_path)
    try:
        _sweep(s.a, s.since)
        assert _dies(s.old_style), "a one-field pid file's writer survived the sweep"
        assert "writer-13.pid" not in s.names(s.a)
    finally:
        s.cleanup()


def test_the_sweep_clears_old_leftovers_and_keeps_this_sessions_files(tmp_path):
    s = Sweepable(tmp_path)
    try:
        _sweep(s.a, s.since)
        left = s.names(s.a)
        assert not {"buffer-3.ogg", "url-3.cfg", "serve-3.port.tmp"} & left, (
            "a dead session's buffer stayed in the cache"
        )
        assert "url-11.cfg" in left, (
            "the sweep took a file newer than the session's start — that is "
            "this session's own arm, and without its url file the writer dies at birth"
        )
        assert "notes.txt" in left, "the sweep deleted a file it does not own"
    finally:
        s.cleanup()


def test_a_missing_directory_is_nothing_to_sweep(tmp_path):
    out = _sweep(tmp_path / "never-made", int(time.time()))
    assert "__TS_SWEEP__ stopped=0 removed=0" in out
    assert not (tmp_path / "never-made").exists()
