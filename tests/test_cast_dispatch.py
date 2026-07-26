# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""argv dispatch in cast.py: every command must reach the right cmd_* with the
right arguments, and anything malformed must answer with the fail sentinel
instead of crashing. A dispatch bug here once shipped in a release — this file
is its regression net."""
import sys

import pytest


def run_main(cast, monkeypatch, argv):
    """Run cast.main() with argv, recording which cmd_* was called and how."""
    calls = []
    for name in ("cmd_probe", "cmd_discover", "cmd_play", "cmd_stop",
                 "cmd_volume", "cmd_get_volume", "cmd_dlna_play",
                 "cmd_dlna_stop", "cmd_dlna_volume", "cmd_dlna_get_volume"):
        monkeypatch.setattr(
            cast, name,
            lambda *a, _n=name, **kw: calls.append((_n, a)),
        )
    monkeypatch.setattr(sys, "argv", ["cast.py"] + argv)
    cast.main()
    return calls


def sentinel_lines(capsys):
    return capsys.readouterr().out.strip().splitlines()


def test_probe(cast, monkeypatch):
    assert run_main(cast, monkeypatch, ["probe"]) == [("cmd_probe", ())]


def test_discover_default_seconds(cast, monkeypatch):
    assert run_main(cast, monkeypatch, ["discover"]) == [("cmd_discover", (6.0,))]


@pytest.mark.parametrize("arg,expected", [
    ("3", 3.0),        # plain value passes through
    ("0.2", 1.0),      # clamped up
    ("99", 15.0),      # clamped down
    ("abc", 6.0),      # unparseable falls back to the default
])
def test_discover_seconds_clamped(cast, monkeypatch, arg, expected):
    assert run_main(cast, monkeypatch, ["discover", arg]) \
        == [("cmd_discover", (expected,))]


def test_play_full_argv(cast, monkeypatch):
    calls = run_main(cast, monkeypatch, [
        "play", "h", "8009", "u", "m", "http://s", "audio/mpeg", "Title", "http://art",
    ])
    assert calls == [("cmd_play",
                      ("h", "8009", "u", "m", "http://s", "audio/mpeg",
                       "Title", "http://art"))]


def test_play_optional_title_art_default_empty(cast, monkeypatch):
    calls = run_main(cast, monkeypatch,
                     ["play", "h", "8009", "u", "m", "http://s", "audio/aac"])
    assert calls == [("cmd_play",
                      ("h", "8009", "u", "m", "http://s", "audio/aac", "", ""))]


def test_stop_and_volume(cast, monkeypatch):
    assert run_main(cast, monkeypatch, ["stop", "h", "8009", "u", "m"]) \
        == [("cmd_stop", ("h", "8009", "u", "m"))]
    assert run_main(cast, monkeypatch, ["volume", "h", "8009", "u", "m", "0.5"]) \
        == [("cmd_volume", ("h", "8009", "u", "m", "0.5"))]


def test_dlna_commands(cast, monkeypatch):
    # Artwork rides along as the optional 5th arg.
    assert run_main(cast, monkeypatch,
                    ["dlna-play", "http://loc", "http://s", "audio/mpeg", "T",
                     "https://cdn/x.jpg"]) \
        == [("cmd_dlna_play", ("http://loc", "http://s", "audio/mpeg", "T",
                               "https://cdn/x.jpg"))]
    # Title and art are optional and default to empty
    assert run_main(cast, monkeypatch,
                    ["dlna-play", "http://loc", "http://s", "audio/mpeg", "T"]) \
        == [("cmd_dlna_play", ("http://loc", "http://s", "audio/mpeg", "T", ""))]
    assert run_main(cast, monkeypatch,
                    ["dlna-play", "http://loc", "http://s", "audio/mpeg"]) \
        == [("cmd_dlna_play", ("http://loc", "http://s", "audio/mpeg", "", ""))]
    assert run_main(cast, monkeypatch, ["dlna-stop", "http://loc"]) \
        == [("cmd_dlna_stop", ("http://loc",))]
    assert run_main(cast, monkeypatch, ["dlna-volume", "http://loc", "0.3"]) \
        == [("cmd_dlna_volume", ("http://loc", "0.3"))]


def test_get_volume_commands(cast, monkeypatch):
    assert run_main(cast, monkeypatch, ["get-volume", "h", "8009", "u", "m"]) \
        == [("cmd_get_volume", ("h", "8009", "u", "m"))]
    assert run_main(cast, monkeypatch, ["dlna-get-volume", "http://loc"]) \
        == [("cmd_dlna_get_volume", ("http://loc",))]


@pytest.mark.parametrize("argv", [
    ["play", "h", "8009", "u", "m", "http://s"],   # ctype missing
    ["stop", "h", "8009", "u"],                    # model missing
    ["volume", "h", "8009", "u", "m"],             # level missing
    ["get-volume", "h", "8009", "u"],              # model missing
    ["dlna-play", "http://loc", "http://s"],       # ctype missing
    ["dlna-stop"],
    ["dlna-volume", "http://loc"],
    ["dlna-get-volume"],
    ["no-such-command"],
])
def test_short_or_unknown_argv_is_bad_arguments(cast, monkeypatch, capsys, argv):
    assert run_main(cast, monkeypatch, argv) == []
    assert sentinel_lines(capsys) == ["%s bad arguments" % cast.FAIL]


def test_no_argv_prints_usage_sentinel(cast, monkeypatch, capsys):
    assert run_main(cast, monkeypatch, []) == []
    out = sentinel_lines(capsys)
    assert len(out) == 1 and out[0].startswith(cast.FAIL)


def test_dbg_writes_stderr_never_stdout(cast, capsys):
    # stdout is the sentinel channel the QML side parses — the debug trace
    # must never leak a single byte into it.
    cast._dbg("unit-test", ValueError("boom"))
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "unit-test" in captured.err and "boom" in captured.err


def test_dbg_survives_a_dead_stderr(cast, monkeypatch):
    class Broken:
        def write(self, *_a):
            raise OSError("closed pipe")

        def flush(self):
            raise OSError("closed pipe")

    monkeypatch.setattr(cast.sys, "stderr", Broken())
    cast._dbg("x", RuntimeError("y"))  # a trace must never add a crash
