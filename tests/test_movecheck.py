# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""movecheck.py is load-bearing — NameGuard.js and the extraction plan both
lean on its word — so its word gets tested. Every case here is a shape that
either fooled the first version or is the reason the tool exists:
punctuation that goes missing without a trace, an edit whose diff lines look
like headers, a staged move the default run used to answer with "nothing to
compare", and a function body that must survive its move byte for byte.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _movecheck():
    spec = importlib.util.spec_from_file_location(
        "movecheck", ROOT / "scripts" / "movecheck.py"
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["movecheck"] = mod
    spec.loader.exec_module(mod)
    return mod


def _git(repo: Path, *args: str) -> str:
    p = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, check=True
    )
    return p.stdout.strip()


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.name", "Test")
    _git(repo, "config", "user.email", "t@example.invalid")
    return repo


def _main(mod, repo: Path, argv: list[str]) -> int:
    mod.REPO = repo
    old = sys.argv
    sys.argv = ["movecheck.py", *argv]
    try:
        return mod.main()
    finally:
        sys.argv = old


def test_a_pure_move_earns_exit_zero(tmp_path, capsys):
    mod = _movecheck()
    repo = _repo(tmp_path)
    (repo / "a.qml").write_text("Item {\n    var x = compute(1);\n    use(x);\n}\n")
    (repo / "b.js").write_text("// empty\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "base")
    (repo / "a.qml").write_text("Item {\n}\n")
    (repo / "b.js").write_text("// empty\nvar x = compute(1);\nuse(x);\n")
    assert _main(mod, repo, []) == 0
    assert "Pure move" in capsys.readouterr().out


def test_a_staged_move_is_still_compared_against_head(tmp_path, capsys):
    # `git diff` with no revision reads worktree-vs-index, so the moment a
    # move was staged the old default said "nothing to compare" — exit 0
    # for a diff nobody had looked at.
    mod = _movecheck()
    repo = _repo(tmp_path)
    (repo / "a.qml").write_text("Item {\n    var x = compute(1);\n}\n")
    (repo / "b.js").write_text("// empty\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "base")
    (repo / "a.qml").write_text("Item {\n}\n")
    (repo / "b.js").write_text("// empty\nvar x = compute(1);\n")
    _git(repo, "add", "-A")
    assert _main(mod, repo, []) == 0
    out = capsys.readouterr().out
    assert "nothing to compare" not in out
    assert "moved unchanged : 1" in out


def test_an_edit_wearing_a_header_costume_is_seen(tmp_path, capsys):
    # A removed `--i;` arrives in the diff as `---i;`, which the first
    # parser dropped as a file header — the edit vanished from both pools.
    mod = _movecheck()
    repo = _repo(tmp_path)
    (repo / "c.js").write_text("start\n--i;\nend\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "base")
    (repo / "c.js").write_text("start\n++i;\nend\n")
    assert _main(mod, repo, []) == 1
    out = capsys.readouterr().out
    assert "- --i;" in out
    assert "+ ++i;" in out


def test_a_stray_brace_blocks_the_pure_verdict(tmp_path, capsys):
    # Punctuation is matched by COUNT, not content — but a net extra `}`
    # reparents every binding after it in QML, so it may not pass silently.
    mod = _movecheck()
    repo = _repo(tmp_path)
    (repo / "a.qml").write_text("Item {\n    use(x);\n}\n")
    (repo / "b.js").write_text("// empty\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "base")
    (repo / "a.qml").write_text("Item {\n}\n")
    (repo / "b.js").write_text("// empty\nuse(x);\n}\n")
    assert _main(mod, repo, []) == 1
    assert "OFF BY 1" in capsys.readouterr().out


def test_funcs_blesses_an_identical_body_across_the_move(tmp_path, capsys):
    mod = _movecheck()
    repo = _repo(tmp_path)
    pkg = repo / "package" / "contents" / "ui"
    pkg.mkdir(parents=True)
    (pkg / "main.qml").write_text(
        "Item {\n"
        "    function heal(u) {\n"
        "        root.saved = Plasmoid.configuration.list;\n"
        "        return root.saved + u;\n"
        "    }\n"
        "}\n"
    )
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "before")
    a = _git(repo, "rev-parse", "HEAD")
    (pkg / "main.qml").write_text("Item {\n}\n")
    (pkg / "Lib.js").write_text(
        "function heal(u) {\n"
        "    app.saved = cfg.list;\n"
        "    return app.saved + u;\n"
        "}\n"
    )
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "after")
    b = _git(repo, "rev-parse", "HEAD")
    assert _main(mod, repo, ["%s..%s" % (a, b), "--funcs", "heal"]) == 0
    assert "identical" in capsys.readouterr().out


def test_funcs_catches_a_one_token_change_inside_the_move(tmp_path, capsys):
    mod = _movecheck()
    repo = _repo(tmp_path)
    pkg = repo / "package" / "contents" / "ui"
    pkg.mkdir(parents=True)
    (pkg / "main.qml").write_text(
        "Item {\n    function pick(n) {\n        return n - 1;\n    }\n}\n"
    )
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "before")
    a = _git(repo, "rev-parse", "HEAD")
    (pkg / "main.qml").write_text("Item {\n}\n")
    (pkg / "Lib.js").write_text("function pick(n) {\n    return n + 1;\n}\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "after")
    b = _git(repo, "rev-parse", "HEAD")
    assert _main(mod, repo, ["%s..%s" % (a, b), "--funcs", "pick"]) == 1
    out = capsys.readouterr().out
    assert "DIFFERS" in out
    assert "return n - 1;" in out
    assert "return n + 1;" in out
