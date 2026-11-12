# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""cmd_play's verdict must follow the receiver, not the clock, and it must be
about the stream that was asked for.

Two ways it has said OK over a device playing something else. pychromecast's
block_until_active returns quietly when its timeout runs out, and OK used to
follow it either way. Then the verdict read the session event, which any
session sets: a television that was in the middle of a YouTube programme
answered OK after 420 ms and went on with YouTube (measured 2026-11-11).

A stand-in receiver takes the network's place and the test holds the clock,
so twelve seconds of waiting cost nothing. The argv dispatch has its own file.
"""

import importlib.util
import subprocess
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

UI = Path(__file__).resolve().parent.parent / "package" / "contents" / "ui"

STREAM = "http://s.example/live"
OTHER = "https://tv.example/programme-1246"


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


class Clock:
    """The helper's clock, in the test's hands. Sleeping moves it, and
    whatever the stand-in receiver was due to say by then gets said."""

    def __init__(self):
        self.now = 0.0
        self._due = []

    def at(self, when, say):
        self._due.append((when, say))

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now = round(self.now + seconds, 6)
        ripe = [d for d in self._due if d[0] <= self.now]
        self._due = [d for d in self._due if d[0] > self.now]
        for _when, say in sorted(ripe, key=lambda d: d[0]):
            say()


class Receiver:
    """Shaped after pychromecast's MediaController, traps included.

    `status` is what the last MEDIA_STATUS said. `session_active_event` is set
    by every status that carries a session id, whoever's session it is, and
    the library leaves it set when the receiver app goes away while it swaps
    `status` for an empty one. `is_active` comes from BaseController and only
    says the media namespace is up, which it is before any session exists.
    """

    def __init__(self, clock):
        self.clock = clock
        self.status = SimpleNamespace(media_session_id=None, content_id=None)
        self.session_active_event = threading.Event()
        self.is_active = True
        self.played = []

    def says(self, session, content):
        self.status.media_session_id = session
        self.status.content_id = content
        if session is None:
            self.session_active_event.clear()
        else:
            self.session_active_event.set()

    def app_gone(self):
        self.status = SimpleNamespace(media_session_id=None, content_id=None)

    def play_media(self, url, **kw):
        self.played.append((url, kw))

    def block_until_active(self, timeout=None):
        waited = 0.0
        while not self.session_active_event.is_set() and waited < (timeout or 0.0):
            self.clock.sleep(0.05)
            waited += 0.05


@pytest.fixture
def rig(cast, monkeypatch):
    clock = Clock()
    mc = Receiver(clock)
    monkeypatch.setattr(cast, "time", clock)
    monkeypatch.setattr(cast, "_import", lambda: object())
    monkeypatch.setattr(
        cast, "_connect_host", lambda *a: SimpleNamespace(media_controller=mc)
    )
    monkeypatch.setattr(cast, "_disconnect", lambda c: None)
    return SimpleNamespace(cast=cast, clock=clock, mc=mc)


def play(rig, capsys, url=STREAM):
    rig.cast.cmd_play("h", 8009, "u", "m", url, "audio/mpeg", "T", "")
    return capsys.readouterr().out.strip()


def test_a_receiver_that_takes_the_stream_is_ok(rig, capsys):
    rig.clock.at(0.4, lambda: rig.mc.says(1, STREAM))
    assert play(rig, capsys) == rig.cast.OK
    assert rig.mc.played[0][0] == STREAM
    assert rig.clock.now <= 0.5, "the answer waited past the moment the stream was taken"


def test_a_slow_receiver_is_waited_for_to_the_last_moment(rig, capsys):
    rig.clock.at(2 * rig.cast.CONNECT_TIMEOUT, lambda: rig.mc.says(1, STREAM))
    assert play(rig, capsys) == rig.cast.OK


def test_a_receiver_that_answers_after_the_wait_is_a_fail(rig, capsys):
    """One look too late: the wait is over at twelve seconds, not a look after."""
    rig.clock.at(2 * rig.cast.CONNECT_TIMEOUT + 0.05, lambda: rig.mc.says(1, STREAM))
    assert play(rig, capsys).startswith(rig.cast.FAIL)
    assert rig.clock.now == 2 * rig.cast.CONNECT_TIMEOUT


def test_a_receiver_that_never_opens_a_session_is_a_fail(rig, capsys):
    out = play(rig, capsys)
    assert out.startswith(rig.cast.FAIL)
    assert "did not take the stream" in out
    assert rig.mc.is_active, (
        "the namespace stayed up the whole time — only the session was missing"
    )


@pytest.mark.parametrize("held", [
    OTHER,                  # another programme
    "",                     # YouTube's own session names no content at all
    None,
    STREAM + "/",           # near enough to fool a prefix match
    STREAM.upper(),
    "x" * 100000,
])
def test_a_device_busy_with_something_else_is_not_casting(rig, capsys, held):
    """The television was already in a session and never took ours.

    Its session event is set before the stream is even sent, so a verdict
    that reads the event says OK at once; what the session holds is what
    tells the two apart.
    """
    rig.mc.says(91, held)
    out = play(rig, capsys)
    assert out.startswith(rig.cast.FAIL), out
    assert rig.mc.status.media_session_id == 91
    assert rig.mc.status.content_id == held


def test_new_content_over_an_old_session_is_ok(rig, capsys):
    rig.mc.says(91, OTHER)
    rig.clock.at(0.3, lambda: rig.mc.says(92, STREAM))
    assert play(rig, capsys) == rig.cast.OK
    assert 0.3 <= rig.clock.now <= 0.4, "OK came before the new content did"


def test_the_old_sessions_late_word_is_not_the_new_one(rig, capsys):
    """The status asked for at connect can land after the stream was sent.

    It carries a session id the helper has not seen before, which is why "a
    new session id" is no proof: here it is the old programme's.
    """
    rig.clock.at(0.2, lambda: rig.mc.says(91, OTHER))
    assert play(rig, capsys).startswith(rig.cast.FAIL)


def test_asking_again_for_what_the_device_already_plays_is_ok(rig, capsys):
    """The same station sent twice, and the receiver keeps its old session.

    No new session id ever shows up, and none is needed: the device holds the
    stream that was asked for, which is all the widget wants to know.
    """
    rig.mc.says(91, STREAM)
    assert play(rig, capsys) == rig.cast.OK
    assert [sent[0] for sent in rig.mc.played] == [STREAM], "the stream was not sent, or sent twice"


def test_asking_again_and_getting_a_new_session_is_ok_too(rig, capsys):
    rig.mc.says(91, STREAM)
    rig.clock.at(0.3, lambda: rig.mc.says(92, STREAM))
    assert play(rig, capsys) == rig.cast.OK


def test_a_receiver_that_quit_while_it_was_asked_is_a_fail(rig, capsys):
    """Stop reaches the device while the play command still waits.

    The app going away leaves the session event set and wipes the status.
    Nothing plays; the command that is still waiting must not say otherwise.
    """
    rig.mc.says(91, OTHER)
    rig.clock.at(0.5, rig.mc.app_gone)
    out = play(rig, capsys)
    assert rig.mc.session_active_event.is_set()
    assert out.startswith(rig.cast.FAIL), out


def test_a_stream_held_before_the_receiver_quit_is_not_held_after(rig, capsys):
    rig.mc.says(91, STREAM)
    rig.mc.app_gone()
    assert play(rig, capsys).startswith(rig.cast.FAIL)


def test_a_receiver_started_for_the_stream_is_ok(rig, capsys):
    """Another app has to make room first: the library swaps the status for
    an empty one when it goes, and the new app's answer lands in that."""
    rig.mc.says(91, OTHER)
    rig.clock.at(0.2, rig.mc.app_gone)
    rig.clock.at(0.9, lambda: rig.mc.says(1, STREAM))
    assert play(rig, capsys) == rig.cast.OK


