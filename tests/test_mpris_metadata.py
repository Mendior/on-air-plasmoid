# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""What the desktop's media player shows as title and album.

With the radio stopped the widget writes an empty title and an empty station,
and the bridge used to fill both with a single space. Read over the bus on the
test rig on 2026-09-23: xesam:title ' ' and xesam:album ' ', so a controller
drew a blank line where it could have drawn nothing. Stopped means no names.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MPRIS = ROOT / "package" / "contents" / "ui" / "mpris.py"


def _names_fn():
    """shown_names() out of mpris.py, without importing dbus or gi."""
    src = MPRIS.read_text(encoding="utf-8")
    m = re.search(r"^def shown_names\(.*?(?=^\S)", src, re.M | re.S)
    assert m, "shown_names is gone from mpris.py"
    ns: dict = {}
    exec(compile(m.group(0), "mpris_names", "exec"), ns)
    return ns["shown_names"]


def test_nothing_on_shows_nothing():
    shown_names = _names_fn()
    assert shown_names({"status": "Stopped", "station": "", "title": "", "artist": ""}) == {}, (
        "a stopped radio still sends placeholder names")


def test_a_station_without_a_title_shows_its_name_twice():
    shown_names = _names_fn()
    assert shown_names({"station": "Dance Wave!", "title": ""}) == {
        "xesam:title": "Dance Wave!", "xesam:album": "Dance Wave!"}


def test_a_track_title_goes_first_and_the_station_is_the_album():
    shown_names = _names_fn()
    assert shown_names({"station": "Radio Paradise", "title": "Widowspeak - No Driver"}) == {
        "xesam:title": "Widowspeak - No Driver", "xesam:album": "Radio Paradise"}


def test_a_missing_or_null_field_counts_as_empty():
    shown_names = _names_fn()
    assert shown_names({}) == {}
    assert shown_names({"station": None, "title": None}) == {}
    # An episode with a title and no station row: no album rather than a blank one.
    assert shown_names({"title": "Episode 12"}) == {"xesam:title": "Episode 12"}


def test_the_bridge_builds_its_names_from_it():
    src = MPRIS.read_text(encoding="utf-8")
    at = src.index("    def _build_metadata(")
    body = src[at:src.index("\n    def ", at + 1)]
    assert "shown_names(self._state)" in body, "the metadata picks its names some other way again"
    assert '"xesam:title"' not in body and '"xesam:album"' not in body, (
        "the metadata writes a title or album of its own beside shown_names")
