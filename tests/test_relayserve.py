# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The relay tap's contract, exercised for real — subprocess, socket, file.

No network: the "station" is a temp file written at a controlled pace,
which is all the tap ever sees anyway. The head-start behaviour these
tests pin was measured against a live 1 Mbps FLAC station first (a
modelled player starved once without the lead, never with it); the
bounds here are loose enough for a busy CI runner and tight enough that
losing the lead, or the release-at-enough-bytes gate, fails loudly.
"""

import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
TAP = ROOT / "package" / "contents" / "ui" / "relayserve.py"

_SRC = TAP.read_text(encoding="utf-8")
LEAD_BYTES = int(re.search(r"^LEAD_BYTES = (\d+) \* 1024", _SRC, re.MULTILINE).group(1)) * 1024
LEAD_SEC = float(re.search(r"^LEAD_SEC = ([\d.]+)", _SRC, re.MULTILINE).group(1))


class Tap:
    """One tap run: process, port, connected socket, past the headers."""

    def __init__(self, tmp: Path):
        self.buf = tmp / "buffer.ogg"
        self.port_file = tmp / "serve.port"
        self.proc = subprocess.Popen(
            [sys.executable, str(TAP), str(self.buf), str(self.port_file)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if self.port_file.exists() and self.port_file.stat().st_size > 0:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("the tap never wrote its port file")
        self.sock = socket.create_connection(
            ("127.0.0.1", int(self.port_file.read_text())), timeout=10)
        self.sock.sendall(b"GET / HTTP/1.0\r\n\r\n")

    def first_body_byte_after(self, timeout: float) -> float:
        """Seconds from now until a byte PAST the headers arrives."""
        self.sock.settimeout(timeout)
        t0 = time.monotonic()
        got = b""
        while True:
            got += self.sock.recv(65536)
            head_end = got.find(b"\r\n\r\n")
            if head_end >= 0 and len(got) > head_end + 4:
                return time.monotonic() - t0

    def close(self):
        try:
            self.sock.close()
        finally:
            self.proc.terminate()
            self.proc.wait(timeout=5)


def test_a_buffer_already_holding_the_lead_streams_at_once(tmp_path):
    tmp_path.joinpath("buffer.ogg").write_bytes(b"x" * (LEAD_BYTES + 4096))
    tap = Tap(tmp_path)
    try:
        waited = tap.first_body_byte_after(5.0)
        # The byte gate must release without waiting out the clock —
        # this is the road every real station takes, because Icecast's
        # own connect burst usually covers the lead in under a second.
        assert waited < LEAD_SEC, (
            f"a buffer already past LEAD_BYTES still sat out the clock "
            f"({waited:.2f}s) — the early-release half of the gate is gone")
    finally:
        tap.close()


def test_a_thin_stream_pays_the_clock_and_no_more(tmp_path):
    buf = tmp_path.joinpath("buffer.ogg")
    buf.write_bytes(b"")
    tap = Tap(tmp_path)
    try:
        # A slow writer: never reaches LEAD_BYTES inside the clock, the
        # way a 128 kbps stream never would.
        t0 = time.monotonic()
        deadline = t0 + LEAD_SEC + 3.0
        first = None

        def feed():
            with open(buf, "ab") as f:
                f.write(b"y" * 8192)
                f.flush()

        tap.sock.settimeout(0.1)
        got = b""
        while time.monotonic() < deadline and first is None:
            feed()
            try:
                got += tap.sock.recv(65536)
            except TimeoutError:
                pass
            head_end = got.find(b"\r\n\r\n")
            if head_end >= 0 and len(got) > head_end + 4:
                first = time.monotonic() - t0
        assert first is not None, "no body byte ever arrived"
        # The whole point of the cap: a stream that cannot fill the byte
        # target must not be held longer than the clock. Floor is loose —
        # the process was already mid-wait when we started timing.
        assert first <= LEAD_SEC + 1.5, (
            f"a thin stream waited {first:.2f}s — the clock cap is not honoured")
    finally:
        tap.close()


def test_the_vanished_buffer_ends_the_tap(tmp_path):
    tmp_path.joinpath("buffer.ogg").write_bytes(b"x" * (LEAD_BYTES + 4096))
    tap = Tap(tmp_path)
    try:
        tap.first_body_byte_after(5.0)
        os.unlink(tap.buf)
        # The stop road only reaps by deleting the buffer — the tap has
        # to notice on its own and leave, or every torn-down arm would
        # strand a process until its 15-minute idle cap.
        try:
            tap.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pytest.fail("the tap outlived its deleted buffer")
    finally:
        tap.close()
