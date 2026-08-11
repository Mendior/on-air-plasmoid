# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Ceilings that may only go down.

main.qml is where the bugs live, and it got that big one honest hundred
lines at a time — every one of them the shortest way to ship the thing in
front of it. Nobody ever decided to write a 9520-line file. A ratchet is
the cheapest thing that turns "we should shrink this" from an intention
into a fact: the number in ratchet.json is today's measurement, and the
gate refuses anything larger.

Two rules make it worth having:

  * Lowering a number needs no ceremony — do it in the same commit that
    removed the lines, so the floor follows the work down.
  * Raising one is a decision, not a fix. Its own commit, and the reason
    in the message. A ratchet quietly bumped to make a red gate green is
    the same as not having one.

The exec count is here for a different reason than size. Every direct
`executable.exec(...)` is a shell command assembled in QML and handed to
a process, and each one has to get its own quoting right. main.qml
already has the facade the SyncEngine goes through (`function exec(cmd)`
at root scope — found by shape, since a line number here was stale the
day after it was written) — the work is moving the rest onto it, and
this number is how we know the direction of travel.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "package" / "contents" / "ui"
RATCHET = json.loads(
    (Path(__file__).resolve().parent / "ratchet.json").read_text(encoding="utf-8")
)

_RAISE = (
    "\n\nIf the growth is deliberate, raise the ceiling in tests/ratchet.json "
    "in its own commit and say why in the message. Do not raise it in the "
    "commit that caused the growth — that is how a ratchet stops meaning "
    "anything."
)


def _brace_body(src: str, start: int) -> str:
    """The brace-balanced block that opens at or after `start`."""
    i = src.index("{", start)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    raise AssertionError("unbalanced braces from offset %d" % start)


def test_the_two_big_files_do_not_grow():
    for rel, ceiling in RATCHET["lines"].items():
        n = len((ROOT / rel).read_text(encoding="utf-8").splitlines())
        assert n <= ceiling, "%s is %d lines, ceiling is %d (+%d)%s" % (
            rel,
            n,
            ceiling,
            n - ceiling,
            _RAISE,
        )


def test_shell_commands_keep_moving_onto_the_facade():
    """Count direct executable.exec( calls, minus the facade's own body.

    The facade is `function exec(cmd)` at main.qml root scope; the one
    call inside it is the whole point of the facade and must not count
    against the ceiling. Anchoring on the brace-balanced body rather
    than a line offset means the number survives edits above it.
    """
    total = 0
    for qml in sorted(UI.rglob("*.qml")):
        total += len(re.findall(r"executable\.exec\(", qml.read_text(encoding="utf-8")))

    src = (UI / "main.qml").read_text(encoding="utf-8")
    m = re.search(r"^    function exec\(cmd\) \{", src, re.MULTILINE)
    assert m, (
        "the exec facade is gone from main.qml — either it was renamed (fix "
        "this test) or the seam was removed (do not)"
    )
    inside = len(re.findall(r"executable\.exec\(", _brace_body(src, m.start())))
    assert inside == 1, (
        "the facade body makes %d direct calls, expected exactly 1 — the "
        "subtraction below is no longer right" % inside
    )

    direct = total - inside
    ceiling = RATCHET["direct_exec_calls"]
    assert direct <= ceiling, (
        "%d direct executable.exec( call sites, ceiling is %d (+%d). Route "
        "new shell work through the exec facade instead — that is the seam "
        "that makes it mockable.%s" % (direct, ceiling, direct - ceiling, _RAISE)
    )


def test_no_shell_walks_around_the_facade_via_connectsource():
    """connectSource("…") is the same shell handed over at a different door.

    The exec ratchet counts executable.exec( literally, so a command built
    inline and given straight to a DataSource — the mprisCmdReader pattern —
    moves the guarded number by nothing. Two such sites exist and are the
    ceiling; the facade's own connectSource(cmd) passes a variable, carries
    no quote, and stays outside this pattern on purpose.

    Re-measure: grep -rn 'connectSource("' package --include='*.qml'
    """
    total = 0
    for qml in sorted(UI.rglob("*.qml")):
        total += qml.read_text(encoding="utf-8").count('connectSource("')
    ceiling = RATCHET["direct_connectsource_calls"]
    assert total <= ceiling, (
        "%d inline-string connectSource( sites, ceiling is %d (+%d). This is "
        "a shell command skipping both the exec facade and the exec ratchet "
        "— route it through the facade.%s"
        % (total, ceiling, total - ceiling, _RAISE)
    )
