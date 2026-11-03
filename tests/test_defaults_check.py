# SPDX-FileCopyrightText: 2026 Egon Greenberg
#
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The bundled-station check: what it reads and what it calls a doubt."""

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "defaults_check", ROOT / "scripts" / "defaults_check.py"
)
assert _spec and _spec.loader
dc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dc)

U1 = "960eb232-0601-11e8-ae97-52543be04c81"
U2 = "78012206-1aa1-11e9-a80b-52543be04c81"


def test_the_bundled_list_is_read_whole():
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(
        encoding="utf-8"
    )
    rows = dc.default_rows(xml)
    assert len(rows) == 20
    assert all(r["hostname"].startswith(("http://", "https://")) for r in rows)
    assert "&amp;" not in "".join(r["hostname"] for r in rows), (
        "the XML escape leaked into an address"
    )


def test_every_bundled_station_carries_a_directory_uuid():
    """Without one a dead default can only be healed by guessing its name."""
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(
        encoding="utf-8"
    )
    for row in dc.default_rows(xml):
        assert len(row.get("uuid", "")) == 36, row["name"]


def test_every_doubt_is_named_and_a_pass_says_nothing():
    rows = [
        {"name": "Beat Blender", "uuid": U1},
        {"name": "Mango", "uuid": U2},
        {"name": "Nobody", "uuid": ""},
        {"name": "Gone", "uuid": "11111111-2222-3333-4444-555555555555"},
    ]
    records = [
        {"stationuuid": U1, "lastcheckok": 1},
        {"stationuuid": U2, "lastcheckok": 0},
    ]
    out = dc.verdicts(rows, records)
    assert len(out) == 3
    assert any(line.startswith("Mango:") and "checker" in line for line in out)
    assert any(line.startswith("Nobody:") and "uuid" in line for line in out)
    assert any(
        line.startswith("Gone:") and "not in the directory" in line for line in out
    )
    assert (
        dc.verdicts(
            [{"name": "Beat Blender", "uuid": U1}],
            [{"stationuuid": U1, "lastcheckok": 1}],
        )
        == []
    )


def test_nonsense_is_answered_not_thrown():
    assert dc.default_rows("") == []
    assert (
        dc.default_rows('<entry name="servers"><default>not json</default></entry>')
        == []
    )
    assert dc.verdicts([], []) == []


def test_no_two_bundled_stations_share_a_uuid():
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(
        encoding="utf-8"
    )
    uuids = [row.get("uuid", "").lower() for row in dc.default_rows(xml)]
    assert len(uuids) == len(set(uuids))


def test_a_uuid_that_belongs_to_another_station_is_named():
    """A copied neighbour's uuid passes a check that only asks whether the
    record exists: four walmradio rows sit side by side on one host."""
    rows = [
        {
            "name": "Classic Vinyl HD",
            "hostname": "https://icecast.walmradio.com:8443/classic",
            "uuid": U1,
        },
        {
            "name": "Adroit Jazz Underground",
            "hostname": "https://icecast.walmradio.com:8443/jazz",
            "uuid": U1,
        },
    ]
    records = [
        {
            "stationuuid": U1,
            "lastcheckok": 1,
            "name": "Adroit Jazz Underground",
            "url": "https://icecast.walmradio.com:8443/jazz",
            "url_resolved": "https://icecast.walmradio.com:8443/jazz",
        }
    ]
    out = dc.verdicts(rows, records)
    assert any(
        line.startswith("Classic Vinyl HD:") and "another station" in line
        for line in out
    ), out
    assert any("shares its uuid" in line for line in out), out
    assert not any(
        line.startswith("Adroit Jazz Underground:") and "another station" in line
        for line in out
    )


def test_a_record_found_by_name_alone_is_still_this_station():
    rows = [
        {
            "name": "SomaFM Groove Salad",
            "hostname": "http://ice3.somafm.com/groovesalad-128-mp3",
            "uuid": U1,
        }
    ]
    records = [
        {
            "stationuuid": U1,
            "lastcheckok": 1,
            "name": "SomaFM Groove Salad",
            "url": "https://somafm.com/groovesalad.pls",
            "url_resolved": "https://ice2.somafm.com/groovesalad-128-mp3",
        }
    ]
    assert dc.verdicts(rows, records) == []


def test_the_same_mount_on_the_same_domain_is_the_same_station():
    """SomaFM's record is named "SomaFM Groove Salad (128k MP3)" and lists
    ice2 while the bundled row plays ice3: one mount, one station."""
    rows = [
        {
            "name": "SomaFM Groove Salad",
            "hostname": "http://ice3.somafm.com/groovesalad-128-mp3",
            "uuid": U1,
        }
    ]
    records = [
        {
            "stationuuid": U1,
            "lastcheckok": 1,
            "name": "SomaFM Groove Salad (128k MP3)",
            "url": "https://somafm.com/groovesalad.pls",
            "url_resolved": "https://ice2.somafm.com/groovesalad-128-mp3",
        }
    ]
    assert dc.verdicts(rows, records) == []