def test_many_words_about_other_things_and_then_the_stream(rig, capsys):
    for n in range(60):
        rig.clock.at(0.05 * (n + 1), lambda n=n: rig.mc.says(100 + n, "%s?n=%d" % (OTHER, n)))
    rig.clock.at(3.5, lambda: rig.mc.says(200, STREAM))
    assert play(rig, capsys) == rig.cast.OK
    assert 3.5 <= rig.clock.now <= 3.6


def test_the_verdict_reads_the_session_and_not_the_namespace(rig):
    """The one a namespace check cannot tell apart from a working cast.

    A receiver sitting in the default media app has the media namespace up
    before it holds any session, so is_active is True while the stream was
    refused. Consulting it hands back OK for a device playing nothing.
    """
    assert rig.mc.is_active is True
    assert rig.cast._took(rig.mc, STREAM) is False
    rig.mc.says(7, STREAM)
    assert rig.cast._took(rig.mc, STREAM) is True


def test_the_verdict_needs_no_session_event(rig, capsys):
    """An older pychromecast has no session_active_event; the status is
    enough, and it is what every version keeps."""
    del rig.mc.session_active_event
    rig.mc.status = SimpleNamespace(media_session_id=7, content_id=STREAM)
    assert play(rig, capsys) == rig.cast.OK


