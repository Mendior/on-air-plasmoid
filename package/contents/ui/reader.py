# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""ICY metadata reader for Advanced Radio Player.

Prints "<title>\t<stream_url>" when the stream's ICY title differs from the
previous metadata (argv[2]). Prints "__NO_ICY__" when the stream can't or
won't deliver usable metadata, so the plasmoid stops respawning us.
"""
import signal
import sys
import time

try:
    import requests
except ImportError:
    # python-requests is a third-party package a Store plasmoid can't declare.
    # The sentinel pins this source after ONE spawn instead of six crashing
    # respawns per playback start.
    print("reader.py: python-requests not installed — track titles disabled", file=sys.stderr)
    print("__NO_ICY__")
    sys.exit(0)

if len(sys.argv) < 3:
    print("reader.py: usage: reader.py <stream_url> <previous_metadata>", file=sys.stderr)
    sys.exit(2)

script, url, meta = sys.argv[0], sys.argv[1], sys.argv[2]

# Hard total-duration cap — the requests timeout only covers the connect and
# the pause between chunks, not the whole download. Without this the process
# could hang and keep downloading the stream forever.
MAX_SECONDS = 20
MAX_META_BLOCKS = 10


def decode_meta(raw: bytes) -> str:
    """UTF-8 first, Latin-1 as a fallback (Latin-1 can never fail)."""
    try:
        return raw.decode("utf-8")
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
        response = requests.get(url, headers=headers, stream=True, timeout=10)

        if response.status_code != 200:
            print(f"reader.py: HTTP {response.status_code} for {url}", file=sys.stderr)
            # Sentinel only on DEFINITIVE failures (4xx: UA filter, 404...) —
            # a transient server error (5xx) must not pin __NO_ICY__ for the
            # whole listening session; exiting silently lets the poll retry.
            # 429/408 are transient BY DEFINITION: connection-capped Icecast
            # answers 429 to the metadata poll's second connection, and one
            # busy moment must not erase titles for the whole session.
            if 400 <= response.status_code < 500 \
                    and response.status_code not in (408, 429):
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
                    safe_title = cleaned_title.replace("\t", " ")
                    safe_url = stream_url.replace("\t", " ")
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
    except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as exc:
        # TRANSIENT network failure — exit silently (no sentinel) so the
        # plasmoid's poll can retry once the network/server recovers. The
        # 6-empty-results counter on the QML side still bounds endless polling.
        print(f"reader.py: transient {type(exc).__name__}: {exc}", file=sys.stderr)
    except requests.exceptions.RequestException as exc:
        print(f"reader.py: {type(exc).__name__}: {exc}", file=sys.stderr)
        # A DEFINITIVE failure (invalid URL, TLS error, redirect loop) — don't
        # let the plasmoid retry forever.
        print("__NO_ICY__")
    except Exception as exc:
        print(f"reader.py: unexpected {type(exc).__name__}: {exc}", file=sys.stderr)
        print("__NO_ICY__")


main()
