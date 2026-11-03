# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""reader.py against a station whose certificate has lapsed.

The player opens a station's address without checking its certificate, so a
station whose edge let the certificate run out keeps playing. The title
reader checked it, and those stations had no titles and no covers at all:
euddn's le0X edges since 2026-10-23 (Raadio Elmar, Kuku, Duo). Measured on
2026-11-02, every one of them failed with OpenSSL's code 10, "certificate has
expired", on a *.euddn.net certificate a trusted authority issued. The reader
now leaves only the dates unchecked; a certificate nobody trusted, or one for
another host, is refused as before.

These run the real script as the widget does, against a local HTTPS server
whose certificates are made for the test by a throwaway authority.
"""

import http.server
import os
import shutil
import ssl
import subprocess
import sys
import threading
from pathlib import Path

import pytest

READER = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui" / "reader.py"
METAINT = 16

# Without requests the reader prints __NO_ICY__ by design, and there is
# nothing of the network road left to test.
pytest.importorskip("requests")


def _openssl(*args: str) -> None:
    subprocess.run(["openssl", *args], check=True, capture_output=True, timeout=60)


@pytest.fixture(scope="module")
def pki(tmp_path_factory):
    """A test authority and three certificates for 127.0.0.1: one it issued
    whose dates have passed, one it issued for another host, and one nobody
    issued. Returns a dict of paths."""
    if shutil.which("openssl") is None:
        pytest.skip("openssl is needed to make the test's certificates")
    helptext = subprocess.run(["openssl", "x509", "-help"], capture_output=True, text=True).stderr
    if "-not_after" not in helptext:
        pytest.skip("this openssl cannot date a certificate in the past (needs 3.4 or later)")
    d = tmp_path_factory.mktemp("pki")
    p = {k: str(d / k) for k in ("ca.key", "ca.pem", "leaf.key", "leaf.csr", "lapsed.pem",
                                  "other.pem", "self.key", "self.pem", "ip.ext", "other.ext",
                                  "cn.csr", "cn.pem", "cn.ext")}
    # Python's default context checks strictly (VERIFY_X509_STRICT), so the
    # test authority and its certificates carry what a real one's do.
    leaf = ("basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n")
    (d / "ip.ext").write_text(leaf + "subjectAltName=IP:127.0.0.1\n")
    (d / "other.ext").write_text(leaf + "subjectAltName=DNS:other.example\n")
    (d / "cn.ext").write_text(leaf)
    _openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=Test Authority",
             "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
             "-keyout", p["ca.key"], "-out", p["ca.pem"])
    _openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
             "-keyout", p["leaf.key"], "-out", p["leaf.csr"])
    _openssl("x509", "-req", "-in", p["leaf.csr"], "-CA", p["ca.pem"], "-CAkey", p["ca.key"],
             "-set_serial", "2", "-not_before", "20250101000000Z", "-not_after", "20260101000000Z",
             "-extfile", p["ip.ext"], "-out", p["lapsed.pem"])
    _openssl("x509", "-req", "-in", p["leaf.csr"], "-CA", p["ca.pem"], "-CAkey", p["ca.key"],
             "-set_serial", "3", "-days", "1", "-extfile", p["other.ext"], "-out", p["other.pem"])
    _openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
             "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", p["self.key"], "-out", p["self.pem"])
    # The host only in the subject's CN, no subjectAltName: what certificates
    # looked like before SANs were required.
    _openssl("req", "-new", "-key", p["leaf.key"], "-subj", "/CN=localhost", "-out", p["cn.csr"])
    _openssl("x509", "-req", "-in", p["cn.csr"], "-CA", p["ca.pem"], "-CAkey", p["ca.key"],
             "-set_serial", "4", "-days", "1", "-extfile", p["cn.ext"], "-out", p["cn.pem"])
    return p


def _icy_body(title: str, blocks: int = 3) -> bytes:
    meta = ("StreamTitle='%s';" % title).encode()
    meta += b"\x00" * (-len(meta) % 16)
    out = b""
    for _ in range(blocks):
        out += b"\xff" * METAINT + bytes([len(meta) // 16]) + meta
    return out


class _Station(http.server.BaseHTTPRequestHandler):
    status = 200
    title = "Artist - Song"
    connections = 0

    def do_GET(self):
        type(self).connections += 1
        self.send_response(self.status)
        if self.status == 200:
            self.send_header("icy-metaint", str(METAINT))
            self.send_header("Content-Type", "audio/aac")
        self.end_headers()
        if self.status == 200:
            self.wfile.write(_icy_body(self.title))

    def log_message(self, format, *args):
        pass


@pytest.fixture
def serve(pki):
    """serve(cert, key) starts an ICY station on https://127.0.0.1:<port>/
    with that certificate and returns (url, handler class)."""
    servers = []

    def start(cert: str, key: str):
        handler = type("Station", (_Station,), {"connections": 0})
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
        return "https://127.0.0.1:%d/live" % srv.server_address[1], handler

    yield start
    for srv in servers:
        srv.shutdown()
        srv.server_close()


def _read(url: str, pki: dict):
    # The test authority stands in for the system's: requests reads its
    # bundle from here.
    env = dict(os.environ, REQUESTS_CA_BUNDLE=pki["ca.pem"])
    return subprocess.run(
        [sys.executable, str(READER), url, ""],
        capture_output=True, text=True, timeout=60, env=env,
    )


def _read_as_if_urllib3(version: str, url: str, pki: dict):
    # urllib3 1.26 hands no server name to the context for an address that
    # is an IP (measured with 1.26.20 on 2026-11-03), and a context that
    # checks host names then refuses every such station with a ValueError.
    code = ("import sys, runpy, urllib3; urllib3.__version__ = %r; sys.argv = [%r, %r, '']; "
            "runpy.run_path(%r, run_name='__main__')" % (version, str(READER), url, str(READER)))
    env = dict(os.environ, REQUESTS_CA_BUNDLE=pki["ca.pem"])
    return subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60, env=env)


def test_on_urllib3_1_26_the_reader_keeps_requests_own_checks(pki, serve):
    url, handler = serve(pki["lapsed.pem"], pki["leaf.key"])
    got = _read_as_if_urllib3("1.26.20", url, pki)
    assert "ValueError" not in got.stderr, got.stderr
    assert handler.connections == 0, "the lapsed certificate was let through"
    assert got.stdout == "", (got.stdout, got.stderr)
    assert "SSLError" in got.stderr, got.stderr
    # The same stack on urllib3 2 lets only the dates go.
    got = _read_as_if_urllib3("2.8.0", url, pki)
    assert got.stdout == "Artist - Song\t\n", (got.stdout, got.stderr)


def test_a_title_behind_a_lapsed_certificate_comes_through(pki, serve):
    url, handler = serve(pki["lapsed.pem"], pki["leaf.key"])
    got = _read(url, pki)
    assert got.stdout == "Artist - Song\t\n", (got.stdout, got.stderr)
    # One connection: a check-then-retry would be a second one, and a
    # connection-capped Icecast answers that with 429.
    assert handler.connections == 1
    assert "Warning" not in got.stderr, got.stderr


def test_a_refusal_behind_a_lapsed_certificate_is_still_a_refusal(pki, serve):
    url, handler = serve(pki["lapsed.pem"], pki["leaf.key"])
    handler.status = 404
    got = _read(url, pki)
    assert got.stdout == "__NO_ICY__\n", (got.stdout, got.stderr)


def test_an_empty_title_behind_a_lapsed_certificate_says_nothing(pki, serve):
    url, handler = serve(pki["lapsed.pem"], pki["leaf.key"])
    handler.title = ""
    got = _read(url, pki)
    assert handler.connections == 1, "the request never got past the certificate"
    assert got.stdout == "", (got.stdout, got.stderr)


def test_a_certificate_nobody_issued_is_still_refused(pki, serve):
    url, handler = serve(pki["self.pem"], pki["self.key"])
    got = _read(url, pki)
    assert handler.connections == 0
    assert got.stdout == "", (got.stdout, got.stderr)
    assert "SSLError" in got.stderr, got.stderr


def test_a_host_named_only_in_the_common_name_is_still_refused(pki, serve):
    # The reader refused it before the dates were let go, as requests' own
    # context does; the context the dates are let go in must do the same.
    url, handler = serve(pki["cn.pem"], pki["leaf.key"])
    got = _read(url.replace("127.0.0.1", "localhost"), pki)
    assert handler.connections == 0
    assert got.stdout == "", (got.stdout, got.stderr)
    assert "SSLError" in got.stderr, got.stderr


def test_a_certificate_for_another_host_is_still_refused(pki, serve):
    url, handler = serve(pki["other.pem"], pki["leaf.key"])
    got = _read(url, pki)
    assert handler.connections == 0
    assert got.stdout == "", (got.stdout, got.stderr)
    assert "SSLError" in got.stderr, got.stderr
