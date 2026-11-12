# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""A member read through an object of another file has to exist in that file.

qmllint checks `root.volume` only where it knows what `root` is, and it knows
that in main.qml alone. FullRepresentation.qml reads main.qml through `root.`
662 times and SyncEngine.qml through `app.` 146 times, and a misspelt name
behind either is reported by nothing. Planted on 2026-11-12:
`root.sedaLiigetEiOleOlemas()` in FullRepresentation.qml drew "Unqualified
access" for `root`, which every such line draws, and not a word about the
member; `app.sedaLiigetEiOleOlemas()` in SyncEngine.qml drew nothing; the lint
stayed green. In a binding such a read is `undefined` without a word, in a
handler it throws when its branch is first taken.

So the names are followed by hand. For every QML file of the package this
finds `<name>.<member>` where `<name>` is known, from the code that wires the
files together, to be an object of another file:

  * an id of the file that creates this one, or of the file that creates
    that one: `root` in every file main.qml loads, `fullRepresentation`,
    `stationsModel`, `playerWindow`;
  * a root property of such a file that holds one (`root.sync` is
    `syncEngine`, so `root.sync.lag` is looked up in SyncEngine.qml);
  * a root property of the file itself, by what every place that creates the
    file binds it to: `app: root`, `engine: timeshift`, `kind: streamKind`,
    `cfg: Plasmoid.configuration` (looked up in main.xml).

The member has to be a property, an alias, a function or a signal declared at
the root of that file, or one the root's type is listed with in INHERITED.

What this does not look at. The first four are counted, and the count is
printed when this file is run by itself:
  * an object whose type is Qt's (`playMusic.position` through `player`,
    `historyModel.count`): qmllint knows those types inside their own file,
    nothing knows them across files;
  * what a root property holds when that is not another file's object (a JS
    object or array in a `var`, a number, a string);
  * attached types and enums (`root.Plasmoid`, `fullRepresentation.Window`);
  * a name a function also uses for a parameter or a local, inside that
    function;
  * anything not written as a dotted name: `root[key]`, what a call returns,
    model roles, the text of a template literal, and the JS libraries
    (test_invariants has those).
