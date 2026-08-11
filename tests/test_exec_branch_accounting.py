# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Every exec sentinel stays accounted for, by name, in exec_branches.json.

The widget answers ~60 sentinel branches and fires nine more commands whose
ack it deliberately ignores. Until 2026-08-09 nothing tied that set to any
record: a branch could gain or lose failure handling and no number moved.
This test keeps the registry and the code byte-honest in both directions —
a sentinel added to the code must be filed (classified, exempt-with-reason,
or on the todo queue), and a registry entry whose code is gone must leave.

The classified count is a floor that may only rise: stage 2 of the plan
moves names from todo into reads_exit_code one measured branch at a time.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "package" / "contents" / "ui"
REG = json.loads((Path(__file__).parent / "exec_branches.json").read_text())

_FILES = ["main.qml", "SyncEngine.qml", "TimeshiftEngine.qml", "PodcastEngine.qml", "RecordingEngine.qml", "AlarmEngine.qml"]


def _handled():
    out = set()
    for name in _FILES:
        out |= set(re.findall(r'cmd\.indexOf\(": ([A-Z][A-Z0-9_]+)',
                              (UI / name).read_text(encoding="utf-8")))
    return out


def _all_qml_text():
    return "\n".join(p.read_text(encoding="utf-8") for p in UI.rglob("*.qml"))


def test_every_handled_sentinel_is_filed_exactly_once():
    reads = set(REG["reads_exit_code"])
    ff = set(REG["fire_and_forget"])
    todo = set(REG["todo"])
    handled = _handled()

    unfiled = handled - reads - ff - todo
    assert not unfiled, (
        "sentinel(s) handled in code but missing from exec_branches.json: %s — "
        "file each one: classify it, exempt it with a reason, or queue it"
        % sorted(unfiled))

    stale = (reads | ff | todo) - handled
    assert not stale, (
        "registry entries whose handler no longer exists: %s — remove them in "
        "the commit that removed the branch" % sorted(stale))

    twice = (reads & ff) | (reads & todo) | (ff & todo)
    assert not twice, "sentinel(s) filed in two groups at once: %s" % sorted(twice)


def test_fired_no_handler_names_are_real_and_truly_unhandled():
    handled = _handled()
    body = _all_qml_text()
    for name, reason in REG["fired_no_handler"].items():
        assert reason.strip(), "%s: an exemption without a reason is a hole" % name
        assert (": %s" % name) in body, (
            "%s is exempted but no command carries that sentinel any more — "
            "remove the entry" % name)
        assert name not in handled, (
            "%s gained a handler; move it out of fired_no_handler and file it "
            "as classified, fire-and-forget or todo" % name)


def test_the_classified_count_only_rises():
    got = len(REG["reads_exit_code"])
    floor = REG["classified_floor"]
    assert got >= floor, (
        "reads_exit_code shrank to %d below its floor %d — a branch lost its "
        "failure handling; if that was deliberate, lower the floor in its own "
        "commit with the reason" % (got, floor))
    # Each classified branch's file must actually mention the code it reads.
    body = _all_qml_text()
    for name in REG["reads_exit_code"]:
        i = body.find('cmd.indexOf(": %s' % name)
        assert i >= 0
        assert "exitCode" in body[i:i + 2500], (
            "%s is filed as reading the exit code, but no exitCode reference "
            "sits near its branch" % name)
