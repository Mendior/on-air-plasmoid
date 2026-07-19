# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Grep-class invariants an exhaustive investigation proved and a future
refactor must not quietly break.

The 2026-07 sync study measured that a station switch does NOT move the
inter-speaker offset — because the playback path has zero sync-engine
call sites. That absence is load-bearing: adding a "helpful" rebuild to
a station switch would ADD an audible step to every switch to cure a
bug that does not exist. These tests pin the proven facts.
"""

import re
from pathlib import Path

UI = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"


def _function_body(src: str, name: str) -> str:
    """The brace-balanced body of a QML/JS function, by name."""
    m = re.search(r"function %s\s*\(" % re.escape(name), src)
    assert m, "function %s not found" % name
    i = src.index("{", m.end() - 1)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
    raise AssertionError("unbalanced braces in %s" % name)


def test_playback_path_never_touches_the_sync_engine():
    src = (UI / "main.qml").read_text(encoding="utf-8")
    forbidden = re.compile(
        r"combineOutputs|_combineRebuild|setSyncOffset|syncOffsetMap"
        r"|_refLatProbe|refLatProbeTimer|_idleTeardown")
    for fn in ("refreshServer", "_playStation", "startWithFade",
               "stopWithFade", "previewStation"):
        body = _function_body(src, fn)
        hit = forbidden.search(body)
        assert hit is None, (
            "%s reaches sync machinery (%r) — the measured guarantee that a "
            "station switch cannot move the inter-speaker offset depends on "
            "this path staying sync-free" % (fn, hit.group(0)))


def test_every_byuuid_concatenation_encodes_its_uuid():
    for qml in UI.rglob("*.qml"):
        src = qml.read_text(encoding="utf-8")
        for m in re.finditer(r'/json/stations/byuuid/"\s*\+\s*', src):
            tail = src[m.end():m.end() + 60].lstrip()
            assert tail.startswith("encodeURIComponent"), (
                "%s: byuuid concatenation without encodeURIComponent: %r"
                % (qml.name, tail.split("\n")[0]))


def test_device_supplied_names_are_stripped_at_the_model_door():
    src = (UI / "main.qml").read_text(encoding="utf-8")
    # The cast device dict, the paired list and the scan list each sanitize
    # LAN/BT-supplied display text through _sanitizeDeviceName. Three
    # sites; losing one reopens the rich-text beacon door.
    assert "function _sanitizeDeviceName" in src, (
        "_sanitizeDeviceName helper missing from main.qml")
    helper = re.search(
        r"function _sanitizeDeviceName[\s\S]{0,200}?replace\(/\[([^\]]+)\]/g",
        src)
    assert helper, "_sanitizeDeviceName no longer strips a character class"
    for needed in ("<>&", "\\u0000-\\u001f", "\\u202a-\\u202e"):
        assert needed in helper.group(1), (
            "_sanitizeDeviceName class lost %r (markup / control / bidi)"
            % needed)
    strips = src.count("_sanitizeDeviceName(")
    assert strips >= 4, (  # 3 model-door call sites + the definition itself
        "expected >=4 _sanitizeDeviceName mentions (3 call sites + def), "
        "found %d" % strips)