"""

from __future__ import annotations

import functools
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
CONTENTS = ROOT / "package" / "contents"


@dataclass
class Verdict:
    problems: list[str] = field(default_factory=list)
    # (file, name, where it leads) -> members looked up
    checked: Counter = field(default_factory=Counter)
    # why a reference was not looked up -> how many
    skipped: Counter = field(default_factory=Counter)
    # (file, name) -> why the name could not be tied to one object
    left_out: dict = field(default_factory=dict)
    # (file, name, Qt's type) -> reads not looked up because the object is Qt's
    qt: Counter = field(default_factory=Counter)


# What a root has without declaring it, by the type it is written as. Only
# what the package reads today is listed, each name looked up in the type
# descriptions Qt and Plasma install (plugins.qmltypes of QtQuick and
# QtQml.Models, plasmoidplugin.qmltypes) on 2026-11-12.
INHERITED = {
    "Item": {"width", "height", "forceActiveFocus"},   # QQuickItem
    "PlasmoidItem": {"expanded"},                      # PlasmoidItem, whose prototype is QQuickItem
    "Window": {"requestActivate"},                     # QWindow
    "ListModel": {"count", "get"},                     # QQmlListModel
}
# Which of those lists a root written as this type draws on.
ROOT_IS = {
    "PlasmoidItem": ("PlasmoidItem", "Item"),
    "Representation": ("Item",),   # PlasmaExtras.Representation.qml is a PlasmaComponents.Page, an Item
    "Item": ("Item",),
    "Window": ("Window",),
    "ListModel": ("ListModel",),
    "QtObject": (),
}

_TOKEN = re.compile(r"//[^\n]*|/\*.*?\*/|'(?:\\.|[^'\\\n])*'|\"(?:\\.|[^\"\\\n])*\"|`(?:\\.|[^`\\])*`|/", re.S)
_BEFORE_REGEX = re.compile(r"(?:^|[(,=:\[!&|?{};+\-*%<>~^]|\b(?:return|typeof|case|in|of|void|delete))\s*$")
_REGEX_BODY = re.compile(r"/(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\n\[])+/")
_BREAK = re.compile(r"[{};\n]")
_OBJECT = re.compile(r"([A-Za-z_][\w.]*)\s*$")
_MODS = r"\s*(?:(?:default|required|readonly)\s+)*property\s+"
_ALIAS = re.compile(_MODS + r"alias\s+(\w+)\s*:\s*(.*)$")
_PROPERTY = re.compile(_MODS + r"(?:list<[\w.]+>|[\w.]+)\s+(\w+)\s*(?::\s*(.*))?$", re.S)
_PROPERTY_HEAD = re.compile(_MODS + r"(?:list<[\w.]+>|[\w.]+)\s+(\w+)\s*:")
_FUNCTION = re.compile(r"\s*function\s+(\w+)\s*\(")
_SIGNAL = re.compile(r"\s*signal\s+(\w+)")
_ID = re.compile(r"\s*id\s*:\s*(\w+)\s*$")
_BINDING = re.compile(r"\s*([a-z]\w*)\s*:\s*(.+?)\s*$", re.S)
_FUNCTION_HEAD = re.compile(r"\bfunction\b[^(]*\(([^)]*)\)\s*$|(?:\(([^()]*)\)|\b([A-Za-z_]\w*))\s*=>\s*$")
_LOCAL = re.compile(r"(?<![\w.])(?:var|let|const)\s+([A-Za-z_]\w*)|(?<![\w.])(?:var|let|const)\s*[\[{]([^\]}]*)[\]}]|\bcatch\s*\(\s*(\w+)")
_BARE_ARROW = re.compile(r"(?:\(([^()]*)\)|\b([A-Za-z_]\w*))\s*=>(?!\s*\{)")
_DIR_IMPORT = re.compile(r'^import\s+"([^"]+)"\s+as\s+(\w+)', re.M)
_PATH = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*")
_WORD = re.compile(r"[A-Za-z_]\w*")


def _code(src: str) -> str:
    """The source at the same length and with the same line breaks, with
    comments, the insides of strings and regex literals blanked."""
    out, last = [], 0
    pos = 0
    while True:
        m = _TOKEN.search(src, pos)
        if not m:
            break
        text = m.group(0)
        if text == "/":
            body = _REGEX_BODY.match(src, m.start()) if _BEFORE_REGEX.search(src[max(0, m.start() - 40):m.start()]) else None
            if not body:
                pos = m.end()
                continue
            text, end = body.group(0), body.end()
        else:
            end = m.end()
        keep = 1 if text[0] in "'\"`/" and not text.startswith(("//", "/*")) else 0
        out.append(src[last:m.start() + keep])
        out.append(re.sub(r"[^\n]", " ", src[m.start() + keep:end - keep]))
        last = pos = end - keep
        pos = end
    out.append(src[last:])
    return "".join(out)


class _File:
    """One QML file: its root's type and id, what the root declares, every
    id with the type it sits on, every object written with its bindings, and
    where a function's parameters and locals hold."""

    def __init__(self, name: str, src: str) -> None:
        self.name = name
        self.code = _code(src)
        self.aliases = {alias for path, alias in _DIR_IMPORT.findall(src) if not path.endswith(".js")}
        self.root_type = ""
        self.members: dict[str, str | None] = {}   # property -> its initializer ("" for none), function or signal -> None
        self.ids: dict[str, str] = {}              # id -> type of its object, "" for the root
        self.sites: list[tuple[str, dict[str, str]]] = []
        self.scopes: list[tuple[int, int, set[str]]] = []
        self._parse()

    def _parse(self) -> None:
        code = self.code
        stack: list[list] = []       # [is an object, type, bindings, start of a scope or -1, names of the scope]
        start = 0
        for m in _BREAK.finditer(code):
            at, c = m.start(), m.group(0)
            text = code[start:at]
            if c == "{":
                self._head(text, stack)
                word = _OBJECT.search(text)
                name = word.group(1) if word else ""
                last = name.rsplit(".", 1)[-1]
                if name and last[:1].isupper() and not re.search(r"\b(?:class|new|enum)\s+[\w.]+\s*$", text):
                    ours = "." not in name or name.rsplit(".", 1)[0] in self.aliases
                    if not stack:
                        self.root_type = name
                    elif stack[-1][0]:
                        b = re.match(r"\s*(\w+)\s*:\s*[\w.]+\s*$", text)
                        if b:
                            stack[-1][2][b.group(1)] = "<a " + last + ">"
                    stack.append([True, last if ours else name if "." in name else "." + name, {}, -1, set()])
                else:
                    f = _FUNCTION_HEAD.search(text)
                    scope = bool(f) or not stack or stack[-1][0]
                    names = set(_WORD.findall(" ".join(g for g in f.groups() if g))) if f else set()
                    stack.append([False, "", {}, at if scope else -1, names])
            elif c == "}":
                self._statement(text, stack)
                if stack:
                    frame = stack.pop()
                    if frame[0]:
                        self.sites.append((frame[1], frame[2]))
                    elif frame[3] >= 0:
                        self.scopes.append((frame[3], at, frame[4]))
            else:
                self._statement(text, stack)
            start = at + 1
        for m in _LOCAL.finditer(code):
            inner = min((s for s in self.scopes if s[0] < m.start() < s[1]), key=lambda s: s[1] - s[0], default=None)
            if inner:
                inner[2].update(_WORD.findall(" ".join(g for g in m.groups() if g)))
        for m in _BARE_ARROW.finditer(code):
            line_end = code.find("\n", m.end())
            self.scopes.append((m.end(), len(code) if line_end < 0 else line_end, set(_WORD.findall(m.group(1) or m.group(2) or ""))))

    def _head(self, text: str, stack: list[list]) -> None:
        """What stands before a brace when the root declares something:
        `function f() {`, `property var m: ({`, `property Item x: Item {`."""
        if len(stack) != 1 or not stack[0][0]:
            return
        f = _FUNCTION.match(text)
        if f:
            self.members[f.group(1)] = None
            return
        p = _PROPERTY_HEAD.match(text)
        if p:
            self.members.setdefault(p.group(1), "{")

    def _statement(self, text: str, stack: list[list]) -> None:
        if not stack or not stack[-1][0] or not text.strip():
            return
        i = _ID.match(text)
        if i:
            self.ids[i.group(1)] = "" if len(stack) == 1 else stack[-1][1]
            return
        if len(stack) == 1:
            a = _ALIAS.match(text)
            if a:
                self.members[a.group(1)] = a.group(2).strip()
                return
            p = _PROPERTY.match(text)
            if p:
                self.members[p.group(1)] = (p.group(2) or "").strip()
                return
            f = _FUNCTION.match(text) or _SIGNAL.match(text)
            if f:
                self.members[f.group(1)] = None
                return
        b = _BINDING.match(text)
        if b:
            stack[-1][2][b.group(1)] = b.group(2)

    def hidden(self, name: str, at: int) -> bool:
        """Is `name` at this place a parameter or a local of a function?"""
        return any(s < at < e and name in names for s, e, names in self.scopes)


