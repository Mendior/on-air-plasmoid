# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The sliding buffer's writer, run for real.

The writer is one shell command (SlideLogic.buildWriter): curl fetches the
station, the first 4 KiB are looked at, and MP3 or AAC is cut into segments
while anything else goes to the single file the buffer always was. The
commands are printed by qmltestrunner from SlideLogic.js itself and run here
under sh as main.qml's exec() would send them, against a station on
127.0.0.1. Nothing is played: the audio only ever lands under tmp_path.

What these hold that the unit tests cannot: that the two roads really start
from one connection, that the address stays out of every argv, and that a
stop leaves no process and no file behind, also when it comes while the
writer is still looking at the stream. Measured before the address file was
made the stop's word to a writer without a pid: a stop 0.3 s after the start
found nothing to signal, and curl and ffmpeg ran on until the guard's tick.
"""

import http.server
import json
import os
import re
import shutil
import subprocess
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

# Each case starts qmltestrunner and a real curl into ffmpeg.
pytestmark = pytest.mark.slow

UI = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"
QMLTESTRUNNER = os.environ.get("QMLTESTRUNNER", "/usr/lib/qt6/bin/qmltestrunner")
TOOLS = ("sh", "bash", "curl", "ffmpeg", "ffprobe", "timeout", "df", "awk", "head", "cat", "stat", "python3")

_HARNESS = """
import QtQuick
import QtTest
import "%(ui)s/SlideLogic.js" as SL

