# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The bug template may only ask for things that exist.

A report form that says "paste the output of X" is worthless — worse than
worthless, it wastes the reporter's goodwill — if X names a tool that is not
there or a flag that does nothing. The old template asked for
`journalctl … | grep -iE 'onair|plasmashell'`, which never caught the widget's
own `[ARP]` lines and said nothing about the audio backend that turned out to
decide issue #10. This test runs every command the template embeds, verbatim,
and fails if one is not runnable.

It checks runnability, not output: on a headless CI box there is no plasmashell
and the journal grep is legitimately empty (grep exits 1, "no match"). What
must never happen is exit 127 (a tool the form names is absent) or 2 (the
command the form prints does not parse) — those are the form lying to a
reporter, and they go red here.
"""

import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / ".github" / "ISSUE_TEMPLATE" / "bug_report.yml"

# The commands the template tells a reporter to run. Kept as an explicit list
# rather than scraped blindly: the test is only honest if a human decided each
# of these is something we actually want a stranger to paste into a terminal.
EMBEDDED = [
    "ls /usr/lib*/qt6/plugins/multimedia/*.so /usr/lib/*/qt6/plugins/multimedia/*.so 2>/dev/null || true",
    "journalctl --user -b --no-pager | grep -iE 'on ?air|\\[ARP\\]|qt\\.multimedia|plasmashell' | tail -80",
]


def test_every_command_the_template_prints_is_actually_in_the_template():
    # The list above and the file cannot drift: each command must appear in the
    # rendered template text, so editing one without the other goes red.
    text = TEMPLATE.read_text(encoding="utf-8")
    # The YAML folds long descriptions across lines; compare on whitespace-
    # collapsed text so a wrapped command still matches.
    flat = re.sub(r"\s+", " ", text)
    for cmd in EMBEDDED:
        needle = re.sub(r"\s+", " ", cmd)
        assert needle in flat, (
            "the template no longer contains this command the test guards:\n  %s\n"
            "update EMBEDDED and the template together" % cmd)


def test_every_command_the_template_prints_is_runnable():
    for cmd in EMBEDDED:
        first = cmd.split()[0]
        assert shutil.which(first), (
            "the bug template tells reporters to run %r, but %s is not on PATH "
            "here — do not ask for a tool that may be absent" % (cmd, first))
        # shell=True is the point: these are the reporter's verbatim pipelines
        # (grep, tail), and EMBEDDED is a hardcoded constant — no external input
        # reaches the shell, so there is nothing to inject.
        p = subprocess.run(  # noqa: S602
            cmd, shell=True, capture_output=True, text=True, timeout=30
        )
        # 0 = ran and matched, 1 = ran and matched nothing (empty journal on a
        # headless box). Anything else means a tool is missing (127) or the
        # command does not parse (2) — the form would be lying to a reporter.
        assert p.returncode in (0, 1), (
            "the template command failed to RUN (exit %d): %s\nstderr: %s"
            % (p.returncode, cmd, p.stderr.strip()[:300]))


def test_the_template_asks_for_the_backend_that_decides_now_playing():
    # Issue #10 was decided entirely by which multimedia plugin Qt loaded, and
    # the old template never asked. Pin that the field and its detection
    # command stay, so the most useful question is not quietly dropped.
    text = TEMPLATE.read_text(encoding="utf-8")
    assert "qt6/plugins/multimedia" in text, (
        "the template stopped asking for the audio backend — the one line that "
        "separates the two mechanisms behind a frozen-titles report")
    assert "[ARP]" in text, (
        "the journal command stopped catching the widget's own [ARP] lines")


def test_triage_doc_exists_and_names_the_backend_split():
    triage = ROOT / "docs" / "TRIAGE.md"
    assert triage.is_file(), "docs/TRIAGE.md is gone — the template points nowhere"
    body = triage.read_text(encoding="utf-8")
    for token in ("ffmpeg", "gstreamer", "[ARP]", "#10"):
        assert token in body.lower() or token in body, (
            "TRIAGE.md no longer explains %r" % token)