@functools.cache
def _read(name: str, src: str) -> _File:
    return _File(name, src)


class _Package:
    def __init__(self, sources: dict[str, str]) -> None:
        self.files = {name: _read(name, src) for name, src in sources.items()}
        self.types = {name.rsplit("/", 1)[-1][:-4]: name for name in self.files if re.fullmatch(r"ui/[^/]+\.qml", name)}
        self.makers: dict[str, set[str]] = {name: set() for name in self.files}
        for name, f in self.files.items():
            for kind, _ in f.sites:
                if kind in self.types and self.types[kind] != name:
                    self.makers[self.types[kind]].add(name)

    # A target is ("file", path), ("config",), ("qt", type), or None for "cannot tell".

    def expr(self, text: str, where: str, seen: tuple = ()) -> tuple | None:
        """The object an expression written in file `where` names."""
        text = text.strip()
        if (where, text) in seen:
            return None
        seen = (*seen, (where, text))
        if text in ("Plasmoid.configuration", "plasmoid.configuration"):
            return ("config",)
        if not _PATH.fullmatch(text):
            return None
        head, _, rest = text.partition(".")
        found = self.name(head, where, seen)
        target = next(iter(found)) if len(found) == 1 else None
        while rest and target and target[0] == "file":
            member, _, rest = rest.partition(".")
            target = self.member(member, target[1], seen)
        return None if rest else target

    def member(self, member: str, where: str, seen: tuple = ()) -> tuple | None:
        """The object a root property of file `where` holds."""
        init = self.files[where].members.get(member)
        if init is None or init == "{":
            return None
        held = self.expr(init, where, seen) if init else None
        if held is None:
            # nothing of its own, or a placeholder like null: what it is given counts
            given = self.given(member, where)
            held = given[0] if given and len(given) == 1 else None
        return held

    def name(self, name: str, where: str, seen: tuple = ()) -> set:
        """What a bare name means in file `where`: its own ids and root
        properties first, then those of each file that creates it."""
        f = self.files[where]
        if name in f.ids:
            kind = f.ids[name]
            return {("file", where) if kind == "" else ("file", self.types[kind]) if kind in self.types else ("qt", kind.lstrip("."))}
        if name in f.members:
            return {self.member(name, where, seen)}
        if not self.makers[where]:
            return {None}
        return set().union(*(self.name(name, maker, seen) for maker in self.makers[where]))

    def given(self, prop: str, where: str) -> list | None:
        """What a root property of file `where` is bound to in the places that
        create the file: the distinct targets, or None when no place binds it."""
        kind = where.rsplit("/", 1)[-1][:-4]
        found = set()
        for name, f in self.files.items():
            for site_kind, bindings in f.sites:
                if site_kind == kind and name != where and prop in bindings:
                    found.add(self.expr(bindings[prop], name))
        return sorted(found, key=str) if found else None

    def names(self, where: str) -> tuple[dict[str, list], dict[str, str]]:
        """{name: targets} for the names file `where` reads another file's
        object through, and {name: why} for those that cannot be tied down."""
        f = self.files[where]
        heads = set(re.findall(r"(?<![\w.$])([A-Za-z_]\w*)\.[A-Za-z_]", f.code))
        found: dict[str, set] = {}
        for prop, init in f.members.items():
            if prop not in heads or init is None:
                continue
            target = self.expr(init, where) if init and init != "{" else None
            if target and target != ("file", where):
                found[prop] = {target}
            elif target is None:
                given = self.given(prop, where)
                if given:
                    found[prop] = set(given)
        up, todo = set(), list(self.makers[where])
        while todo:
            maker = todo.pop()
            if maker not in up:
                up.add(maker)
                todo.extend(self.makers[maker])
        for maker in up:
            m = self.files[maker]
            for n in (set(m.ids) | {k for k, v in m.members.items() if v}) & heads:
                if n not in f.ids and n not in f.members and n not in found:
                    found[n] = self.name(n, where)
        tied, loose = {}, {}
        for n, targets in found.items():
            if None not in targets and (len(targets) == 1 or all(t[0] == "file" for t in targets)):
                tied[n] = sorted(targets)
            elif targets != {None}:
                loose[n] = "it is not the same kind of object in every place that creates this file: " + ", ".join(
                    sorted("nothing known" if t is None else " ".join(t) for t in targets))
        return tied, loose

    def has(self, member: str, where: str) -> tuple[bool, str]:
        """Does the root of file `where` have this member, and if not, what to say."""
        f = self.files[where]
        kind = f.root_type.rsplit(".", 1)[-1]
        inherited = set().union(*(INHERITED[k] for k in ROOT_IS.get(kind, ()))) if kind in ROOT_IS else set()
        if member in f.members or member in inherited:
            return True, ""
        if member.endswith("Changed") and len(member) > 7 and (member[:-7] in f.members or member[:-7] in inherited):
            return True, ""
        why = f"{member!r} is not a property, function or signal at the root of {where} ({f.root_type})"
        if kind in ROOT_IS:
            return False, why + " and is not listed for that type in INHERITED"
        return False, why + f"; INHERITED has no list for a root written as {f.root_type}, add one if the type has it"