TestCase {
    name: "SlideCommands"
    function test_print_the_commands() {
        var d = %(dir)s, ui = %(uiq)s;
        var o = { cfgPath: d + "/url-7.cfg", dirPath: d, slidePath: d + "/buffer-7.hls", outPath: d + "/buffer-7.mka",
                  pidPath: d + "/writer-7.pid", headPath: d + "/head-7.bin", kindPath: d + "/kind-7.txt",
                  probePath: ui + "/streamkind.py", guardPath: ui + "/tsguard.sh", windowMin: 1, needKiB: 16, seq: 7 };
        console.log("CMD writer " + JSON.stringify(SL.buildWriter(o)));
        console.log("CMD kind " + JSON.stringify(SL.buildKindWait({ kindPath: o.kindPath, seq: 8 })));
        console.log("CMD have " + JSON.stringify(SL.buildHave({ scriptPath: ui + "/tsslide.sh", slidePath: o.slidePath, seq: 9 })));
        console.log("CMD stop " + JSON.stringify(SL.buildStop({ pidPath: o.pidPath, slidePath: o.slidePath, cfgPath: o.cfgPath,
            headPath: o.headPath, kindPath: o.kindPath, outPath: o.outPath, seq: 10 })));
        console.log("CMD end " + JSON.stringify(SL.buildEnd({ pidPath: o.pidPath, seq: 11 })));
    }
}
"""


def _commands(d: Path, tmp: Path) -> dict[str, str]:
    harness = tmp / "tst_slidecommands.qml"
    harness.write_text(_HARNESS % {"ui": UI, "uiq": json.dumps(str(UI)), "dir": json.dumps(str(d))}, encoding="utf-8")
    run = subprocess.run(
        [QMLTESTRUNNER, "-input", str(harness)],
        capture_output=True, text=True, timeout=120, check=False, env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
    )
    found = dict(re.findall(r"CMD (\w+) (\".*\")", run.stdout + run.stderr))
    assert set(found) == {"writer", "kind", "have", "stop", "end"}, run.stdout + run.stderr
    cmds = {name: json.loads(text) for name, text in found.items()}
    for name, cmd in cmds.items():
        assert cmd, "SlideLogic built no %s command" % name
    return cmds


@pytest.fixture(scope="module")
def tone(tmp_path_factory) -> dict[str, bytes]:
    """Forty seconds of a sine as a station would send it: bare MP3 frames,
    and Ogg Vorbis for the stream that is neither MP3 nor AAC."""
    missing = [t for t in TOOLS if shutil.which(t) is None]
    if missing or not Path(QMLTESTRUNNER).exists():
        pytest.skip("not installed: %s" % ", ".join(missing or [QMLTESTRUNNER]))
    d = tmp_path_factory.mktemp("tone")
    made = {}
    for name, args in (
        ("mp3", ["-c:a", "libmp3lame", "-b:a", "64k", "-ar", "44100", "-write_xing", "0", "-id3v2_version", "0", "-f", "mp3"]),
        ("ogg", ["-c:a", "libvorbis", "-b:a", "64k", "-f", "ogg"]),
    ):
        out = d / ("tone." + name)
        done = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=40",
             *args, str(out)], capture_output=True, text=True, timeout=120, check=False)
        if done.returncode != 0:
            pytest.skip("this ffmpeg cannot encode %s: %s" % (name, done.stderr.strip()[-200:]))
        made[name] = out.read_bytes()
    return made


@pytest.fixture
def station() -> Iterator[Callable[..., str]]:
    """A station on 127.0.0.1: four seconds at once, as a station's burst is,
    and the rest at the pace it plays. Its address carries a quote, a double
    quote, an escaped space and a token."""
    servers: list[http.server.ThreadingHTTPServer] = []

    def start(body: bytes, seconds: float = 40.0, first_after: float = 0.0, stall_at: float = 0.0, stall_for: float = 0.0) -> str:
        per_sec = len(body) / seconds
        # The first connection alone stands still, stall_at seconds into its
        # pace and for stall_for seconds, without closing: a line that went
        # quiet. Whoever asks again is served as if nothing had happened.
        asked = [0]

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.end_headers()
                self.wfile.flush()
                asked[0] += 1
                stalls = stall_for > 0 and asked[0] == 1
                try:
                    if first_after:
                        time.sleep(first_after)
                    burst = int(per_sec * 4)
                    self.wfile.write(body[:burst])
                    self.wfile.flush()
                    sent, step = burst, max(1, int(per_sec / 10))
                    while sent < len(body):
                        if stalls and sent >= burst + int(per_sec * stall_at):
                            stalls = False
                            time.sleep(stall_for)
                        time.sleep(0.1)
                        self.wfile.write(body[sent:sent + step])
                        self.wfile.flush()
                        sent += step
                except OSError:
                    # The writer hung up, which is what a stop looks like from here.
                    pass

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        srv.daemon_threads = True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
        return "http://127.0.0.1:%d/live?token=a%%20b'c\"d" % srv.server_address[1]

    yield start
    for srv in servers:
        srv.shutdown()
        srv.server_close()


def _cmdlines() -> list[tuple[int, str]]:
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            raw = Path("/proc", entry, "cmdline").read_bytes()
            state = Path("/proc", entry, "stat").read_text().rsplit(") ", 1)[1].split()[0]
        except (OSError, IndexError):
            # It ended between the listing and the read.
            continue
        if state != "Z" and raw:
            out.append((int(entry), raw.replace(b"\0", b" ").decode("utf-8", "replace")))
    return out


def _mine(d: Path) -> list[str]:
    """Every living process whose argv names the arm's directory: the run
    shell and its subshells, curl (by its config file) and ffmpeg."""
    me = os.getpid()
    return ["%d %s" % (pid, cmd[:160]) for pid, cmd in _cmdlines() if pid != me and str(d) in cmd]


def _wait(what: Callable[[], bool], secs: float, every: float = 0.05) -> bool:
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if what():
            return True
        time.sleep(every)
    return what()


def _sh(cmd: str, secs: float = 30.0) -> str:
    done = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, timeout=secs, check=False)
    return done.stdout


class Arm:
    """One arm of the writer in a directory of its own, whose name holds a
    space and a quote as a cache path may."""

    def __init__(self, tmp: Path, url: str):
        self.d = tmp / "my cache's" / "onair-timeshift-9"
        self.d.mkdir(parents=True)
        self.cmds = _commands(self.d, tmp)
        self.folder = self.d / "buffer-7.hls"
        self.single = self.d / "buffer-7.mka"
        # The address file as the engine writes it (TimeshiftLogic.buildBufferCommands).
        (self.d / "url-7.cfg").write_text('url = "%s"\n' % url.replace("\\", "\\\\").replace('"', '\\"'), encoding="utf-8")
        self.log = open(tmp / "writer.out", "w+", encoding="utf-8")
        self.proc = subprocess.Popen(
            ["sh", "-c", self.cmds["writer"]], stdout=self.log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            start_new_session=True)

    def kind(self) -> str:
        return _sh(self.cmds["kind"])

    def have(self) -> str:
        return _sh(self.cmds["have"])

    def stop(self) -> float:
        began = time.monotonic()
        _sh(self.cmds["stop"])
        return time.monotonic() - began

    def output(self) -> str:
        self.log.flush()
        self.log.seek(0)
        return self.log.read()

    def close(self) -> None:
        try:
            os.killpg(self.proc.pid, 9)
        except OSError:
            # The whole group ended on its own, as it should have.
            pass
        self.proc.wait(timeout=10)
        self.log.close()


@pytest.fixture
def arm(tmp_path) -> Iterator[Callable[[str], Arm]]:
    arms: list[Arm] = []

    def start(url: str) -> Arm:
        arms.append(Arm(tmp_path, url))
        return arms[-1]

    yield start
    for a in arms:
        a.close()


def test_an_mp3_station_is_cut_into_segments_and_a_stop_leaves_nothing(tone, station, arm):
    a = arm(station(tone["mp3"]))
    assert a.kind() == "__TS_KIND__ slide mp3\n"
    assert _wait(lambda: len(list(a.folder.glob("seg-*.ts"))) >= 3, 15), sorted(p.name for p in a.d.rglob("*"))
    assert not [cmd for _pid, cmd in _cmdlines() if "a%20b" in cmd], "the station's address is in a process's argv"
    # The three numbers the guard and the sweep read: the writer, the run's shell, its host.
    writer, shell, host = (int(x) for x in (a.d / "writer-7.pid").read_text().split())
    assert Path("/proc/%d/comm" % writer).read_text().strip() == "ffmpeg"
    assert (shell, host) == (a.proc.pid, os.getpid())
    have = a.have()
    assert have.startswith("__TS_HAVE__ first=0 last="), have
    assert int(have.split("last=")[1]) >= 2
    # A finished segment is two seconds of the station's own frames, untouched.
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-count_packets", "-select_streams", "a:0", "-show_entries",
         "stream=codec_name,nb_read_packets", "-of", "csv=p=0", str(a.folder / "seg-1.ts")],
        capture_output=True, text=True, timeout=30, check=False)
    codec, frames = probe.stdout.strip().split("\n")[0].split(",")[:2]
    assert codec == "mp3" and 76 <= int(frames) <= 77, probe.stdout
    assert not a.single.exists(), "the single file was written beside the segments"
    took = a.stop()
    assert took < 2.5, "the stop took %.1f s" % took
    assert _wait(lambda: not _mine(a.d), 2), "still alive two seconds after the stop: %s" % _mine(a.d)
    assert a.proc.wait(timeout=5) is not None
    assert sorted(p.name for p in a.d.iterdir()) == [], "the stop left files"
    assert "__TS_EXIT__ rc=" in a.output()


def test_a_stream_that_is_neither_mp3_nor_aac_is_written_to_the_single_file(tone, station, arm):
    a = arm(station(tone["ogg"]))
    assert a.kind() == "__TS_KIND__ file\n"
    assert _wait(lambda: a.single.exists() and a.single.stat().st_size > 20000, 15), sorted(p.name for p in a.d.rglob("*"))
    assert not a.folder.exists(), "a folder of segments was made for a stream they cannot hold"
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", str(a.single)],
        capture_output=True, text=True, timeout=30, check=False)
    assert probe.stdout.strip().split("\n")[0] == "vorbis", probe.stdout + probe.stderr
    assert a.have() == "__TS_HAVE__ first=-1 last=-1\n"
    a.stop()
    assert _wait(lambda: not _mine(a.d), 2), "still alive two seconds after the stop: %s" % _mine(a.d)
    assert a.proc.wait(timeout=5) is not None
    assert sorted(p.name for p in a.d.iterdir()) == [], "the stop left files"


@pytest.mark.parametrize("wait", [0.3, 1.45, 1.6])
def test_a_stop_that_comes_while_the_writer_is_still_looking_leaves_nothing(tone, station, arm, wait):
    """The station sends its first byte 1.5 s after the request. A stop before
    it finds no pid to signal; one right at it races the writer's start."""
    a = arm(station(tone["mp3"], first_after=1.5))
    time.sleep(wait)
    a.stop()
    assert _wait(lambda: not _mine(a.d), 4), "still alive four seconds after the stop: %s" % _mine(a.d)
    assert a.proc.wait(timeout=5) is not None
    # And nothing comes up afterwards, from a start that had not happened yet.
    time.sleep(2.5)
    assert not _mine(a.d), _mine(a.d)
    assert sorted(p.name for p in a.d.iterdir()) == [], "the stop left files"


