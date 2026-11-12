# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The AUR recipe keeps up with the releases.

packaging/aur/PKGBUILD pins the tag tarball of one release by its digest, so
it can only be written after that tag exists. Nothing else in the tree reads
it, and it sat at 2026.39 while 2026.40 to 2026.43 went out. The rule that
can be held without the network: the recipe names the newest version in the
changelog or the one before it. During development the newest heading is the
release in the making and the recipe still names the last one that shipped;
two releases behind is a recipe somebody forgot.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKGBUILD = ROOT / "packaging" / "aur" / "PKGBUILD"
CHANGELOG = ROOT / "CHANGELOG.md"


def _recipe(name: str) -> str:
    m = re.search(rf"^{name}=(.+)$", PKGBUILD.read_text(encoding="utf-8"), re.MULTILINE)
    assert m, f"the recipe has no {name}"
    return m.group(1).strip()


def _released() -> list[str]:
    """Version headings of the changelog, newest first."""
    return re.findall(
        r"^## (\d{4}\.\d+(?:\.\d+)?)\s*$",
        CHANGELOG.read_text(encoding="utf-8"),
        re.MULTILINE,
    )


def test_the_recipe_names_the_newest_release_or_the_one_before():
    versions = _released()
    assert len(versions) >= 2, "the changelog lists fewer than two versions"
    assert _recipe("pkgver") in versions[:2], (
        f"packaging/aur/PKGBUILD is at {_recipe('pkgver')}, the changelog at {versions[0]}: "
        "raise pkgver to the last tag and run updpkgsums in packaging/aur"
    )


def test_the_recipe_pins_one_real_digest():
    sums = re.findall(r"[0-9a-f]{64}", _recipe("sha256sums"))
    assert len(sums) == 1, "the tag tarball is pinned by exactly one sha256"
    assert "SKIP" not in _recipe("sha256sums")


def test_the_recipe_builds_from_the_tag_it_names():
    src = _recipe("source")
    assert "refs/tags/v$pkgver.tar.gz" in src, (
        "the source is no longer the release tag's tarball"
    )