def check(sources: dict[str, str], keys: set[str]) -> Verdict:
    """Every cross-file member read in `sources` (path under contents/ ->
    text) against the file it leads to; `keys` are main.xml's."""
    package = _Package(sources)
    verdict = Verdict()
    for where in sorted(package.files):
        f = package.files[where]
        tied, loose = package.names(where)
        for n, why in loose.items():
            verdict.left_out[(where, n)] = why
        if not tied:
            continue
        pattern = re.compile(r"(?<![\w.$])(%s)((?:\.[A-Za-z_]\w*)+)" % "|".join(sorted(map(re.escape, tied), key=len, reverse=True)))
        for m in pattern.finditer(f.code):
            name, members = m.group(1), m.group(2)[1:].split(".")
            if f.hidden(name, m.start()):
                verdict.skipped["a local of the same name"] += 1
                continue
            line = f.code.count("\n", 0, m.start()) + 1
            targets = tied[name]
            for depth, member in enumerate(members):
                written = ".".join([name, *members[:depth + 1]])
                if targets[0][0] == "qt":
                    verdict.skipped["a Qt type"] += 1
                    verdict.qt[(where, name, targets[0][1])] += 1
                    break
                if member[:1].isupper():
                    verdict.skipped["an attached type or an enum"] += 1
                    break
                if targets[0][0] == "config":
                    verdict.checked[(where, name, "main.xml")] += 1
                    if member not in keys:
                        verdict.problems.append(f"{where}:{line}: {written} — main.xml declares no key {member!r}")
                    break
                verdict.checked[(where, name, " + ".join(t[1] for t in targets))] += 1
                bad = [why for ok, why in (package.has(member, t[1]) for t in targets) if not ok]
                if bad:
                    verdict.problems.append(f"{where}:{line}: {written} — " + "; ".join(bad))
                    break
                held = package.member(member, targets[0][1]) if len(targets) == 1 else None
                if held is None:
                    if depth + 1 < len(members):
                        verdict.skipped["what a property holds"] += 1
                    break
                targets = [held]
    return verdict


