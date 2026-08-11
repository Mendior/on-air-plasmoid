#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Egon Greenberg
#
# SPDX-License-Identifier: LGPL-2.0-or-later

"""Break the widget on purpose and check that the gate notices.

A green suite proves nothing on its own: it can be green because the code is
right, or green because nothing looks at that code. Most mutants here are real
bugs this project has already shipped once, reduced to a single text swap; two
(07, 08b) are the untouched neighbour of a shipped bug — the same wrong edit
one call site over, which their own text says out loud. The gate must go RED
for every one of them; a mutant that survives marks a blind spot, and that
number is the only honest measure of what the tests are worth.

Mutants are stored as text substitutions rather than diffs on purpose — line
numbers drift with every commit and a patch that no longer applies looks
exactly like a mutant that was killed.

A kill only counts against a gate that was green to begin with, so the run
starts with the unmutated tree. Without that control, any unrelated red — a
broken working tree, a missing tool — reads as a perfect score, which is the
same lie in the other direction. Found the day the harness moved machines:
the work machine reported 01 "killed" when the only thing that had gone red
was the line-count ratchet noticing the mutant's own extra line.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MUTANTS_DIR = REPO / "tests" / "mutants"


@dataclass
class Mutant:
    name: str
    summary: str
    history: str
    target: Path
    find: str
    replace: str
    expect: str  # which check is supposed to catch it


def parse(path: Path) -> Mutant:
    """Read one .mut file. Blocks are `key:` followed by indented lines."""
    fields: dict[str, str] = {}
    key: str | None = None
    buf: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.startswith("#"):
            continue
        if raw and not raw[0].isspace() and raw.rstrip().endswith(":"):
            if key is not None:
                fields[key] = "\n".join(buf).strip("\n")
            key = raw.rstrip()[:-1]
            buf = []
        elif key is not None:
            buf.append(raw.removeprefix("  "))
    if key is not None:
        fields[key] = "\n".join(buf).strip("\n")

    missing = {
        "summary",
        "history",
        "target",
        "find",
        "replace",
        "expect",
    } - fields.keys()
    if missing:
        sys.exit(f"{path.name}: missing field(s): {', '.join(sorted(missing))}")

    return Mutant(
        name=path.stem,
        summary=fields["summary"].strip(),
        history=fields["history"].strip(),
        target=REPO / fields["target"].strip(),
        find=fields["find"],
        replace=fields["replace"],
        expect=fields["expect"].strip(),
    )


def apply_to(mut: Mutant, tree: Path) -> str | None:
    """Apply the substitution inside `tree`. Returns an error string, or None."""
    rel = mut.target.relative_to(REPO)
    f = tree / rel
    if not f.is_file():
        return f"target missing: {rel}"
    text = f.read_text(encoding="utf-8")
    hits = text.count(mut.find)
    if hits == 0:
        # The code moved out from under the mutant. That is NOT a kill — it is a
        # mutant that has to be rewritten, and saying so loudly is the point.
        return "anchor not found (code changed — rewrite this mutant)"
    if hits > 1:
        return f"anchor is not unique ({hits} matches — make it longer)"
    f.write_text(text.replace(mut.find, mut.replace), encoding="utf-8")
    return None


def run_gate(tree: Path, quick: bool, active: str = "") -> tuple[bool, str]:
    """Run the gate inside a mutated copy. True = gate stayed green.

    `active` names the mutant applied to this tree. The harness's own anchor
    test needs it: inside a mutated copy the applied mutant's find-text is
    GONE by definition, and without the name every mutant would die on that
    bookkeeping test instead of on a guard that understands the bug.
    """
    cmd = ["./scripts/dev.sh", "lint" if quick else "check"]
    env_note = "lint" if quick else "check"
    env = {**_clean_env(), "QMLLINT": "/usr/lib/qt6/bin/qmllint"}
    if active:
        env["ONAIR_ACTIVE_MUTANT"] = active
    try:
        p = subprocess.run(
            cmd,
            cwd=tree,
            capture_output=True,
            text=True,
            timeout=900,
            env=env,
            check=False,  # a non-zero exit IS the expected outcome here
        )
    except subprocess.TimeoutExpired:
        return False, f"{env_note}: timed out (counts as caught)"
    tail = (p.stdout + p.stderr).strip().splitlines()
    last = tail[-1] if tail else ""
    return p.returncode == 0, f"{env_note}: exit {p.returncode} · {last[:90]}"


def _clean_env() -> dict[str, str]:
    import os

    env = dict(os.environ)
    # A stray QMLTESTRUNNER=none in the shell would flip a real result:
    # tst_nameguard.qml is the ONLY thing that kills 08a, and dev.sh skips
    # the QML tests on that variable. QMLLINT is popped for symmetry, though
    # run_gate pins it to the Qt6 path anyway — none of the current mutants
    # is caught by qmllint (measured: it accepts `function _pad2(final)`).
    env.pop("QMLLINT", None)
    env.pop("QMLTESTRUNNER", None)
    return env


def _copy_tree(dst: Path) -> None:
    shutil.copytree(
        REPO,
        dst,
        ignore=shutil.ignore_patterns(
            ".git", "__pycache__", "*.pyc", ".venv", "node_modules"
        ),
        symlinks=True,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--quick",
        action="store_true",
        help="run dev.sh lint instead of dev.sh check (faster, weaker)",
    )
    ap.add_argument("--only", help="run a single mutant by name")
    ap.add_argument("--list", action="store_true", help="list mutants and exit")
    ap.add_argument(
        "--trust-green",
        action="store_true",
        help="skip the unmutated control run (only when the gate just passed)",
    )
    ap.add_argument(
        "--check-baseline",
        action="store_true",
        help="exit nonzero only on a REGRESSION vs tests/mutants_baseline.json "
        "(a mutant that was being killed now survives); the documented "
        "survivors staying alive is green. For the nightly CI job.",
    )
    args = ap.parse_args()

    files = sorted(MUTANTS_DIR.glob("*.mut"))
    if not files:
        sys.exit(f"no mutants in {MUTANTS_DIR}")
    mutants = [parse(f) for f in files]
    if args.only:
        mutants = [m for m in mutants if m.name == args.only]
        if not mutants:
            sys.exit(f"no such mutant: {args.only}")

    if args.list:
        for m in mutants:
            print(f"{m.name:32} {m.summary}")
        return 0

    killed, survived, broken = [], [], []
    print(
        f"Running {len(mutants)} mutant(s) against dev.sh "
        f"{'lint' if args.quick else 'check'}\n"
    )

    # The control: the same gate on the same tree, nothing mutated. A red here
    # makes every "killed" below meaningless, so the run refuses to continue.
    if args.trust_green:
        print("  (control run skipped on --trust-green)\n")
    else:
        print(f"  {'unmutated control':32} ", end="", flush=True)
        with tempfile.TemporaryDirectory(prefix="onair-mutant-") as tmp:
            tree = Path(tmp) / "tree"
            _copy_tree(tree)
            green, note = run_gate(tree, args.quick)
        if not green:
            print(f"RED      {note}")
            print("\nThe gate is red before any mutation. Fix that first —")
            print("against a red gate every mutant reads as killed.")
            return 2
        print(f"green    {note}\n")

    for m in mutants:
        print(f"  {m.name:32} ", end="", flush=True)
        with tempfile.TemporaryDirectory(prefix="onair-mutant-") as tmp:
            tree = Path(tmp) / "tree"
            # Copy the working tree, not a git checkout: the mutant has to face
            # the code as it stands right now, including uncommitted work.
            _copy_tree(tree)
            err = apply_to(m, tree)
            if err:
                print(f"BROKEN   {err}")
                broken.append((m, err))
                continue
            green, note = run_gate(tree, args.quick, active=m.name)
            if green:
                print(f"SURVIVED {note}")
                survived.append((m, note))
            else:
                print(f"killed   {note}")
                killed.append((m, note))

    total = len(killed) + len(survived)
    print(f"\n  {len(killed)}/{total} killed", end="")
    if broken:
        print(f" · {len(broken)} broken (anchor moved)", end="")
    print()

    if survived:
        print("\nSurvived — the gate does not look at these:")
        for m, _ in survived:
            print(f"  · {m.name}: {m.summary}")
            print(f"      was expected to trip: {m.expect}")
            print(f"      real incident: {m.history}")
    if broken:
        print("\nBroken — rewrite the anchor, do not count these:")
        for m, err in broken:
            print(f"  · {m.name}: {err}")

    if args.check_baseline:
        return _baseline_verdict(
            {m.name for m, _ in survived}, {m.name for m, _ in broken}
        )

    # Survivors are the finding, not a failure of this script. Exit 1 so the
    # number can gate a ratchet later, once the baseline is known.
    return 1 if survived or broken else 0


def _baseline_verdict(survived: set, broken: set) -> int:
    """Green while the survivors stay within the documented blind-spot list.

    A NEW survivor means a guard that used to catch its bug no longer does —
    the whole reason the nightly run exists. A documented survivor that got
    killed is good news and asks for the baseline to tighten. A broken anchor
    proves nothing and is a failure here, same as in the ordinary gate.
    """
    import json

    path = REPO / "tests" / "mutants_baseline.json"
    expected = set(json.loads(path.read_text(encoding="utf-8"))["expected_survivors"])

    regressed = survived - expected
    recovered = expected - survived - broken

    if recovered:
        print(
            "\nGood news — these blind spots are now covered; drop them from "
            "tests/mutants_baseline.json in the commit that added the test:"
        )
        for name in sorted(recovered):
            print(f"  · {name}")

    if not regressed and not broken:
        print(f"\nBaseline holds: {len(survived)} survivor(s), all documented.")
        return 0

    if regressed:
        print("\nREGRESSION — a mutant that used to be caught now survives:")
        for name in sorted(regressed):
            print(f"  · {name} — a guard lost its teeth; find what changed")
    if broken:
        print("\nBROKEN anchors block the verdict — rewrite them:")
        for name in sorted(broken):
            print(f"  · {name}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
