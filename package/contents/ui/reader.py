# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""ICY metadata reader for Advanced Radio Player.

Prints "<title>\t<stream_url>" when the stream's ICY title differs from the
previous metadata (argv[2]). Prints "__NO_ICY__" when the stream can't or
won't deliver usable metadata, so the plasmoid stops respawning us.
"""
import sys
import time

import requests

if len(sys.argv) < 3:
    print("reader.py: usage: reader.py <stream_url> <previous_metadata>", file=sys.stderr)
    sys.exit(2)

script, url, meta = sys.argv[0], sys.argv[1], sys.argv[2]

# Kõva kogukestuse piir — requests'i timeout katab ainult connect'i ja
# chunk'ide-vahelise pausi, mitte kogu allalaadimist. Ilma selleta võib
# protsess rippuda ja striimi igavesti alla laadida.
MAX_SECONDS = 20
MAX_META_BLOCKS = 10


def decode_meta(raw: bytes) -> str:
    """UTF-8 esimesena, Latin-1 varuvariandina (Latin-1 ei saa ebaõnnestuda)."""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def extract_field(raw_meta: bytes, key: bytes) -> str:
    """Loe ICY väli kujul key='value'; — otsi lõppu "';" järgi, et semikoolon
    VÄÄRTUSE SEES (nt "AC/DC; Live") pealkirja ei kärbiks."""
    if key not in raw_meta:
        return ""
    start = raw_meta.index(key) + len(key)
    end = raw_meta.find(b"';", start)
    if end == -1:
        end = raw_meta.find(b";", start)
    if end == -1:
        end = len(raw_meta)
    return decode_meta(raw_meta[start:end]).strip("'").strip()


def main():
    headers = {
        'Icy-MetaData': '1',
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
    }
    started = time.monotonic()

    try:
        response = requests.get(url, headers=headers, stream=True, timeout=10)

        if response.status_code != 200:
            print(f"reader.py: HTTP {response.status_code} for {url}", file=sys.stderr)
            # Sentinel ka veateel — muidu respawnib plasmoid meid iga 2 s igavesti.
            print("__NO_ICY__")
            return

        icy_metaint = int(response.headers.get('icy-metaint', 0))
        if icy_metaint == 0:
            # Sentinel: tells the plasmoid to stop polling this stream for
            # metadata — it does not expose ICY.
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

                    # TAB-separaator: '::' esines päris-pealkirjades ja lõhkus
                    # QML-i splitti. TAB-i striimi tiitlis esineda ei saa
                    # (asendame igaks juhuks tühikuga).
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
    except requests.exceptions.RequestException as exc:
        print(f"reader.py: {type(exc).__name__}: {exc}", file=sys.stderr)
        # Ühendus ebaõnnestus (UA-filter, TLS-viga, timeout) — ära lase
        # plasmoidil igavesti uuesti proovida.
        print("__NO_ICY__")
    except Exception as exc:
        print(f"reader.py: unexpected {type(exc).__name__}: {exc}", file=sys.stderr)
        print("__NO_ICY__")


main()
