# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""streamkind.py: what a stream is, by its first bytes.

Only an Ogg stream with FLAC inside has to start through the relay, and
neither the directory's label nor the address tells it apart: measured on
2026-11-11, a station filed as FLAC sent plain FLAC and lost two and a half
seconds and its titles to the relay, and an Opus station filed as OGG, like
the Ogg FLAC ones, lost five.

The parser is tested on byte strings built here; the script is then run as
the widget runs it, against a loopback station that follows a script.
"""

import importlib.util
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

HELPER = (
    Path(__file__).resolve().parent.parent
    / "package"
    / "contents"
    / "ui"
    / "streamkind.py"
)

Script = Callable[[socket.socket], None]


def _module():
    spec = importlib.util.spec_from_file_location("streamkind", HELPER)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


SK = _module()


def _page(packet: bytes, version: int = 0, lacing: bytes | None = None) -> bytes:
    """One Ogg page that begins a stream and carries `packet`."""
    table = lacing if lacing is not None else bytes([len(packet)])
    return (
        b"OggS"
        + bytes([version, 2])
        + struct.pack("<qIII", 0, 7, 0, 0)
        + bytes([len(table)])
        + table
        + packet
    )


OGG_FLAC = _page(b"\x7fFLAC\x01\x00\x00\x01fLaC" + b"\x00" * 38)
VORBIS = _page(b"\x01vorbis" + b"\x00" * 23)
OPUS = _page(b"OpusHead\x01\x02" + b"\x00" * 9)
MP3_WITH_TAG = (
    b"ID3\x04\x00\x00\x00\x00\x02\x01"
    + b"TIT2"
    + b"\x00" * 250
    + b"\xff\xfb\x90\x64"
    + b"\x00" * 400
)
HTML = b"<!DOCTYPE html><html><head><title>404 Not Found</title></head><body>gone</body></html>"


def test_the_three_kinds_and_everything_else():
    assert SK.kind_of(OGG_FLAC) == "ogg-flac"
    assert SK.kind_of(VORBIS) == "ogg"
    assert SK.kind_of(OPUS) == "ogg"
    assert SK.kind_of(b"fLaC\x00\x00\x00\x22" + b"\x00" * 34) == "flac"
    assert SK.kind_of(b"\xff\xfb\x90\x64" + b"\x00" * 400) == "other"
    assert SK.kind_of(b"\xff\xf1\x50\x80" + b"\x00" * 400) == "other"
    # What followed the cut does not change what the first page said.
    assert SK.kind_of(OGG_FLAC + VORBIS) == "ogg-flac"
    assert SK.kind_of(bytearray(OGG_FLAC)) == "ogg-flac"


def test_a_tag_or_an_error_page_in_front_is_not_ogg():
    assert SK.kind_of(MP3_WITH_TAG) == "other"
    assert SK.kind_of(b"ICY 200 OK\r\nicy-name: x\r\n\r\n") == "other"
    # The words alone, somewhere inside, are not a first page.
    assert SK.kind_of(b"junk" + OGG_FLAC) == "other"
    assert SK.kind_of(b"fLa" + b"c" * 20) == "other"


def test_a_page_of_markup_is_no_stream_and_says_nothing():
    """An answer is remembered for the address. A login page of a hotel's
    network or a server's error page sent with 200 is not what the station
    is, so it must not be written down as "other"."""
    for page in (
        HTML,
        b"<html><body>Sign in to the network</body></html>",
        b"  \r\n\t<!doctype html><title>x</title>",
        b"\xef\xbb\xbf<!DOCTYPE html><html>",
        b'<?xml version="1.0"?><error>busy</error>',
        b"<h1>503</h1>",
    ):
        assert SK.kind_of(page) == "", page[:20]
    # What starts like audio is still judged, also when it holds a "<".
    assert SK.kind_of(MP3_WITH_TAG + b"<html>") == "other"
    assert SK.kind_of(b"\xff\xf1\x50\x80<<<<" + b"\x00" * 40) == "other"
    assert SK.kind_of(b"#EXTM3U\nhttp://x.example/live\n") == "other"
    assert SK.kind_of(OGG_FLAC + HTML) == "ogg-flac"
    # Too little to tell a page from anything: nothing, as before.
    assert SK.kind_of(b"<") == ""
    assert SK.kind_of(b"   ") == ""


def test_an_ogg_page_with_another_codec_is_ogg_and_no_more():
    assert SK.kind_of(_page(b"Speex   1.2rc1" + b"\x00" * 66)) == "ogg"
    assert SK.kind_of(_page(b"\x80theora\x03\x02" + b"\x00" * 33)) == "ogg"
    assert SK.kind_of(_page(b"fishead\x00\x03\x00" + b"\x00" * 54)) == "ogg"
    assert SK.kind_of(_page(b"\x00" * 30)) == "ogg"
    # The mapping libFLAC wrote before 1.1.1 is FLAC in Ogg all the same.
    assert SK.kind_of(_page(b"fLaC\x00\x00\x00\x22" + b"\x00" * 34)) == "ogg-flac"
    # A page of some later Ogg version is not one this reads.
    assert SK.kind_of(_page(b"\x7fFLAC\x01\x00" + b"\x00" * 40, version=1)) == "other"


def test_a_head_cut_short_says_nothing():
    for cut in (0, 1, 3):
        assert SK.kind_of(OGG_FLAC[:cut]) == "", cut
    # The page header is there, the codec header is not yet.
    for cut in (4, 26, 27, 28, 31):
        assert SK.kind_of(OGG_FLAC[:cut]) == "", cut
    assert SK.kind_of(OGG_FLAC[:33]) == "ogg-flac"
    # Seven bytes of an unknown packet could still be "OpusHead".
    assert SK.kind_of(_page(b"OpusHea")) == ""
    assert SK.kind_of(VORBIS[: 28 + 7]) == ""
    assert SK.kind_of(VORBIS[: 28 + 8]) == "ogg"
    # A lacing table longer than what arrived.
    assert SK.kind_of(_page(b"", lacing=b"\xff" * 255)[:60]) == ""
    assert SK.kind_of(b"fLa") == ""
    assert SK.kind_of(b"fLaC") == "flac"


def test_what_is_not_bytes_says_nothing():
    for junk in (None, "", "OggS", 0, 7, 3.5, [], [79, 103, 103, 83], {}, object()):
        assert SK.kind_of(junk) == "", repr(junk)


def test_ten_megabytes_are_judged_by_their_first_page():
    blob = b"\xa5" * (10 * 1024 * 1024)
    began = time.perf_counter()
    assert SK.kind_of(blob) == "other"
    assert SK.kind_of(OGG_FLAC + blob) == "ogg-flac"
    assert SK.kind_of(b"OggS" + blob) == "other"
    # The lacing count sits at byte 26 and a packet can start 255 bytes on.
    assert SK.kind_of(_page(b"", lacing=b"\xff" * 255) + blob) == "ogg"
    assert time.perf_counter() - began < 0.5
    assert SK.HEAD_BYTES <= 8192


def _answer(body: bytes, status: str = "200 OK", extra: str = "") -> Script:
    def script(conn: socket.socket) -> None:
        conn.sendall(
            (
                "HTTP/1.0 %s\r\nContent-Type: application/octet-stream\r\n%s\r\n"
                % (status, extra)
            ).encode()
            + body
        )

    return script


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

    def make(script: Script) -> str:
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(4)
        srv.settimeout(0.2)
        listeners.append(srv)
        threading.Thread(target=serve, args=(srv, script), daemon=True).start()
        return "http://127.0.0.1:%d/live" % srv.getsockname()[1]

    yield make
    stop.set()
    for srv in listeners:
        srv.close()


def _ask(
    tmp_path: Path, address: str, limit: float = 10.0
) -> tuple[str, int, Path, float]:
    note = tmp_path / "address"
    note.write_text(address, encoding="utf-8")
    began = time.monotonic()
    done = subprocess.run(
        [sys.executable, str(HELPER), str(note)],
        capture_output=True,
        text=True,
        timeout=limit,
        check=False,
    )
    return done.stdout, done.returncode, note, time.monotonic() - began


def test_the_script_names_a_station_and_removes_the_address(tmp_path, station):
    out, rc, note, _took = _ask(
        tmp_path, station(_answer(OGG_FLAC + b"\x00" * 9000)) + "?token=s3cret"
    )
    assert (out, rc) == ("ogg-flac\n", 0)
    assert not note.exists(), "the address is left lying in its file"
    assert _ask(tmp_path, station(_answer(b"fLaC" + b"\x00" * 600)))[0] == "flac\n"
    assert _ask(tmp_path, station(_answer(VORBIS)))[0] == "ogg\n"
    assert _ask(tmp_path, station(_answer(MP3_WITH_TAG)))[0] == "other\n"


def test_the_script_reads_an_address_with_a_space_in_it(tmp_path, station):
    """The player plays such an address; a helper that refused it left the
    stream's kind unknown for good."""
    base = station(_answer(OGG_FLAC + b"\x00" * 200))
    for path in ("/it's live?token=s3cret", "/it's%20live", "/\u00f5htu raadio.ogg"):
        out, rc, note, _took = _ask(tmp_path, base.replace("/live", path))
        assert (out, rc) == ("ogg-flac\n", 0), path
        assert not note.exists()


