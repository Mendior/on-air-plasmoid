#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Egon Greenberg
#
# SPDX-License-Identifier: LGPL-2.0-or-later

"""Ask the station directory about every station the widget ships with.

Deep House Lounge sat in the bundled list long after its server stopped
answering and the directory forgot it (found 2026-11-02, the address timed
out and a name search gave nothing). A new install played a dead row with
no way to heal it. This runs in the release preflight: one byuuid request
for all bundled uuids, and every row the directory does not vouch for is
named. It fails closed: a directory that cannot be asked is not a pass.
"""

from __future__ import annotations

import html
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIRRORS = ("de1", "de2", "all")


def default_rows(xml_text: str) -> list[dict]:
    """The bundled station list: the servers entry's default in main.xml."""
    m = re.search(
        r'<entry name="servers"[^>]*>.*?<default>(.*?)</default>', xml_text, re.S
    )
    if not m:
        return []
    try:
        rows = json.loads(html.unescape(m.group(1).strip()))
    except json.JSONDecodeError:
        return []
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []


def _addr(u: object) -> str:
    """An address folded the way the widget compares them (HealLogic.addrKey)."""
    return (
        re.sub(r"^https?://", "", str(u or "").strip(), flags=re.I).rstrip("/").lower()
    )


def _name(s: object) -> str:
    return " ".join(str(s or "").split()).lower()


def _mount(u: object) -> tuple[str, str]:
    """(base domain, last path segment) of an address, both lower-cased."""
    parts = re.match(
        r"^https?://([^/:?#]+)[^/?#]*(/[^?#]*)?", str(u or "").strip(), flags=re.I
    )
    if not parts:
        return ("", "")
    host = parts.group(1).lower()
    segment = [p for p in (parts.group(2) or "").split("/") if p]
    return (".".join(host.split(".")[-2:]), segment[-1].lower() if segment else "")


def _same_station(row: dict, rec: dict) -> bool:
    """The record lists the row's address, carries its exact name, or plays
    the same mount on the same domain (SomaFM spreads one mount over ice2,
    ice3, ice5 and ice6; a copied neighbour plays another mount)."""
    if _addr(row.get("hostname")) in (
        _addr(rec.get("url")),
        _addr(rec.get("url_resolved")),
    ):
        return True
    if _name(row.get("name")) == _name(rec.get("name")):
        return True
    mine = _mount(row.get("hostname"))
    return mine[1] != "" and mine in (
        _mount(rec.get("url")),
        _mount(rec.get("url_resolved")),
    )


def verdicts(rows: list[dict], records: list[dict]) -> list[str]:
    """One line per bundled row the directory does not vouch for, else [].

    A row is vouched for when its uuid is its own (no other bundled row has
    it), the record exists and the checker passes it, and the record is this
    station: it lists the row's address, or carries the row's exact name.
    A copied neighbour's uuid would otherwise pass, and the heal trusts a
    byuuid answer for good.
    """
    by_uuid = {str(r.get("stationuuid", "")).lower(): r for r in records}
    first_with: dict[str, str] = {}
    out = []
    for row in rows:
        name, uuid = row.get("name", "?"), str(row.get("uuid", "")).lower()
        if len(uuid) != 36:
            out.append(f"{name}: no directory uuid")
            continue
        if uuid in first_with:
            out.append(f"{name}: shares its uuid with {first_with[uuid]}")
        else:
            first_with[uuid] = name
        rec = by_uuid.get(uuid)
        if rec is None:
            out.append(f"{name}: not in the directory any more")
        elif str(rec.get("lastcheckok")) != "1":
            out.append(f"{name}: the directory's checker fails it")
        elif not _same_station(row, rec):
            out.append(
                f"{name}: the directory's record is another station ({rec.get('name')})"
            )
    return out


def main() -> int:
    """Run the check against the live directory; 0 pass, 1 doubt, 2 unasked."""
    rows = default_rows(
        (ROOT / "package" / "contents" / "config" / "main.xml").read_text(
            encoding="utf-8"
        )
    )
    meta = json.loads((ROOT / "package" / "metadata.json").read_text(encoding="utf-8"))
    user_agent = "OnAir/" + meta["KPlugin"]["Version"]
    uuids = ",".join(str(r.get("uuid", "")) for r in rows if r.get("uuid"))
    records = None
    for mirror in MIRRORS:
        url = f"https://{mirror}.api.radio-browser.info/json/stations/byuuid?uuids={uuids}"
        req = urllib.request.Request(url, headers={"User-Agent": user_agent})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                records = json.load(r)
            break
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            print(
                f"defaults: {mirror} did not answer ({type(exc).__name__})",
                file=sys.stderr,
            )
    if not isinstance(records, list):
        print("defaults: the directory could not be asked, so nothing is vouched for")
        return 2
    doubts = verdicts(rows, records)
    for line in doubts:
        print("defaults: " + line)
    if not doubts:
        print(
            f"defaults: all {len(rows)} bundled stations are listed and pass the directory's check"
        )
    return 1 if doubts else 0


if __name__ == "__main__":
    sys.exit(main())
