# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The local install's catalogs follow po/.

`install` synced the QML and left contents/locale alone: the install's
catalogs are named after the install's own plugin id, so they cannot be
copied from the package, and they were only ever compiled by a separate
`locale-install` that was easy to forget. Seen on 2026-11-11: the panel ran
that day's code with catalogs 23 messages short in Estonian and 28 in the
other twelve languages, so "Paused", "Back 30 seconds" and "System volume"
stood there in English beside a translated "Stations", while `doctor` said
the install matched the repo.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
DEV = REPO / "scripts" / "dev.sh"
LANGS = sorted(p.stem for p in (REPO / "po").glob("*.po"))

pytestmark = pytest.mark.skipif(any(shutil.which(t) is None for t in ("bash", "rsync", "msgfmt")), reason="the install itself needs rsync and gettext")

STALE_PO = """msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\\n"
"Language: et\\n"

msgid "Stations"
msgstr "Jaamad"
"""


def _tree(tmp_path: Path, plugin: str = "org.kde.plasma.advancedradio") -> Path:
    inst = tmp_path / plugin
    (inst / "contents").mkdir(parents=True)
    meta = json.loads((REPO / "package" / "metadata.json").read_text(encoding="utf-8"))
    meta["KPlugin"]["Id"] = plugin
    (inst / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")
    return inst


def _dev(inst: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(DEV), *args], capture_output=True, text=True, timeout=180, check=False, env={**os.environ, "INSTALL_DIR": str(inst)}
    )


def _mo(inst: Path, lang: str) -> Path:
    return inst / "contents" / "locale" / lang / "LC_MESSAGES" / ("plasma_applet_%s.mo" % inst.name)


def _fresh(lang: str) -> bytes:
    return subprocess.run(["msgfmt", "-o", "-", str(REPO / "po" / (lang + ".po"))], capture_output=True, timeout=60, check=True).stdout


def _stale(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["msgfmt", "-o", str(path), "-"], input=STALE_PO.encode(), timeout=60, check=True)


def _locale_line(out: str) -> str:
    lines = [line for line in out.splitlines() if line.startswith("locale  :")]
    assert len(lines) == 1, out
    return lines[0]


def test_install_compiles_every_catalog_under_the_installs_own_name(tmp_path):
    inst = _tree(tmp_path)
    assert len(LANGS) >= 13
    done = _dev(inst, "install")
    assert done.returncode == 0, done.stdout + done.stderr
    for lang in LANGS:
        assert _mo(inst, lang).exists(), "no catalog for %s after the install" % lang
        assert _mo(inst, lang).read_bytes() == _fresh(lang), lang
    # Nothing was written under the package's own name, which this install never looks up.
    assert not list(inst.rglob("plasma_applet_io.github.mendior.onair.mo"))
    assert (inst / "contents" / "ui" / "main.qml").exists()


def test_install_replaces_a_catalog_that_fell_behind(tmp_path):
    inst = _tree(tmp_path)
    _stale(_mo(inst, "et"))
    old = _mo(inst, "et").read_bytes()
    assert old != _fresh("et")
    assert _dev(inst, "install").returncode == 0
    assert _mo(inst, "et").read_bytes() == _fresh("et")
    # Twice over changes nothing.
    assert _dev(inst, "install").returncode == 0
    assert _mo(inst, "et").read_bytes() == _fresh("et")


def test_the_catalogs_name_follows_the_tree_they_are_installed_in(tmp_path):
    inst = _tree(tmp_path, "io.github.mendior.onair")
    assert _dev(inst, "install").returncode == 0
    assert _mo(inst, "fi").name == "plasma_applet_io.github.mendior.onair.mo"
    assert _mo(inst, "fi").exists(), "the catalog was not written under this tree's own name"
    assert _mo(inst, "fi").read_bytes() == _fresh("fi")
    assert not list(inst.rglob("plasma_applet_org.kde.plasma.advancedradio.mo"))


def test_doctor_says_whether_the_installed_catalogs_are_those_of_po(tmp_path):
    inst = _tree(tmp_path)
    assert _dev(inst, "install").returncode == 0
    said = _locale_line(_dev(inst, "doctor").stdout)
    assert said == "locale  : %d catalogs match po/" % len(LANGS), said
    # One fell behind, one is gone.
    _stale(_mo(inst, "et"))
    _mo(inst, "uk").unlink()
    after = _dev(inst, "doctor")
    said = _locale_line(after.stdout)
    assert said == "locale  : 2 of %d catalogs differ from po/ (et uk) — run: scripts/dev.sh install" % len(LANGS), said
    # Skew, not "cannot tell". On a machine whose panel loaded before this
    # test's tree was written the panel line says 1 by itself; where no panel
    # runs (the CI container) this line is what tells the two apart.
    assert after.returncode == 1, after.stdout
    # Looking changed nothing.
    assert not _mo(inst, "uk").exists()
    assert _mo(inst, "et").read_bytes() != _fresh("et")


def test_doctor_counts_a_tree_without_any_catalog_as_all_behind(tmp_path):
    inst = _tree(tmp_path)
    (inst / "contents" / "ui").mkdir()
    said = _locale_line(_dev(inst, "doctor").stdout)
    assert said.startswith("locale  : %d of %d catalogs differ from po/ (" % (len(LANGS), len(LANGS))), said
    assert not (inst / "contents" / "locale").exists(), "doctor wrote into the install"