@pytest.mark.parametrize("mc, url, taken", [
    (SimpleNamespace(status=SimpleNamespace(media_session_id=7, content_id=STREAM)), STREAM, True),
    # The library counts every id that is not None as a session; so does this.
    (SimpleNamespace(status=SimpleNamespace(media_session_id=0, content_id=STREAM)), STREAM, True),
    (SimpleNamespace(status=SimpleNamespace(media_session_id=None, content_id=STREAM)), STREAM, False),
    (SimpleNamespace(status=SimpleNamespace(media_session_id=7, content_id=None)), STREAM, False),
    (SimpleNamespace(status=SimpleNamespace(media_session_id=7)), STREAM, False),
    (SimpleNamespace(status=SimpleNamespace(content_id=STREAM)), STREAM, False),
    (SimpleNamespace(status=None), STREAM, False),
    (SimpleNamespace(), STREAM, False),
    (None, STREAM, False),
    # Nothing was asked for: a session that names no content is not a match.
    (SimpleNamespace(status=SimpleNamespace(media_session_id=7, content_id="")), "", False),
    (SimpleNamespace(status=SimpleNamespace(media_session_id=7, content_id=None)), None, False),
    (SimpleNamespace(status=SimpleNamespace(media_session_id=7, content_id=STREAM.encode())), STREAM, False),
])
def test_what_counts_as_holding_the_stream(cast, mc, url, taken):
    assert cast._took(mc, url) is taken


# ── a receiver that says it could not load the stream ────────────────────────

def hears_failures(rig):
    """The stand-in learns what the library's controller does since 14.0:
    listeners are registered, and a failed load is told to each of them."""
    rig.mc.listeners = []
    rig.mc.register_status_listener = rig.mc.listeners.append

    def load_failed(item, code):
        for listener in rig.mc.listeners:
            listener.load_media_failed(item, code)

    return load_failed


def test_a_receiver_that_could_not_load_the_stream_says_which_error(rig, capsys):
    load_failed = hears_failures(rig)
    rig.clock.at(0.3, lambda: load_failed(1, 104))
    out = play(rig, capsys)
    assert out == "%s load=104 action=play the receiver could not load the stream" % rig.cast.FAIL
    # The verdict still follows the receiver to the end of the wait: what it
    # says about a load does not cut the wait short.
    assert rig.clock.now == 2 * rig.cast.CONNECT_TIMEOUT
    for secret in ("s.example", STREAM):
        assert secret not in out


def test_a_stream_that_is_taken_after_all_is_ok_whatever_was_said_before(rig, capsys):
    load_failed = hears_failures(rig)
    rig.clock.at(0.2, lambda: load_failed(1, 103))
    rig.clock.at(0.6, lambda: rig.mc.says(2, STREAM))
    assert play(rig, capsys) == rig.cast.OK


def test_a_receiver_that_says_nothing_about_the_load_keeps_the_line_of_before(rig, capsys):
    hears_failures(rig)
    out = play(rig, capsys)
    assert out == "%s the device did not take the stream within 12s" % rig.cast.FAIL
    assert len(rig.mc.listeners) == 1, "the helper listens twice, or not at all"


@pytest.mark.parametrize("code, field", [
    (104, "load=104 "), (0, "load=0 "), (9999, "load=9999 "), (905, "load=905 "),
    # What is no error code names none, and the line still says what happened.
    (10000, ""), (-1, ""), (None, ""), ("104", ""), (104.5, ""), (True, ""), ("x" * 5000, ""), ([104], ""),
])
def test_what_a_receiver_gives_for_a_code_is_passed_on_only_as_a_number(rig, capsys, code, field):
    load_failed = hears_failures(rig)
    rig.clock.at(0.3, lambda: load_failed(1, code))
    out = play(rig, capsys)
    assert out == "%s %saction=play the receiver could not load the stream" % (rig.cast.FAIL, field)


