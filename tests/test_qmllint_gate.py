# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The lint's qmllint pass has to prove that qmllint looked.

Twice now the three largest QML files went unread for weeks while the lint
stayed green, because a quiet qmllint and a blind one print the same nothing:
on 2026-09-20 (16 766 lines) and again by 2026.43. Two things did it, both
measured on qmllint 6.12.0. A const or let inside a callback makes it give up
on the file from that object on. And its text output throws away every
message it had printed each time it meets a loop, so what the old pass
grepped was only what came after the last loop of a file; the JSON report
keeps them all.

So the pass reads JSON, plants a name that exists nowhere in a new last
object of a copy of every file and fails when that name is not reported, and
fails on every message unless it is one of the two kinds healthy code
produces by the hundred or a row in KNOWN accounts for it.
"""

import importlib.util
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
QMLLINT = os.environ.get("QMLLINT") or "/usr/lib/qt6/bin/qmllint"

needs_qmllint = pytest.mark.skipif(
    QMLLINT == "none" or not Path(QMLLINT).is_file(),
    reason="no Qt6 qmllint here (the Arch job and a developer machine have one)",
)


def _gate():
    spec = importlib.util.spec_from_file_location("qmllint_gate", ROOT / "scripts" / "qmllint_gate.py")
    assert spec is not None and spec.loader is not None, "qmllint_gate.py is not loadable"
    mod = importlib.util.module_from_spec(spec)
    sys.modules["qmllint_gate"] = mod
    spec.loader.exec_module(mod)
    return mod


def _package(tmp_path: Path, files: dict[str, str], keys: tuple[str, ...] = ("volume",)) -> Path:
    pkg = tmp_path / "package"
    (pkg / "contents" / "ui").mkdir(parents=True)
    (pkg / "contents" / "config").mkdir()
    entries = "".join('    <entry name="%s" type="Int"><default>0</default></entry>\n' % k for k in keys)
    (pkg / "contents" / "config" / "main.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<kcfg>\n  <group name="General">\n%s  </group>\n</kcfg>\n' % entries,
        encoding="utf-8",
    )
    for name, text in files.items():
        (pkg / "contents" / "ui" / name).write_text(text, encoding="utf-8")
    return pkg


# The same file twice; the only difference is the keyword inside the callback.
CALLBACK = """import QtQuick

Item {
    id: root
    property int total: 0
    function sum(list) {
        list.forEach(function (v) { %s doubled = v * 2; root.total += doubled })
        return root.total
    }
    Timer { interval: 1000; onTriggered: root.sum([1, 2]) }
}
"""


@needs_qmllint
def test_a_file_qmllint_reads_to_its_end_passes(tmp_path):
    pkg = _package(tmp_path, {"Reads.qml": CALLBACK % "var"})
    assert _gate().run(QMLLINT, pkg, known=[]) == []


@needs_qmllint
def test_a_file_qmllint_gives_up_on_fails_by_name(tmp_path):
    """The other direction, on the smallest file that does it: a const inside
    a callback. qmllint exits 0 on it and prints nothing about it."""
    pkg = _package(tmp_path, {"Blind.qml": CALLBACK % "const", "Reads.qml": CALLBACK % "var"})
    out = _gate().run(QMLLINT, pkg, known=[])
    blind = [line for line in out if "qmllint does not analyse" in line]
    assert len(blind) == 1 and "ui/Blind.qml" in blind[0], out
    assert not any("Reads.qml" in line for line in out), out


@needs_qmllint
def test_the_probe_never_lands_in_the_package(tmp_path):
    pkg = _package(tmp_path, {"Reads.qml": CALLBACK % "var"})
    before = sorted((p.relative_to(pkg), p.read_bytes()) for p in pkg.rglob("*") if p.is_file())
    _gate().run(QMLLINT, pkg, known=[])
    assert sorted((p.relative_to(pkg), p.read_bytes()) for p in pkg.rglob("*") if p.is_file()) == before


@needs_qmllint
def test_a_member_that_does_not_exist_is_reported_though_a_loop_follows(tmp_path):
    """qmllint 6.12's text output loses this one: the loop in the function
    below makes it discard what it printed for the function above."""
    pkg = _package(tmp_path, {"Typo.qml": """import QtQuick

