# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""ICY metadata reader for Advanced Radio Player.

Prints "<title>\t<stream_url>" when the stream's ICY title differs from the
previous metadata (argv[2]). Prints "__NO_ICY__" when the stream can't or
won't deliver usable metadata, so the plasmoid stops respawning us.
"""
import os
import signal
import ssl
import sys
import time
import urllib.parse

# An Ogg chain restart writes one of these identification headers before its
# fresh comment block, so they — not a neighbouring title — are where one
# track's fields end and the next track's begin.
_OGG_BLOCK_MARKS = (b"\x03vorbis", b"OpusTags", b"OpusHead", b"\x01vorbis", b"\x7fFLAC")


def _ogg_buffer_title(path: str) -> str:
    """Current track of a relayed Ogg station, read from its buffer file.

    Ogg-family streams carry no ICY interleave at all — the track name
    lives in vorbis-comment fields (the same layout for FLAC, Vorbis and
    Opus), and a reconnecting upstream writes a fresh comment block into
    the buffer at every chain start. The LAST block is the current track.
    The relay already has the bytes on disk, so this opens no second
    connection anywhere; the player itself surfaces none of it (measured:
    three minutes of a tagged stream, Qt's metaData stayed empty).
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, size - 4 * 1024 * 1024))
            blob = fh.read()
    except OSError:
        return ""

    # A field name counts whatever its case, by the format's own rule, and
    # encoders do differ. The search runs on a lowered copy: lowering moves
    # no byte, so a place found in one is the same place in the other.
    low = blob.lower()

    def last_field(key: bytes, not_before: int = 0, not_after: int = -1) -> tuple[int, str]:
        """The last whole field of that name inside the window.

        Where its name starts and what it says; (-1, "") when there is none.
        """
        end = len(low) if not_after < 0 else not_after
        while True:
            pos = low.rfind(key, 0, end)
            if pos < 4 or pos < not_before:
                return -1, ""
            # Each field rides as <u32le length><KEY=value>. A match whose
            # length disagrees is stream data that happened to spell the key,
            # the tail of a longer name (ALBUMARTIST= ends in ARTIST=), or a
            # field the relay has not finished writing. Giving up there lost
            # the artist of every block that names the album's artist after
            # the track's, so the search goes on with what stands before it.
            ln = int.from_bytes(blob[pos - 4:pos], "little")
            if len(key) + 1 <= ln <= 1000 and pos + ln <= len(blob):
                try:
                    return pos, blob[pos + len(key):pos + ln].decode("utf-8").strip()
                except UnicodeDecodeError:
                    pass
            end = pos + len(key) - 1

    tpos, title = last_field(b"title=")
    # The artist has to come from the SAME comment block as the title: a
    # newer block carrying a title and no artist used to be paired with the
    # previous track's artist. The block is the one around the title that was
    # taken, not around the last place the word stood: with those two apart
    # the old song was printed under the new artist.
    #
    # A block's real boundary is the identification header an Ogg chain
    # restart writes before its comments, not a neighbouring title. Anchoring
    # on the previous TITLE only held for blocks that spell ARTIST before
    # TITLE; in the other order the old artist sat between the two titles and
    # was taken for the new one. The window is bounded at BOTH ends, so a
    # later block carrying an artist and no title cannot reach back either.
    floor, ceil = 0, len(blob)
    if tpos >= 0:
        for mark in _OGG_BLOCK_MARKS:
            before = blob.rfind(mark, 0, tpos)
            if before > floor:
                floor = before
            after = blob.find(mark, tpos)
            if after != -1 and after < ceil:
                ceil = after
        if floor == 0:
            # No header inside the window — the 4 MB tail cut it off. Fall
            # back to the previous title, which still separates blocks when
            # ARTIST leads and is no worse than what it replaced.
            prev = low.rfind(b"title=", 0, tpos)
            floor = prev + 1 if prev >= 0 else 0
    artist = last_field(b"artist=", floor, ceil)[1]
    if title and artist:
        return f"{artist} - {title}"
    return title


if len(sys.argv) >= 3 and sys.argv[1] == "--oggbuf":
    text = _ogg_buffer_title(sys.argv[2])
    if text:
        # Same shape the ICY road prints: title, TAB, (empty) stream url.
        print(f"{text}\t")
    sys.exit(0)

try:
    import requests
    import requests.adapters
    import urllib3
except ImportError:
    # python-requests is a third-party package a Store plasmoid can't declare.
    # The sentinel pins this source after ONE spawn instead of six crashing
    # respawns per playback start.
    print("reader.py: python-requests not installed — track titles disabled", file=sys.stderr)
    print("__NO_ICY__")
    sys.exit(0)

# OpenSSL's X509_V_FLAG_NO_CHECK_TIME; Python's ssl module has no name for it.
_NO_CHECK_TIME = 0x200000


