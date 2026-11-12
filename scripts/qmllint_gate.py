#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Egon Greenberg
#
# SPDX-License-Identifier: LGPL-2.0-or-later

"""qmllint over every QML file of the package, for `dev.sh lint`.

    qmllint_gate.py <qmllint binary> <package dir>

Prints what is wrong and exits 1, or prints nothing and exits 0.

A qmllint that found nothing and a qmllint that did not look print the same
nothing, and this project has mistaken the second for the first twice: the
largest files went unread from before 2026-09-20, and again by 2026.43. Both
ways it happens were measured on 6.12.0:

  * Every function nested in another is compiled a second time, and a const
    or let in it fails that second time. qmllint then drops the object and
    every object after it, exits 0 and says nothing.
  * The text output is thrown away each time a loop makes the type pass start
    over, with everything printed for the file so far. main.qml showed only
    the messages past line 7002. The JSON report keeps them all.

So: the report is read as JSON; each file is linted as a copy that ends in one
more object reading a name nothing declares, and a file where that read is not
reported fails; and a message fails the lint unless it is one of the two kinds
healthy code produces by the hundred or a row in KNOWN accounts for it.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

Complaint = tuple[tuple[str, str, str], str]  # ((file, category, what), the line to print)

# The new last object. Last, because qmllint takes a file's objects in the
# order they are written and stops at the first it cannot compile: a read
# reported from here means it got through all of them.
PROBE = (
    "    property QtObject zzSightProbe: QtObject {\n"
    "        function probe() { return aNameNothingDeclares; }\n"
    "    }\n"
)

# Messages that are right about the code and wrong about the harm, each read
# against the code on 2026-11-12. (file, category, what, how many, why) — what
# is the missing member's name, or else the text qmllint points at. The count
# is exact: one more is a new one, one fewer means the row is out of date.
KNOWN: list[tuple[str, str, str, int, str]] = [
    ("ui/FullRepresentation.qml", "missing-property", "count", 2,
     "webRows is declared Item and holds the Repeater that registers itself in it"),
    ("ui/FullRepresentation.qml", "missing-property", "itemAt", 2,
     "webRows is declared Item and holds the Repeater that registers itself in it"),
    ("ui/FullRepresentation.qml", "missing-property", "targetIndex", 3,
     "currentItem is the list's delegate, a MediaListItem, which declares it"),
    ("ui/FullRepresentation.qml", "missing-property", "text", 1,
     "the parent of a button's contentItem is the button"),
    ("ui/FullRepresentation.qml", "missing-property", "font", 1,
     "the parent of a button's contentItem is the button"),
    ("ui/FullRepresentation.qml", "missing-property", "hovered", 1,
     "the parent of a control's background is the control"),
    ("ui/MediaListItem.qml", "missing-property", "dragActive", 4,
     "declared on the station list in FullRepresentation.qml, the only view these rows live in"),
    ("ui/main.qml", "incompatible-type", "Plasmoid.configuration", 2,
     "the configuration map is a QObject; Qt's description of the type leaves the base out"),
    ("ui/config/configGeneral.qml", "id-shadows-member", "listItem", 2,
     "the id wins, and the row it names is the one whose ListView the drag handle needs"),
    # A read with no use is how a binding is told to run again.
    ("ui/EpisodeListItem.qml", "confusing-expression-statement", "root._podPosRev;", 1,
     "read so the binding runs again when a position is saved"),
    ("ui/EpisodeListItem.qml", "confusing-expression-statement", "root._podPlayedRev;", 1,
     "read so the binding runs again when an episode is marked played"),
    ("ui/FullRepresentation.qml", "confusing-expression-statement", "root._podPlayedRev", 1,
     "read so the binding runs again when an episode is marked played"),
    ("ui/FullRepresentation.qml", "confusing-expression-statement", "podcastSubsModel.count", 2,
     "read so the binding runs again when a show is added or dropped"),
    ("ui/FullRepresentation.qml", "confusing-expression-statement", "podcastFolder.count", 1,
     "read so the binding runs again when the download folder changes"),
    # A Rectangle has no size of its own, and a layout then takes the one it
    # was given: measured offscreen, 7 by 7 stays 7 by 7.
    ("ui/FullRepresentation.qml", "Quick.layout-positioning", "7", 2,
     "a Rectangle without an implicit size keeps the width and height it is given in a layout"),
    ("ui/EpisodeListItem.qml", "Quick.layout-positioning", "Kirigami.Units.smallSpacing * 1.5", 1,
     "a Rectangle without an implicit size keeps the width and height it is given in a layout"),
    ("ui/EpisodeListItem.qml", "Quick.layout-positioning", "width", 1,
     "a Rectangle without an implicit size keeps the width and height it is given in a layout"),
    ("ui/FullRepresentation.qml", "Quick.layout-positioning", "podAlarmBtn.height + Kirigami.Units.smallSpacing", 1,
     "a Popup is placed against its parent, the layout it is written in does not manage it"),
    ("ui/FullRepresentation.qml", "Quick.layout-positioning", "-width + podAlarmBtn.width", 1,
     "a Popup is placed against its parent, the layout it is written in does not manage it"),
    ("ui/FullRepresentation.qml", "Quick.layout-positioning",
     "Math.min(implicitWidth, fullRepresentation.width - 2 * Kirigami.Units.smallSpacing)", 1,
     "a Popup is placed against its parent, the layout it is written in does not manage it"),
]


def with_probe(text: str) -> tuple[str, int] | None:
    """The file with PROBE before its last brace, and the line the undeclared
    name is on; None for a ListModel, inside which qmllint reports nothing."""
    root = re.search(r"^([A-Za-z][\w.]*)\s*\{", text, re.M)
    if root and root.group(1).split(".")[-1] == "ListModel":
        return None
    end = text.rstrip().rfind("}")
    return text[:end] + PROBE + text[end:], text.count("\n", 0, end) + 2


def config_keys(package: Path) -> set[str]:
    """The names main.xml declares."""
    xml = (package / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    return set(re.findall(r'<entry\s+name="(\w+)"', xml))


def judge(
    name: str,
    source: str,
    rc: int,
    warnings: list[dict] | None,
    probe_line: int | None,
    keys: set[str],
) -> tuple[list[str], list[Complaint]]:
    """One file's verdict: what is wrong outright, and what KNOWN may cover."""
    if warnings is None:
        return [f"{name}: qmllint gave no report (exit {rc})"], []
    problems: list[str] = []
    complaints: list[Complaint] = []
    if rc != 0:
        problems.append(f"{name}: qmllint exit {rc}")
    lines = source.split("\n")
    seen = False
    for w in warnings:
        line, column = w.get("line", 0), w.get("column", 0)
        if probe_line is not None and probe_line - 1 <= line <= probe_line + 1:
            seen = seen or line == probe_line
            continue
        category, message = w.get("id", ""), w.get("message", "").split("\n")[0]
        if w.get("type") == "info":
            continue
        # An id of another file, a model role, i18n(): 2191 of these on
        # 2026-11-12, every name checked against what its file can reach.
        if category == "unqualified" and message == "Unqualified access":
            continue
        # 903 of these: it asks for let and const, which is the very thing
        # this qmllint cannot read inside a callback.
        if category == "block-scope-var-declaration":
            continue
        text = lines[line - 1] if 0 < line <= len(lines) else ""
        where = f"{name}:{line}:{column} [{category}] {message}"
        member = re.match(r'Member "(\w+)" not found on type ', message) if category == "missing-property" else None
        if member and message.rstrip('"').endswith("KConfigPropertyMap"):
            if member.group(1) not in keys:
                problems.append(f'{where} — main.xml declares no key "{member.group(1)}"')
            continue
        what = member.group(1) if member else text[column - 1 : column - 1 + w.get("length", 0)] or message
        complaints.append(((name, category, what), f"{where}\n    {text.strip()}"))
    if probe_line is not None and not seen:
        problems.append(
            f"qmllint does not analyse {name}: a name nothing declares, read in a new last object, was not reported "
            "(on Qt 6.12 a const or let inside a callback does this)"
        )
    return problems, complaints


