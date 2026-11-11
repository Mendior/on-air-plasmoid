# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Stop against a capture shell that is still getting ready.

The capture is one shell command: it checks its tools, makes the folder, asks
df for the free space, and only then starts curl into ffmpeg and writes
ffmpeg's pid down. Stop read that pid file once. Measured on 2026-11-10 with
df held back: at Stop there was no pid file, nothing was signalled, and the
shell went on to ask for the stream and wrote 159819 bytes of it. A stop sent
the moment the pid file appeared was lost too, because the ffmpeg behind it
was a few milliseconds old and still ignored SIGINT (SigIgn 0x6, no handler
yet); 50 ms later the same stop worked.

The commands are the engine's own. qmltestrunner drives RecordingEngine.qml
behind a stand-in widget and prints what it hands to the shell, and that text
runs here under sh as main.qml's exec() would send it, against a station on
127.0.0.1 that sends silent MPEG frames. Nothing is played: the audio only
ever goes into a file under tmp_path.
"""

import http.server
import json
import os
import re
import select
import shutil
import signal
import subprocess
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import pytest

# Each case starts qmltestrunner and a real curl into ffmpeg.
pytestmark = pytest.mark.slow

UI = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"
QMLTESTRUNNER = os.environ.get("QMLTESTRUNNER", "/usr/lib/qt6/bin/qmltestrunner")
# What the capture and the stop call by name, and what the stand-ins need.
TOOLS = (
    "sh",
    "curl",
    "ffmpeg",
    "timeout",
    "df",
    "awk",
    "ps",
    "grep",
    "stat",
    "cat",
    "mkdir",
    "rm",
    "sleep",
)

# MPEG-1 layer III, 128 kb/s, 44.1 kHz, mono, and nothing in it: a header and
# an all-zero body is a valid frame of silence. 417 bytes, 1152 samples.
FRAME = bytes([0xFF, 0xFB, 0x90, 0xC4]) + bytes(413)
FRAMES_PER_SEC = 44100 / 1152

# Recording Alpha is started, its capture sent, stopped and answered for;
# recording Beta is started after it. Everything the engine gave the shell on
# the way is printed as one line of JSON.
_DRIVER = """
import QtQuick
import QtTest
import "%(ui)s"

