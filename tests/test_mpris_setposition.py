# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Which SetPosition calls the bridge passes on to the widget.

MPRIS gives every track an id with its metadata and wants it back with the
position, so that a call made for a track that has ended in the meantime can
be told from one meant for what plays now. The bridge read neither the id nor
the track's length: a slider let go as one episode gave way to the next moved
the new episode, and a position past the end was sent on for the widget to
bend into "the very end", which finishes the episode.

The contract is the specification's: wrong track, below zero or past the end
are all ignored, and nothing happens at all where seeking is not offered.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MPRIS = ROOT / "package" / "contents" / "ui" / "mpris.py"

NOW = "/org/mpris/MediaPlayer2/Track/2"
BEFORE = "/org/mpris/MediaPlayer2/Track/1"
EPISODE = {"canSeek": True, "episode": True, "durationMs": 600000}


def _position_asked():
    """position_asked() out of mpris.py, without importing dbus or gi."""
    src = MPRIS.read_text(encoding="utf-8")
    start = src.index("def position_asked(")
    ns: dict = {}
    exec(
        compile(src[start : src.index("\nclass ", start)], "mpris_position", "exec"), ns
    )
    return ns["position_asked"]


def test_the_track_that_plays_is_moved_where_asked():
    asked = _position_asked()
    assert asked(EPISODE, NOW, NOW, 30_000_000) == 30_000_000
    assert asked(EPISODE, NOW, NOW, 0) == 0


def test_a_call_for_a_track_that_is_over_moves_nothing():
    asked = _position_asked()
    assert asked(EPISODE, NOW, BEFORE, 30_000_000) is None
    assert (
        asked(EPISODE, NOW, "/org/mpris/MediaPlayer2/TrackList/NoTrack", 30_000_000)
        is None
    )
    assert asked(EPISODE, NOW, "", 30_000_000) is None


def test_the_end_of_the_track_is_the_last_place_to_ask_for():
    asked = _position_asked()
    assert asked(EPISODE, NOW, NOW, 600_000_000) == 600_000_000
    assert asked(EPISODE, NOW, NOW, 600_000_001) is None
    assert asked(EPISODE, NOW, NOW, 700_000_000) is None


def test_below_zero_is_nowhere():
    asked = _position_asked()
    assert asked(EPISODE, NOW, NOW, -1) is None


def test_a_length_not_known_yet_holds_nobody_back():
    # The duration lands a beat after the episode starts. Until then there is
    # no end to measure against, and the widget keeps its own.
    asked = _position_asked()
    for unknown in (
        {"canSeek": True},
        {"canSeek": True, "durationMs": 0},
        {"canSeek": True, "durationMs": None},
    ):
        assert asked(unknown, NOW, NOW, 700_000_000) == 700_000_000


def test_a_live_stream_has_nowhere_to_go():
    asked = _position_asked()
    assert asked({"canSeek": False, "durationMs": 600000}, NOW, NOW, 30_000_000) is None
    assert asked({}, NOW, NOW, 30_000_000) is None


def test_the_bus_types_are_read_as_what_they_say():
    # dbus hands over an ObjectPath and an Int64; both print as their value.
    class Path_:
        def __str__(self) -> str:
            return NOW

    class Int64(int):
        pass

    asked = _position_asked()
    assert asked(EPISODE, NOW, Path_(), Int64(30_000_000)) == 30_000_000


def test_the_bridge_asks_before_it_sends():
    src = MPRIS.read_text(encoding="utf-8")
    at = src.index("    def SetPosition(")
    body = src[at : src.index("\n    @dbus.service.method", at)]
    assert (
        "position_asked(self._state, self._tracker_path, track_id, position)" in body
    ), "SetPosition decides for itself again, without the track id"
    assert body.count("_emit_command(") == 1
