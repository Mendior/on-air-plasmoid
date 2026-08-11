# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The relayed-Ogg title road, proven against real comment layout.

FLAC/Vorbis/Opus streams carry no ICY interleave: the current track lives
in vorbis-comment fields inside the relay's buffer file, and a
reconnecting upstream writes a fresh block at every chain start. These
pin the three behaviours that matter to a listener: a well-formed block
is read, a NEWER block wins (the title updates on track change - the
exact complaint class of issue #10, which this road is immune to), and a
length field that lies is silence, never garbage.
"""
import struct
import subprocess
import sys
from pathlib import Path

READER = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui" / "reader.py"


def _field(kv: bytes) -> bytes:
    return struct.pack("<I", len(kv)) + kv


def _read(tmp_path, blob: bytes) -> str:
    buf = tmp_path / "relay.buf"
    buf.write_bytes(blob)
    out = subprocess.run([sys.executable, str(READER), "--oggbuf", str(buf)],
                         capture_output=True, text=True, timeout=10)
    assert out.returncode == 0
    return out.stdout


def test_a_tagged_buffer_yields_artist_dash_title(tmp_path):
    blob = (b"OggS" + b"\x00" * 20
            + _field(b"ARTIST=Smilers")
            + _field(b"TITLE=Jalgpall On Parem Kui Seks")
            + b"\xf1audio" * 40)
    assert _read(tmp_path, blob).startswith(
        "Smilers - Jalgpall On Parem Kui Seks\t")


def test_the_newest_comment_block_wins(tmp_path):
    blob = (b"OggS" + b"\x00" * 20
            + _field(b"ARTIST=Smilers") + _field(b"TITLE=Vana Lugu")
            + b"\xf1audio" * 40
            + b"OggS" + b"\x00" * 12
            + _field(b"ARTIST=Terminaator") + _field(b"TITLE=Juulikuu lumi")
            + b"\xf2audio" * 30)
    assert _read(tmp_path, blob).startswith("Terminaator - Juulikuu lumi\t")


def test_a_lying_length_field_is_silence_not_garbage(tmp_path):
    blob = b"\xff\xff\xff\xffTITLE=Peibutis" + b"\x00" * 20
    assert _read(tmp_path, blob) == ""