def test_the_script_stops_reading_once_it_knows(tmp_path, station):
    sent = []

    def endless(conn: socket.socket) -> None:
        conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n")
        while True:
            conn.sendall(b"\xa5" * 4096)
            sent.append(4096)
            time.sleep(0.01)

    out, _rc, _note, took = _ask(tmp_path, station(endless))
    assert out == "other\n"
    assert took < 2.5
    # A socket buffer or two may have left the station; megabytes may not.
    assert sum(sent) < 512 * 1024


def test_the_script_answers_on_the_first_page_alone(tmp_path, station):
    # A station that sends its first page and then nothing for a while: the
    # answer is in those 79 bytes, and waiting for more would lose it.
    def one_page(conn: socket.socket) -> None:
        conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n" + OGG_FLAC)
        time.sleep(7)

    out, _rc, _note, took = _ask(tmp_path, station(one_page))
    assert out == "ogg-flac\n"
    assert took < 2.0


def test_the_script_follows_a_station_that_sends_it_on(tmp_path, station):
    there = station(_answer(OGG_FLAC))
    out, _rc, _note, _took = _ask(
        tmp_path, station(_answer(b"", "302 Found", "Location: %s\r\n" % there))
    )
    assert out == "ogg-flac\n"
    # But not out of the web: urllib would fetch an ftp address too. The
    # trap is a door an ftp client would knock on.
    trap = socket.socket()
    trap.bind(("127.0.0.1", 0))
    trap.listen(1)
    trap.settimeout(0.3)
    try:
        there = "ftp://127.0.0.1:%d/x.flac" % trap.getsockname()[1]
        out, rc, _note, _took = _ask(
            tmp_path, station(_answer(b"", "302 Found", "Location: %s\r\n" % there))
        )
        assert (out, rc) == ("", 0)
        with pytest.raises(TimeoutError):
            trap.accept()
    finally:
        trap.close()


