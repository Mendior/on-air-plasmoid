# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The mutation harness gets the same treatment it hands out.

Everything here is fast — no gate runs. The slow proof (a mutated tree turns
the gate red) stays scripts/mutants.py's own job; what these tests pin is the
harness bookkeeping that a 20-minute run would otherwise discover late or,
worse, not at all: anchors that rotted, a mutant that fakes its kill through
the size ratchet, an expect field that points at a test which does not exist.
"""

import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MUTANTS_DIR = ROOT / "tests" / "mutants"


def _harness():
    spec = importlib.util.spec_from_file_location(
        "mutants", ROOT / "scripts" / "mutants.py"
    )
    mod = importlib.util.module_from_spec(spec)
    # dataclass introspection needs the module registered before exec.
    sys.modules["mutants"] = mod
    spec.loader.exec_module(mod)
    return mod


def _all(mod):
    files = sorted(MUTANTS_DIR.glob("*.mut"))
    assert files, "no mutants found"
    return [mod.parse(f) for f in files]


def test_every_mutant_parses_whole():
    mod = _harness()
    for m in _all(mod):
        for field in ("summary", "history", "find", "replace", "expect"):
            assert getattr(m, field).strip(), f"{m.name}: empty {field}"
        assert m.target.is_file(), f"{m.name}: target missing: {m.target}"


def test_every_anchor_still_bites_exactly_once():
    """Anchor rot answered in a second, not after a 20-minute run.

    mutants.py reports a moved anchor as BROKEN at run time, which is honest
    but late. Here the same drift is a red unit test in the ordinary gate, in
    the same commit that moved the code out from under the anchor.

    Inside a mutated copy the applied mutant's find-text is gone BY DESIGN —
    the harness names that mutant in ONAIR_ACTIVE_MUTANT, and for it the
    replacement must sit there instead. Without this, the first run of the
    new harness killed 9/9: every mutant died on this very test, not on a
    guard that knows anything about its bug (measured 2026-08-09).
    """
    import os

    mod = _harness()
    active = os.environ.get("ONAIR_ACTIVE_MUTANT", "")
    for m in _all(mod):
        text = m.target.read_text(encoding="utf-8")
        needle = m.replace if m.name == active else m.find
        hits = text.count(needle)
        assert hits == 1, (
            f"{m.name}: anchor found {hits} times in {m.target.name} — "
            "rewrite the mutant in the commit that moved the code"
        )


def test_no_mutant_on_a_ratcheted_file_grows_it():
    """A mutant that adds net lines to a size-ratcheted file fakes its kill.

    Measured 2026-08-09: mutant 01 carried one extra line, main.qml stood
    exactly on its 9520-line ceiling, and the run reported "killed" — by
    test_the_two_big_files_do_not_grow, which knows nothing about metadata
    latches. A kill must come from a guard that understands the bug, so on
    these files a mutant may keep or shrink the line count, never raise it.
    """
    mod = _harness()
    ratchet = json.loads(
        (ROOT / "tests" / "ratchet.json").read_text(encoding="utf-8")
    )
    capped = {ROOT / rel for rel in ratchet["lines"]}
    for m in _all(mod):
        if m.target not in capped:
            continue
        grow = len(m.replace.splitlines()) - len(m.find.splitlines())
        assert grow <= 0, (
            f"{m.name}: replacement adds {grow} line(s) to {m.target.name}, "
            "which sits under a line-count ratchet — the size lock would fake "
            "this kill. Keep the substitution line-neutral."
        )


def test_apply_refuses_a_missing_or_ambiguous_anchor(tmp_path):
    mod = _harness()
    m = _all(mod)[0]
    rel = m.target.relative_to(ROOT)
    scratch = tmp_path / rel
    scratch.parent.mkdir(parents=True)

    scratch.write_text("nothing to see here", encoding="utf-8")
    err = mod.apply_to(m, tmp_path)
    assert err and "anchor not found" in err

    scratch.write_text(m.find + "\n" + m.find, encoding="utf-8")
    err = mod.apply_to(m, tmp_path)
    assert err and "not unique" in err


def test_every_named_expectation_exists():
    """An expect field may describe a wish, but a PATH it names must be real.

    The suite's convention: mutants whose killer exists name it by path
    (03, 05, 06, 08a, 08b); mutants whose killer is still to be written say
    so in words. What must never happen is a path or test name that points
    at nothing — a survivor report would then print a diagnosis nobody can
    follow.
    """
    mod = _harness()
    for m in _all(mod):
        for rel in re.findall(r"tests/[\w./-]+\.(?:py|qml)", m.expect):
            assert (ROOT / rel).is_file(), f"{m.name}: expect names missing {rel}"
        for rel, fn in re.findall(r"(tests/[\w./-]+\.(?:py|qml))::(\w+)", m.expect):
            body = (ROOT / rel).read_text(encoding="utf-8")
            # QML tests declare `function test_x()`, python ones `def test_x(`.
            # The name check used to cover .py alone, so a mutant naming a QML
            # killer had only its FILE verified — rename the test and the
            # survivor report would point at nothing.
            decl = f"def {fn}(" if rel.endswith(".py") else f"function {fn}("
            assert decl in body, (
                f"{m.name}: expect names {rel}::{fn}, which is not defined there"
            )