def _session():
    """A session that checks a station's certificate as usual except for its
    dates: the authority and the host still have to be right.

    The player opens the stream without checking the certificate at all
    (Qt's FFmpeg backend does not), so a station whose edge let it run out
    keeps playing, and the title reader alone refused it. euddn's le0X edges
    have been like that since 2026-10-23: measured on 2026-11-02, each failed
    with OpenSSL's code 10, "certificate has expired", on a *.euddn.net
    certificate a trusted authority issued, and Raadio Elmar, Kuku and Duo
    lost their titles and covers.
    """
    # urllib3 1.26 hands no server name to the context for an address that is
    # an IP, and a context that checks host names then refuses every such
    # station with a ValueError (measured with urllib3 1.26.20 on
    # 2026-11-03). There the reader keeps requests' own checks, dates
    # included, as it did before.
    if int(str(getattr(urllib3, "__version__", "2")).split(".")[0] or "2") < 2:
        return requests.Session()
    ctx = ssl.create_default_context()
    ctx.verify_flags |= _NO_CHECK_TIME
    # Python's default context still lets the subject's CN name the host when
    # a certificate has no subjectAltName; requests' own does not, and this
    # one stands in for it.
    ctx.hostname_checks_common_name = False

    class _Adapter(requests.adapters.HTTPAdapter):
        def init_poolmanager(self, *args, **kwargs):
            kwargs["ssl_context"] = ctx
            return super().init_poolmanager(*args, **kwargs)

    s = requests.Session()
    s.mount("https://", _Adapter())
    return s


