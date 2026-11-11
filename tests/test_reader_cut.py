# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""reader.py against a station that drops the title request half way.

The widget pins "__NO_ICY__" for the station that answered with it: no more
polls, no titles and no covers until the station is started again by hand. A
connection cut in the middle of the body is not that kind of answer. Measured
on 2026-11-10 with a loopback station sending icy-metaint, 3000 bytes and then
a reset: requests raised ChunkedEncodingError, which is neither a
ConnectionError nor a Timeout, and the reader filed it as final.

These run the real script as the widget does, against a socket that follows a
script byte for byte.
"""

import os
import socket
import struct
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

READER = (
    Path(__file__).resolve().parent.parent / "package" / "contents" / "ui" / "reader.py"
)
METAINT = 8192

# Without requests the reader prints __NO_ICY__ by design, and there is
# nothing of the network road left to test.
pytest.importorskip("requests")

Script = Callable[[socket.socket], None]


def _head(*lines: str) -> bytes:
    return (
        "\r\n".join(("HTTP/1.0 200 OK", "Content-Type: audio/mpeg", *lines))
        + "\r\n\r\n"
    ).encode()


def _titled(title: str) -> bytes:
    meta = ("StreamTitle='%s';" % title).encode()
    meta += b"\x00" * (-len(meta) % 16)
    return b"\xff" * METAINT + bytes([len(meta) // 16]) + meta


def _reset(conn: socket.socket) -> None:
    # Linger on with no time to linger: close() sends RST, not FIN.
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()


@pytest.fixture
def station() -> Iterator[Callable[[Script], str]]:
    """station(script) listens on 127.0.0.1 and hands every connection, its
    request already read, to script(conn). Returns the address."""
    stop = threading.Event()
    listeners: list[socket.socket] = []

    def serve(srv: socket.socket, script: Script) -> None:
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            try:
                conn.settimeout(5)
                seen = b""
                while b"\r\n\r\n" not in seen:
                    part = conn.recv(4096)
                    if not part:
                        break
                    seen += part
                script(conn)
            except OSError:
                # The reader hung up first; the script has nothing left to say.
                pass
            finally:
                conn.close()

    def start(script: Script) -> str:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(8)
        srv.settimeout(0.2)
        listeners.append(srv)
        threading.Thread(target=serve, args=(srv, script), daemon=True).start()
        return "http://127.0.0.1:%d/live" % srv.getsockname()[1]

    yield start
    stop.set()
    for srv in listeners:
        srv.close()


def _read(url: str) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ, NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
    return subprocess.run(
        [sys.executable, str(READER), url, ""],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
    )


def test_a_title_comes_through_this_rig(station):
    # The control: what the scripts below cut short is a station that works.
    def whole(conn: socket.socket) -> None:
        conn.sendall(_head("icy-metaint: %d" % METAINT) + _titled("Artist - Song"))

    done = _read(station(whole))
    assert done.stdout == "Artist - Song\t\n", done.stderr
    assert done.returncode == 0


def test_a_reset_in_the_middle_of_the_body_is_not_a_verdict(station):
    def cut(conn: socket.socket) -> None:
        conn.sendall(_head("icy-metaint: %d" % METAINT) + b"\xff" * 3000)
        # Let the reader take the headers in first, so the reset lands on
        # the body. One that beats the headers is a ConnectionError, which
        # was always quiet, and would prove nothing here.
        time.sleep(0.3)
        _reset(conn)

    done = _read(station(cut))
    assert "ChunkedEncodingError" in done.stderr, (
        "the cut did not land mid-body: " + done.stderr
    )
    assert done.stdout == "", "a dropped connection switched the station's titles off"
    assert done.returncode == 0


def test_a_reset_after_a_long_run_of_audio_is_not_a_verdict(station):
    # Past the first read and past the first metadata block, which is empty.
    def cut(conn: socket.socket) -> None:
        conn.sendall(
            _head("icy-metaint: %d" % METAINT)
            + b"\xff" * METAINT
            + b"\x00"
            + b"\xff" * 5000
        )
        time.sleep(0.3)
        _reset(conn)

    done = _read(station(cut))
    assert "ChunkedEncodingError" in done.stderr, (
        "the cut did not land mid-body: " + done.stderr
    )
    assert done.stdout == ""
    assert done.returncode == 0


def test_a_chunked_stream_cut_inside_a_chunk_is_not_a_verdict(station):
    def cut(conn: socket.socket) -> None:
        conn.sendall(
            b"HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n"
            b"icy-metaint: %d\r\nTransfer-Encoding: chunked\r\n\r\n"
            % METAINT
            + b"1000\r\n"
            + b"\xff" * 100
        )

    done = _read(station(cut))
    assert "ChunkedEncodingError" in done.stderr, done.stderr
    assert done.stdout == ""
    assert done.returncode == 0


def test_a_body_shorter_than_its_declared_length_is_not_a_verdict(station):
    def short(conn: socket.socket) -> None:
        conn.sendall(
            _head("icy-metaint: %d" % METAINT, "Content-Length: 100000")
            + b"\xff" * 3000
        )

    done = _read(station(short))
    assert done.stdout == "", done.stderr
    assert done.returncode == 0


def test_a_body_that_does_not_unpack_is_not_a_verdict(station):
    def garbled(conn: socket.socket) -> None:
        conn.sendall(
            _head("icy-metaint: %d" % METAINT, "Content-Encoding: gzip")
            + b"\xff" * 3000
        )

    done = _read(station(garbled))
    assert "ContentDecodingError" in done.stderr, done.stderr
    assert done.stdout == ""
    assert done.returncode == 0


def test_a_clean_close_before_the_first_title_says_nothing(station):
    def brief(conn: socket.socket) -> None:
        conn.sendall(_head("icy-metaint: %d" % METAINT) + b"\xff" * 3000)

    done = _read(station(brief))
    assert done.stdout == "", done.stderr
    assert done.returncode == 0


def test_a_connection_closed_without_a_word_says_nothing(station):
    done = _read(station(lambda conn: None))
    assert done.stdout == "", done.stderr
    assert done.returncode == 0


def test_a_station_without_icy_still_says_so(station):
    # The verdict this file is about has to stay available to the stations
    # that earn it: plain audio and no icy-metaint.
    def plain(conn: socket.socket) -> None:
        conn.sendall(_head() + b"\xff" * 3000)

    done = _read(station(plain))
    assert done.stdout == "__NO_ICY__\n", done.stderr


def test_a_redirect_that_never_ends_is_still_final(station):
    # requests gives up after thirty hops with TooManyRedirects: nothing a
    # later poll would mend, and the branch the cut used to fall into.
    def around(conn: socket.socket) -> None:
        conn.sendall(
            b"HTTP/1.1 302 Found\r\nLocation: /live\r\nContent-Length: 0\r\n"
            b"Connection: close\r\n\r\n"
        )

    done = _read(station(around))
    assert "TooManyRedirects" in done.stderr, done.stderr
    assert done.stdout == "__NO_ICY__\n"