Item {
    id: root
    function early() { return root.noSuchMember }
    function later(n) {
        var sum = 0
        for (var i = 0; i < n; i++) sum += i
        return sum
    }
}
"""})
    out = _gate().run(QMLLINT, pkg, known=[])
    assert any("ui/Typo.qml:5" in line and "noSuchMember" in line for line in out), out


@needs_qmllint
def test_a_listed_exception_excuses_exactly_what_it_counts(tmp_path):
    files = {"Typo.qml": 'import QtQuick\n\nItem {\n    id: root\n    function f() { return root.noSuchMember + root.noSuchMember }\n}\n'}
    pkg = _package(tmp_path, files)
    gate = _gate()
    row = ("ui/Typo.qml", "missing-property", "noSuchMember")
    assert gate.run(QMLLINT, pkg, known=[(*row, 2, "a test row")]) == []
    # One more than the row counts: both are shown, nobody can say which is new.
    one_short = gate.run(QMLLINT, pkg, known=[(*row, 1, "a test row")])
    assert sum("ui/Typo.qml:5" in line and "noSuchMember" in line for line in one_short) == 2, one_short
    # One fewer: the code is fine and the row is what has to change.
    one_over = gate.run(QMLLINT, pkg, known=[(*row, 3, "a test row")])
    assert len(one_over) == 1 and "KNOWN lists 3" in one_over[0] and "out of date" in one_over[0], one_over


@needs_qmllint
def test_an_unread_file_is_not_also_blamed_for_its_rows(tmp_path):
    """What qmllint did not read it did not report, so every row of that file
    comes up short. The row is not what is wrong then."""
    typo = "    function f() { return root.noSuchMember }\n"
    files = {"Blind.qml": (CALLBACK % "const").replace("    function sum(list) {", typo + "    function sum(list) {")}
    out = _gate().run(QMLLINT, _package(tmp_path, files), known=[("ui/Blind.qml", "missing-property", "noSuchMember", 1, "a test row")])
    assert len(out) == 1 and "qmllint does not analyse ui/Blind.qml" in out[0], out


@needs_qmllint
def test_a_list_model_file_is_let_through_only_while_it_has_no_script(tmp_path):
    """qmllint reports nothing inside a ListModel, so the probe cannot work
    there. That is fine for a file of roles and no more."""
    plain = "import QtQuick\n\nListModel {\n    id: rows\n    dynamicRoles: true\n}\n"
    scripted = plain.replace("    dynamicRoles: true\n", "    dynamicRoles: true\n    function first() { return rows.get(0) }\n")
    gate = _gate()
    assert gate.run(QMLLINT, _package(tmp_path / "a", {"Rows.qml": plain}), known=[]) == []
    out = gate.run(QMLLINT, _package(tmp_path / "b", {"Rows.qml": scripted}), known=[])
    assert any("ui/Rows.qml" in line and "ListModel" in line for line in out), out


def _warning(category, message, line=3, column=5, length=4, kind="warning"):
    return {"id": category, "message": message, "line": line, "column": column, "length": length, "type": kind}


SOURCE = "import QtQuick\nItem {\n    oops: 1\n    property QtObject p: QtObject {\n        function probe() {}\n    }\n}\n"


def test_the_verdict_on_one_file():
    """Every branch of the verdict, on reports made by hand, so it is checked
    where there is no Qt as well."""
    judge = _gate().judge
    seen = _warning("unqualified", "Unqualified access", line=5)

    assert judge("ui/A.qml", SOURCE, 0, [seen], 5, set()) == ([], [])

    problems, complaints = judge("ui/A.qml", SOURCE, 0, [], 5, set())
    assert len(problems) == 1 and "qmllint does not analyse ui/A.qml" in problems[0] and complaints == []

    problems, _ = judge("ui/A.qml", SOURCE, 0, None, 5, set())
    assert problems and "no report" in problems[0]

    problems, _ = judge("ui/A.qml", SOURCE, 255, [seen], 5, set())
    assert problems and "exit 255" in problems[0]

    # The two kinds healthy code produces by the hundred, and remarks.
    quiet = [seen, _warning("unqualified", "Unqualified access"),
             _warning("block-scope-var-declaration", "var declaration in block scope is hoisted to function scope"),
             _warning("unused-imports", "Unused import", kind="info")]
    assert judge("ui/A.qml", SOURCE, 0, quiet, 5, set()) == ([], [])

    # A handler for a signal that does not exist arrives under "unqualified" too.
    _, complaints = judge("ui/A.qml", SOURCE, 0, [seen, _warning("unqualified", 'no matching signal found for handler "onNope"')], 5, set())
    assert [key for key, _ in complaints] == [("ui/A.qml", "unqualified", "oops")]

    # Anything else counts, named by the text qmllint points at.
    _, complaints = judge("ui/A.qml", SOURCE, 0, [seen, _warning("duplicate-property-binding", "Duplicate binding")], 5, set())
    assert [key for key, _ in complaints] == [("ui/A.qml", "duplicate-property-binding", "oops")]
    assert "ui/A.qml:3:5" in complaints[0][1] and "Duplicate binding" in complaints[0][1]


def test_a_config_key_is_checked_against_main_xml():
    """Plasmoid.configuration is a map qmllint knows no keys of, so it calls
    every read a missing member: 156 of them. The key list is in main.xml."""
    judge = _gate().judge
    seen = _warning("unqualified", "Unqualified access", line=5)
    bare = _warning("missing-property", 'Member "volume" not found on type "KConfigPropertyMap"')
    long = _warning("missing-property",
                    'Member "volume" not found on type Plasma::Applet::configuration with type KConfigPropertyMap')
    assert judge("ui/A.qml", SOURCE, 0, [seen, bare, long], 5, {"volume"}) == ([], [])
    problems, complaints = judge("ui/A.qml", SOURCE, 0, [seen, bare], 5, {"loudness"})
    assert complaints == [] and len(problems) == 1
    assert "volume" in problems[0] and "main.xml" in problems[0] and "ui/A.qml:3" in problems[0]
    # A member missing from anything else is named by the member.
    _, complaints = judge("ui/A.qml", SOURCE, 0, [seen, _warning("missing-property", 'Member "noSuchMember" not found on type "QQuickItem"')], 5, set())
    assert [key for key, _ in complaints] == [("ui/A.qml", "missing-property", "noSuchMember")]


def test_the_key_list_is_read_from_the_package(tmp_path):
    pkg = _package(tmp_path, {}, keys=("volume", "lastplay"))
    assert _gate().config_keys(pkg) == {"volume", "lastplay"}


def test_every_row_of_the_real_list_says_why():
    known = _gate().KNOWN
    assert known, "the list of accepted messages was not read: this test checks nothing"
    assert all(len(row) == 5 and row[3] > 0 and len(row[4]) > 20 for row in known), known
    assert len({row[:3] for row in known}) == len(known), "a message is listed twice"
