# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The relay's head start, sized by what the stream actually delivers.

A reporter heard micro-cuts through the first ten seconds of two
lossless stations and none at all on a 128 kbps one. The reason was in
these constants: the byte target exists for exactly the fat streams,
but the short clock always released them first - measured 2026-08-11,
those two stations arrive at 1181 and 749 kbps, needing 3.6 s and 5.6 s
to reach the target, so they started on a fifth of the intended
cushion. These pin the sizing for all three classes.
"""
import re
from pathlib import Path

RELAY = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui" / "relayserve.py"


def _consts():
    src = RELAY.read_text(encoding="utf-8")
    out = {}
    for name in ("LEAD_BYTES", "LEAD_SEC", "FAT_RATE", "MAX_LEAD_SEC"):
        m = re.search(rf"^{name} = (.+)$", src, re.M)
        assert m, f"{name} is gone from the relay"
        out[name] = eval(m.group(1))  # noqa: S307 - our own literals
    return out


def _wait_for(rate_bytes_per_sec, c):
    """Replay the relay's wait loop against a steady arrival rate."""
    lead = 0.0
    while lead < c["MAX_LEAD_SEC"]:
        have = rate_bytes_per_sec * lead
        if have >= c["LEAD_BYTES"]:
            break
        if lead >= c["LEAD_SEC"] and have / max(lead, 0.1) < c["FAT_RATE"]:
            break
        lead += 0.1
    return lead, rate_bytes_per_sec * lead


def test_a_thin_stream_still_starts_on_the_short_clock():
    c = _consts()
    lead, _ = _wait_for(16000, c)          # 128 kbps
    assert lead <= c["LEAD_SEC"] + 0.05, (
        "a stream that never starved now waits for a cushion it does not "
        "need - that is a fresh bug, not a fix")


def test_the_reporters_lossless_stations_get_a_real_cushion():
    c = _consts()
    for rate in (147620, 93708):           # 1181 and 749 kbps, measured
        lead, have = _wait_for(rate, c)
        assert lead > 3.0, "a fat stream is being released on the short clock again"
        assert have > 400 * 1024, (
            "the cushion is back under half a megabyte, which is where the "
            "micro-cuts lived")


def test_no_stream_can_hold_the_listener_forever():
    c = _consts()
    lead, _ = _wait_for(1000, c)           # a source barely trickling
    assert lead <= c["MAX_LEAD_SEC"] + 0.05
