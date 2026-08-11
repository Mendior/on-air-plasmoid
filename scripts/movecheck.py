#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Egon Greenberg
#
# SPDX-License-Identifier: LGPL-2.0-or-later

"""Separate what MOVED from what CHANGED in a diff.

Pulling logic out of main.qml produces diffs that are enormous and almost
entirely uninteresting: four hundred lines leave one file and arrive in
another, and somewhere in there are the three lines that were actually
edited. Reading that by eye is how a real change rides into the tree
disguised as a move — and a move is exactly the kind of commit that gets
skimmed, because "it's just a move".

So don't skim it: measure it. Every removed line is matched against the
added lines, ignoring indentation (code lands at a different depth in a
library than it sat at in a QML block). What matches is a move; what is
left over is the real diff, and it is usually short enough to read line
by line.

Two boundaries, said out loud because the first version oversold itself:
lines are matched as a POOL, so ORDER and OWNERSHIP are not checked — a
line that steps outside its if-block still counts as moved. And
punctuation-only lines are kept out of the matching (pairing every `}` in
the tree would bless anything), but their NET count is still balanced: a
brace that appears from nowhere reparents whatever follows it in QML, so
an imbalance blocks the pure-move verdict. For a moved FUNCTION the
--funcs mode compares the brace-balanced body itself, in order, which
closes both gaps for the piece that matters.

    scripts/movecheck.py                     working tree against HEAD
    scripts/movecheck.py --staged            what is about to be committed
    scripts/movecheck.py HEAD~3..HEAD        a range
    scripts/movecheck.py A..B --funcs f,g    those bodies byte-identical?

Exit 0 when the residue is empty (a pure move), 1 when something changed.
Non-zero is not a failure — on a commit that both moves and edits it is
the expected answer, and the listing below it is the thing to read.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Lines that carry no meaning on their own: matching them across files
# would pair up every closing brace in the tree and report a clean move
# for a diff that is nothing of the sort. They are counted, not matched.
NOISE = re.compile(r"^[\s{}()\[\];,]*$")

# The renames a move between main.qml and an engine is ALLOWED to make,
# applied to both sides before comparing: the facade objects change name,
# nothing else may.
CANON = (("root.", "app."), ("Plasmoid.configuration.", "cfg."))


def git_out(args: list[str], ok: tuple[int, ...] = (0,)) -> str:
    p = subprocess.run(
        ["git", *args], cwd=REPO, capture_output=True, text=True, check=False
    )
    if p.returncode not in ok:
        sys.exit("git %s failed: %s" % (args[0], p.stderr.strip()))
    return p.stdout


def git_diff(args: list[str]) -> str:
    return git_out(["diff", "-U0", "--no-color", "--no-ext-diff", *args], ok=(0, 1))


def parse(diff: str) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """Removed and added lines, per file.

    A tiny state machine, because prefixes alone cannot be trusted: a
    removed line `--i;` arrives as `---i;` and a header also starts with
    `---`. Headers only appear between `diff --git` and the first `@@`,
    so inside a hunk everything starting with one `+` or `-` is content —
    the first version dropped such lines and a real edit vanished from
    both pools.
    """
    removed: dict[str, list[str]] = {}
    added: dict[str, list[str]] = {}
    path = ""
    in_hunk = False
    for line in diff.splitlines():
        if line.startswith("diff --git"):
            path, in_hunk = "", False
            continue
        if line.startswith("@@"):
            in_hunk = True
            continue
        if not in_hunk:
            if line.startswith("+++ b/") or (
                line.startswith("--- a/") and not path
            ):
                path = line[6:]
            continue
        if not path:
            continue
        if line.startswith("+"):
            added.setdefault(path, []).append(line[1:])
        elif line.startswith("-"):
            removed.setdefault(path, []).append(line[1:])
        # context lines (" ") and "\ No newline" markers carry nothing here
    return removed, added


def _pools(
    removed: dict[str, list[str]], added: dict[str, list[str]]
) -> tuple[Counter, Counter, int, int]:
    add_pool = Counter(
        ln.strip() for lns in added.values() for ln in lns if not NOISE.match(ln)
    )
    rem_pool = Counter(
        ln.strip() for lns in removed.values() for ln in lns if not NOISE.match(ln)
    )
    noise_rem = sum(1 for lns in removed.values() for ln in lns if NOISE.match(ln))
    noise_add = sum(1 for lns in added.values() for ln in lns if NOISE.match(ln))
    return rem_pool, add_pool, noise_rem, noise_add


def _brace_body(src: str, start: int) -> str | None:
    i = src.find("{", start)
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    return None


def _canon_body(body: str) -> str:
    lines = [ln.strip() for ln in body.splitlines()]
    text = "\n".join(ln for ln in lines if ln)
    for a, b in CANON:
        text = text.replace(a, b)
    return text


def _find_function(rev: str, name: str) -> tuple[str, str] | None:
    """The brace-balanced body of `function name(...)` anywhere in package/.

    Returns (file, canonical body) or None. Two definitions with the same
    name would be a lie waiting to happen, so that case exits loudly.
    """
    files = [
        f
        for f in git_out(["ls-tree", "-r", "--name-only", rev]).splitlines()
        if f.startswith("package/") and f.endswith((".qml", ".js"))
    ]
    pat = re.compile(r"\bfunction\s+%s\s*\(" % re.escape(name))
    hits: list[tuple[str, str]] = []
    for f in files:
        src = git_out(["show", "%s:%s" % (rev, f)])
        for m in pat.finditer(src):
            body = _brace_body(src, m.end())
            if body is not None:
                hits.append((f, _canon_body(body)))
    if len(hits) > 1:
        sys.exit(
            "function %s is defined %d times at %s (%s) — compare by hand"
            % (name, len(hits), rev, ", ".join(f for f, _ in hits))
        )
    return hits[0] if hits else None


def check_funcs(rev_range: str, names: list[str]) -> int:
    if ".." not in rev_range:
        sys.exit("--funcs needs a range like A..B")
    a, b = rev_range.split("..", 1)
    bad = 0
    for name in names:
        left, right = _find_function(a, name), _find_function(b, name)
        if left is None or right is None:
            side = a if left is None else b
            print("  ? %-28s missing at %s" % (name, side))
            bad += 1
            continue
        if left[1] == right[1]:
            print(
                "  = %-28s identical (%s -> %s, modulo indentation and the "
                "facade renames)" % (name, left[0], right[0])
            )
            continue
        bad += 1
        print("  ! %-28s DIFFERS (%s -> %s):" % (name, left[0], right[0]))
        old, new = left[1].splitlines(), right[1].splitlines()
        gone = Counter(old) - Counter(new)
        fresh = Counter(new) - Counter(old)
        for ln in list(gone)[:10]:
            print("      - %s" % ln)
        for ln in list(fresh)[:10]:
            print("      + %s" % ln)
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("range", nargs="?", help="commit range, e.g. HEAD~1..HEAD")
    ap.add_argument("--staged", action="store_true", help="check the index instead")
    ap.add_argument(
        "--funcs",
        metavar="NAMES",
        help="comma-separated function names whose brace-balanced bodies "
        "must be byte-identical across the range (modulo indentation and "
        "the root.->app. / Plasmoid.configuration.->cfg. facade renames)",
    )
    ap.add_argument(
        "--show",
        type=int,
        default=40,
        help="how many residue lines to print (default 40)",
    )
    ap.add_argument(
        "--path",
        action="append",
        default=[],
        metavar="P",
        help="limit to these paths (repeatable). Without it the whole "
        "working tree is compared, and unrelated work in progress "
        "shows up as residue",
    )
    args = ap.parse_args()

    if args.funcs:
        return check_funcs(args.range or "", [n for n in args.funcs.split(",") if n])

    if args.staged:
        diff_args = ["--staged"]
    elif args.range:
        diff_args = [args.range]
    else:
        # A bare `git diff` compares against the INDEX, so the moment a move
        # is staged it reports nothing — the opposite of what this tool is
        # for. HEAD is what the docstring promises.
        diff_args = ["HEAD"]
    if args.path:
        diff_args += ["--", *args.path]
    removed, added = parse(git_diff(diff_args))
    if not removed and not added:
        print("nothing to compare")
        return 0

    # One pool for the whole diff: a move goes from some file to some other
    # file, and which pair it was is not what this tool is for.
    rem_pool, add_pool, noise_rem, noise_add = _pools(removed, added)

    moved = add_pool & rem_pool  # multiset intersection
    gone = rem_pool - add_pool  # left and did not arrive
    fresh = add_pool - rem_pool  # arrived from nowhere

    n_moved, n_gone, n_fresh = (
        sum(moved.values()),
        sum(gone.values()),
        sum(fresh.values()),
    )
    total = n_moved + max(n_gone, n_fresh)

    print("  moved unchanged : %d lines" % n_moved)
    print("  left            : %d lines" % n_gone)
    print("  new             : %d lines" % n_fresh)
    if total:
        print("  → %.0f%% of this diff is a pure move" % (100.0 * n_moved / total))
    if noise_rem or noise_add:
        print(
            "  punctuation-only: %d removed, %d added (matched by count only)"
            % (noise_rem, noise_add)
        )
    print()

    clean = not n_gone and not n_fresh and noise_rem == noise_add
    if clean:
        print("Pure move: every meaningful line that left arrived somewhere else,")
        print("byte for byte (indentation aside), and punctuation stayed balanced.")
        print("Order and ownership are NOT checked here — for a moved function,")
        print("--funcs compares the body itself.")
        return 0

    def dump(pool: Counter, title: str, sign: str) -> None:
        if not pool:
            return
        print("%s — READ THESE:" % title)
        shown = 0
        for line, n in pool.most_common():
            if shown >= args.show:
                print("  … and %d more (raise --show)" % (sum(pool.values()) - shown))
                break
            print("  %s %s%s" % (sign, line, "" if n == 1 else "  (×%d)" % n))
            shown += n
        print()

    dump(gone, "Left without arriving", "-")
    dump(fresh, "Arrived from nowhere", "+")
    if noise_rem != noise_add:
        print(
            "Punctuation-only lines are OFF BY %d (%d removed, %d added) — in"
            % (abs(noise_rem - noise_add), noise_rem, noise_add)
        )
        print("QML a stray brace reparents every binding after it. Find it.")
        print()
    print("This is the real diff. On a commit that claims to be only a move,")
    print("every line above is either a mistake or an undeclared change.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