def shipped() -> tuple[dict[str, str], set[str]]:
    sources = {p.relative_to(CONTENTS).as_posix(): p.read_text(encoding="utf-8") for p in sorted(CONTENTS.rglob("*.qml"))}
    xml = (CONTENTS / "config" / "main.xml").read_text(encoding="utf-8")
    return sources, set(re.findall(r'<entry\s+name="(\w+)"', xml))


@pytest.fixture(scope="module")
def tree():
    return shipped()


# The wires this check stands on, and the fewest reads each must find. The
# numbers are about half of what was there on 2026-11-12 (662, 146, 103, …):
# a wire that stops resolving reads as a file with nothing wrong in it.
WIRES = {
    ("ui/FullRepresentation.qml", "root", "ui/main.qml"): 300,
    ("ui/FullRepresentation.qml", "root", "ui/SyncEngine.qml"): 30,
    ("ui/MediaListItem.qml", "root", "ui/main.qml"): 20,
    ("ui/EpisodeListItem.qml", "root", "ui/main.qml"): 20,
    ("ui/CompactRepresentation.qml", "root", "ui/main.qml"): 15,
    ("ui/SyncEngine.qml", "app", "ui/main.qml"): 70,
    ("ui/SyncEngine.qml", "cfg", "main.xml"): 50,
    ("ui/TimeshiftEngine.qml", "app", "ui/main.qml"): 25,
    ("ui/PodcastEngine.qml", "app", "ui/main.qml"): 30,
    ("ui/AlarmEngine.qml", "app", "ui/main.qml"): 50,
    ("ui/StreamKind.qml", "engine", "ui/TimeshiftEngine.qml"): 4,
    ("ui/StandWatch.qml", "engine", "ui/TimeshiftEngine.qml"): 2,
    ("ui/Loudness.qml", "kind", "ui/StreamKind.qml"): 1,
    ("ui/CoverTouch.qml", "face", "ui/FullRepresentation.qml"): 1,
    ("ui/PopupFace.qml", "house", "ui/PlayerWindow.qml"): 1,
    ("ui/main.qml", "sync", "ui/SyncEngine.qml"): 5,
    ("ui/LogoHunt.qml", "app", "ui/config/configGeneral.qml + ui/main.qml"): 4,
}


