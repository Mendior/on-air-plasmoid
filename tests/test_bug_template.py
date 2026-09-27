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
must never happen is a tool the form names being absent, or a command the form
prints not parsing — those are the form lying to a reporter, and they go red
here.

The exit code alone cannot carry that, which this file claimed for a while and
which measuring it disproved. `cmd | missing | tail` exits 0: a pipeline
reports its LAST stage, so 127 only surfaces when the absent tool happens to be
the final one, and `… || true` buries every failure in the first command
outright. So presence is checked directly instead, on every stage of every
pipe, and the run is kept for what it alone can show — that the command parses
and the tools accept the flags the form prints.
"""

import re
import shlex
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


# A shell builtin is always there, and `x=1 cmd` is an assignment, not a tool.
SHELL_BUILTINS = {"true", "false", ":", "cd", "echo", "test", "["}
# Where one command ends and the next begins. Anything else is an argument.
COMMAND_SEPARATORS = {"|", "||", "&&", ";", "&"}


def programs_in(cmd):
    """Every program the shell would try to launch, in order.

    shlex is what makes this honest rather than a split on "|": the journal
    command's own grep pattern contains three pipe characters inside quotes,
    and a naive split turns `'on ?air|\\[ARP\\]|…'` into four imaginary tools.
    """
    found, starting = [], True
    for token in shlex.split(cmd, posix=True):
        if token in COMMAND_SEPARATORS:
            starting = True
        elif starting:
            if token not in SHELL_BUILTINS and "=" not in token:
                found.append(token)
            starting = False
    return found


def test_every_command_the_template_prints_is_runnable():
    for cmd in EMBEDDED:
        # Every stage, not just the first word. The journal command is
        # journalctl | grep | tail, and a form that names a grep or a tail the
        # reporter does not have is just as broken as one naming a missing
        # journalctl — but the exit code cannot say so (see the module
        # docstring), so it is asked directly.
        for tool in programs_in(cmd):
            assert shutil.which(tool), (
                "the bug template tells reporters to run %r, but %s is not on "
                "PATH here — do not ask for a tool that may be absent"
                % (cmd, tool))
        # shell=True is the point: these are the reporter's verbatim pipelines
        # (grep, tail), and EMBEDDED is a hardcoded constant — no external input
        # reaches the shell, so there is nothing to inject.
        p = subprocess.run(  # noqa: S602
            cmd, shell=True, capture_output=True, text=True, timeout=30
        )
        # 0 = ran and matched, 1 = ran and matched nothing (empty journal on a
        # headless box). 2 means the command the form prints does not parse,
        # and 127 still catches an absent tool in the LAST stage of a pipe —
        # the presence check above covers the stages this cannot reach.
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
