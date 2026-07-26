# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Placeholder integrity for the translation catalogs.

msgfmt --check only validates placeholders on entries carrying a format
flag, and the xgettext shipping here does not know kde-format — so a
translation that drops or corrupts a %1 would sail through the gate and
ship a broken string. This check is toolchain-independent: every %N in
the English source must appear in the translation, and the translation
must not invent one the source lacks.
"""
import re
from pathlib import Path

PO_DIR = Path(__file__).resolve().parent.parent / "po"
PLACEHOLDER = re.compile(r"%\d")


def _entries(text):
    """Yield (msgid, msgstr) pairs, multiline strings joined."""
    blocks = re.split(r"\n\n+", text)
    for block in blocks:
        if '#~' in block:  # obsolete entries do not ship
            continue
        m_id = re.search(r'msgid\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        m_str = re.search(r'msgstr\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        if not m_id or not m_str:
            continue
        join = lambda s: "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', s))
        yield join(m_id.group(1)), join(m_str.group(1))


def test_every_translated_placeholder_matches_the_source():
    po_files = sorted(PO_DIR.glob("*.po"))
    assert po_files, "no catalogs found"
    problems = []
    for po in po_files:
        for msgid, msgstr in _entries(po.read_text(encoding="utf-8")):
            if not msgid or not msgstr:  # header / untranslated
                continue
            want = sorted(set(PLACEHOLDER.findall(msgid)))
            got = sorted(set(PLACEHOLDER.findall(msgstr)))
            if want != got:
                problems.append(f"{po.name}: {msgid[:60]!r} has {want} but translation has {got}")
    assert not problems, "\n".join(problems)
