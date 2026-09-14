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


def test_a_newer_block_without_an_artist_does_not_borrow_the_old_one(tmp_path):
    """Chain start two carries a title only: the previous track's artist must
    not be glued to it. The artist has to come from the same block."""
    blob = (b"OggS" + b"\x00" * 20
            + _field(b"ARTIST=Smilers")
            + _field(b"TITLE=Jalgpall On Parem Kui Seks")
            + b"\xf1audio" * 40
            + b"OggS" + b"\x00" * 20
            + _field(b"TITLE=Uudised")
            + b"\xf1audio" * 40)
    assert _read(tmp_path, blob).startswith("Uudised\t")


def test_a_block_that_spells_title_before_artist_keeps_them_apart(tmp_path):
    """The boundary is the chain's identification header, not a neighbouring
    title.

    Anchoring the artist search on the previous TITLE only separated blocks
    that spell ARTIST first. Spell TITLE first and the old artist sits between
    the two titles, inside the window — so a newer title-only block borrowed
    it anyway, which is the exact pairing this road exists to prevent.
    """
    blob = (b"OggS" + b"\x00" * 20 + b"\x03vorbis"
            + _field(b"TITLE=Vana Lugu")
            + _field(b"ARTIST=Smilers")
            + b"\xf1audio" * 40
            + b"OggS" + b"\x00" * 20 + b"\x03vorbis"
            + _field(b"TITLE=Uudised")
            + b"\xf1audio" * 40)
    assert _read(tmp_path, blob).startswith("Uudised\t")


def test_a_later_artist_without_a_title_cannot_reach_back(tmp_path):
    """The window is bounded at both ends.

    A chain start that carries an artist and no title leaves the newest TITLE
    behind it — and an unbounded search took that artist for the older track.
    """
    blob = (b"OggS" + b"\x00" * 20 + b"OpusTags"
            + _field(b"ARTIST=Smilers")
            + _field(b"TITLE=Jalgpall On Parem Kui Seks")
            + b"\xf1audio" * 40
            + b"OggS" + b"\x00" * 20 + b"OpusTags"
            + _field(b"ARTIST=Terminaator")
            + b"\xf1audio" * 40)
    assert _read(tmp_path, blob).startswith(
        "Smilers - Jalgpall On Parem Kui Seks\t")