# A name that is used like an object of another file where the wiring does not
# settle which: one place that creates the file passes something this test
# cannot follow. Listed here with the reason, it is left alone; unlisted, it
# fails the test, so coverage cannot shrink without a line saying so.
LEFT_OUT: dict[tuple[str, str], str] = {}


def test_the_shipped_files_read_no_member_that_is_not_there(tree):
    verdict = check(*tree)
    assert not verdict.problems, "\n" + "\n".join(verdict.problems)
    short = {wire: (verdict.checked[wire], least) for wire, least in WIRES.items() if verdict.checked[wire] < least}
    assert not short, f"a wire between two files is no longer followed (found, least expected): {short}"
    assert sum(verdict.checked.values()) >= 1000, "fewer than 1000 reads were looked up: this test checks next to nothing"
    assert set(verdict.left_out) == set(LEFT_OUT), (
        f"used like an object of another file, and not tied to one: {verdict.left_out}; LEFT_OUT lists {sorted(LEFT_OUT)}")


def _planted(sources: dict[str, str], name: str, body: str) -> tuple[dict[str, str], int]:
    """`sources` with one more function at the end of a file's root, and the
    line it is on."""
    text = sources[name]
    end = text.rstrip().rfind("}")
    return {**sources, name: text[:end] + "    function zzPlanted() { " + body + " }\n" + text[end:]}, text.count("\n", 0, end) + 1


@pytest.mark.parametrize(
    ("file", "body", "written", "looked_in"),
    [
        ("ui/FullRepresentation.qml", "return root.tsBufering", "root.tsBufering", "ui/main.qml"),
        ("ui/SyncEngine.qml", 'app.notifyy("a", "b", "c")', "app.notifyy", "ui/main.qml"),
        ("ui/FullRepresentation.qml", "return root.sync.calibPhaze", "root.sync.calibPhaze", "ui/SyncEngine.qml"),
        ("ui/StandWatch.qml", "return engine.bufferSecondz", "engine.bufferSecondz", "ui/TimeshiftEngine.qml"),
        ("ui/Loudness.qml", "return kind.isLivee", "kind.isLivee", "ui/StreamKind.qml"),
        ("ui/SyncEngine.qml", "return cfg.combineWantd", "cfg.combineWantd", "main.xml"),
        ("ui/MediaListItem.qml", "return root.playLastt()", "root.playLastt", "ui/main.qml"),
        ("ui/LogoHunt.qml", "return app.nextSeq()", "app.nextSeq", "ui/config/configGeneral.qml"),
    ],
)
def test_a_misspelt_member_is_named_with_its_line_and_the_file_it_was_looked_for_in(tree, file, body, written, looked_in):
    sources, keys = tree
    planted, line = _planted(sources, file, body)
    problems = check(planted, keys).problems
    assert len(problems) == 1, problems
    assert problems[0].startswith(f"{file}:{line}: {written} "), problems
    assert looked_in in problems[0], problems


