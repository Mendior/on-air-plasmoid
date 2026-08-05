# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Freedesktop icon lookup, filesystem level — no Qt, no display.

Follows the icon-theme spec far enough to answer one question honestly:
does theme T (through its Inherits chain, ending at hicolor) provide a
file for icon name N?
"""
import configparser
import os

ICON_DIRS = ["/usr/share/icons", os.path.expanduser("~/.local/share/icons"),
             "/usr/share/pixmaps"]
EXTS = (".svg", ".svgz", ".png", ".xpm")


def _theme_dir(theme):
    for root in ICON_DIRS:
        d = os.path.join(root, theme)
        if os.path.isdir(d):
            return d
    return None


def _inherits(theme):
    d = _theme_dir(theme)
    if not d:
        return []
    idx = os.path.join(d, "index.theme")
    if not os.path.isfile(idx):
        return []
    cp = configparser.RawConfigParser(strict=False)
    try:
        cp.read(idx, encoding="utf-8")
    except (OSError, UnicodeDecodeError, configparser.Error):
        return []
    raw = cp.get("Icon Theme", "Inherits", fallback="")
    return [t.strip() for t in raw.split(",") if t.strip()]


def chain(theme, _seen=None):
    """Theme plus everything it inherits, breadth-first, hicolor last."""
    if _seen is None:
        _seen = []
    if theme in _seen:
        return _seen
    _seen.append(theme)
    for parent in _inherits(theme):
        chain(parent, _seen)
    if "hicolor" not in _seen:
        _seen.append("hicolor")
    return _seen


def find(name, theme):
    """Path of the first file providing `name` in the theme chain, or None."""
    for t in chain(theme):
        d = _theme_dir(t)
        if not d:
            continue
        for dirpath, _dirnames, filenames in os.walk(d):
            for ext in EXTS:
                if name + ext in filenames:
                    return os.path.join(dirpath, name + ext)
    # Loose files (pixmaps) are a legitimate last resort in the spec.
    for root in ICON_DIRS:
        for ext in EXTS:
            p = os.path.join(root, name + ext)
            if os.path.isfile(p):
                return p
    return None


def installed_themes():
    out = []
    for root in ICON_DIRS:
        if not os.path.isdir(root):
            continue
        for e in sorted(os.listdir(root)):
            if os.path.isfile(os.path.join(root, e, "index.theme")):
                out.append(e)
    return out

