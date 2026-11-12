# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""How loud a station is, heard beside the player.

    loudness.py <file holding the address> [seconds]

Prints one number: the integrated loudness (EBU R 128, in LUFS, one decimal)
of the first `seconds` of the stream, twenty when none are given. Prints
nothing when the station sent less than that, sent a page of text or an
error, when ffmpeg is not installed, or when the time ran out.

The address comes in a file because an argv is readable by every user on the
machine for as long as the process lives, and an address can carry a
listener's token. For the same reason ffmpeg is not handed the address: this
helper opens the stream itself and feeds ffmpeg through a pipe.

The file is emptied as soon as it has been read, and from then on it is the
leash: the helper stops within a quarter of a second of the file being
removed, which is how the widget ends a reading nobody waits for. The helper
removes it when it is done.
"""

import http.client
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

import streamkind

LISTEN_SECONDS = 20
# Wall clock allowed on top of the seconds listened to. A station sends a
# burst first, so twenty seconds of stream arrive in less than twenty; what
# is left over is for the connect and for ffmpeg to start and finish.
# LoudLogic.js names the sum for the shell's own limit above this one.
SLACK_SECONDS = 20
# How often the leash and the clock are looked at.
TICK_SECONDS = 0.25
# One read of the socket. The clock above ends a station that stalls; this
# only keeps a read from outliving it.
READ_SECONDS = 10
# ffmpeg cuts at the second asked for, give or take one frame of the codec.
SHORT_BY = 0.5

_SUMMARY = re.compile(r"Summary:\s+Integrated loudness:\s+I:\s+(-?\d+(?:\.\d+)?) LUFS")
_OUT_TIME = re.compile(r"^out_time=(\d+):(\d\d):(\d\d(?:\.\d+)?)\s*$", re.MULTILINE)


class _Over(Exception):
    """The leash is gone, the time is out, or the helper was told to end."""


def loudness_of(log) -> str:
    """The integrated loudness in ffmpeg's ebur128 summary.

    Contract: the number after "I:" in the summary, as text with one decimal;
    "" when `log` is no text, holds no summary, or the summary holds no
    number there. A frame's own line, which also has an "I:", is not a
    summary. Never raises.
    """
    if not isinstance(log, str):
        return ""
    found = _SUMMARY.search(log)
    return "%.1f" % float(found.group(1)) if found else ""


def heard(log) -> float:
    """How many seconds of sound ffmpeg decoded, by its last progress block.

    Contract: the last "out_time=" of `log` in seconds; 0.0 when `log` is no
    text or holds none that can be read. Never raises.
    """
    if not isinstance(log, str):
        return 0.0
    blocks = _OUT_TIME.findall(log)
    if not blocks:
        return 0.0
    hours, minutes, secs = blocks[-1]
    return int(hours) * 3600 + int(minutes) * 60 + float(secs)


def _ffmpeg_args(ffmpeg: str, seconds: int) -> list[str]:
    return [
        ffmpeg,
        "-hide_banner",
        "-nostdin",
        "-nostats",
        "-loglevel",
        "info",
        # A stream can be a playlist, and a playlist names addresses and
        # files. ffmpeg's own default for a pipe already keeps it from
        # opening them (9.0.2 logs "Setting default whitelist 'crypto,data'");
        # it is said outright here so that it does not hang on a default.
        "-protocol_whitelist",
        "pipe",
        "-progress",
        "pipe:2",
        "-t",
        str(seconds),
        "-i",
        "pipe:0",
        "-vn",
        "-sn",
        "-dn",
        # The frame log would be ten lines a second; the summary is enough.
        "-af",
        "ebur128=framelog=verbose",
        "-f",
        "null",
        "-",
    ]


def listen(url: str, seconds: int, ffmpeg: str) -> str:
    """The loudness of the first `seconds` of the stream at `url`.

    Contract: text as loudness_of gives it; "" when the answer says it is
    text, or ffmpeg decoded less than `seconds` of it. ffmpeg is given the
    stream on its standard input and may open nothing else. Raises OSError or
    http.client.HTTPException when the station cannot be read.
    """
    log: list[str] = []
    with streamkind.open_stream(url, READ_SECONDS) as resp:
        if streamkind.says_text(resp):
            return ""
        proc = subprocess.Popen(
            _ffmpeg_args(ffmpeg, seconds),
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"},
            # No buffer of this side's own: ffmpeg leaves when it has its
            # seconds, and what a buffer still held could not be written out.
            bufsize=0,
        )
        if proc.stdin is None or proc.stderr is None:
            raise OSError("ffmpeg came up without its pipes")
        # Read as it comes: a pipe nobody empties stops ffmpeg, and with it
        # the reading.
        ear = threading.Thread(
            target=lambda out: log.append(out.read().decode("utf-8", "replace")),
            args=(proc.stderr,),
            daemon=True,
        )
        ear.start()
        try:
            try:
                while proc.poll() is None:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    left = memoryview(chunk)
                    while left:
                        left = left[proc.stdin.write(left) :]
                proc.stdin.close()
            except BrokenPipeError:
                # ffmpeg has its seconds and went: the reading is complete.
                pass
            proc.wait(timeout=READ_SECONDS)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    ear.join(timeout=READ_SECONDS)
    text = "".join(log)
    if heard(text) < seconds - SHORT_BY:
        return ""
    return loudness_of(text)


def _seconds(argv) -> int:
    """The seconds to listen: argv[2] when it is a whole number from 1 to 60."""
    word = argv[2] if len(argv) == 3 else ""
    if word.isascii() and word.isdigit() and 1 <= int(word) <= 60:
        return int(word)
    return LISTEN_SECONDS


def main(argv) -> int:
    if len(argv) not in (2, 3):
        print(
            "loudness.py: usage: loudness.py <file holding the address> [seconds]",
            file=sys.stderr,
        )
        return 2
    leash = argv[1]
    seconds = _seconds(argv)
    end = time.monotonic() + seconds + SLACK_SECONDS
    over = []

    def tick(signum, _frame) -> None:
        # Raised wherever the helper stands: in a name lookup that never
        # answers, in a read, in a write ffmpeg is slow to take. Once: what
        # follows is the way out, and that is not interrupted again.
        if over:
            return
        if (
            signum == signal.SIGTERM
            or time.monotonic() > end
            or not os.path.exists(leash)
        ):
            over.append(signum)
            raise _Over

    before = (
        signal.signal(signal.SIGALRM, tick),
        signal.signal(signal.SIGTERM, tick),
    )
    word = ""
    try:
        signal.setitimer(signal.ITIMER_REAL, TICK_SECONDS, TICK_SECONDS)
        with open(leash, "r+", encoding="utf-8") as fh:
            url = fh.read().strip()
            fh.seek(0)
            fh.truncate()
        ffmpeg = shutil.which("ffmpeg")
        # urllib opens file: and ftp: addresses too, and neither is a
        # station. Without ffmpeg nobody is connected to for nothing.
        if ffmpeg and url.lower().startswith(("http://", "https://")):
            word = listen(url, seconds, ffmpeg)
    except (_Over, OSError, ValueError, http.client.HTTPException):
        # No file, no station, no time: all of them are no reading.
        word = ""
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, before[0])
        signal.signal(signal.SIGTERM, before[1])
        try:
            os.unlink(leash)
        except OSError:
            # Gone already, or a folder: the answer does not hang on it.
            pass
    if word:
        print(word)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
