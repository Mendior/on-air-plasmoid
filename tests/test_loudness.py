# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""loudness.py: how loud a station is, heard beside the player.

Stations differ by up to 13 dB (measured on 2026-11-11: -7.8 to -21.1 LUFS
over the twenty bundled ones), and the widget turns the loud ones down by
what this helper reads. A wrong number is a station played too quietly for a
month, so what is asked here is that the number is the standard's, that
anything short of a full reading is no number at all, and that the helper
leaves nothing behind: no address, no file, no process.

The expected readings come from ITU-R BS.1770 and not from ffmpeg: a 997 Hz
sine in both channels reads its peak level in LUFS, so an amplitude of 0.5
is -6.0 and 0.05 is -26.0.

The script is run as the widget runs it, against a loopback station that
follows a script, with the real ffmpeg.
"""

import importlib.util
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

UI = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"
HELPER = UI / "loudness.py"
FFMPEG = shutil.which("ffmpeg")
needs_ffmpeg = pytest.mark.skipif(
    FFMPEG is None,
    reason="ffmpeg is not installed: the helper measures with it, and without "
    "it there is nothing to run these against",
)

Script = Callable[[socket.socket], None]


def _module():
    # The helper imports streamkind.py from its own folder, as a script does.
    sys.path.insert(0, str(UI))
    try:
        spec = importlib.util.spec_from_file_location("loudness", HELPER)
        assert spec is not None and spec.loader is not None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.path.remove(str(UI))
    return mod


LD = _module()

SUMMARY = """\
[Parsed_ebur128_0 @ 0x7fe258003b40] Summary:

  Integrated loudness:
    I:          -9.6 LUFS
    Threshold: -19.9 LUFS

  Loudness range:
    LRA:         1.7 LU
    Threshold: -29.8 LUFS
    LRA low:   -10.6 LUFS
    LRA high:   -8.9 LUFS
