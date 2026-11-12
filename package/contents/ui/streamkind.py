# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""What a stream is, read off its first bytes.

    streamkind.py <file holding the address>
    streamkind.py --codec <file holding a stream's first bytes>

The second form is the pause buffer's writer asking about the bytes it has
already fetched: it prints "mp3" or "aac" when they are bare frames of one
of the two, which is what its segments can hold, and nothing otherwise.

The first form opens the stream itself and prints one word: "ogg-flac" (an
Ogg container with FLAC inside), "ogg" (any other Ogg), "flac" (FLAC with
no container around it) or "other". Prints
nothing when the stream gave too little to judge, or nothing in time, or
when what came is a page of text: the word is remembered for the address,
and a sign-in page or an error page sent with 200 is not what a station is.

The directory's codec label and the address's extension both mislead. Measured
on 2026-11-11: every station the directory calls FLAC that was tried sent
plain FLAC, which the player reads off the socket without trouble, and the
Ogg FLAC stations, which freeze 278 ms in, are filed under OGG together with
Vorbis and Opus, which do not freeze. Only the bytes tell them apart.

The address comes in a file because an argv is readable by every user on the
machine for as long as the process lives, and an address can carry a
listener's token. This helper removes the file once it has read it.
"""

import http.client
import os
import signal
import ssl
import sys
import time
import urllib.parse
import urllib.request

# A first Ogg page with its codec header is under 100 bytes; an ID3 tag or an
# error page shows itself in the first four.
HEAD_BYTES = 4096
TOTAL_SECONDS = 3
# OpenSSL's X509_V_FLAG_NO_CHECK_TIME; Python's ssl module has no name for it.
_NO_CHECK_TIME = 0x200000
_USER_AGENT = "VLC/3.0.20 LibVLC/3.0.20"


def kind_of(head) -> str:
    """The kind the first bytes of a stream show.

    Contract: "ogg-flac", "ogg", "flac" or "other"; "" when `head` is not
    bytes, holds fewer than four of them, is an Ogg page cut off before its
    codec header, or opens with markup. Only the first HEAD_BYTES are looked
    at. Never raises.
    """
    if not isinstance(head, (bytes, bytearray)):
        return ""
    data = bytes(head[:HEAD_BYTES])
    if len(data) < 4:
        return ""
    if data[:4] == b"fLaC":
        return "flac"
    if data[:4] != b"OggS":
        # No audio opens with "<" (MP3 and AAC with 0xFF or a tag, Matroska
        # with 0x1A, MP4 with a box length); HTML and XML do, after a byte
        # order mark and blank space at most.
        return (
            "" if data.removeprefix(b"\xef\xbb\xbf").lstrip()[:1] == b"<" else "other"
        )
    # A page header is 27 bytes, the last of them the count of lacing values
    # that follow; the first packet starts right after those.
    if len(data) < 27:
        return ""
    if data[4] != 0:
        return "other"
    packet = data[27 + data[26] :]
    # "\x7fFLAC" is the Ogg FLAC mapping; "fLaC" the one before it, which
    # libFLAC wrote until 1.1.1 and FFmpeg still reads.
    if packet[:5] == b"\x7fFLAC" or packet[:4] == b"fLaC":
        return "ogg-flac"
    # The longest codec mark a first packet opens with is eight bytes
    # ("OpusHead"); with fewer than that there is nothing to rule out.
    return "ogg" if len(packet) >= 8 else ""


def codec_of(head) -> str:
    """Whether the first bytes of a stream are bare MP3 or bare AAC.

    Contract: "mp3" when the bytes hold three MPEG layer III frames in a
    row, "aac" when they hold three ADTS frames in a row, each one starting
    where the one before says it ends; an ID3v2 tag that fits may stand in
    front, and the frames may begin anywhere after it. "" for everything
    else: Ogg, FLAC, a container, markup, fewer than three whole frames, a
    tag longer than the head, and whatever is not bytes. Only the first
    HEAD_BYTES are looked at. Never raises.
    """
    if not isinstance(head, (bytes, bytearray)):
        return ""
    data = bytes(head[:HEAD_BYTES])
    if kind_of(data) != "other":
        return ""
    start = 0
    if data[:3] == b"ID3":
        # Ten bytes of header, the last four the length of what follows,
        # seven bits to a byte.
        if len(data) < 10 or any(b & 0x80 for b in data[6:10]):
            return ""
        start = 10 + ((data[6] << 21) | (data[7] << 14) | (data[8] << 7) | data[9])
    # Both codecs open a frame with eleven set bits. One such pair of bytes
    # proves nothing, since any compressed audio has them by chance, so a
    # frame counts only with two more behind it, each where the last one's
    # own length puts it.
    for at in range(start, len(data) - 1):
        if data[at] != 0xFF or data[at + 1] & 0xE0 != 0xE0:
            continue
        for word, frame in (("mp3", _mp3_frame), ("aac", _adts_frame)):
            first = frame(data, at)
            if first is None:
                continue
            second = frame(data, at + first[0])
            if second is None or second[1] != first[1]:
                continue
            third = frame(data, at + first[0] + second[0])
            if third is not None and third[1] == first[1]:
                return word
    return ""


# Bitrates in kbit/s by the header's four bits, layer III: MPEG-1, then
# MPEG-2 and 2.5. Index 0 is "free", which gives no length to step by.
_MP3_KBPS = (
    (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320),
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
)
_MP3_HZ = {3: (44100, 48000, 32000), 2: (22050, 24000, 16000), 0: (11025, 12000, 8000)}


def _mp3_frame(data: bytes, at: int):
    """(length, (version, rate)) of the layer III frame whose header is at
    `at`; None when there is no whole header there or it is not one."""
    if at + 4 > len(data) or data[at] != 0xFF or data[at + 1] & 0xE0 != 0xE0:
        return None
    version, layer = (data[at + 1] >> 3) & 3, (data[at + 1] >> 1) & 3
    bitrate, rate = data[at + 2] >> 4, (data[at + 2] >> 2) & 3
    if version == 1 or layer != 1 or bitrate in (0, 15) or rate == 3:
        return None
    hz = _MP3_HZ[version][rate]
    kbps = _MP3_KBPS[0 if version == 3 else 1][bitrate]
    # 1152 samples a frame in MPEG-1, 576 in the two lower versions.
    length = (144 if version == 3 else 72) * kbps * 1000 // hz + ((data[at + 2] >> 1) & 1)
    return length, (version, rate)


def _adts_frame(data: bytes, at: int):
    """(length, (profile, rate)) of the ADTS frame whose header is at `at`;
    None when there is no whole header there or it is not one."""
    if at + 7 > len(data) or data[at] != 0xFF or data[at + 1] & 0xF6 != 0xF0:
        return None
    rate = (data[at + 2] >> 2) & 0x0F
    length = ((data[at + 3] & 3) << 11) | (data[at + 4] << 3) | (data[at + 5] >> 5)
    # Thirteen sampling rates are defined, and a frame holds its own header.
    if rate > 12 or length < 7:
        return None
    return length, (data[at + 2] >> 6, rate)


class _WebOnly(urllib.request.HTTPRedirectHandler):
    """A station may send the request on, as it may for the player, but only
    to another web address: urllib would also follow one to ftp."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.lower().startswith(("http://", "https://")):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_stream(url: str, seconds: float) -> http.client.HTTPResponse:
    """The station's answer to a request for `url`, for a helper that reads
    the stream beside the player. `seconds` bounds the connect and each read.

    The certificate is checked as the title reader checks it: authority and
    host, not the dates. Raises OSError or http.client.HTTPException when the
    station cannot be read.
    """
    ctx = ssl.create_default_context()
    ctx.verify_flags |= _NO_CHECK_TIME
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx), _WebOnly()
    )
    # The player spells a saved address for the wire itself: a space becomes
    # %20, a letter outside ASCII its bytes. urllib refuses both as they are
    # (measured: no connection was made for an address with a space), so the
    # same is done here, and an escape that is already there is left alone.
    spelled = urllib.parse.quote(url, safe="%/:=&?~#+!$,;'@()*[]")
    req = urllib.request.Request(spelled, headers={"User-Agent": _USER_AGENT})
    return opener.open(req, timeout=seconds)


