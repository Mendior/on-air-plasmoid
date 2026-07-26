# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Device cache + avahi parsing in cast.py. Discovery over SSDP/mDNS is a UDP
lottery — the cache is what keeps the device picker stable between rounds, so
its merge/expiry behaviour and the avahi fallback parser get pinned here."""
import json
import os
import time

AVAHI_SAMPLE = "\n".join([
    # resolved IPv4 with a Bose GUID in the TXT record
    '=;wlan0;IPv4;Bose\\032Soundbar;_bose._tcp;local;bose.local;192.168.1.10;8090;'
    '"GUID=975fefe8-299e-47ff" "MANUFACTURER=Bose"',
    # resolved IPv4, no GUID
    '=;wlan0;IPv4;TV;_googlecast._tcp;local;tv.local;192.168.1.100;8009;"id=abc"',
    # IPv6 must be ignored
    '=;wlan0;IPv6;TV;_googlecast._tcp;local;tv.local;fe80::1;8009;"id=abc"',
    # loopback must be ignored
    '=;lo;IPv4;Self;_x._tcp;local;self.local;127.0.0.1;80;"a=b"',
    # unresolved (+) lines must be ignored
    '+;wlan0;IPv4;Other;_y._tcp;local',
])


def test_parse_avahi_extracts_candidates(cast):
    cand = cast._parse_avahi(AVAHI_SAMPLE)
    assert set(cand) == {"192.168.1.10", "192.168.1.100"}
    assert cand["192.168.1.10"] == {":8091/975fefe8-299e-47ff.xml"}
    assert cand["192.168.1.100"] == set()


def test_parse_avahi_empty_and_garbage(cast):
    assert cast._parse_avahi("") == {}
    assert cast._parse_avahi("not;avahi;output") == {}


def _dev(name):
    return {"kind": "dlna", "name": name, "host": "192.168.1.7",
            "port": 0, "model": "M", "location": "http://192.168.1.7:8080/dd.xml"}


def test_cache_roundtrip_and_merge(cast, tmp_path, monkeypatch):
    monkeypatch.setattr(cast, "CACHE_PATH", str(tmp_path / "devices.json"))
    cast._cache_save({"udn-a": _dev("A")})
    cast._cache_save({"udn-b": _dev("B")})   # merge, must keep A
    cache = cast._cache_load()
    assert set(cache) == {"udn-a", "udn-b"}
    assert cache["udn-a"]["name"] == "A"
    assert cache["udn-a"]["last_seen"] > 0


def test_cache_expires_long_unseen_devices(cast, tmp_path, monkeypatch):
    path = tmp_path / "devices.json"
    monkeypatch.setattr(cast, "CACHE_PATH", str(path))
    stale = dict(_dev("Old"), last_seen=time.time() - cast.CACHE_MAX_AGE_S - 60)
    path.write_text(json.dumps({"udn-old": stale}))
    cast._cache_save({"udn-new": _dev("New")})
    assert set(cast._cache_load()) == {"udn-new"}


def test_cache_save_sweeps_aged_orphan_temps(cast, tmp_path, monkeypatch):
    # A hard kill between mkstemp and os.replace leaves a uniquely named temp
    # behind. A successful save must sweep aged siblings, but spare a recent
    # one (it may be a concurrent in-flight temp) and the real cache file.
    monkeypatch.setattr(cast, "CACHE_PATH", str(tmp_path / "onair-cast-devices.json"))
    old = tmp_path / ".onair-cast-deadbeef"
    old.write_text("{}")
    os.utime(old, (time.time() - 7200, time.time() - 7200))
    fresh = tmp_path / ".onair-cast-inflight"
    fresh.write_text("{}")
    cast._cache_save({"udn-a": _dev("A")})
    assert not old.exists()
    assert fresh.exists()
    assert (tmp_path / "onair-cast-devices.json").exists()


def test_cache_load_survives_corrupt_file(cast, tmp_path, monkeypatch):
    path = tmp_path / "devices.json"
    monkeypatch.setattr(cast, "CACHE_PATH", str(path))
    path.write_text("{ not json")
    assert cast._cache_load() == {}
    path.write_text('["a list, not a dict"]')
    assert cast._cache_load() == {}