TestCase {
    id: tc
    name: "RecordingCommands"
    property var sent: []
    property int seq: 0
    function i18n(s) { return s; }
    Component { id: engineComp; RecordingEngine {} }
    function test_print_the_commands() {
        var app = {
            exec: function(c) { tc.sent.push(c); },
            nextSeq: function() { return ++tc.seq; },
            notify: function(t, x, i) {},
            downloadDirPath: %(out)s,
            _mprisRunDir: %(run)s,
            _mprisId: "7",
            isPlaying: function() { return true; },
            upstreamSourceString: function() { return %(url)s; },
            currentStation: "Alpha FM",
            fadeStopInProgress: false
        };
        var e = engineComp.createObject(tc, { app: app, cfg: {
            recSchedules: "[]", recordFormat: "original", recordMaxMinutes: 120 } });
        e._recStart("Alpha FM", %(url)s, 60, false);
        e.handleExec(tc.sent[0], "__REC_URL_OK__", "", 0);
        e.recStop();
        var alpha = tc.sent;
        var token = e._recToken;
        e.handleExec(": REC_START;", "__REC_DONE__ rc=255 bytes=9999999", "", 0);
        tc.sent = [];
        e._recStart("Beta FM", %(url)s, 60, false);
        e.handleExec(tc.sent[0], "__REC_URL_OK__", "", 0);
        console.log("ONAIR_REC " + JSON.stringify({
            write: alpha[0], capture: alpha[1], stop: alpha[2], token: token,
            nextWrite: tc.sent[0], nextCapture: tc.sent[1],
            pidFile: e._recPidFile, markFile: e._recStopFile
        }));
    }
}
"""


class Rig:
    """One station, one set of folders and the engine's commands for them."""

    def __init__(self, tmp: Path, url: str, hits: Callable[[], int]) -> None:
        self.tmp = tmp
        self.url = url
        self.hits = hits
        self.out = tmp / "Music dir"
        self.run = tmp / "run"
        self.stubs = tmp / "stubs"
        self.run.mkdir()
        self.stubs.mkdir()
        self.path = "%s:%s" % (self.stubs, os.environ["PATH"])
        self.shells: list[subprocess.Popen[str]] = []
        self.cmd = self._commands()
        self.pid_file = Path(self.cmd["pidFile"])
        self.mark_file = Path(self.cmd["markFile"])
        # df answers when the test lets it: the preparation is held open
        # exactly as long as a case needs, with no sleep to guess at.
        self._stub(
            "df",
            ': > "$ONAIR_RIG/df-entered"\n'
            "n=0\n"
            'while [ ! -e "$ONAIR_RIG/df-release" ] && [ "$n" -lt 1000 ]; do\n'
            "  sleep 0.02; n=$((n + 1))\n"
            "done\n"
            'exec %s "$@"\n' % shutil.which("df"),
        )

    def _stub(self, name: str, body: str) -> None:
        path = self.stubs / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def _commands(self) -> dict[str, str]:
        driver = self.tmp / "tst_commands.qml"
        driver.write_text(
            _DRIVER
            % {
                "ui": UI.as_uri(),
                "out": json.dumps(str(self.out)),
                "run": json.dumps(str(self.run)),
                "url": json.dumps(self.url),
            }
        )
        done = subprocess.run(
            [QMLTESTRUNNER, "-input", str(driver)],
            capture_output=True,
            text=True,
            timeout=120,
            env=dict(os.environ, QT_QPA_PLATFORM="offscreen"),
        )
        for line in (done.stdout + done.stderr).splitlines():
            at = line.find("ONAIR_REC ")
            if at >= 0:
                return json.loads(line[at + len("ONAIR_REC ") :])
        raise AssertionError("the engine printed no commands:\n" + done.stdout)

    def slow_ffmpeg(self, seconds: float) -> None:
        """An ffmpeg that takes its time to load, as from a cold disk."""
        self._stub(
            "ffmpeg", 'sleep %s\nexec %s "$@"\n' % (seconds, shutil.which("ffmpeg"))
        )

    def hide(self, tool: str) -> None:
        """A machine without `tool`: every other one is linked into a folder
        of its own, and the shells get that folder for a PATH."""
        tools = self.tmp / "tools"
        tools.mkdir()
        for name in TOOLS:
            found = shutil.which(name)
            assert found and name != tool
            (tools / name).symlink_to(found)
        self.path = "%s:%s" % (self.stubs, tools)

    def release_df(self) -> None:
        (self.tmp / "df-release").touch()

    def shell(self, cmd: str) -> subprocess.Popen[str]:
        """Runs a command as the widget does: sh -c, with the locale export
        main.qml's exec() puts in after the sentinel."""
        head = re.match(r":[^;]*;\s*", cmd)
        assert head, "not one of the engine's commands: " + cmd[:60]
        env = dict(
            os.environ,
            PATH=self.path,
            ONAIR_RIG=str(self.tmp),
            NO_PROXY="127.0.0.1",
            no_proxy="127.0.0.1",
        )
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

    def start_capture(
        self, write: str = "write", capture: str = "capture"
    ) -> subprocess.Popen[str]:
        wrote = self.shell(self.cmd[write])
        assert "__REC_URL_OK__" in wrote.communicate(timeout=20)[0]
        return self.shell(self.cmd[capture])

    def stop(self) -> None:
        assert self.shell(self.cmd["stop"]).wait(timeout=20) == 0

    def ended(self, capture: subprocess.Popen[str], within: float = 15.0) -> str:
        """The capture shell's answer; a failure when it is still recording."""
        try:
            out, _ = capture.communicate(timeout=within)
        except subprocess.TimeoutExpired:
            pytest.fail("the capture was still running %.0f s later" % within)
        return out

    def recordings(self) -> list[Path]:
        return sorted(self.out.glob("*")) if self.out.exists() else []

    def close(self) -> None:
        self.release_df()
        for proc in self.shells:
            # Whatever a failed case left running goes with its shell.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=10)
            for pipe in (proc.stdout, proc.stderr):
                if pipe:
                    pipe.close()