def test_the_last_failure_heard_is_the_one_named(rig, capsys):
    load_failed = hears_failures(rig)
    rig.clock.at(0.1, lambda: load_failed(1, 103))
    rig.clock.at(0.2, lambda: load_failed(2, 104))
    assert play(rig, capsys).startswith("%s load=104 " % rig.cast.FAIL)


def test_a_library_without_listeners_is_cast_through_as_before(rig, capsys):
    # The stand-in as it was: no register_status_listener at all.
    assert not hasattr(rig.mc, "register_status_listener")
    rig.clock.at(0.4, lambda: rig.mc.says(1, STREAM))
    assert play(rig, capsys) == rig.cast.OK


LOAD_CHECK = r"""
import importlib.util, sys
try:
    from pychromecast.controllers import media
except ImportError:
    sys.exit(3)
spec = importlib.util.spec_from_file_location("cast_beside_the_library", sys.argv[1])
cast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cast)
mc = media.MediaController()
watch = cast._LoadWatch()
mc.register_status_listener(watch)
said = [watch.code]
mc.receive_message(None, {"type": "MEDIA_STATUS", "status": [{"mediaSessionId": 91, "playerState": "IDLE"}]})
said.append(watch.code)
mc.receive_message(None, {"type": "LOAD_FAILED", "requestId": 7})
said.append(watch.code)
mc.receive_message(None, {"type": "LOAD_FAILED", "requestId": 7, "itemId": 1, "detailedErrorCode": 104})
said.append(watch.code)
print(" ".join(str(x) for x in said))
"""


def test_the_library_tells_the_helper_of_a_failed_load():
    """The real controller, fed what a receiver sends, with no socket. It
    tells its listeners of a LOAD_FAILED that names an item and a code, and
    of nothing else; an installed library older than that is skipped."""
    done = subprocess.run([sys.executable, "-c", LOAD_CHECK, str(UI / "cast.py")], capture_output=True, text=True, timeout=60)
    if done.returncode == 3:
        pytest.skip("the optional Cast library is not installed here")
    if "load_media_failed" not in done.stderr and done.returncode != 0:
        raise AssertionError(done.stderr[-2000:])
    if done.returncode != 0:
        pytest.skip("the installed Cast library has no word for a failed load")
    #     nothing yet | a status | a failure that names nothing | one that names its code
    assert done.stdout.split() == ["None", "None", "None", "104"]


LIBRARY_CHECK = r"""
import importlib.util, sys
try:
    from pychromecast.controllers import media
except ImportError:
    sys.exit(3)
spec = importlib.util.spec_from_file_location("cast_beside_the_library", sys.argv[1])
cast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cast)
STREAM, OTHER = sys.argv[2], sys.argv[3]
mc = media.MediaController()

def hears(status):
    mc.receive_message(None, {"type": "MEDIA_STATUS", "status": status})

said = [cast._took(mc, STREAM)]
hears([{"mediaSessionId": 91, "playerState": "PLAYING", "media": {"contentId": OTHER}}])
said += [mc.session_active_event.is_set(), cast._took(mc, STREAM)]
hears([{"mediaSessionId": 92, "playerState": "IDLE",
        "extendedStatus": {"playerState": "LOADING", "media": {"contentId": STREAM}}}])
said.append(cast._took(mc, STREAM))
hears([{"mediaSessionId": 92, "playerState": "PLAYING"}])
said.append(cast._took(mc, STREAM))
mc.channel_disconnected()
said += [mc.session_active_event.is_set(), cast._took(mc, STREAM)]
print(" ".join(str(x) for x in said))
"""


def test_the_stand_in_agrees_with_the_library():
    """The real controller, fed the messages a receiver sends, with no socket.

    A stream that is still loading sits in extendedStatus under an IDLE
    player, and a television showed exactly that for the first samples of a
    cast that went on to play (2026-11-11). The app going away is the trap
    the stand-in copies: the event stays set, the status is new and empty.

    In an interpreter of its own, so the library's compiled modules stay out
    of the one the rest of the suite runs in.
    """
    done = subprocess.run([sys.executable, "-c", LIBRARY_CHECK, str(UI / "cast.py"), STREAM, OTHER],
                          capture_output=True, text=True, timeout=60)
    if done.returncode == 3:
        pytest.skip("the optional Cast library is not installed here")
    assert done.returncode == 0, done.stderr[-2000:]
    #     nothing yet | another's session: event set, not ours | loading | playing | app gone: event still set, not held
    assert done.stdout.split() == ["False", "True", "False", "True", "True", "True", "False"]