MAIN = """import QtQuick
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root
    property int volume: 0
    readonly property var sync: syncEngine
    readonly property alias lagAlias: syncEngine.lag
    signal poked(int n)
    function play(url) { return url }
    Item {
        id: inner
        property int deep: 1
    }
    ListModel { id: rows }
    SyncEngine { id: syncEngine; app: root; cfg: Plasmoid.configuration }
    fullRepresentation: Face { }
}
"""

ENGINE = """import QtQuick

Item {
    id: engine
    required property var app
    required property var cfg
    property int lag: 0
    function start() { app.play("x"); return cfg.volume + app.volume }
    %s
}
"""

FACE = """import QtQuick

Item {
    id: face
    function f() { return root.volume + root.sync.lag + sync.lag }
    %s
}
"""


def _small(face: str = "", engine: str = "", **more: str) -> dict[str, str]:
    return {"ui/main.qml": MAIN, "ui/SyncEngine.qml": ENGINE % engine, "ui/Face.qml": FACE % face, **more}


def test_what_is_there_passes_and_is_counted():
    verdict = check(_small(), {"volume"})
    assert verdict.problems == []
    assert verdict.checked == Counter({
        ("ui/Face.qml", "root", "ui/main.qml"): 2,           # root.volume, root.sync
        ("ui/Face.qml", "root", "ui/SyncEngine.qml"): 1,     # root.sync.lag
        ("ui/Face.qml", "sync", "ui/SyncEngine.qml"): 1,     # main's property, come down the context
        ("ui/SyncEngine.qml", "app", "ui/main.qml"): 2,
        ("ui/SyncEngine.qml", "cfg", "main.xml"): 1,
    })
    assert verdict.left_out == {}


@pytest.mark.parametrize(
    ("face", "engine", "names"),
    [
        ("function g() { return root.volumee }", "", "root.volumee"),
        ("", "function g() { return app.plai() }", "app.plai"),
        ("function g() { return root.sync.lagg }", "", "root.sync.lagg"),
        ("", "function g() { return cfg.volumme }", "cfg.volumme"),
        # declared, but on an object inside the root, or only as an id
        ("function g() { return root.deep }", "", "root.deep"),
        ("function g() { return root.inner }", "", "root.inner"),
        # declared, but in the other file
        ("function g() { return root.lag }", "", "root.lag"),
        ("", "function g() { return app.lag }", "app.lag"),
        # through a property that is only given its object where the file is created
        ("function g() { return root.sync.app.volumee }", "", "root.sync.app.volumee"),
        # a change signal of a property that is not there
        ("function g() { root.volumeeChanged.connect(f) }", "", "root.volumeeChanged"),
    ],
)
def test_a_member_has_to_be_at_the_root_of_the_file_the_name_leads_to(face, engine, names):
    problems = check(_small(face, engine), {"volume"}).problems
    assert len(problems) == 1 and f": {names} " in problems[0], problems


def test_signals_change_signals_and_listed_inherited_members_count():
    face = "function g() { root.poked.connect(f); root.volumeChanged.connect(f); return root.expanded ? root.width : root.height }"
    assert check(_small(face), {"volume"}).problems == []
    # ... and only for the type they are listed under: the engine is an Item
    problems = check(_small("function g() { return root.sync.expanded }"), {"volume"}).problems
    assert len(problems) == 1 and "root.sync.expanded" in problems[0], problems


def test_a_root_type_without_a_list_is_asked_for_one():
    lamp = "import QtQuick\n\nRectangle {\n    id: lamp\n    property bool lit: false\n}\n"
    main = MAIN.replace("    ListModel { id: rows }\n", "    ListModel { id: rows }\n    Lamp { id: lamp }\n")
    sources = {**_small("function g() { return lamp.lit ? lamp.radius : 0 }"), "ui/main.qml": main, "ui/Lamp.qml": lamp}
    problems = check(sources, {"volume"}).problems
    assert len(problems) == 1 and "lamp.radius" in problems[0] and "Rectangle" in problems[0] and "INHERITED" in problems[0], problems