def _until(what: Callable[[], Any], limit: float = 15.0) -> bool:
    end = time.monotonic() + limit
    while not what():
        if time.monotonic() > end:
            return False
        time.sleep(0.001)
    return True


def _read_pipe(path: Path, limit: float = 15.0) -> str:
    """What the other end writes into a named pipe, without waiting for
    ever on a writer that never comes."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        end = time.monotonic() + limit
        while time.monotonic() < end:
            if select.select([fd], [], [], 0.05)[0]:
                got = os.read(fd, 64)
                if got:
                    return got.decode()
            time.sleep(0.005)
    finally:
        os.close(fd)
    pytest.fail("nothing was written to %s" % path.name)


def _rig(tmp_path: Path, live: bool) -> Iterator[Rig]:
    for tool in TOOLS:
        if shutil.which(tool) is None:
            pytest.skip("%s is not installed" % tool)
    if shutil.which(QMLTESTRUNNER) is None:
        pytest.skip("Qt 6 qmltestrunner is not installed")

    off = threading.Event()
    asked: list[str] = []

    class Station(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            asked.append(self.path)
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.end_headers()
            try:
                if not live:
                    self.wfile.write(FRAME * int(10 * FRAMES_PER_SEC))
                    return
                # Two seconds up front, as a real server bursts on connect.
                sent = int(2 * FRAMES_PER_SEC)
                self.wfile.write(FRAME * sent)
                began = time.monotonic()
                while not off.is_set() and sent < 60 * FRAMES_PER_SEC:
                    due = int((2 + time.monotonic() - began) * FRAMES_PER_SEC)
                    if due > sent:
                        self.wfile.write(FRAME * (due - sent))
                        self.wfile.flush()
                        sent = due
                    time.sleep(0.02)
            except OSError:
                # The recorder hung up, which is what a stop looks like here.
                pass

        def log_message(self, format: str, *args: Any) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Station)
    server.daemon_threads = True
    # Asked every 50 ms whether to stop, so the teardown is not half a second.
    threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True
    ).start()
    made = Rig(
        tmp_path,
        "http://127.0.0.1:%d/live.mp3" % server.server_address[1],
        lambda: len(asked),
    )
    try:
        yield made
    finally:
        off.set()
        made.close()
        server.shutdown()
        server.server_close()


@pytest.fixture
def rig(tmp_path: Path) -> Iterator[Rig]:
    """A station that sends ten seconds at once and hangs up."""
    yield from _rig(tmp_path, live=False)


@pytest.fixture
def live_rig(tmp_path: Path) -> Iterator[Rig]:
    """A station that keeps sending for a minute, at the pace of a broadcast."""
    yield from _rig(tmp_path, live=True)


def test_without_a_stop_the_capture_is_written(rig: Rig) -> None:
    # The control: what the stops below call off is a capture that works.
    capture = rig.start_capture()
    assert _until((rig.tmp / "df-entered").exists)
    rig.release_df()
    out = rig.ended(capture)
    done = re.search(r"__REC_DONE__ rc=0 bytes=(\d+)", out)
    assert done, out
    files = rig.recordings()
    assert [f.suffix for f in files] == [".mp3"], files
    assert files[0].stat().st_size == int(done.group(1)) > 150000
    assert rig.hits() == 1
    # The address was on no command line, and is on no disk afterwards.
    assert "127.0.0.1" not in rig.cmd["capture"]
    assert sorted(p.name for p in rig.run.iterdir()) == []


def test_a_stop_during_the_preparation_records_nothing(rig: Rig) -> None:
    capture = rig.start_capture()
    assert _until((rig.tmp / "df-entered").exists)
    # The window itself: the shell is running and there is no pid to signal.
    assert not rig.pid_file.exists()
    rig.stop()
    rig.release_df()
    out = rig.ended(capture)
    assert rig.hits() == 0, "the stream was asked for after the stop: " + out
    assert rig.recordings() == []
    assert "__REC_OFF__" in out, out
    assert sorted(p.name for p in rig.run.iterdir()) == []


def test_the_mark_of_the_recording_before_stops_nothing(rig: Rig) -> None:
    # Stop pressed as Alpha ended by itself: its mark lands with no shell
    # left to read it, and Beta starts right after.
    rig.stop()
    assert rig.mark_file.exists(), "Alpha's stop left no mark"
    assert rig.mark_file.read_text() == rig.cmd["token"]
    rig.release_df()
    out = rig.ended(rig.start_capture("nextWrite", "nextCapture"))
    assert re.search(r"__REC_DONE__ rc=0 bytes=\d+", out), out
    assert [f.suffix for f in rig.recordings()] == [".mp3"]
    assert rig.hits() == 1


def test_a_stop_between_the_last_look_and_the_pid_ends_the_capture(
    live_rig: Rig,
) -> None:
    rig = live_rig
    # The pid file is a pipe here, so the shell stands still at the very
    # line that writes the pid down: past its look at the mark, the stream
    # already asked for. The mark is put down by hand and no signal is sent,
    # which leaves the shell's second look as the only thing that can stop it.
    os.mkfifo(rig.pid_file)
    rig.release_df()
    capture = rig.start_capture()
    assert _until(lambda: rig.hits() == 1), "the capture never asked for the stream"
    assert rig.cmd["token"], "the recording has no token"
    rig.mark_file.write_text(rig.cmd["token"])
    pid = int(_read_pipe(rig.pid_file))
    out = rig.ended(capture)
    assert "__REC_" in out, out
    assert not Path("/proc/%d" % pid).exists(), "ffmpeg outlived the stop"
    # A few frames at the most, and never the minute the station had to give.
    assert sum(f.stat().st_size for f in rig.recordings()) < 5 * FRAMES_PER_SEC * 417


def test_a_stop_the_moment_the_pid_is_written_ends_the_capture(
    live_rig: Rig,
) -> None:
    rig = live_rig
    # An ffmpeg half a second from its own signal handlers, which is where
    # the measured stop was lost: the process is there, has the recorder's
    # command line, and ignores SIGINT.
    rig.slow_ffmpeg(0.5)
    rig.release_df()
    capture = rig.start_capture()
    assert _until(rig.pid_file.exists)
    rig.stop()
    out = rig.ended(capture)
    assert "__REC_EMPTY__" in out, out
    assert rig.recordings() == []
    assert sorted(p.name for p in rig.run.iterdir()) == []


def test_a_stop_after_the_file_exists_closes_it(live_rig: Rig) -> None:
    rig = live_rig
    rig.release_df()
    capture = rig.start_capture()
    # Its existence and not its size: ffmpeg writes in 256 KiB blocks.
    assert _until(rig.recordings), "the capture never opened its file"
    rig.stop()
    out = rig.ended(capture)
    done = re.search(r"__REC_DONE__ rc=255 bytes=(\d+)", out)
    assert done, out
    assert rig.recordings()[0].stat().st_size == int(done.group(1)) > 0
    assert sorted(p.name for p in rig.run.iterdir()) == []


# ── What the finished capture says about its own length ──────────────────
# The verdict used to ask the wall clock alone. Measured with this rig's
# station changed to send ten seconds and then hold the socket silent: a
# one-minute capture ran its whole six-minute cap and answered rc=0 with
# 159819 bytes, 9.98 s of audio, which read "Recording saved".


def test_the_answer_names_the_seconds_in_the_file(rig: Rig) -> None:
    if shutil.which("ffprobe") is None:
        pytest.skip("ffprobe is not installed")
    rig.release_df()
    out = rig.ended(rig.start_capture())
    done = re.search(r"^__REC_DONE__ rc=0 bytes=\d+ secs=(\d+)$", out, re.MULTILINE)
    assert done, out
    # 382 frames of 1152 samples at 44.1 kHz are 9.98 s.
    assert done.group(1) in ("9", "10")


def test_without_ffprobe_the_capture_is_written_and_names_no_seconds(rig: Rig) -> None:
    rig.hide("ffprobe")
    rig.release_df()
    out = rig.ended(rig.start_capture())
    assert re.search(r"^__REC_DONE__ rc=0 bytes=\d+ secs=$", out, re.MULTILINE), out
    assert [f.suffix for f in rig.recordings()] == [".mp3"]
    assert sorted(p.name for p in rig.run.iterdir()) == []