def test_the_script_says_nothing_when_there_is_nothing_to_judge(tmp_path, station):
    for script in (
        _answer(b""),
        _answer(b"Og"),
        _answer(HTML, "404 Not Found"),
        _answer(OGG_FLAC, "503 Busy"),
    ):
        out, rc, _note, _took = _ask(tmp_path, station(script))
        assert (out, rc) == ("", 0)
    # A server that speaks no HTTP, and one that is not there at all.
    out, rc, _note, _took = _ask(
        tmp_path, station(lambda conn: conn.sendall(b"ICY 200 OK\r\n\r\n" + OGG_FLAC))
    )
    assert (out, rc) == ("", 0)
    assert _ask(tmp_path, "http://127.0.0.1:9/live")[:2] == ("", 0)


def _typed(body: bytes, ctype: str) -> Script:
    def script(conn: socket.socket) -> None:
        head = (
            "HTTP/1.0 200 OK\r\n"
            + ("Content-Type: %s\r\n" % ctype if ctype else "")
            + "\r\n"
        )
        conn.sendall(head.encode() + body)

    return script


def test_the_script_does_not_name_a_page_that_came_with_200(tmp_path, station):
    """A captive portal and many an error page answer 200. What they send is
    text, and a text answer is never a kind: the address is asked about
    again at its next start instead of being remembered as "other"."""
    silent = (
        _typed(HTML, "text/html; charset=utf-8"),
        _typed(HTML, "application/octet-stream"),
        _typed(HTML, ""),
        _typed(b"Service temporarily unavailable, try again later.", "text/plain"),
        _typed(b"Service temporarily unavailable, try again later.", "TEXT/HTML"),
        # Audio said to be text is not trusted either way: nothing is remembered.
        _typed(OGG_FLAC, "text/html"),
    )
    for script in silent:
        out, rc, _note, _took = _ask(tmp_path, station(script))
        assert (out, rc) == ("", 0)
    # A station that names no type at all, as ICY servers do, is still read.
    out, rc, _note, _took = _ask(tmp_path, station(_typed(OGG_FLAC, "")))
    assert (out, rc) == ("ogg-flac\n", 0)
    out, rc, _note, _took = _ask(tmp_path, station(_typed(MP3_WITH_TAG, "audio/mpeg")))
    assert (out, rc) == ("other\n", 0)
    # A playlist is not a page: the player is handed it as before.
    out, rc, _note, _took = _ask(
        tmp_path,
        station(_typed(b"#EXTM3U\nhttp://x.example/live\n", "audio/x-mpegurl")),
    )
    assert (out, rc) == ("other\n", 0)
    # Sent on to a sign-in page: the page it lands on says nothing.
    portal = station(_typed(HTML, "text/html"))
    out, rc, _note, _took = _ask(
        tmp_path, station(_answer(b"", "302 Found", "Location: %s\r\n" % portal))
    )
    assert (out, rc) == ("", 0)


