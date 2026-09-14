# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""cmd_play's verdict must follow the receiver, not the clock. pychromecast's
block_until_active returns quietly when its timeout runs out, and the OK
sentinel used to follow it either way — a device that never opened a media
session read as "casting" in the widget. A fake receiver stands in for the
network here; the argv dispatch has its own file."""

import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

UI = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"


@pytest.fixture
def cast():
    spec = importlib.util.spec_from_file_location(
        "cast_play_under_test", UI / "cast.py"
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


class FakeEvent:
    """pychromecast's session_active_event, as far as cmd_play is concerned."""

    def __init__(self, mc):
        self._mc = mc

    def is_set(self):
        return self._mc.waits >= self._mc.active_after


class FakeMC:
    """Shaped after the real MediaController, including the trap.

    `is_active` comes from BaseController and reports namespace presence, so a
    receiver can carry it while holding no session — modelled here as always
    True. The session lives in session_active_event, which is what
    block_until_active waits on and what the verdict has to read.
    """

    def __init__(self, active_after):
        self.waits = 0
        self.active_after = active_after
        self.played = []
        self.is_active = True
        self.session_active_event = FakeEvent(self)
        # The old-pychromecast road reads this one; declared so it exists.
        self.status = SimpleNamespace(media_session_id=None)

    def play_media(self, url, **kw):
        self.played.append((url, kw))

    def block_until_active(self, timeout=None):
        self.waits += 1


def _wire(cast, monkeypatch, mc):
    monkeypatch.setattr(cast, "_import", lambda: object())
    monkeypatch.setattr(
        cast, "_connect_host", lambda *a: SimpleNamespace(media_controller=mc)
    )
    monkeypatch.setattr(cast, "_disconnect", lambda c: None)


def test_a_receiver_that_opens_a_session_is_ok(cast, monkeypatch, capsys):
    mc = FakeMC(active_after=1)
    _wire(cast, monkeypatch, mc)
    cast.cmd_play("h", 8009, "u", "m", "http://s.example/live", "audio/mpeg", "T", "")
    assert capsys.readouterr().out.strip() == cast.OK
    assert mc.played[0][0] == "http://s.example/live"


def test_a_slow_receiver_gets_a_second_wait(cast, monkeypatch, capsys):
    mc = FakeMC(active_after=2)
    _wire(cast, monkeypatch, mc)
    cast.cmd_play("h", 8009, "u", "m", "http://s.example/live", "audio/mpeg", "", "")
    assert capsys.readouterr().out.strip() == cast.OK
    assert mc.waits == 2


def test_a_receiver_that_never_opens_a_session_is_a_fail(cast, monkeypatch, capsys):
    mc = FakeMC(active_after=99)
    _wire(cast, monkeypatch, mc)
    cast.cmd_play("h", 8009, "u", "m", "http://s.example/live", "audio/mpeg", "", "")
    out = capsys.readouterr().out.strip()
    assert out.startswith(cast.FAIL)
    assert "no media session" in out
    assert mc.is_active, (
        "the namespace stayed up the whole time — only the session was missing"
    )


def test_the_verdict_reads_the_session_and_not_the_namespace(cast):
    """The one a namespace check cannot tell apart from a working cast.

    A receiver sitting in the default media app has the media namespace up
    before it holds any session, so is_active is True while the stream was
    refused. Consulting it hands back OK for a device playing nothing.
    """
    mc = FakeMC(active_after=99)
    assert mc.is_active is True
    assert cast._media_session_open(mc) is False
    mc.waits = 99
    assert cast._media_session_open(mc) is True


def test_an_old_pychromecast_without_the_event_falls_back_to_the_status(cast):
    mc = FakeMC(active_after=1)
    del mc.session_active_event
    mc.status = SimpleNamespace(media_session_id=None)
    assert cast._media_session_open(mc) is False
    mc.status = SimpleNamespace(media_session_id=7)
    assert cast._media_session_open(mc) is True
