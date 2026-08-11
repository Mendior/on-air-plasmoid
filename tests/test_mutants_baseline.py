# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The mutation baseline names only real, currently-surviving mutants.

The nightly run trusts tests/mutants_baseline.json to say which blind spots
are expected, so a name that rotted out of the mutant set, or a survivor the
file forgot to list, would quietly break the regression check. These are fast
text checks — they do NOT run the 25-minute mutation suite; they keep the
file honest so that when the suite does run, its verdict means something.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MUTANTS_DIR = ROOT / "tests" / "mutants"
BASELINE = json.loads(
    (ROOT / "tests" / "mutants_baseline.json").read_text(encoding="utf-8")
)


def _mutant_names():
    return {p.stem for p in MUTANTS_DIR.glob("*.mut")}


def test_every_expected_survivor_is_a_real_mutant():
    names = _mutant_names()
    for name, reason in BASELINE["expected_survivors"].items():
        assert name in names, (
            "mutants_baseline.json expects %r to survive, but no such .mut "
            "file exists — remove it or fix the name" % name)
        assert reason.strip(), (
            "%s is listed with no reason — a blind spot without a reason is "
            "just a hole nobody has to justify" % name)


def test_the_baseline_is_not_the_whole_set():
    # If every mutant were expected to survive, the suite would prove nothing.
    # The baseline must be a strict subset — some mutants MUST be killed.
    expected = set(BASELINE["expected_survivors"])
    names = _mutant_names()
    assert expected < names, (
        "the baseline lists every mutant (or an unknown one); at least one "
        "mutant must be expected to die, or the nightly run is toothless")
    assert len(names) - len(expected) >= 1