def test_what_is_not_looked_up_is_counted_by_reason():
    face = """function g(app) { return app.anything + rows.count + root.Plasmoid.title }
    function h() { var cfg = {}; return cfg.anything }"""
    verdict = check(_small(face), {"volume"})
    assert verdict.problems == []
    assert verdict.skipped["a Qt type"] == 1 and verdict.skipped["an attached type or an enum"] == 1


def test_a_local_of_the_same_name_hides_the_object_only_inside_its_function():
    engine = """function g(app) { return app.anything }
    function h() { var cfg = {}; return cfg.anything }
    function k() { return app.plai() + cfg.volumme }"""
    verdict = check(_small("", engine), {"volume"})
    assert sorted(p.split(" ")[1] for p in verdict.problems) == ["app.plai", "cfg.volumme"], verdict.problems
    assert verdict.skipped["a local of the same name"] == 2


def test_a_name_two_places_give_different_objects_is_checked_against_both_or_left_out_by_name():
    # LogoHunt's case: made in main.qml and on a settings page, each passing its own root
    page = "import QtQuick\nimport \"..\" as ARP\n\nItem {\n    id: root\n    function play(url) { return url }\n    ARP.SyncEngine { app: root }\n}\n"
    both = check(_small("", "function g() { return app.volume }", **{"ui/config/page.qml": page}), {"volume"})
    assert len(both.problems) == 2, both.problems     # app.volume in start() and in g(): main.qml has it, the page does not
    assert all("ui/config/page.qml" in p for p in both.problems), both.problems
    # one place passes something that is no object of a file: the name is out, and said to be
    odd = page.replace("app: root", "app: makeOne()")
    verdict = check(_small(**{"ui/config/page.qml": odd}), {"volume"})
    assert verdict.problems == [] and list(verdict.left_out) == [("ui/SyncEngine.qml", "app")], (verdict.problems, verdict.left_out)


def test_a_type_of_the_same_name_from_a_module_is_not_one_of_ours():
    # Kirigami.Heading is not ui/Heading.qml: taken for it, a settings page
    # became a second home of Heading.qml and `root` in it led nowhere.
    heading = "import QtQuick\n\nItem {\n    id: headingRoot\n    property bool on: root.volume > 0\n}\n"
    page = "import QtQuick\nimport org.kde.kirigami as Kirigami\n\nItem {\n    id: root\n    Kirigami.Heading { }\n}\n"
    main = MAIN.replace("    ListModel { id: rows }\n", "    ListModel { id: rows }\n    Heading { }\n")
    verdict = check({**_small(), "ui/main.qml": main, "ui/Heading.qml": heading, "ui/config/page.qml": page}, {"volume"})
    assert verdict.problems == [] and verdict.checked[("ui/Heading.qml", "root", "ui/main.qml")] == 1 and verdict.left_out == {}


if __name__ == "__main__":
    # python3 tests/test_cross_file_members.py: what was looked at, and what was not
    result = check(*shipped())
    for (file, name, target), n in sorted(result.checked.items()):
        print(f"{n:6d}  {file}: {name}. -> {target}")
    print(f"{sum(result.checked.values()):6d}  member reads looked up, between {len({k[0] for k in result.checked})} files and what they lead to")
    for reason, n in sorted(result.skipped.items()):
        print(f"{n:6d}  not looked up: {reason}")
    for (file, name, kind), n in sorted(result.qt.items()):
        print(f"        {n:4d}  {file}: {name}. is a {kind}")
    for (file, name), why in sorted(result.left_out.items()):
        print(f"        left out: {name} in {file}: {why}")
    print("\n".join(result.problems) or "nothing read that is not there")
