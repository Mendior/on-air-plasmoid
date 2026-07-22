# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Shared test fixtures: load the plasmoid's Python helpers from package/."""
import ast
import importlib.util
import pathlib

import pytest

UI_DIR = pathlib.Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"


@pytest.fixture(scope="session")
def cast():
    """cast.py imported as a module (stdlib-only, guarded by __main__)."""
    spec = importlib.util.spec_from_file_location("onair_cast", UI_DIR / "cast.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="session")
def reader_funcs():
    """decode_meta/extract_field lifted out of reader.py via AST.

    reader.py runs main() at import time and exits without argv/requests, so
    the pure functions are compiled out of the real source instead — the code
    under test is still byte-for-byte the shipped code.
    """
    src = (UI_DIR / "reader.py").read_text()
    tree = ast.parse(src)
    wanted = [n for n in tree.body
              if isinstance(n, ast.FunctionDef)
              and n.name in ("decode_meta", "extract_field", "resolve_url")]
    assert len(wanted) == 3, "reader.py no longer defines the expected helpers"
    ns = {}
    module = ast.Module(body=wanted, type_ignores=[])
    exec(compile(module, str(UI_DIR / "reader.py"), "exec"), ns)
    return ns