[out#0/null @ 0x5577060efa00] video:0KiB audio:3750KiB subtitle:0KiB
"""
FRAME = (
    "[Parsed_ebur128_0 @ 0x55d0] t: 4.99998  TARGET:-23 LUFS    "
    "M: -9.1 S: -9.3     I: -12.4 LUFS       LRA:   1.2 LU\n"
)
PROGRESS = "bitrate=N/A\nout_time_us=20000000\nout_time=00:00:20.000000\nspeed=4x\n"


def test_the_number_is_the_summarys():
    assert LD.loudness_of(SUMMARY) == "-9.6"
    assert LD.loudness_of(SUMMARY.replace("-9.6", "-21.1")) == "-21.1"
    assert LD.loudness_of(SUMMARY.replace("-9.6", "-70.0")) == "-70.0"
    assert LD.loudness_of(SUMMARY.replace("-9.6", "0.4")) == "0.4"
    assert LD.loudness_of(SUMMARY.replace("-9.6", "-9")) == "-9.0"
    # Whatever stands around it: the stream's own lines, the progress block.
    assert LD.loudness_of("Input #0, mp3\n" + SUMMARY + PROGRESS) == "-9.6"


def test_a_frames_line_is_not_the_answer():
    # With the frame log on, every tenth of a second prints an "I:" of its
    # own: the running figure, five seconds in, is not the reading.
    assert LD.loudness_of(FRAME) == ""
    assert LD.loudness_of(FRAME * 200) == ""
    assert LD.loudness_of(FRAME * 200 + SUMMARY) == "-9.6"
    # The threshold and the range are not the loudness either.
    cut = SUMMARY.replace("    I:          -9.6 LUFS\n", "")
    assert LD.loudness_of(cut) == ""


def test_a_log_without_a_number_says_nothing():
    for log in (
        "",
        "Summary:",
        "Summary:\n\n  Integrated loudness:\n    I:          nan LUFS\n",
        "Summary:\n\n  Integrated loudness:\n    I:         -inf LUFS\n",
        "Summary:\n\n  Integrated loudness:\n    I:          LUFS\n",
        "Summary:\n\n  Integrated loudness:\n    I:   -9.6 LU\n",
        "pipe:0: Invalid data found when processing input\n",
        "    I:          -9.6 LUFS\n",
    ):
        assert LD.loudness_of(log) == "", log
    for junk in (None, b"", SUMMARY.encode(), 0, -9.6, [], [SUMMARY], {}, object()):
        assert LD.loudness_of(junk) == "", repr(junk)


def test_ten_megabytes_of_log_are_read_at_once():
    began = time.perf_counter()
    assert LD.loudness_of(FRAME * 80000 + SUMMARY) == "-9.6"
    assert LD.loudness_of(FRAME * 80000) == ""
    assert LD.heard(FRAME * 80000 + PROGRESS) == 20.0
    assert time.perf_counter() - began < 2.0


def test_what_was_heard_is_the_last_progress_blocks_time():
    assert LD.heard(PROGRESS) == 20.0
    assert LD.heard("out_time=00:00:03.000000\n") == 3.0
    assert LD.heard("out_time=00:01:02.500000\n") == 62.5
    assert LD.heard("out_time=01:00:00.000000\n") == 3600.0
    # ffmpeg prints a block twice a second; the last one is where it ended.
    assert LD.heard("out_time=00:00:07.000000\n" + SUMMARY + PROGRESS) == 20.0
    assert LD.heard(PROGRESS + "out_time=00:00:07.250000\n") == 7.25
    for log in (
        "",
        SUMMARY,
        "out_time=N/A\n",
        "out_time=\n",
        "out_time=-00:00:03.000000\n",
        "time=00:00:20.00 bitrate=N/A\n",
        "out_time_us=20000000\n",
    ):
        assert LD.heard(log) == 0.0, log
    for junk in (None, b"out_time=00:00:03.000000\n", 3, [], {}):
        assert LD.heard(junk) == 0.0, repr(junk)


def _tone(amplitude: float, seconds: float) -> bytes:
    """A 997 Hz sine in both channels, as a WAV the way a pipe carries one."""
    assert FFMPEG is not None
    wave = "%s*sin(2*PI*997*t)" % amplitude
    done = subprocess.run(
        [
            FFMPEG,
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "aevalsrc=%s|%s:d=%s:s=48000" % (wave, wave, seconds),
            "-c:a",
            "pcm_s16le",
            "-f",
            "wav",
            "-",
        ],
        capture_output=True,
        timeout=30,
        check=True,
    )
    return done.stdout


# One second of the tone above is 192 000 bytes after a header of under a hundred.
SECOND = 48000 * 2 * 2


def _answer(body: bytes, status: str = "200 OK", extra: str = "") -> Script:
    def script(conn: socket.socket) -> None:
        conn.sendall(
            (
                "HTTP/1.0 %s\r\nContent-Type: audio/wav\r\n%s\r\n" % (status, extra)
            ).encode()
            + body
        )

    return script


def _typed(body: bytes, ctype: str) -> Script:
    def script(conn: socket.socket) -> None:
        head = (
            "HTTP/1.0 200 OK\r\n"
            + ("Content-Type: %s\r\n" % ctype if ctype else "")
            + "\r\n"
        )
        conn.sendall(head.encode() + body)

    return script


def _live(body: bytes, rate: float = 1.0) -> Script:
    """The body as a station sends it: as fast as it plays, times `rate`."""

    def script(conn: socket.socket) -> None:
        conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: audio/wav\r\n\r\n")
        step = SECOND // 10
        for at in range(0, len(body), step):
            conn.sendall(body[at : at + step])
            time.sleep(0.1 / rate)

    return script


class Station:
    """Listens on 127.0.0.1 and hands every connection, its request already
    read, to a script. Counts the connections it was given."""

    def __init__(self) -> None:
        self.stop = threading.Event()
        self.listeners: list[socket.socket] = []
        self.calls = 0

    def _serve(self, srv: socket.socket, script: Script) -> None:
        while not self.stop.is_set():
            try:
                conn, _ = srv.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            self.calls += 1
            try:
                conn.settimeout(8)
                seen = b""
                while b"\r\n\r\n" not in seen:
                    part = conn.recv(4096)
                    if not part:
                        break
                    seen += part
                script(conn)
            except OSError:
                # The helper hung up first, which is what several of these ask of it.
                pass
            finally:
                conn.close()

    def __call__(self, script: Script) -> str:
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(4)
        srv.settimeout(0.2)
        self.listeners.append(srv)
        threading.Thread(target=self._serve, args=(srv, script), daemon=True).start()
        return "http://127.0.0.1:%d/live" % srv.getsockname()[1]


@pytest.fixture
def station() -> Iterator[Station]:
    made = Station()
    yield made
    made.stop.set()
    for srv in made.listeners:
        srv.close()


def _ask(
    tmp_path: Path, address: str, seconds: int = 2, limit: float = 30.0
) -> tuple[str, int, Path, float]:
    note = tmp_path / "address"
    note.write_text(address, encoding="utf-8")
    began = time.monotonic()
    done = subprocess.run(
        [sys.executable, "-B", str(HELPER), str(note), str(seconds)],
        capture_output=True,
        text=True,
        timeout=limit,
        check=False,
    )
    return done.stdout, done.returncode, note, time.monotonic() - began


def _start(tmp_path: Path, address: str, seconds: int = 2) -> tuple:
    note = tmp_path / "address"
    note.write_text(address, encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, "-B", str(HELPER), str(note), str(seconds)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return proc, note


def _children(pid: int) -> list[tuple[int, str]]:
    """(pid, command line) of every process whose parent is `pid`."""
    found = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / "stat").read_text()
            cmd = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode()
        except OSError:
            continue
        # The command's name is in brackets and may hold spaces; the parent
        # is the second field after it.
        if int(stat.rsplit(")", 1)[1].split()[1]) == pid:
            found.append((int(entry.name), cmd.strip()))
    return found


def _wait_for(what: Callable[[], bool], limit: float = 5.0) -> bool:
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if what():
            return True
        time.sleep(0.05)
    return what()


def _alive(pid: int) -> bool:
    """Whether the process still runs.

    One that has ended and waits to be collected does not: it holds no file and
    makes no sound. A signal still reaches it, so asking with one said "alive"
    for an ffmpeg orphaned by a killed helper wherever the first process of the
    machine collects nobody's children, which is how a container job on GitHub
    is started; there the row stays in the table for good.
    """
    try:
        stat = Path("/proc/%d/stat" % pid).read_text()
    except OSError:
        return False
    return stat.rsplit(")", 1)[-1].split()[0] != "Z"


@needs_ffmpeg
def test_the_reading_is_the_standards(tmp_path, station):
    out, rc, note, _took = _ask(
        tmp_path, station(_answer(_tone(0.5, 4))) + "?token=s3cret"
    )
    assert rc == 0
    assert out.endswith("\n") and out.count("\n") == 1
    assert abs(float(out) - -6.0) <= 0.2, out
    assert not note.exists(), "the address file is left lying"
    quiet, _rc, _note, _took = _ask(tmp_path, station(_answer(_tone(0.05, 4))))
    assert abs(float(quiet) - -26.0) <= 0.2, quiet


@needs_ffmpeg
def test_only_the_seconds_asked_for_are_heard(tmp_path, station):
    # Two quiet seconds and then two loud ones: a reading of the first two
    # knows nothing of the rest, and a reading of all four is the louder half
    # (the standard's gate leaves the quiet half out of the mean).
    quiet, loud = _tone(0.05, 2), _tone(0.5, 2)
    both = quiet + loud[loud.index(b"data") + 8 :]
    out, _rc, _note, _took = _ask(tmp_path, station(_answer(both)), seconds=2)
    assert abs(float(out) - -26.0) <= 0.3, out
    out, _rc, _note, _took = _ask(tmp_path, station(_answer(both)), seconds=4)
    assert abs(float(out) - -6.0) <= 0.5, out


@needs_ffmpeg
def test_a_stream_that_goes_on_past_the_reading_is_left_without_a_word(
    tmp_path, station
):
    # A station never ends, so ffmpeg always leaves first. What was still on
    # its way to it then is nobody's, and is not complained about.
    note = tmp_path / "address"
    note.write_text(station(_answer(_tone(0.5, 30))), encoding="utf-8")
    done = subprocess.run(
        [sys.executable, "-B", str(HELPER), str(note), "2"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert abs(float(done.stdout) - -6.0) <= 0.2, done.stdout
    assert done.stderr == ""
    assert not note.exists()


@needs_ffmpeg
def test_a_stream_that_ends_early_is_no_reading(tmp_path, station):
    out, rc, note, _took = _ask(tmp_path, station(_answer(_tone(0.5, 1))), seconds=2)
    assert (out, rc) == ("", 0)
    assert not note.exists()
    # Just under the two seconds is under them.
    body = _tone(0.5, 2)[: SECOND * 3 // 2]
    assert _ask(tmp_path, station(_answer(body)), seconds=2)[0] == ""
    assert _ask(tmp_path, station(_answer(b"")), seconds=2)[0] == ""


@needs_ffmpeg
def test_silence_is_printed_as_what_it_measured(tmp_path, station):
    # Whether that is a station is LoudLogic.answerOf's to say; here only
    # that a stream of zeros is not passed off as programme.
    hush = _tone(0.0, 3)
    out, rc, _note, _took = _ask(tmp_path, station(_answer(hush)))
    assert rc == 0
    assert float(out) <= -69.0, out


@needs_ffmpeg
def test_a_page_or_an_error_is_no_reading(tmp_path, station):
    html = b"<!DOCTYPE html><html><body>Sign in to the network</body></html>" * 400
    tone = _tone(0.5, 3)
    for script in (
        _typed(html, "text/html; charset=utf-8"),
        _typed(html, "audio/mpeg"),
        _typed(html, ""),
        # Audio said to be text is not trusted either.
        _typed(tone, "text/plain"),
        _typed(tone, "TEXT/HTML"),
        _answer(tone, "404 Not Found"),
        _answer(tone, "503 Busy"),
        _answer(tone, "429 Too Many Requests"),
        _typed(b"#EXTM3U\nhttp://127.0.0.1:9/live\n", "audio/x-mpegurl"),
    ):
        out, rc, note, _took = _ask(tmp_path, station(script))
        assert (out, rc) == ("", 0)
        assert not note.exists()
    # A station that names no type at all, as ICY servers do, is still heard.
    out, _rc, _note, _took = _ask(tmp_path, station(_typed(tone, "")))
    assert abs(float(out) - -6.0) <= 0.2, out


@needs_ffmpeg
def test_a_station_that_sends_it_on_is_followed_inside_the_web(tmp_path, station):
    there = station(_answer(_tone(0.5, 3)))
    out, _rc, _note, _took = _ask(
        tmp_path, station(_answer(b"", "302 Found", "Location: %s\r\n" % there))
    )
    assert abs(float(out) - -6.0) <= 0.2, out
    trap = socket.socket()
    trap.bind(("127.0.0.1", 0))
    trap.listen(1)
    trap.settimeout(0.3)
    try:
        there = "ftp://127.0.0.1:%d/x.wav" % trap.getsockname()[1]
        out, rc, _note, _took = _ask(
            tmp_path, station(_answer(b"", "302 Found", "Location: %s\r\n" % there))
        )
        assert (out, rc) == ("", 0)
        with pytest.raises(TimeoutError):
            trap.accept()
    finally:
        trap.close()


@needs_ffmpeg
def test_an_address_with_a_space_a_quote_and_a_token_is_heard(tmp_path, station):
    """The player takes an address as it was saved and spells it for the
    wire itself. A helper that refused a space left such a station unread
    for good: measured before this was fixed, no connection was made at all."""
    asked = []

    def script(conn: socket.socket) -> None:
        asked.append(1)
        _answer(_tone(0.5, 3))(conn)

    base = station(script)
    for path in (
        "/it's live?token=s3cret&u=$(id)",
        "/it's%20live?token=s3cret",
        "/\u00f5htu raadio.mp3",
        "/a%2Fb c",
    ):
        before = len(asked)
        out, rc, note, _took = _ask(tmp_path, base.replace("/live", path))
        assert rc == 0 and len(asked) == before + 1, path
        assert abs(float(out) - -6.0) <= 0.2, path
        assert not note.exists()


@needs_ffmpeg
def test_a_stream_cannot_send_ffmpeg_to_another_address(tmp_path, station):
    """ffmpeg reads playlists too, and a playlist names addresses and files.
    What a station sends must not be able to make this machine open them.
    On ffmpeg 9.0.2 its own default for a pipe is enough for the forms tried
    here, with the helper's whitelist or without it; this holds the outcome,
    whichever of the two gives it."""
    bait = station(_answer(_tone(0.5, 3)))
    secret = tmp_path / "secret.wav"
    secret.write_bytes(_tone(0.5, 3))
    for inner in (bait, secret.as_uri(), str(secret)):
        playlist = (
            "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\n%s\n#EXT-X-ENDLIST\n"
            % inner
        ).encode()
        before = station.calls
        out, rc, _note, _took = _ask(
            tmp_path, station(_typed(playlist, "application/vnd.apple.mpegurl"))
        )
        assert (out, rc) == ("", 0), inner
        assert station.calls == before + 1, "ffmpeg followed the playlist"


def test_only_web_addresses_are_opened(tmp_path):
    secret = tmp_path / "secret.wav"
    secret.write_bytes(b"RIFF" + b"\x00" * 100)
    for address in (
        secret.as_uri(),
        str(secret),
        "ftp://127.0.0.1/x",
        "",
        "   ",
        "not an address",
        "data:audio/wav;base64,UklGRg==",
    ):
        out, rc, note, _took = _ask(tmp_path, address)
        assert (out, rc) == ("", 0), address
        assert not note.exists()
    for argv in ([str(tmp_path / "nope")], [str(tmp_path)]):
        done = subprocess.run(
            [sys.executable, "-B", str(HELPER), *argv],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        assert (done.stdout, done.returncode) == ("", 0), argv
    for argv in ([], ["a", "2", "c"]):
        done = subprocess.run(
            [sys.executable, "-B", str(HELPER), *argv],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        assert (done.stdout, done.returncode) == ("", 2), argv


@needs_ffmpeg
def test_seconds_that_are_no_count_fall_back_to_twenty(tmp_path, station):
    assert LD.LISTEN_SECONDS == 20
    # Three seconds of tone are not twenty: no reading, whatever was typed.
    tone = _tone(0.5, 3)
    for typed in ("0", "-2", "abc", "2.5", "", "9999"):
        note = tmp_path / "address"
        note.write_text(station(_answer(tone)), encoding="utf-8")
        done = subprocess.run(
            [sys.executable, "-B", str(HELPER), str(note), typed],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        assert (done.stdout, done.returncode) == ("", 0), typed
        assert not note.exists()


def test_without_ffmpeg_nobody_is_connected_to(tmp_path, station):
    bare = tmp_path / "bin"
    bare.mkdir()
    address = station(_answer(b"\x00" * 4096))
    note = tmp_path / "address"
    note.write_text(address, encoding="utf-8")
    done = subprocess.run(
        [sys.executable, "-B", str(HELPER), str(note), "2"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
        env={"PATH": str(bare)},
    )
    assert (done.stdout, done.returncode) == ("", 0)
    assert not note.exists()
    time.sleep(0.3)
    assert station.calls == 0, "a station was connected to for nothing"


@needs_ffmpeg
def test_the_address_is_gone_from_the_file_at_once_and_never_on_a_command_line(
    tmp_path, station
):
    address = station(_live(_tone(0.5, 6))) + "?token=s3cret"
    proc, note = _start(tmp_path, address, seconds=3)
    try:
        assert _wait_for(lambda: note.exists() and note.stat().st_size == 0), (
            "the address is still in its file while the helper listens"
        )
        assert _wait_for(lambda: len(_children(proc.pid)) > 0), "no ffmpeg came up"
        for _pid, cmd in _children(proc.pid):
            assert "ffmpeg" in cmd and "pipe:0" in cmd
            assert "127.0.0.1" not in cmd and "s3cret" not in cmd, cmd
        own = Path("/proc/%d/cmdline" % proc.pid).read_bytes()
        assert b"s3cret" not in own and b"127.0.0.1" not in own
        out, _err = proc.communicate(timeout=20)
    finally:
        proc.kill()
    assert abs(float(out) - -6.0) <= 0.2, out
    assert not note.exists()


@needs_ffmpeg
def test_the_helper_stops_when_its_file_is_removed(tmp_path, station):
    proc, note = _start(tmp_path, station(_live(_tone(0.5, 30))), seconds=20)
    try:
        assert _wait_for(lambda: len(_children(proc.pid)) > 0), "no ffmpeg came up"
        kids = [pid for pid, _cmd in _children(proc.pid)]
        note.unlink()
        began = time.monotonic()
        out, _err = proc.communicate(timeout=5)
        assert time.monotonic() - began < 1.5
    finally:
        proc.kill()
    assert (out, proc.returncode) == ("", 0)
    assert _wait_for(lambda: not any(_alive(pid) for pid in kids)), "ffmpeg lives on"
    assert not note.exists(), "the helper put its file back"


@needs_ffmpeg
def test_a_file_removed_before_the_helper_starts_is_no_question(tmp_path, station):
    address = station(_answer(_tone(0.5, 3)))
    done = subprocess.run(
        [sys.executable, "-B", str(HELPER), str(tmp_path / "gone"), "2"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (done.stdout, done.returncode) == ("", 0)
    assert address and station.calls == 0


@needs_ffmpeg
def test_a_helper_that_is_told_to_end_takes_ffmpeg_with_it(tmp_path, station):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        proc, note = _start(tmp_path, station(_live(_tone(0.5, 30))), seconds=20)
        try:
            assert _wait_for(lambda p=proc: len(_children(p.pid)) > 0)
            kids = [pid for pid, _cmd in _children(proc.pid)]
            proc.send_signal(sig)
            out, _err = proc.communicate(timeout=5)
        finally:
            proc.kill()
        assert out == "", sig
        assert _wait_for(lambda k=kids: not any(_alive(pid) for pid in k)), sig
        if sig == signal.SIGTERM:
            assert not note.exists()
        else:
            # Nothing runs after a kill. What is left is empty, and the
            # shell that started the helper removes it.
            assert note.read_text() == ""
            note.unlink()


@needs_ffmpeg
def test_the_helper_gives_up_when_its_time_is_out(tmp_path, station, monkeypatch):
    """A station that trickles: two seconds of stream would take eight. The
    clock is the helper's own and reaches it wherever it waits."""
    monkeypatch.setattr(LD, "SLACK_SECONDS", 1)
    note = tmp_path / "address"
    note.write_text(station(_live(_tone(0.5, 6), rate=0.25)), encoding="utf-8")
    began = time.monotonic()
    assert LD.main(["loudness.py", str(note), "2"]) == 0
    assert 2.5 < time.monotonic() - began < 4.5
    assert not note.exists()
    # The clock is put away again: nothing fires into whoever runs next.
    assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)


@needs_ffmpeg
def test_a_station_that_says_nothing_is_given_up_on(
    tmp_path, station, monkeypatch, capsys
):
    monkeypatch.setattr(LD, "SLACK_SECONDS", 1)

    def mute(conn: socket.socket) -> None:
        time.sleep(6)

    note = tmp_path / "address"
    note.write_text(station(mute), encoding="utf-8")
    began = time.monotonic()
    assert LD.main(["loudness.py", str(note), "1"]) == 0
    assert time.monotonic() - began < 3.5
    assert capsys.readouterr().out == ""
    assert not note.exists()


def test_the_two_clocks_agree():
    """The shell's limit is LoudLogic's and stands above the helper's own."""
    logic = (UI / "LoudLogic.js").read_text(encoding="utf-8")

    def number(name: str) -> int:
        line = next(
            ln for ln in logic.splitlines() if ln.startswith("var %s = " % name)
        )
        return int(line.split("=")[1].strip(" ;"))

    assert number("LISTEN_S") == LD.LISTEN_SECONDS
    assert number("HELPER_LIMIT_S") == LD.LISTEN_SECONDS + LD.SLACK_SECONDS
