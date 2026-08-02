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


_STRINGS = r'((?:"(?:[^"\\]|\\.)*"\s*)+)'


def _join(raw):
    return "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', raw))


def _entries(text):
    """Yield (source, translation) pairs, multiline strings joined.

    A plural entry has one source in two spellings and a translation per
    form, so the source side is both spellings together and each form comes
    back on its own. Matching msgstr on trailing whitespace alone used to
    miss "msgstr[0]" entirely, which left the single plural string in these
    catalogs — and it carries a %1 — as the one nobody was checking.
    """
    for block in re.split(r"\n\n+", text):
        if '#~' in block:  # obsolete entries do not ship
            continue
        m_id = re.search(r'^msgid\s+' + _STRINGS, block, re.MULTILINE)
        if not m_id:
            continue
        source = _join(m_id.group(1))
        m_plural = re.search(r'^msgid_plural\s+' + _STRINGS, block, re.MULTILINE)
        if m_plural:
            source += " " + _join(m_plural.group(1))
        forms = re.findall(r'^msgstr(?:\[\d+\])?\s+' + _STRINGS, block, re.MULTILINE)
        for form in forms:
            yield source, _join(form)


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