def test_the_script_opens_web_addresses_only(tmp_path):
    secret = tmp_path / "secret.flac"
    secret.write_bytes(b"fLaC" + b"\x00" * 100)
    for address in (
        secret.as_uri(),
        str(secret),
        "ftp://127.0.0.1/x",
        "",
        "   ",
        "not an address",
        "data:audio/flac;base64,ZkxhQw==",
    ):
        out, rc, note, _took = _ask(tmp_path, address)
        assert (out, rc) == ("", 0), address
        assert not note.exists()
    # No file at all, a folder for a file, and no argument.
    gone = subprocess.run(
        [sys.executable, str(HELPER), str(tmp_path / "nope")],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (gone.stdout, gone.returncode) == ("", 0)
    folder = subprocess.run(
        [sys.executable, str(HELPER), str(tmp_path)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (folder.stdout, folder.returncode) == ("", 0)
    bare = subprocess.run(
        [sys.executable, str(HELPER)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (bare.stdout, bare.returncode) == ("", 2)


@pytest.mark.slow
def test_the_script_gives_up_on_a_station_that_goes_quiet(tmp_path, station):
    def quiet(conn: socket.socket) -> None:
        conn.sendall(b"HTTP/1.0 200 OK\r\n\r\nOg")
        time.sleep(7)

    out, _rc, note, took = _ask(tmp_path, station(quiet))
    assert out == ""
    assert took < SK.TOTAL_SECONDS + 2.0
    assert not note.exists()

    def never(conn: socket.socket) -> None:
        time.sleep(7)

    out, _rc, _note, took = _ask(tmp_path, station(never))
    assert out == ""
    assert took < SK.TOTAL_SECONDS + 2.0


@pytest.fixture(scope="module")
def pki(tmp_path_factory) -> dict[str, str]:
    """A test authority and three certificates for 127.0.0.1: one it issued
    whose dates have passed, one it issued for another host, and one nobody
    issued. The same set test_reader_tls.py makes for the title reader."""
    if shutil.which("openssl") is None:
        pytest.skip("openssl is needed to make the test's certificates")
    helptext = subprocess.run(
        ["openssl", "x509", "-help"], capture_output=True, text=True, check=False
    ).stderr
    if "-not_after" not in helptext:
        pytest.skip(
            "this openssl cannot date a certificate in the past (needs 3.4 or later)"
        )
    d = tmp_path_factory.mktemp("pki")
    p = {
        k: str(d / k)
        for k in (
            "ca.key",
            "ca.pem",
            "leaf.key",
            "leaf.csr",
            "lapsed.pem",
            "other.pem",
            "self.key",
            "self.pem",
            "ip.ext",
            "other.ext",
        )
    }
    leaf = (
        "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n"
    )
    (d / "ip.ext").write_text(leaf + "subjectAltName=IP:127.0.0.1\n")
    (d / "other.ext").write_text(leaf + "subjectAltName=DNS:other.example\n")

    def openssl(*args: str) -> None:
        subprocess.run(["openssl", *args], check=True, capture_output=True, timeout=60)

    openssl(
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-days",
        "2",
        "-subj",
        "/CN=Test Authority",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign",
        "-keyout",
        p["ca.key"],
        "-out",
        p["ca.pem"],
    )
    openssl(
        "req",
        "-new",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-subj",
        "/CN=127.0.0.1",
        "-keyout",
        p["leaf.key"],
        "-out",
        p["leaf.csr"],
    )
    openssl(
        "x509",
        "-req",
        "-in",
        p["leaf.csr"],
        "-CA",
        p["ca.pem"],
        "-CAkey",
        p["ca.key"],
        "-set_serial",
        "2",
        "-not_before",
        "20250101000000Z",
        "-not_after",
        "20260101000000Z",
        "-extfile",
        p["ip.ext"],
        "-out",
        p["lapsed.pem"],
    )
    openssl(
        "x509",
        "-req",
        "-in",
        p["leaf.csr"],
        "-CA",
        p["ca.pem"],
        "-CAkey",
        p["ca.key"],
        "-set_serial",
        "3",
        "-days",
        "1",
        "-extfile",
        p["other.ext"],
        "-out",
        p["other.pem"],
    )
    openssl(
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-days",
        "1",
        "-subj",
        "/CN=127.0.0.1",
        "-addext",
        "subjectAltName=IP:127.0.0.1",
        "-keyout",
        p["self.key"],
        "-out",
        p["self.pem"],
    )
    return p


@pytest.fixture
def tls_station() -> Iterator[Callable[[str, str], str]]:
    """tls_station(cert, key) serves an Ogg FLAC stream's first page on
    https://127.0.0.1:<port>/live with that certificate."""
    stop = threading.Event()
    listeners: list[socket.socket] = []

    def serve(srv: socket.socket, ctx: ssl.SSLContext) -> None:
        while not stop.is_set():
            try:
                raw, _ = srv.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            try:
                raw.settimeout(5)
                conn = ctx.wrap_socket(raw, server_side=True)
                conn.recv(4096)
                conn.sendall(
                    b"HTTP/1.0 200 OK\r\nContent-Type: application/ogg\r\n\r\n"
                    + OGG_FLAC
                )
                conn.close()
            except OSError:
                # A helper that refuses the certificate hangs up in the handshake.
                raw.close()

    def make(cert: str, key: str) -> str:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(4)
        srv.settimeout(0.2)
        listeners.append(srv)
        threading.Thread(target=serve, args=(srv, ctx), daemon=True).start()
        return "https://127.0.0.1:%d/live" % srv.getsockname()[1]

    yield make
    stop.set()
    for srv in listeners:
        srv.close()


def _ask_trusting(tmp_path: Path, address: str, authority: str) -> str:
    # The test authority stands in for the system's: OpenSSL's default
    # context reads its bundle from here.
    note = tmp_path / "address"
    note.write_text(address, encoding="utf-8")
    env = dict(os.environ, SSL_CERT_FILE=authority)
    done = subprocess.run(
        [sys.executable, str(HELPER), str(note)],
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
        check=False,
    )
    assert done.returncode == 0, done.stderr
    return done.stdout


def test_a_station_behind_a_lapsed_certificate_is_still_read(
    tmp_path, pki, tls_station
):
    # The player does not look at a certificate's dates, and the title
    # reader stopped doing so on 2026-11-02 for the stations that lost their
    # titles to it; a helper that did would send those to the rescue.
    assert (
        _ask_trusting(
            tmp_path, tls_station(pki["lapsed.pem"], pki["leaf.key"]), pki["ca.pem"]
        )
        == "ogg-flac\n"
    )


def test_a_certificate_nobody_issued_or_for_another_host_is_refused(
    tmp_path, pki, tls_station
):
    assert (
        _ask_trusting(
            tmp_path, tls_station(pki["self.pem"], pki["self.key"]), pki["ca.pem"]
        )
        == ""
    )
    assert (
        _ask_trusting(
            tmp_path, tls_station(pki["other.pem"], pki["leaf.key"]), pki["ca.pem"]
        )
        == ""
    )


# ------------------------------------------------- the buffer writer's codec
#
# The sliding buffer cuts MPEG-TS segments, which hold MP3 and AAC (measured:
# FLAC and Vorbis written into them come out unplayable, with ffmpeg exiting
# 0). Its writer asks about the bytes it has already fetched, so the answer
# costs no connection, and a stream that is neither goes to the single file.

_MP3_RATES = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)


def _mp3_frame(kbps: int = 128, hz: int = 44100, pad: bool = False) -> bytes:
    """One MPEG-1 layer III frame with a true header and a made-up body."""
    rate = {44100: 0, 48000: 1, 32000: 2}[hz]
    head = bytes([0xFF, 0xFB, (_MP3_RATES.index(kbps) << 4) | (rate << 2) | (2 if pad else 0), 0x64])
    return head + b"\x55" * (144 * kbps * 1000 // hz + (1 if pad else 0) - 4)


def _mp3_v2_frame(kbps: int = 64, hz: int = 22050) -> bytes:
    """One MPEG-2 layer III frame: half the samples, so half the bytes."""
    rates = (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)
    head = bytes([0xFF, 0xF3, (rates.index(kbps) << 4) | ({22050: 0, 24000: 1, 16000: 2}[hz] << 2), 0x64])
    return head + b"\x55" * (72 * kbps * 1000 // hz - 4)


def _adts_frame(size: int = 371, rate_index: int = 4) -> bytes:
    """One ADTS frame: AAC LC, stereo, no CRC, `size` bytes with its header."""
    head = bytes([
        0xFF, 0xF1, (1 << 6) | (rate_index << 2), (2 << 6) | (size >> 11),
        (size >> 3) & 0xFF, ((size & 7) << 5) | 0x1F, 0xFC,
    ])
    return head + b"\x21" * (size - 7)


def _id3(size: int) -> bytes:
    safe = bytes([(size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F])
    return b"ID3\x04\x00\x00" + safe + b"\x00" * size


def test_bare_mp3_and_bare_aac_are_named():
    assert SK.codec_of(_mp3_frame() * 9) == "mp3"
    assert SK.codec_of((_mp3_frame() + _mp3_frame(pad=True)) * 5) == "mp3"
    assert SK.codec_of(_mp3_frame(320, 48000) * 4) == "mp3"
    assert SK.codec_of(_mp3_v2_frame() * 12) == "mp3"
    assert SK.codec_of(_adts_frame() * 11) == "aac"
    assert SK.codec_of(_adts_frame(130, 3) * 30) == "aac"
    # A station sends from wherever it is: the first frame is cut.
    assert SK.codec_of(_mp3_frame()[150:] + _mp3_frame() * 8) == "mp3"
    assert SK.codec_of(_adts_frame()[9:] + _adts_frame() * 10) == "aac"
    # A tag in front, as a file served as a stream has.
    assert SK.codec_of(_id3(300) + _mp3_frame() * 8) == "mp3"
    assert SK.codec_of(_id3(0) + _adts_frame() * 10) == "aac"


def test_what_a_tag_holds_is_not_the_stream():
    # A tag can carry anything, a picture for one, and here it carries what
    # reads as AAC frames. The stream behind it is MP3.
    inside = _adts_frame(130, 3) * 4
    tag = b"ID3\x04\x00\x00" + bytes([0, 0, len(inside) >> 7, len(inside) & 0x7F]) + inside
    assert SK.codec_of(inside + _mp3_frame() * 8) == "aac"
    assert SK.codec_of(tag + _mp3_frame() * 8) == "mp3"


def test_three_frames_in_a_row_are_what_it_takes():
    three = _mp3_frame() * 3
    # The third frame only has to show its header.
    assert SK.codec_of(three[: 2 * 417 + 4]) == "mp3"
    assert SK.codec_of(three[: 2 * 417 + 3]) == ""
    assert SK.codec_of(_mp3_frame() * 2) == ""
    assert SK.codec_of(_adts_frame() * 2 + _adts_frame()[:7]) == "aac"
    assert SK.codec_of(_adts_frame() * 2 + _adts_frame()[:6]) == ""
    # Two sync words that do not sit a frame apart are noise.
    assert SK.codec_of(_mp3_frame()[:200] * 20) == ""
    assert SK.codec_of(_adts_frame()[:100] * 40) == ""
    # A frame of another rate in the row breaks it; the row after it counts.
    assert SK.codec_of(_mp3_frame() + _mp3_frame(128, 48000) + _mp3_frame()) == ""
    assert SK.codec_of(_mp3_frame() + _mp3_frame(128, 48000) + _mp3_frame() * 3) == "mp3"


def test_what_is_neither_says_nothing():
    assert SK.codec_of(OGG_FLAC + b"\x00" * 4000) == ""
    assert SK.codec_of(VORBIS + b"\x00" * 4000) == ""
    assert SK.codec_of(b"fLaC" + _mp3_frame() * 9) == ""
    assert SK.codec_of(b"<html>" + _mp3_frame() * 9) == ""
    # Layer II and layer I are MPEG audio and not MP3.
    layer2 = bytes([0xFF, 0xFD, 0x90, 0x64]) + b"\x55" * 413
    assert SK.codec_of(layer2 * 9) == ""
    # A header with a rate or a bitrate nobody defined.
    assert SK.codec_of((bytes([0xFF, 0xFB, 0x9C, 0x64]) + b"\x55" * 413) * 9) == ""
    assert SK.codec_of((bytes([0xFF, 0xFB, 0xF0, 0x64]) + b"\x55" * 413) * 9) == ""
    assert SK.codec_of((bytes([0xFF, 0xFB, 0x00, 0x64]) + b"\x55" * 413) * 9) == ""
    assert SK.codec_of(bytes([0xFF, 0xF1, 0x7C, 0x80, 0x2E, 0x7F, 0xFC]) * 300) == ""
    # An ADTS frame that claims to be shorter than its own header.
    assert SK.codec_of(bytes([0xFF, 0xF1, 0x50, 0x80, 0x00, 0x9F, 0xFC]) * 300) == ""
    assert SK.codec_of(b"\xa5" * 4096) == ""
    assert SK.codec_of(b"\xff" * 4096) == ""
    assert SK.codec_of(b"\x00" * 4096) == ""
    # A frame that claims no length at all would be its own successor.
    assert SK.codec_of(bytes([0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC]) + b"\xa5" * 4000) == ""
    # A tag that runs past the head hides whatever follows it.
    assert SK.codec_of(_id3(5000) + _mp3_frame() * 9) == ""
    assert SK.codec_of(b"ID3\x04\x00\x00\xff\xff\xff\xff" + _mp3_frame() * 9) == ""
    # A length byte with its top bit set is no ID3 length, however short the
    # tag it would spell: what follows cannot be placed.
    assert SK.codec_of(b"ID3\x04\x00\x00\x00\x00\x00\x85" + b"\x00" * 133 + _mp3_frame() * 9) == ""
    assert SK.codec_of(b"ID3\x04\x00\x00\x00\x00\x01\x05" + b"\x00" * 133 + _mp3_frame() * 9) == "mp3"


def test_too_little_and_what_is_not_bytes_say_nothing():
    for few in (b"", b"\xff", b"\xff\xfb", b"\xff\xfb\x90\x64", b"ID3", b"ID3\x04\x00\x00\x00\x00\x00"):
        assert SK.codec_of(few) == "", few
    for junk in (None, "", "ID3", 0, 7, 3.5, [], [255, 251], {}, object()):
        assert SK.codec_of(junk) == "", repr(junk)
    assert SK.codec_of(bytearray(_mp3_frame() * 9)) == "mp3"


def test_ten_megabytes_of_frames_are_judged_by_their_head():
    began = time.perf_counter()
    assert SK.codec_of(_mp3_frame() * 25000) == "mp3"
    assert SK.codec_of(_adts_frame() * 28000) == "aac"
    # Frames that begin past the head are not looked for.
    assert SK.codec_of(b"\x00" * SK.HEAD_BYTES + _mp3_frame() * 25000) == ""
    assert SK.codec_of(b"\xff\xfb" * (5 * 1024 * 1024)) == ""
    assert time.perf_counter() - began < 1.0


def _codec(path: Path) -> tuple[str, int]:
    done = subprocess.run(
        [sys.executable, str(HELPER), "--codec", str(path)], capture_output=True, text=True, timeout=10, check=False
    )
    return done.stdout, done.returncode


def test_the_script_names_the_codec_of_a_head_file_and_leaves_it(tmp_path):
    head = tmp_path / "head-7.bin"
    head.write_bytes((_mp3_frame() * 12)[:4096])
    assert _codec(head) == ("mp3\n", 0)
    assert head.exists(), "the writer still has to hand these bytes to ffmpeg"
    head.write_bytes((_adts_frame() * 12)[:4096])
    assert _codec(head) == ("aac\n", 0)
    head.write_bytes(OGG_FLAC + b"\x00" * 4000)
    assert _codec(head) == ("", 0)
    head.write_bytes(b"")
    assert _codec(head) == ("", 0)
    assert _codec(tmp_path / "missing.bin") == ("", 0)
    assert _codec(tmp_path) == ("", 0)
    # A file far longer than a head is read as far as a head goes.
    head.write_bytes(_mp3_frame() * 25000)
    assert _codec(head) == ("mp3\n", 0)


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is not installed")
def test_the_script_names_what_real_encoders_write(tmp_path):
    """Four seconds of tone through the encoders a station would use."""
    made = {}
    for name, args in (
        ("a.mp3", ["-c:a", "libmp3lame", "-b:a", "128k", "-write_xing", "0", "-id3v2_version", "0", "-f", "mp3"]),
        ("tagged.mp3", ["-c:a", "libmp3lame", "-b:a", "64k", "-ar", "22050", "-f", "mp3"]),
        ("a.aac", ["-c:a", "aac", "-b:a", "96k", "-f", "adts"]),
        ("a.flac", ["-c:a", "flac", "-f", "flac"]),
        ("a.ogg", ["-c:a", "flac", "-f", "ogg"]),
        ("a.mka", ["-c:a", "libmp3lame", "-f", "matroska"]),
    ):
        out = tmp_path / name
        done = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
             *args, str(out)], capture_output=True, text=True, timeout=60, check=False)
        if done.returncode == 0:
            head = tmp_path / (name + ".head")
            head.write_bytes(out.read_bytes()[: SK.HEAD_BYTES])
            # And from the middle, where a listener joins a station.
            mid = tmp_path / (name + ".mid")
            mid.write_bytes(out.read_bytes()[5000 : 5000 + SK.HEAD_BYTES])
            made[name] = (_codec(head)[0], _codec(mid)[0])
    if "a.mp3" not in made or "a.aac" not in made:
        pytest.skip("this ffmpeg cannot encode MP3 and AAC")
    assert made["a.mp3"] == ("mp3\n", "mp3\n")
    assert made["a.aac"] == ("aac\n", "aac\n")
    if "tagged.mp3" in made:
        assert made["tagged.mp3"] == ("mp3\n", "mp3\n")
    for other in ("a.flac", "a.ogg", "a.mka"):
        if other in made:
            assert made[other][0] == "", other