def says_text(resp: http.client.HTTPResponse) -> bool:
    """Text is a page, whatever its bytes look like. The header is asked for
    itself: a station that names no type at all, as ICY servers do, would
    read as text/plain through the message's own default."""
    return resp.headers.get("Content-Type", "").strip().lower().startswith("text/")


def read_head(
    url: str, limit: int = HEAD_BYTES, seconds: float = TOTAL_SECONDS
) -> bytes:
    """The first bytes of the stream at `url`, as many as it takes to name
    its kind and at most `limit`.

    Nothing is read of an answer that says it is text. Raises as open_stream
    does.
    """
    end = time.monotonic() + seconds
    buf = b""
    with open_stream(url, seconds) as resp:
        if says_text(resp):
            return b""
        while len(buf) < limit and time.monotonic() < end:
            chunk = resp.read1(limit - len(buf))
            if not chunk:
                break
            buf += chunk
            if kind_of(buf):
                break
    return buf


def codec_main(path: str) -> int:
    """The buffer writer's question about bytes it has already fetched.

    Prints "mp3" or "aac", or nothing. The file stays: the writer hands the
    same bytes on to ffmpeg.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(HEAD_BYTES)
    except OSError:
        return 0
    word = codec_of(head)
    if word:
        print(word)
    return 0


def main(argv) -> int:
    if len(argv) == 3 and argv[1] == "--codec":
        return codec_main(argv[2])
    if len(argv) != 2:
        print(
            "streamkind.py: usage: streamkind.py <file holding the address>"
            " | --codec <file holding a stream's first bytes>",
            file=sys.stderr,
        )
        return 2
    # The socket timeout covers a connect and each read, not a name lookup
    # that never answers; the alarm ends the process whatever it waits on.
    signal.alarm(TOTAL_SECONDS + 1)
    try:
        with open(argv[1], encoding="utf-8") as fh:
            url = fh.read().strip()
    except (OSError, ValueError):
        return 0
    finally:
        try:
            os.unlink(argv[1])
        except OSError:
            # Gone already, or a folder: the answer does not hang on it.
            pass
    # urllib opens file: and ftp: addresses too, and neither is a station.
    if not url.lower().startswith(("http://", "https://")):
        return 0
    try:
        head = read_head(url)
    except (OSError, ValueError, http.client.HTTPException):
        return 0
    word = kind_of(head)
    if word:
        print(word)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
