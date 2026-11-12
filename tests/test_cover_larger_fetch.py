# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Showing the cover larger must not fetch the picture a second time.

The larger view is a second Image with the cover's address. Qt hands two
Images the same pixmap when they ask for the same address in the same size
and with the same fitting mode, and fetches again when any of them differs,
so the promise hangs on CoverTouch.qml asking the way FullRepresentation.qml
does: two numbers, and no fitting mode on either. Here it is measured
instead of believed: a server on the loopback counts what is asked of it
while the real component shows a picture larger. The second run asks for
another size on purpose, to see that the count can go up at all.

The picture served is 400 pixels a side. Read without a fitting mode it
keeps that size, which is what lets the larger view stop at twice a
picture's own pixels; the same run checks that it did.
"""

import http.server
import os
import shutil
import struct
import subprocess
import threading
import zlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "package" / "contents" / "ui"
RUNNER = os.environ.get("QMLTESTRUNNER", "/usr/lib/qt6/bin/qmltestrunner")


def _png(side=400, rgb=(59, 238, 150)):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    row = b"\x00" + bytes(rgb) * side
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * side)) + chunk(b"IEND", b""))


HARNESS = """import QtQuick
import QtTest
import "%(ui)s"

FocusScope {
    id: root
    width: 420
    height: 420
    focus: true
    property color accent: "#3BEE96"
    property color accentTextOn: "#000000"
    function i18n(s) { return s; }
    function i18nc(context, s) { return s; }

    Item {
        x: 110; y: 110; width: 200; height: 200
        // The page's own cover, as FullRepresentation.qml declares it.
        CoverImage {
            id: cover
            anchors.fill: parent
            anchors.margins: 1
            source: "%(url)s"
        }
        CoverTouch {
            id: touch
            anchors.fill: parent
            face: root
            art: cover.status === Image.Ready ? cover.source : ""
            natural: cover.natural
            open: function(address) {}
        }
    }
    Image { id: other; sourceSize.width: 300; sourceSize.height: 300; asynchronous: true }

    TestCase {
        name: "CoverLargerFetch"
        when: windowShown
        function test_the_cover_is_shown_larger() {
            tryCompare(cover, "status", Image.Ready, 10000);
            // Its own 400 pixels, drawn to cover the frame of 200.
            compare(cover.natural.width, 400);
            fuzzyCompare(cover._image.width, 198, 0.01);
            mouseClick(touch, 100, 100);
            verify(touch.larger);
            tryCompare(touch._largerImage, "status", Image.Ready, 10000);
            compare(touch._largerImage.natural.width, 400);
            verify(touch._largerImage._image.paintedWidth > 200);
            if (%(other)s) {
                other.source = cover.source;
                tryCompare(other, "status", Image.Ready, 10000);
            }
            wait(300);
        }
    }
}
"""


class _Server(http.server.ThreadingHTTPServer):
    """Keeps the path of every request it was sent."""

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _Counting)
        self.asked: list[str] = []


DRAWING = (b'<svg xmlns="http://www.w3.org/2000/svg" width="200" height="80" viewBox="0 0 200 80">'
           b'<rect width="200" height="80" fill="#223344"/></svg>')


class _Counting(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert isinstance(self.server, _Server)
        self.server.asked.append(self.path)
        drawing = self.path.startswith("/logo")
        body = DRAWING if drawing else _png()
        self.send_response(200)
        self.send_header("Content-Type", "image/svg+xml" if drawing else "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


DRAWN = """import QtQuick
import QtTest
import "%(ui)s"

Item {
    width: 300
    height: 300
    CoverImage { id: page; width: 200; height: 200; source: "%(url)s" }
    TestCase {
        name: "CoverDrawingFetch"
        when: windowShown
        function test_a_drawing_from_the_network_keeps_its_shape() {
            tryCompare(page, "status", Image.Ready, 10000);
            fuzzyCompare(page._image.width / page._image.height, 2.5, 0.1);
            fuzzyCompare(Math.min(page._image.width, page._image.height), 200, 0.5);
            verify(page.natural.width <= 620 && page.natural.height <= 620,
                   "read at " + page.natural.width + " by " + page.natural.height);
            if (%(other)s) compare(Math.max(page.natural.width, page.natural.height), 600);
            wait(300);
        }
    }
}
"""


def _fetches(tmp_path, other_size, path="/cover.png", harness=HARNESS):
    server = _Server()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        test = tmp_path / ("tst_fetch_%s_%s.qml" % (path.strip("/").replace(".", "_"), other_size))
        test.write_text(harness % {
            "ui": UI.as_uri(),
            "url": "http://127.0.0.1:%d%s" % (server.server_address[1], path),
            "other": "true" if other_size else "false",
        }, encoding="utf-8")
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
        done = subprocess.run([RUNNER, "-input", str(test)], capture_output=True, text=True, timeout=120, env=env)
        assert done.returncode == 0, (done.stdout + done.stderr)[-3000:]
        return list(server.asked)
    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.skipif(shutil.which(RUNNER) is None, reason="qmltestrunner is not installed here; the gate on a Qt machine runs this")
def test_the_larger_cover_is_the_picture_the_page_already_holds(tmp_path):
    assert _fetches(tmp_path, other_size=False) == ["/cover.png"], (
        "showing the cover larger fetched the picture again")
    assert _fetches(tmp_path, other_size=True) == ["/cover.png", "/cover.png"], (
        "an Image of another size did not fetch either, so the count above proves nothing")


@pytest.mark.skipif(shutil.which(RUNNER) is None, reason="qmltestrunner is not installed here; the gate on a Qt machine runs this")
def test_a_drawing_from_the_network_is_asked_for_its_shape_once(tmp_path):
    """A station's logo that is an SVG is on the network until the logo cache
    has it. Named ".svg", Qt fills the whole source size with it, 600 by 600
    whatever its shape, and a logo of 200 by 80 was drawn squeezed. Its shape
    is read off a copy of 16 pixels first: one more request for that one
    file, and then it is rendered in its shape inside the source size.

    Without the extension nothing says it is a drawing. It is read like any
    picture, at the 200 by 80 it declares, in its shape, with one request.
    """
    assert _fetches(tmp_path, True, "/logo.svg", DRAWN) == ["/logo.svg", "/logo.svg"], (
        "a drawing named so is no longer asked for its shape, or is asked more than once")
    assert _fetches(tmp_path, False, "/logo", DRAWN) == ["/logo"], (
        "a picture that is not named a drawing is fetched more than once")