def test_a_writer_whose_host_is_gone_is_stopped_by_its_guard(tone, station, tmp_path):
    """The run's shell is the child of a host that ends three seconds in,
    without a stop: what a crashed panel does."""
    url = station(tone["mp3"])
    d = tmp_path / "my cache's" / "onair-timeshift-9"
    d.mkdir(parents=True)
    cmds = _commands(d, tmp_path)
    (d / "url-7.cfg").write_text('url = "%s"\n' % url.replace("\\", "\\\\").replace('"', '\\"'), encoding="utf-8")
    host = subprocess.Popen(
        ["sh", "-c", 'sh -c "$1" > /dev/null 2>&1 & sleep 3', "host", cmds["writer"]],
        stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        assert _wait(lambda: len(list((d / "buffer-7.hls").glob("seg-*.ts"))) >= 1, 15)
        host.wait(timeout=10)
        # The guard looks every five seconds.
        assert _wait(lambda: not _mine(d), 12, 0.2), "the writer outlived its host: %s" % _mine(d)
    finally:
        try:
            os.killpg(host.pid, 9)
        except OSError:
            # Nothing of the group is left, which is the point of the test.
            pass
        host.wait(timeout=10)


def test_a_station_that_stops_sending_ends_the_writer(tone, station, arm):
    """The station sends seven seconds and then nothing for 45 s, without
    closing. curl gives up after 30 s below one byte a second. It used to ask
    the station again, and the writer went on cutting with a hole in its
    segments that the engine's clock knew nothing of: measured on the rig, a
    pause after such a stall came back at the wrong place. Now the writer
    ends, the engine is told, and the station's next buffer is a new one."""
    a = arm(station(tone["mp3"], stall_at=3.0, stall_for=45.0))
    assert a.kind() == "__TS_KIND__ slide mp3\n"
    assert _wait(lambda: a.proc.poll() is not None, 42, 0.5), "still cutting 42 s on: %s" % _mine(a.d)
    assert "__TS_EXIT__ rc=" in a.output()
    assert not _mine(a.d), _mine(a.d)
    # What it cut stays, for a listener who is parked in it; the stop takes it.
    assert len(list(a.folder.glob("seg-*.ts"))) >= 2
    a.stop()
    assert sorted(p.name for p in a.d.iterdir()) == [], "the stop left files"


def test_the_end_of_a_capture_ends_the_writer_and_leaves_what_it_cut(tone, station, arm):
    """What the engine sends when a pause is a window old: the writer goes,
    with its curl and its guard's reason to stay, and every segment it cut
    stays where Play will look for it. Only the stop takes the folder."""
    a = arm(station(tone["mp3"]))
    assert a.kind() == "__TS_KIND__ slide mp3\n"
    assert _wait(lambda: len(list(a.folder.glob("seg-*.ts"))) >= 3, 15)
    _sh(a.cmds["end"])
    assert _wait(lambda: a.proc.poll() is not None, 5, 0.1), "the writer's command is still running: %s" % _mine(a.d)
    assert _wait(lambda: not _mine(a.d), 3), _mine(a.d)
    assert "__TS_EXIT__ rc=" in a.output()
    kept = sorted(p.name for p in a.folder.glob("seg-*.ts"))
    assert len(kept) >= 3, kept
    have = a.have()
    assert have.startswith("__TS_HAVE__ first=0 last=") and int(have.split("last=")[1]) >= 2, have
    # Nothing is fetched or cut any more.
    time.sleep(3)
    assert sorted(p.name for p in a.folder.glob("seg-*.ts")) == kept
    # The writer tidied its own small files; the folder is the stop's.
    assert sorted(p.name for p in a.d.iterdir()) == ["buffer-7.hls"]
    a.stop()
    assert sorted(p.name for p in a.d.iterdir()) == [], "the stop left files"