def resolve_url(arg):
    """The URL comes as a 0600 FILE in the runtime dir, not inline.

    On argv the URL sits world-readable in /proc/<pid>/cmdline for this
    process's whole 10-20 s life, every poll — leaking any per-listener token
    the path/query carries (the same /proc reason the previous metadata was
    already dropped from argv). The plasmoid writes the URL to an owner-only
    file and passes its PATH instead.

    A bare http(s) URL is accepted as-is so a direct call or a test needs no
    file. Anything else is the runtime file path: a MISSING or unreadable file
    yields "" (the caller then exits quietly and the plasmoid retries next
    tick) — never the path itself, which would reach requests.get() as a bogus
    URL and pin the station __NO_ICY__ for the whole session.
    """
    if arg.startswith(("http://", "https://")):
        return arg
    try:
        with open(arg, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


if len(sys.argv) < 3:
    print("reader.py: usage: reader.py <url-or-file> <previous_metadata>", file=sys.stderr)
    sys.exit(2)

script, meta = sys.argv[0], sys.argv[2]
url = resolve_url(sys.argv[1])
if not url:
    # No readable URL (missing/blank file, or an unreadable path) — nothing to
    # poll. Exit quietly so the plasmoid simply retries next tick.
    sys.exit(0)

# Errors log the hostname only: full stream URLs can carry listener tokens in
# path/query, and stderr ends up in the journal.
try:
    log_host = urllib.parse.urlsplit(url).hostname or "<no-host>"
except ValueError:
    log_host = "<unparseable-url>"

# Hard total-duration cap — the requests timeout only covers the connect and
# the pause between chunks, not the whole download. Without this the process
# could hang and keep downloading the stream forever.
MAX_SECONDS = 20
MAX_META_BLOCKS = 10


def decode_meta(raw: bytes) -> str:
    """UTF-8 first, then Windows-1252, then Latin-1, which can never fail.

    The two single-byte tables differ only from 0x80 to 0x9f, where Latin-1
    has control characters and Windows-1252 has the en dash (0x96), the curly
    quotes (0x91 to 0x94) and the euro sign. Read as Latin-1, a line with
    that dash between artist and title did not split into the two.
    Windows-1252 has no character at 0x81, 0x8d, 0x8f, 0x90 and 0x9d, so a
    title with one of those still goes to Latin-1 whole.
    """
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        try:
            return raw.decode("cp1252")
        except UnicodeDecodeError:
            return raw.decode("latin-1")


def extract_field(raw_meta: bytes, key: bytes) -> str:
    """Read an ICY field of the form key='value'; — find the end via "';" so that
    a semicolon INSIDE THE VALUE (e.g. "AC/DC; Live") does not truncate the title."""
    if key not in raw_meta:
        return ""
    start = raw_meta.index(key) + len(key)
    end = raw_meta.find(b"';", start)
    if end == -1:
        end = raw_meta.find(b";", start)
    if end == -1:
        end = len(raw_meta)
    val = decode_meta(raw_meta[start:end])
    # Remove exactly ONE delimiter quote per side — a greedy .strip("'")
    # destroys apostrophes that belong to the title ("'39", "Rockin'").
    if val.startswith("'"):
        val = val[1:]
        # The "';" terminator already excludes the closing quote from the
        # slice; only the end-of-buffer fallback can still contain it.
        if end == len(raw_meta) and val.endswith("'"):
            val = val[:-1]
    return val.strip()


def main():
    headers = {
        'Icy-MetaData': '1',
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
    }
    started = time.monotonic()

    # True OS-level cap: the soft MAX_SECONDS check below only runs between
    # iter_content chunks, and a slow-drip stream (each recv gap < the 10 s
    # socket timeout, rate far below the 4096 B chunk) never yields a chunk —
    # SIGALRM's default action kills the process regardless. No output means
    # an empty result to the plasmoid, which is the correct outcome here.
    signal.alarm(MAX_SECONDS + 10)

    try:
        # One connection, not a check and a retry: connection-capped Icecast
        # answers a second one with 429.
        response = _session().get(url, headers=headers, stream=True, timeout=10)

        if response.status_code != 200:
            print(f"reader.py: HTTP {response.status_code} for {log_host}", file=sys.stderr)
            # Sentinel only on DEFINITIVE failures (4xx: UA filter, 404...) —
            # a transient server error (5xx) must not pin __NO_ICY__ for the
            # whole listening session; exiting silently lets the poll retry.
            # 429/408 are transient BY DEFINITION: connection-capped Icecast
            # answers 429 to the metadata poll's second connection, and one
            # 403 rides with them since 2026-08-11: a WAF that tolerated the
            # first polls starts refusing the REPEAT visitor mid-session,
            # and a refusal born from polling too visibly must not become
            # a permanent verdict that the station carries no titles.
            # busy moment must not erase titles for the whole session.
            if 400 <= response.status_code < 500 \
                    and response.status_code not in (403, 408, 429):
                print("__NO_ICY__")
            return

        icy_metaint = int(response.headers.get('icy-metaint', 0))
        if not (0 < icy_metaint <= 1_000_000):
            # Sentinel: no ICY (0/absent), or a nonsensical metaint — negative
            # would index the buffer from the end and parse audio bytes as
            # metadata; a huge one would buffer the stream into RAM.
            print("__NO_ICY__")
            return

        audio_buf = b''
        max_bytes = icy_metaint * 4
        meta_blocks_seen = 0

        try:
            for chunk in response.iter_content(chunk_size=4096):
                if time.monotonic() - started > MAX_SECONDS:
                    return
                audio_buf += chunk

                if len(audio_buf) < icy_metaint + 1:
                    continue

                meta_length = audio_buf[icy_metaint] * 16
                needed = icy_metaint + 1 + meta_length
                if len(audio_buf) < needed:
                    if len(audio_buf) > max_bytes:
                        return
                    continue

                if meta_length == 0:
                    audio_buf = audio_buf[needed:]
                    meta_blocks_seen += 1
                    if meta_blocks_seen >= MAX_META_BLOCKS:
                        return
                    continue

                raw_meta = audio_buf[icy_metaint + 1:needed]
                raw_meta = raw_meta.rstrip(b'\x00')

                if b'StreamTitle=' in raw_meta:
                    stream_title = extract_field(raw_meta, b'StreamTitle=')
                    stream_url = extract_field(raw_meta, b'StreamUrl=')

                    cleaned_title = stream_title.strip()
                    placeholders = {"", "-", "--", "unknown", "n/a", "none", "null"}
                    if cleaned_title.lower() in placeholders:
                        return

                    # TAB separator: '::' appeared in real titles and broke the
                    # QML split. A TAB cannot occur in a stream title
                    # (we replace it with a space just in case).
                    # Tabs are the field separator and NEWLINES are the
                    # record separator of the line protocol — a station
                    # whose ICY title carries either would split the line
                    # and feed the parser a stray half-record.
                    safe_title = cleaned_title.replace("\t", " ") \
                                              .replace("\n", " ").replace("\r", " ")
                    safe_url = stream_url.replace("\t", " ") \
                                         .replace("\n", " ").replace("\r", " ")
                    stream_metadata = safe_title + "\t" + safe_url
                    if stream_metadata != meta:
                        print(stream_metadata)
                    return

                audio_buf = audio_buf[needed:]
                meta_blocks_seen += 1
                if len(audio_buf) > max_bytes or meta_blocks_seen >= MAX_META_BLOCKS:
                    return

        except KeyboardInterrupt:
            pass
    except (requests.exceptions.Timeout, requests.exceptions.ConnectionError,
            requests.exceptions.ChunkedEncodingError,
            requests.exceptions.ContentDecodingError) as exc:
        # TRANSIENT network failure — exit silently (no sentinel) so the
        # plasmoid's poll can retry once the network/server recovers. The
        # 6-empty-results counter on the QML side still bounds endless polling.
        # A connection cut inside the body belongs here as well. requests
        # raises ChunkedEncodingError for it (measured: a reset after 3000
        # bytes, a chunk cut short, a body shorter than its Content-Length)
        # and that is not a ConnectionError, so one dropped poll used to
        # reach the verdict below and the station lost its titles until it
        # was started again by hand.
        # requests embeds the full URL in the exception text — type+host only.
        print(f"reader.py: transient {type(exc).__name__} for {log_host}", file=sys.stderr)
    except requests.exceptions.RequestException as exc:
        print(f"reader.py: {type(exc).__name__} for {log_host}", file=sys.stderr)
        # A DEFINITIVE failure (invalid URL, TLS error, redirect loop) — don't
        # let the plasmoid retry forever.
        print("__NO_ICY__")
    except Exception as exc:
        print(f"reader.py: unexpected {type(exc).__name__}: {exc}", file=sys.stderr)
        print("__NO_ICY__")


main()