def settle(complaints: list[Complaint], known: list[tuple[str, str, str, int, str]], unread: set[str]) -> list[str]:
    """Complaints against the rows that excuse them; every line left is a
    problem. A file in `unread` is not asked why its rows come up short."""
    listed = {row[:3]: row[3] for row in known}
    found = Counter(key for key, _ in complaints)
    out = [text for key, text in complaints if found[key] > listed.get(key, 0)]
    for key, want in listed.items():
        row = f"KNOWN lists {want} of {key[0]} [{key[1]}] {key[2]!r} and qmllint reports {found[key]}"
        if found[key] > want:
            out.append(row + " — at least one of the lines above is new")
        elif found[key] < want and key[0] not in unread:
            out.append(row + " — the row in scripts/qmllint_gate.py is out of date")
    return out


def run(qmllint: str, package: Path, known: list[tuple[str, str, str, int, str]] | None = None) -> list[str]:
    """Lint a copy of the package; the lines to print, none when all is well."""
    keys = config_keys(package)
    with tempfile.TemporaryDirectory(prefix="onair-qmllint-") as tmp:
        # A copy of the whole tree, so the probe never sits in the package and
        # every relative import still finds its neighbour.
        tree = Path(tmp) / "contents"
        shutil.copytree(package / "contents", tree, ignore=shutil.ignore_patterns("__pycache__", "locale"))
        jobs = []
        problems: list[str] = []
        for path in sorted(tree.rglob("*.qml")):
            name = path.relative_to(tree).as_posix()
            source = path.read_text(encoding="utf-8")
            probed = with_probe(source)
            if probed is None:
                if re.search(r"\bfunction\b|=>|\bon[A-Z]\w*\s*:", source):
                    problems.append(f"{name}: script inside a ListModel, where qmllint reports nothing — move it out")
            else:
                path.write_text(probed[0], encoding="utf-8")
            jobs.append((name, source, path, probed[1] if probed else None))

        def lint(job: tuple[str, str, Path, int | None]) -> tuple[int, list[dict] | None]:
            p = subprocess.run([qmllint, "--json", "-", str(job[2])], capture_output=True, text=True, check=False)
            try:
                return p.returncode, json.loads(p.stdout)["files"][0]["warnings"]
            except (ValueError, KeyError, IndexError):
                return p.returncode, None

        with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            reports = list(pool.map(lint, jobs))
    complaints: list[Complaint] = []
    unread: set[str] = set()
    for (name, source, _, probe_line), (rc, warnings) in zip(jobs, reports, strict=True):
        bad, maybe = judge(name, source, rc, warnings, probe_line, keys)
        if bad:
            unread.add(name)
        problems += bad
        complaints += maybe
    return problems + settle(complaints, KNOWN if known is None else known, unread)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        out = run(argv[1], Path(argv[2]))
    except OSError as e:
        out = [f"qmllint could not be run: {e}"]
    if out:
        print("\n".join(out))
        print(f"lint FAILED: qmllint ({len(out)})")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
