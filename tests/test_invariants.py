# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Grep-class invariants an exhaustive investigation proved and a future
refactor must not quietly break.

The 2026-07 sync study measured that a station switch does NOT move the
inter-speaker offset — because the playback path has zero sync-engine
call sites. That absence is load-bearing: adding a "helpful" rebuild to
a station switch would ADD an audible step to every switch to cure a
bug that does not exist. These tests pin the proven facts.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "package" / "contents" / "ui"
TESTS = Path(__file__).resolve().parent


def _function_body(src: str, name: str) -> str:
    """The brace-balanced body of a QML/JS function, by name."""
    m = re.search(r"function %s\s*\(" % re.escape(name), src)
    assert m, "function %s not found" % name
    i = src.index("{", m.end() - 1)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
    raise AssertionError("unbalanced braces in %s" % name)


def test_playback_path_never_touches_the_sync_engine():
    src = (UI / "main.qml").read_text(encoding="utf-8")
    forbidden = re.compile(
        r"combineOutputs|_combineRebuild|setSyncOffset|syncOffsetMap"
        r"|_refLatProbe|refLatProbeTimer|_idleTeardown")
    for fn in ("refreshServer", "_playStation", "startWithFade",
               "stopWithFade", "previewStation"):
        body = _function_body(src, fn)
        hit = forbidden.search(body)
        assert hit is None, (
            "%s reaches sync machinery (%r) — the measured guarantee that a "
            "station switch cannot move the inter-speaker offset depends on "
            "this path staying sync-free" % (fn, hit.group(0)))


def test_every_byuuid_concatenation_encodes_its_uuid():
    for qml in UI.rglob("*.qml"):
        src = qml.read_text(encoding="utf-8")
        # The click and the vote take the same uuid, from a row a listener
        # can edit by hand or import: it stays one path segment there too.
        for m in re.finditer(r'/json/(?:stations/byuuid|url|vote)/"\s*\+\s*', src):
            tail = src[m.end():m.end() + 60].lstrip()
            assert tail.startswith("encodeURIComponent"), (
                "%s: uuid concatenation without encodeURIComponent: %r"
                % (qml.name, tail.split("\n")[0]))


def test_every_device_supplied_name_still_goes_through_the_stripper():
    """The stripper itself is tested by CALLING it (tests/qml/tst_nameguard.qml).

    What that behavioural test cannot see is whether main.qml still HANDS
    it anything. Those are two different failures and they need two
    different guards: drop the character class and the QML test goes red;
    drop one call site and only this one does.

    Measured 2026-08-09: eight call sites, plus the wrapper's definition.
    The count is pinned rather than given a floor because the floor is what
    let the old version of this test through — it asked for `>= 4` while
    there were nine, so losing five would have been silent.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")

    # The body lives in the library now; main.qml must still route to it.
    assert 'import "NameGuard.js" as NameGuard' in src, (
        "main.qml no longer imports NameGuard")
    body = _function_body(src, "_sanitizeDeviceName")
    assert "NameGuard.sanitize(s)" in body, (
        "_sanitizeDeviceName stopped delegating to NameGuard — the wrapper "
        "is the only thing keeping eight callers pointed at the tested code")

    mentions = src.count("_sanitizeDeviceName(")
    calls = mentions - src.count("function _sanitizeDeviceName(")
    eng = (UI / "PodcastEngine.qml").read_text(encoding="utf-8")
    calls += eng.count("app._sanitizeDeviceName(")
    assert calls == 8, (
        "expected 8 _sanitizeDeviceName call sites across main.qml and "
        "PodcastEngine.qml (the download title moved with slice 3a), found "
        "%d. A name that skips it reaches the model, a filename and a shell "
        "command line unstripped; a NEW one that legitimately needs "
        "stripping means this number goes UP, in the commit that adds it."
        % calls)

    # The library must still be the one door, not a second copy. The class
    # is read out of the regex LINE, not the whole file: every group also
    # appears in the explanatory comment above it, so a whole-file grep
    # stayed green with a group deleted from the code — measured, and the
    # exact text-not-behaviour trap this extraction was meant to end.
    lib = (UI / "NameGuard.js").read_text(encoding="utf-8")
    assert ".pragma library" in lib, "NameGuard.js stopped being a library"
    cls = re.search(r"\.replace\(/\[([^\]]+)\]/g", lib)
    assert cls, "NameGuard.sanitize no longer strips a character class"
    for needed in ("<>&", "\\u0000-\\u001f", "\\u202a-\\u202e", "\\u2066-\\u2069"):
        assert needed in cls.group(1), (
            "NameGuard's regex lost %r (markup / control / bidi / isolate) — "
            "tst_nameguard.qml says what each group is for" % needed)


def test_every_notice_body_is_spelled_out_at_the_one_door():
    """Plasma draws a notification's body as rich text, links included, and
    its title as plain text (read from the notification applet shipped with
    plasma-workspace 6.8.2). Device and feed names were stripped before they
    got there; a station's name and a song's title were not, and they are
    whatever the station wrote. notify() is the only door to the
    notification, so the body is escaped there once, for every caller, with
    NameGuard.escapeMarkup (called in tst_nameguard). The title stays as it
    is: escaped, a plain-text title would show the entities themselves.

    notify() swallows what it throws, so a call to a name that does not
    exist would mean no notice at all and no error anyone sees. The name is
    therefore checked against the library here.
    """
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "notify")
    assert "dlNotification.text = NameGuard.escapeMarkup(text);" in body, (
        "a notice's body reaches the notification as the station wrote it")
    assert "dlNotification.title = title;" in body, (
        "the title is no longer handed over as it is; it is drawn as plain "
        "text and would show an escape's own characters")
    lib = (UI / "NameGuard.js").read_text(encoding="utf-8")
    assert re.search(r"^function escapeMarkup\(s\) \{$", lib, re.M), (
        "NameGuard.escapeMarkup is gone or renamed: notify() would throw into "
        "its own catch and every notice would vanish without a word")
    for qml in sorted(UI.rglob("*.qml")):
        code = _code_only(qml.read_text(encoding="utf-8"))
        want = 1 if qml.name == "main.qml" else 0
        assert len(re.findall(r"dlNotification\.text\s*=", code)) == want, (
            "%s sets the notification's body outside notify(), past the one "
            "place that escapes it" % qml.name)


def test_the_readme_never_claims_more_checks_than_exist():
    # Counted 2026-07-25: 326 test functions, while the README still said
    # 350+. Whoever reads that line cannot run the suite to check it, so the
    # printed number has to stay under the real one. 320+ leaves room to add
    # tests without going back to edit prose.
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    claim = re.search(r"(\d+)\+ automated checks", readme)
    assert claim, "README no longer states an 'N+ automated checks' figure"
    claimed = int(claim.group(1))

    qml = sum(len(re.findall(r"\bfunction test_", p.read_text(encoding="utf-8")))
              for p in (TESTS / "qml").glob("*.qml"))
    py = sum(len(re.findall(r"^\s*def test_", p.read_text(encoding="utf-8"),
                            re.MULTILINE))
             for p in TESTS.glob("test_*.py"))
    actual = qml + py

    assert claimed <= actual, (
        f"README claims {claimed}+ automated checks, but only {actual} test "
        f"functions exist ({qml} QML + {py} Python). Lower the README figure "
        f"or write the missing tests.")


def test_the_raw_episode_url_retires_with_its_siblings():
    # _podPlayingRawUrl used to survive stops and station handoffs while
    # Key/Url/Art/Show were cleared, so the episode row kept painting
    # itself as playing and its first tap stopped the radio instead of
    # starting the episode. The field set is cleared as a unit or the bug
    # comes straight back — this pins every clearing block together.
    src = (UI / "main.qml").read_text(encoding="utf-8")
    # The four identical player-death sites folded into the engine's
    # clearPlaying() (A2); the sites main still spells by hand keep the
    # pairing rule, and the fold itself must keep the pair together.
    eng = (UI / "PodcastEngine.qml").read_text(encoding="utf-8")
    clear = _function_body(eng, "clearPlaying")
    assert '_podPlayingUrl = "";' in clear and '_podPlayingRawUrl = "";' in clear, (
        "clearPlaying no longer retires the raw URL with its siblings")
    assert src.count("podcastEngine.clearPlaying();") >= 4, (
        "the player-death sites stopped using the unified clear — "
        "hand-spelled copies are how the fields drift apart again")
    blocks = list(re.finditer(r'_podPlayingUrl = "";', src))
    assert len(blocks) >= 3, "expected the handoff + both stop paths"
    for m in blocks:
        window = src[max(0, m.start() - 300):m.end() + 300]
        assert '_podPlayingRawUrl = "";' in window, (
            "a block clears _podPlayingUrl without clearing "
            "_podPlayingRawUrl nearby — the stale raw URL turns the "
            "episode row into a stop button for whatever plays next")


def test_the_podcast_download_keeps_its_url_off_the_transfer_argv():
    # Same class as the 2026.23 reader.py fix: an enclosure URL can carry
    # a private feed's token, and anything on argv sits world-readable in
    # /proc for the life of the process. The transfer command may name
    # paths only; the URL travels through the owner-only -K config that a
    # separate, microsecond-lived printf staged.
    # The pipeline lives in PodcastEngine since the slice-3a move; the
    # guard follows the code, asserting the same shape it always did.
    src = (UI / "PodcastEngine.qml").read_text(encoding="utf-8")
    stage = _function_body(src, "_podStartDownload")
    assert ": POD_URL;" in stage and "umask 077" in stage, (
        "the staging step no longer writes the URL file owner-only")
    run = _function_body(src, "_podRunDownload")
    assert "-K " in run, "curl lost its -K config — the URL is back on argv"
    assert "shQuote(url)" not in run and "safeUrl" not in run, (
        "the transfer command quotes the URL directly onto its own "
        "command line again")


def test_the_mute_button_asks_the_sink_instead_of_its_own_cache():
    """A cached mute flag must never decide what the mute button SENDS.

    The poll behind `_sinkMasterMuted` is two seconds behind on mains, and
    the keyboard mute key is exactly the thing people press in between.
    Computing an absolute `set-sink-mute 0/1` from a stale belief sends the
    OPPOSITE of what was asked: mute from the keyboard, then press the
    widget's speaker for sound, and it re-muted. pactl's own `toggle`
    cannot be wrong about the state it is toggling.
    """
    body = _function_body((UI / "main.qml").read_text(encoding="utf-8"),
                          "toggleSinkMasterMute")
    assert "set-sink-mute @DEFAULT_SINK@ toggle" in body, (
        "the mute button no longer lets pactl decide — an absolute 0/1 here "
        "is wrong whenever the mute moved since the last poll")
    assert "_sinkMasterMuted = !" not in body, (
        "the cached flag is being flipped to choose the command again")


def test_the_volume_slider_unmutes_with_an_absolute_zero_never_a_toggle():
    """The neighbouring site wants the OPPOSITE command, and only the mute
    button's site was guarded. Raising the volume must unmute — an
    absolute 0 is always right there, while `toggle` would mute a sink
    that was already playing on every second drag. Bench mutant
    07-sink-mute-absolute swaps exactly this and survived every run
    since the bench existed; this is the test that kills it.
    """
    body = _function_body((UI / "main.qml").read_text(encoding="utf-8"),
                          "setSinkMaster")
    assert 'p > 0 ? " pactl set-sink-mute @DEFAULT_SINK@ 0 ' in body, (
        "the volume path no longer unmutes with an absolute 0 on a "
        "positive volume - either the unmute is gone (raising volume "
        "leaves a muted sink silent) or it became a toggle (every second "
        "drag mutes a playing sink)")
    assert "set-sink-mute @DEFAULT_SINK@ toggle" not in body, (
        "the volume path toggles the mute - right half the time, silence "
        "the other half")


def test_the_profile_bounce_restores_the_cards_own_a2dp_seat_first():
    """On a multi-codec speaker every codec is its own profile, and the
    generic a2dp-sink name is a REAL seat (the AAC one, measured on a
    JBL Flip 7). Trying it before the captured profile always succeeded
    and silently moved the speaker to AAC - the codec whose latency the
    drift check cannot see through - so a user's SBC-XQ choice never
    survived a bounce. The card's own A2DP profile comes back first;
    only a card parked outside A2DP (off, headset) takes the generic
    road.
    """
    body = _function_body((UI / "main.qml").read_text(encoding="utf-8"),
                          "btProfileBounceShell")
    own = body.find('case \\"$p\\" in a2dp*)')
    generic = body.find('a2dp-sink >')
    assert own != -1, (
        "the bounce no longer restores the captured a2dp profile - a "
        "multi-codec speaker lands on AAC on every kick")
    assert generic != -1 and own < generic, (
        "the generic a2dp-sink attempt runs before the captured profile "
        "again - on a multi-codec card it always wins and the user's "
        "codec choice is lost")


def test_a_stream_the_rescue_relayed_once_arms_the_relay_at_start():
    """The rescue needs six frozen seconds to be sure - an audible hiccup
    on every start of the same station (issue #11's reporter measured it
    on 2026.33). The verdict is remembered for the session: the rescue
    records the stream, and the arm road consults the record next to the
    codec test, so the second start goes straight through the relay.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    assert "streamKind.rescued(src, root._currentOrigUrl);" in src, (
        "the rescue no longer records the stream it relayed - every "
        "start replays the six frozen seconds")
    assert "tsOgg || streamKind.proven(tsUrl)" in src, (
        "the arm road no longer consults the rescue's session record")
    kind = (UI / "StreamKind.qml").read_text(encoding="utf-8")
    assert "_proven[spelled[i]] = true;" in _function_body(kind, "rescued")
    assert "_proven[url] === true" in _function_body(kind, "proven")


def test_the_url_file_ack_asks_for_the_title_at_once():
    """Writing the address must not cost a station its first title.

    A station switch spends its one immediate getStreamInfo on writing the
    URL to its owner-only file and returns without spawning the reader. If
    the ack does not then ask, the first track name waits out a whole
    infoTimer interval on top of the reader's own second — measured at
    6.2 s on mains and 16.2 s on battery, with the cover queued behind it.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index('": ICY_SRC;"')
    ack = src[i:i + 1800]
    assert "getStreamInfo(" in ack, (
        "the __ICY_SRC_OK__ ack no longer requests the title — the first "
        "track name is back to waiting out a full poll interval")


def test_the_popup_volume_poll_is_not_slowed_on_battery():
    """This poll runs while the face is watched: with a popup that means
    expanded; on a desktop containment, where expanded is pinned true for
    the applet's life, the pointer stands in and the unattended face coasts
    at thirty seconds instead. Since 2026.44 it also runs, at the unattended
    rate, while a device follows the reading
    (test_the_rooms_reading_is_kept_fresh_while_a_device_follows_it).

    Stretching it on BATTERY bought nothing worth having: the seconds saved
    are seconds the user spends looking straight at the slider it feeds, and
    an external volume or mute change then sat wrong on screen for all of
    them. Pinned because it was tried and reverted: no battery term in the
    interval, and the attended rate stays at two seconds.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index("id: sinkMasterPoll")
    block = src[i:i + 1600]
    m = re.search(r"^\s*interval:\s*(.+)$", block, re.M)
    assert m, "sinkMasterPoll lost its interval"
    assert "thrifty" not in m.group(1) and "onBattery" not in m.group(1), (
        "sinkMasterPoll is being slowed on battery again: %r" % m.group(1))
    assert re.search(r"\b2000\b", m.group(1)), (
        "the attended poll rate drifted off two seconds: %r" % m.group(1))


def test_no_reserved_word_is_used_as_an_identifier():
    """Qt 6.10's QML parser rejects `var final = ...` outright — "Expected
    token `identifier`" at install, the whole widget dead on Kubuntu 26.04
    LTS — while the newer parsers on the development machines accept it
    silently. Reported on the KDE forum the day after 2026.24 shipped; two
    declarations were enough. Every machine here is too new to reproduce
    the failure, so the class is pinned by grep: none of ECMAScript's
    future-reserved words may be DECLARED as a name. Member access like
    obj.final stays legal and is not matched."""
    reserved = (
        "abstract|boolean|byte|char|double|enum|final|float|goto|"
        "implements|int|interface|long|native|package|private|protected|"
        "public|short|static|synchronized|throws|transient|volatile"
    )
    decl = re.compile(
        r"\b(?:var|let|const)\s+(?:%s)\b"
        r"|\bfunction\s+(?:%s)\s*\("
        r"|\bfunction\s*\w*\s*\([^)]*\b(?:%s)\b[^)]*\)"
        r"|\bcatch\s*\(\s*(?:%s)\s*\)"
        r"|\([^()]*\b(?:%s)\b[^()]*\)\s*=>"
        r"|\b(?:%s)\s*=>"
        r"|\bproperty\s+\w+\s+(?:%s)\b"
        % ((reserved,) * 7))
    hits = []
    # Every shipped QML and JS file, not just ui/: the widget's own
    # contents/config/config.qml parses with the same Qt 6.10 parser, and a
    # glob that stopped at ui/ left it unguarded.
    #
    # tests/qml is in the list for the same reason one level up, and it was
    # added the day it bit: a new test file here declared `var long` and
    # every check in the gate stayed green. Not because a broken test file
    # fails quietly — measured on 6.11, qmltestrunner reports an unparseable
    # file as compile() FAIL and exits 1 — but because NOTHING runs these
    # files on an old parser at all: the LTS-parse CI job only qmllints
    # `find package`, and the machines that do run qmltestrunner carry a
    # rolling Qt where `long` is an ordinary name. The break would have
    # surfaced on the first LTS machine that ran the suite — months away
    # from the commit that caused it, with this green tree looking innocent.
    # Both extensions guard .js too: the libraries these tests import ride
    # through the same old parser.
    for p in sorted((ROOT / "package").rglob("*.qml")) \
            + sorted((ROOT / "package").rglob("*.js")) \
            + sorted((TESTS / "qml").rglob("*.qml")) \
            + sorted((TESTS / "qml").rglob("*.js")):
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            if decl.search(line):
                hits.append("%s:%d: %s"
                            % (p.relative_to(ROOT), i, stripped[:70]))
    assert not hits, (
        "Reserved words declared as identifiers — Qt 6.10 refuses to parse "
        "these files at all:\n" + "\n".join(hits))


def test_every_pragma_library_has_its_own_test_file():
    """The quality strategy in one rule: logic lives in .pragma library
    files and every one of them answers to a test file of its own. This
    is the ratchet for shrinking main.qml — an extraction that arrives
    without tests fails here instead of passing silently."""
    missing = []
    for lib in sorted(UI.glob("*.js")):
        if ".pragma library" not in lib.read_text(encoding="utf-8"):
            continue
        expected = TESTS / "qml" / ("tst_%s.qml" % lib.stem.lower())
        if not expected.exists():
            missing.append("%s -> %s" % (lib.name, expected.name))
    assert not missing, (
        "Library files without a matching test file:\n" + "\n".join(missing))


def test_the_widget_ships_its_own_panel_icon_and_falls_back_to_it():
    """The panel icon must survive any icon theme.

    Both names the widget defaults to — audio-radio-symbolic and its
    fallback radio-symbolic — are Breeze's own; neither is in the
    freedesktop naming spec. Measured on the reporting desk: of the icon
    themes installed there, only breeze and breeze-dark carried the first
    one. A listener on openSUSE switched themes and the panel went empty
    (GitHub #4). So the widget carries a copy of its own and the compact
    representation falls through to it when the theme has neither name.
    """
    svg = ROOT / "package" / "contents" / "icons" / "on-air.svg"
    assert svg.is_file(), (
        "package/contents/icons/on-air.svg is gone — without a bundled icon "
        "the panel depends entirely on the user's icon theme")
    body = svg.read_text(encoding="utf-8")
    assert "<svg" in body and "</svg>" in body, "the bundled icon is not an SVG"

    src = (UI / "CompactRepresentation.qml").read_text(encoding="utf-8")
    assert "icons/on-air.svg" in src, (
        "CompactRepresentation no longer references the bundled icon")
    assert "Kirigami.Icon.Error" in src, (
        "nothing watches the icon's status any more, so a theme that lacks "
        "the configured name silently wins again")


def test_what_a_station_sends_reaches_the_panel_as_plain_text():
    """The panel can show artist and title next to its icon (GitHub #14),
    and both are whatever the station put in its stream.

    A label left on Qt's default format decides by itself whether its text
    is markup, and styled text follows an <img> tag to the address in it.
    So every label in the panel item says PlainText, and its rules are
    asked of PanelLogic, where they are tested, not written out here.
    """
    src = _code_only((UI / "CompactRepresentation.qml").read_text(encoding="utf-8"))
    bodies = []
    for m in re.finditer(r"\bLabel\s*\{", src):
        depth, i = 1, m.end()
        while depth and i < len(src):
            depth += {"{": 1, "}": -1}.get(src[i], 0)
            i += 1
        bodies.append(src[m.end():i])
    assert len(bodies) == 2, (
        "the panel item has %d labels, not the two lines this test knows; "
        "a new one must be plain text as well" % len(bodies))
    for body in bodies:
        assert "textFormat: Text.PlainText" in body, (
            "a panel label would read a station's title as markup")
    for rule in ("PanelLogic.lines(", "PanelLogic.shown(", "PanelLogic.stacked(",
                 "PanelLogic.textWidth(", "PanelLogic.widthHints(", "TransportLogic.held("):
        assert rule in src, "the panel item no longer asks %s)" % rule


def test_every_icon_name_the_widget_asks_for_exists_in_breeze():
    """Breeze ships with every Plasma install, so a name Breeze lacks is a
    name nobody has.

    This is how `media-playback-cast` went out: a plausible-looking name
    that exists in no theme at all, on the cast button, blank in exactly
    the state that needed feedback. Names missing only from OTHER themes
    are a different matter — a widget may not carry the whole icon set —
    but a name Breeze itself does not have is simply wrong.
    """
    import sys
    sys.path.insert(0, str(TESTS))
    import icon_theme_lookup as lookup

    if lookup._theme_dir("breeze") is None:
        import pytest
        pytest.skip("breeze icons are not installed on this machine")

    names = set()
    pat = re.compile(
        r'(?:source|fallback|placeholder|iconName|icon\.name)\s*:\s*"([a-z0-9][a-z0-9+.-]*)"')
    for qml in list(UI.rglob("*.qml")):
        for m in pat.finditer(qml.read_text(encoding="utf-8")):
            names.add(m.group(1))

    missing = sorted(n for n in names if lookup.find(n, "breeze") is None)
    assert not missing, (
        "icon names that exist in no theme, Breeze included — these render as "
        "a placeholder wherever they are used: " + ", ".join(missing))


def test_the_relay_tap_hands_the_player_a_head_start():
    """The tap used to start serving the moment the buffer file appeared.

    That handed the player the live edge with no cushion: every time it
    caught up it waited on the network for the next packet, and a listener
    reported the result — a 1.5 Mbps FLAC station stuttering through its
    first ten seconds while low-bitrate streams never did. (The player's
    own buffer is counted in bytes, so the same 64 KiB is 0.35 s of FLAC
    and 4 s of a 128 kbps stream.) Measured on a 1 Mbps FLAC station: a
    modelled player starved once with no lead and never with one.

    The clock cap stays short on purpose — a thin stream never starved,
    so making its listener wait for a cushion it does not need would be a
    fresh bug of its own.
    """
    src = (UI / "relayserve.py").read_text(encoding="utf-8")
    m = re.search(r"^LEAD_BYTES\s*=\s*(\d+)\s*\*\s*1024", src, re.MULTILINE)
    assert m and int(m.group(1)) >= 256, (
        "the relay tap no longer waits for a byte head start before the "
        "first byte reaches the player")
    sec = re.search(r"^LEAD_SEC\s*=\s*([\d.]+)", src, re.MULTILINE)
    assert sec and 0 < float(sec.group(1)) <= 2.0, (
        "the lead's clock cap is missing or long enough to make a "
        "low-bitrate station wait for nothing: %r" % (sec and sec.group(1)))
    # ...and the short clock must apply to THIN streams only. It used to
    # release everyone, which is how the two lossless stations a reporter
    # named started on a fifth of the cushion the byte target intends
    # (measured 2026-08-11: they arrive at 1181 and 749 kbps, needing 3.6
    # and 5.6 s to reach it). A fat stream waits for bytes, capped.
    fat = re.search(r"^FAT_RATE\s*=\s*(\d+)", src, re.MULTILINE)
    assert fat, "the thin/fat discriminator is gone — the clock releases everyone again"
    cap = re.search(r"^MAX_LEAD_SEC\s*=\s*([\d.]+)", src, re.MULTILINE)
    assert cap and 2.0 < float(cap.group(1)) <= 8.0, (
        "the fat stream's cap is missing, too short to hold a real "
        "cushion, or long enough to feel like a hang")
    assert "have >= LEAD_BYTES" in src, (
        "the lead constant is no longer what actually gates the first byte")
    assert "< FAT_RATE" in src, (
        "the wait no longer measures the rate from what has arrived — a "
        "stream must not have to be recognised in advance")
    idle = re.search(r"^IDLE_SLEEP\s*=\s*([\d.]+)", src, re.MULTILINE)
    assert idle and float(idle.group(1)) <= 0.1, (
        "the tap's idle wait grew back: at 200 ms it was itself a gap the "
        "player could run dry in (measured cost of 50 ms: 0.1% CPU)")


def test_a_hidden_tab_never_leaves_the_listener_on_its_page():
    """Tabs can be switched off (asked for on GitHub: give the space back).

    Two roads reach a hidden page and both must bounce: arriving at one
    (a swipe, a restored index) and switching off the tab you are already
    standing on. The second was missed the first time — no view changes,
    so a guard hanging off onViewChanged alone never hears about it, and
    the page stays on screen with its tab gone (caught on the bench).
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    m = re.search(r"onViewChanged: \{?[^}]*_ensureViewVisible\(\);", src)
    assert m, (
        "arriving at a hidden page is no longer guarded")
    for key in ("onShowMusicTabChanged", "onShowPodcastsTabChanged",
                "onShowTimersTabChanged"):
        assert "%s() { root._ensureViewVisible() }" % key in src, (
            "%s does not re-check the current page: switching that tab off "
            "while standing on it strands the listener there" % key)
    # The walk itself is ViewLogic.nextVisibleView, under tst_viewrules: it
    # looks the way the listener was going first (it used to look forward
    # whatever the direction, and a step back from My Music with Playing
    # off landed on My Music), and Stations is its floor.
    body = _function_body(src, "_ensureViewVisible")
    assert ("ViewLogic.nextVisibleView(view, view < _viewWas ? -1 : 1, shownViews())"
            in body), (
        "the guard no longer asks the tested walk, or no longer tells it "
        "which way the listener was going")
    assert "_viewWas = to" in body and re.search(r"\bview = to\b", body), (
        "the guard stopped landing on the page the walk named, or stopped "
        "remembering it — the next step's direction is read against it")
    # Escape goes home to the first page that HAS a tab and closes the popup
    # only from there. It went to page 0 whatever was shown: with Stations
    # off the guard walked it on to Playing, and four presses left the view
    # at 1, 1, 1, 1 with the popup still open.
    rep_code = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = rep_code.index("event.key === Qt.Key_Escape")
    esc = rep_code[at:rep_code.index("event.key === Qt.Key_Space", at)]
    assert "var home = ViewLogic.firstVisibleView(root.shownViews())" in esc, (
        "Escape no longer asks which page is the first one shown")
    assert "root.view !== home" in esc and "root.view = home" in esc, (
        "Escape goes somewhere other than the first shown page, so with "
        "Stations switched off it can never reach the popup")
    assert "root.view === 0 && filterField.text !== \"\"" in esc, (
        "Escape clears the station filter from a page that is not the "
        "station list, and is held back by a field nobody can see")
    # The UI half lives in FullRepresentation.qml and the first version of
    # this test never opened it — a refactor could have dropped every
    # visible: binding while the test stayed green.
    rep = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    for i in range(5):
        assert "visible: root.viewVisible(%d)" % i in rep, (
            "tab %d lost its visibility binding — the switch in Settings "
            "no longer hides anything" % i)
    # An invisible TabButton keeps its equal-share slot on this Qt
    # (measured: a hidden tab held its 100px of a 500px bar, a dead hole
    # in the middle), and simply zeroing it is not enough either: the
    # survivors then keep their old fifth each and huddle at the left,
    # which is what the listener photographed the day the switches
    # shipped. Every tab sizes itself from the VISIBLE count.
    assert rep.count("navTabs.availableWidth / fullRepresentation._visibleTabCount") == 5, (
        "a tab stopped sharing the bar by visible count — either a hidden "
        "one keeps its slice, or the survivors keep their old width and "
        "leave a hole beside them")
    assert "_visibleTabCount" in rep and "on_VisibleTabCountChanged" in rep, (
        "the visible-tab count is gone or no longer re-measures the "
        "popup's floor — a widget down to two tabs would still demand "
        "the width of five")
    # In-app jumps to the Podcasts page must close with its tab: both
    # doors used to stay live and the guard walked the click on to
    # Timers, a page nobody asked for.
    assert "visible: podcastFolder.count > 0 && root.viewVisible(3)" in rep, (
        "the My Music bridge row no longer honours a hidden Podcasts tab")


def test_a_heal_generation_is_claimed_fresh_and_abandoned_whole():
    """Healing is the only road that rewrites the user's SAVED address.

    The whole safety of that road is one integer. A heal run takes a
    generation number, every network reply it started compares its own
    number against the current one before it writes anything, and any
    road that abandons the run bumps the number so the strays die. Two
    halves, and the road is only safe while BOTH hold:

      * the run must claim a FRESH number (pre-increment). Reading the
        number without bumping it leaves every earlier run in flight
        still matching, and a slow reply from an attempt the user has
        already walked away from can land afterwards and write the wrong
        URL into their station list.
      * abandoning a generation must also drop the pending audition. The
        commit path (onMediaStatusChanged's BufferedMedia branch →
        _healCommit) does NOT look at the generation at all — its only
        gate is that _healPendingUrl is still set and still equals the
        player's source. Bump without clearing and an abandoned audition
        can still commit.

    Measured 2026-08-09 on e4d9eb1: both halves hold on all five sites,
    and mutation 05-heal-generation-check (which turns the pre-increment
    into a plain read) walked past the entire gate before this test
    existed.

    This reads the source as text, so say what that cannot see: it proves
    the bookkeeping is SHAPED right, not that a late reply is dropped at
    runtime. The behavioural version wants the run bookkeeping out of
    main.qml and under qmltestrunner.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    lines = src.splitlines()

    # Both spellings count everywhere below: main.qml already writes the
    # sibling counter as `root._previewSeq++;` in half its sites, so a
    # pattern that only knows the bare form goes quietly blind the day a
    # heal site is written house-style.
    body = _function_body(src, "_tryHealStation")
    assert re.search(r"\+\+(root\.)?_healSeq", body), (
        "the heal run no longer claims a fresh generation — every reply "
        "from an abandoned earlier run still matches, and one of them can "
        "overwrite the user's saved station address")
    creators = len(re.findall(r"\+\+(?:root\.)?_healSeq", src))
    assert creators == 1, (
        "a second place creates heal generations (%d found); one creator "
        "is what makes the number mean 'the run that is current'" % creators)

    # Bare `_healSeq++;` statements are the abandon sites. The creator uses
    # the pre-increment form above, so the two never get confused here.
    # The alarm tone's site moved into the engine with the fire half and
    # speaks facade (`app._healSeq++;`) — counted from there, same rules.
    eng_lines = (UI / "AlarmEngine.qml").read_text(encoding="utf-8").splitlines()
    bumps = [i for i, ln in enumerate(lines)
             if re.match(r"^\s*(root\.)?_healSeq\+\+;\s*$", ln)]
    eng_bumps = [i for i, ln in enumerate(eng_lines)
                 if re.match(r"^\s*app\._healSeq\+\+;\s*$", ln)]
    assert len(eng_bumps) >= 1, (
        "the wake tone no longer abandons the heal generation — a heal "
        "audition in flight can replace the looping chime")
    assert len(bumps) + len(eng_bumps) >= 4, (
        "only %d road(s) abandon a heal generation — the stop, the local "
        "file, the alarm tone and the station switch each owe one"
        % (len(bumps) + len(eng_bumps)))
    for i in eng_bumps:
        near = "\n".join(eng_lines[max(0, i - 2):i + 3])
        assert "_healClearPending()" in near, (
            "AlarmEngine.qml:%d bumps the heal generation without dropping "
            "the pending audition" % (i + 1))
    for i in bumps:
        near = "\n".join(lines[max(0, i - 2):i + 3])
        assert "_healClearPending()" in near, (
            "main.qml:%d bumps the heal generation without dropping the "
            "pending audition — _healCommit does not check generations, so "
            "the stray can still be written to the saved address" % (i + 1))

    # Every rung that comes back from the network compares before it
    # writes — and the COUNT is pinned per function, because the entry
    # guard alone satisfied a mere `in`: delete the reply-side check in
    # _healNameSearch or the async playlist-callback check in _healAdvance
    # and `'!== _healSeq' in body` stayed green while the exact stray this
    # docstring warns about was free to land (measured 2026-08-09).
    guards = {"_tryHealStation": 1, "_healNameSearch": 2, "_healAdvance": 2}
    for fn, want in guards.items():
        got = len(re.findall(r"!== (?:root\.)?_healSeq", _function_body(src, fn)))
        assert got == want, (
            "%s carries %d generation checks, expected %d — the missing one "
            "is the reply-side guard, the only thing between an abandoned "
            "run's late network callback and the generation-blind commit "
            "path. A NEW legitimate check moves this number UP in the same "
            "commit." % (fn, got, want))


def _code_only(src):
    """Drop // comments. A prose mention must never satisfy a code check —
    the retry guards below were briefly passing on a comment that named the
    very function whose call had been removed."""
    return "\n".join(re.sub(r"//.*$", "", ln) for ln in src.split("\n"))


def _no_comments(src):
    """_code_only, and block comments too, but only one that opens its own
    line. Taking every "/*" up to the next "*/" took 4848 of main.qml's 7701
    lines with it (measured 2026-11-10): an Accept header of "*/*" opens such
    a comment, and whatever a check was looking for in there went unseen."""
    return _code_only(re.sub(r"^[ \t]*/\*.*?\*/", "", src, flags=re.S | re.M))


def test_the_retry_switch_gates_the_ladder_and_not_the_network():
    """The listener's retry switch must reach the ladder and stop there.

    Asked for on issue #13: a station that dies while the connection is fine
    was retried forever, and there was no way to say no. The switch belongs on
    the ladder's single arming point — and NOT on the resume that follows the
    network coming back, which is the one case people expect to be handled for
    them. Those are separate roads (onIsConnectedChanged -> netResumeTimer),
    and this pins them apart so a later tidy-up cannot merge them.

    Alarms are the one exemption and it is deliberate. A wake-up raises the
    standing order itself and hands the later death of its station to this
    very ladder — the chime only covers the first 25 seconds — so a setting
    about ordinary listening must never be able to silence one. Scheduled
    recordings genuinely do not lean on this road: they run their own ffmpeg
    with their own relaunch.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")

    arm = _code_only(_function_body(src, "_healArmRetry"))
    assert "_mayKnock(" in arm, (
        "_healArmRetry no longer asks whether it may knock — a listener who "
        "turned the switch off, or whose budget ran out, is knocked at anyway")

    # The single predicate the three sites share. It has to read all three
    # inputs, or one of them silently stops counting.
    knock = _code_only(_function_body(src, "_mayKnock"))
    for needed in ("autoRetry", "_alarmStandingOrder", "autoRetryKnocks"):
        assert needed in knock, (
            "_mayKnock stopped reading %s, so that input no longer decides "
            "anything at any of its call sites" % needed)

    # The ladder's spacing belongs to the library that is tested for it.
    assert "RetryLogic.nextRetryMs" in arm, (
        "the retry interval is computed in main.qml again — the arithmetic "
        "has a behavioural test only where it lives, in RetryLogic.js")

    # One arming point is what makes one guard enough.
    starts = len(re.findall(r"healRetryTimer\.(?:re)?start\(\)", src))
    assert starts == 1, (
        "the retry ladder now arms in %d places; the switch guards one of them, "
        "so a second site is a hole. Route it through _healArmRetry." % starts)

    # The network-back road must stay open regardless of the switch.
    i = src.index("id: netResumeTimer")
    net = src[i:src.index("\n        }", i)]
    assert "autoRetry" not in net, (
        "the network-back resume is gated by the retry switch — that is the "
        "one recovery a listener asked to KEEP")


def test_the_retry_switch_also_covers_the_address_lookup():
    """Switched off, the whole road back stops — not only the ladder.

    Shipped half-wired in 2026.37 and measured the next day. The switch was
    read where the ladder arms and nowhere else, so _tryHealStation still ran
    its directory lookup, found the station's new address and started playing
    it. The setting promises that a dead stream simply stops; with address
    healing on, which is the default, it did not. Both roads ask now.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    heal = _code_only(_function_body(src, "_tryHealStation"))
    assert "_mayKnock(" in heal, (
        "_tryHealStation no longer asks whether it may knock — someone who "
        "turned the switch off, or whose budget ran out, still gets the "
        "station started from the directory lookup")


def test_a_wake_up_keeps_its_road_back_whatever_the_switch_says():
    """An alarm must never end in silence because of the retry setting.

    The alarm raises the standing order itself and hands the later death of
    its station to the heal road; the bundled chime only guards the first 25
    seconds. So every place the switch may refuse has to let a wake-up
    through, or an alarm set for 7:00 goes quiet at 7:10 with the sleeper
    still asleep. The flag lives exactly as long as the standing order it
    qualifies: raised with it, cleared by the same "I'm up".
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    # Every road that may refuse to knock goes through the one predicate,
    # and that predicate hands the alarm through ahead of both refusals.
    refusals = re.findall(r"if \(!_mayKnock\([^\n]*", _code_only(src))
    assert len(refusals) >= 2, (
        "expected the refusal on both the ladder and the address lookup, "
        "found %d — a road that decides for itself can forget the alarm"
        % len(refusals))
    assert not re.search(r"autoRetry !== true|configuration\.autoRetry ===",
                         src.replace(_function_body(src, "_mayKnock"), "")), (
        "the retry switch is read outside _mayKnock; that is how 2026.37 "
        "shipped with the address lookup unguarded")

    logic = (UI / "RetryLogic.js").read_text(encoding="utf-8")
    exempt = logic.index("if (exempt === true) return true;")
    for later in ("if (enabled !== true)", "return (attempts | 0) < c;"):
        assert logic.index(later) > exempt, (
            "the alarm's exemption no longer comes before %r, so a wake-up "
            "can be refused by it" % later)

    alarm = (UI / "AlarmEngine.qml").read_text(encoding="utf-8")
    assert "_alarmStandingOrder = true" in alarm, (
        "the alarm no longer raises its standing order, so the exemptions "
        "guarding it can never be true")
    stand_down = _function_body(alarm, "standDown")
    assert "_alarmStandingOrder = false" in stand_down, (
        "the alarm's standing order outlives the sleeper saying 'I'm up'")


def test_every_minute_dial_stops_on_its_own_grid():
    """A five-minute stepper whose ceiling is 59 steps off its own grid.

    Found by driving the widget, 2026-09-18: one press down from :00 on the
    wake-up dial gave :59, not :55. From there the box walks 54, 49, 44 and
    never returns to a round minute — two disjoint cycles on one control.
    Nobody sets an alarm for :59 on a five-minute dial; they land there by
    accident and cannot get back. The ceiling has to be a multiple of the
    step, so 55.
    """
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    for name in ("alarmMM", "schedMM", "podAlarmMM"):
        i = src.index("id: %s" % name)
        # Strip comments FIRST, then take the window: a long comment above
        # the properties used to push stepSize out of a fixed-size slice, and
        # the check then read the default step of 1 and passed on anything.
        blk = _code_only(src[i:i + 2500])
        nxt = blk.find("QQC2.SpinBox")
        if nxt > 0:
            blk = blk[:nxt]
        top = re.search(r"to:\s*(\d+)", blk)
        step = re.search(r"stepSize:\s*(\d+)", blk)
        assert top and step, (
            "%s lost its range or its step; this check cannot speak for a "
            "dial whose grid it cannot see" % name)
        s_, t_ = int(step.group(1)), int(top.group(1))
        assert t_ % s_ == 0, (
            "%s steps by %d but stops at %d — the last step leaves the grid "
            "every other step lands on" % (name, s_, t_))


def test_the_recording_length_box_starts_and_stops_on_its_own_grid():
    """The same fault at the other end of a dial. "Max length" stepped by 30
    from a floor of 10: one walk down to the floor and the arrows gave 40,
    70, 100 from then on, with the default of 180 out of their reach. Both
    ends have to be multiples of the step. tst_recordingpage walks the real
    page; this keeps the three numbers from drifting apart again, and keeps
    the read-back of a typed value on the tested parser: the box shows
    "1,440 min", and parseInt made 1 of that when the field lost focus.
    """
    src = _code_only((UI / "config" / "configRecording.qml").read_text(encoding="utf-8"))
    i = src.index("id: recMaxSpin")
    blk = src[i:src.index("QQC2.Label", i)]

    def number(key):
        m = re.search(r"^\s*%s:\s*([\d *]+)$" % key, blk, re.M)
        assert m, "the Max length box lost its %r; this check cannot see its grid" % key
        out = 1
        for part in m.group(1).split("*"):
            out *= int(part)
        return out

    lo, hi, step = number("from"), number("to"), number("stepSize")
    assert lo % step == 0 and hi % step == 0, (
        "Max length steps by %d between %d and %d: an end that is not a "
        "multiple of the step takes every later press off the grid" % (step, lo, hi))
    assert re.search(r"^\s*editable: true\s*$", blk, re.M), (
        "a length can no longer be typed into the box")
    assert "valueFromText: function(t) { return RecLogic.typedMinutes(t, 180) }" in blk, (
        "the typed length is read some other way than the tested one; "
        "parseInt reads the grouped \"1,440 min\" as 1")


def test_the_chosen_podcast_speed_reaches_the_config():
    """A readonly binding cannot be assigned, and the throw eats the save.

    main.qml holds _podSpeeds as a readonly binding to the engine's map, so
    the in-place mutations above work but the prune — which returns a NEW
    object — must land on the engine. It landed here instead and threw, and
    the config write on the very next line never ran. The speed applied and
    held for the session, so nothing looked wrong until the next start put
    every show back at 1.0x. Found by a hunt, 2026-09-19, and confirmed
    against the declaration.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "setPodcastRate"))
    assert not re.search(r"(?<![.\w])_podSpeeds\s*=", body), (
        "setPodcastRate assigns to main.qml's own _podSpeeds, which is a "
        "readonly binding — that throws and the config write below it never "
        "runs. Assign to podcastEngine._podSpeeds instead.")
    assert "podcastEngine._podSpeeds =" in body, (
        "nothing writes the pruned map back to the engine, so the prune is "
        "thrown away and the map grows without limit")
    assert "Plasmoid.configuration.podcastSpeeds" in body, (
        "the chosen speed is never persisted")


def test_every_tab_switch_is_watched_and_the_guard_runs_at_startup():
    """Hiding a tab must never leave the listener standing on it.

    Two halves, both measured 2026-09-19. The Connections block watched
    three of the five tab switches, so hiding Stations or Playing while
    standing on that page moved nothing and left a page on screen whose
    button was gone. And the guard was only ever reached from onViewChanged
    — a view that starts at 0 emits no change, so at startup it never ran at
    all: hide the Stations tab and every login handed it back, with no tab
    highlighted because its own button is hidden.

    The key list is read from main.xml so a sixth tab cannot be added
    without this noticing.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    cfg = (UI.parent / "config" / "main.xml").read_text(encoding="utf-8")
    keys = re.findall(r'<entry name="(show\w*Tab)"', cfg)
    assert len(keys) >= 5, "expected the tab switches in main.xml, found %r" % keys

    i = src.index("function onShowMusicTabChanged")
    block = _code_only(src[src.rindex("Connections", 0, i):i + 600])
    for k in keys:
        handler = "on" + k[0].upper() + k[1:] + "Changed"
        assert handler in block, (
            "%s has no %s — switching that tab off while standing on its page "
            "leaves the listener there with no button to leave by" % (k, handler))

    started = _code_only(_function_body(src, "Component.onCompleted")
                         if "function Component.onCompleted" in src
                         else src[src.index("Component.onCompleted"):
                                  src.index("Component.onCompleted") + 2000])
    assert "_ensureViewVisible()" in started, (
        "the visible-view guard is never asked at startup, so a hidden tab "
        "can still be the page the popup opens on")


def test_the_buffer_sweep_runs_before_anything_else_the_start_does():
    """The start clears what a host that died without a teardown left behind.

    Measured on the bench 2026-09-23: the viewer was killed while a FLAC
    preview played through the relay, and the writer chain (sh, timeout,
    curl, ffmpeg -t 3600) lived on under systemd --user at ~128 KiB/s. The
    next start never looked. The sweep's age line is the moment it is called,
    so it has to come before anything that can arm: a url file written first
    is older than the line and would be swept out from under its own writer,
    which then dies at birth and bans the station from the relay for ten
    minutes.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    at = src.index("Component.onCompleted")
    started = _code_only(src[at:at + 2000])
    assert "timeshift.startup(Date.now())" in started, (
        "the start never sweeps the buffer directory, so a crashed session's "
        "writer and its hour of buffer stay behind")
    assert started.index("timeshift.startup(") < started.index("_ensureViewVisible()"), (
        "the buffer sweep is no longer the first thing the start does")


def test_starring_a_web_result_holds_its_references_before_it_removes_the_row():
    """A delegate cannot reach its own scope after it has been destroyed.

    Found by running the widget and clicking the star, 2026-09-18:
    "ReferenceError: fullRepresentation is not defined". starThisRow ran
    inside the row's own delegate and called webResultsModel.remove() in the
    middle — which destroys that delegate. Everything after the remove was
    executing in a torn-down context, so the file-scope id no longer
    resolved, the result cap never shrank, and keyboard focus never landed.
    Nothing looked wrong at the time, because the station HAD been added:
    the damage shows up later as "Show more" going missing over a page the
    directory still has more of.

    The rule this pins: take the references you need after the removal
    BEFORE performing it. A grep, because the failure is a runtime scope
    teardown that neither qmllint nor the offscreen smoke test can see.
    """
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _function_body(src, "starThisRow")
    code = _code_only(body)
    cut = code.index(".remove(")
    after = code[cut:]
    for name in ("fullRepresentation.", "webRepeater.", "webResultsModel."):
        assert name not in after, (
            "starThisRow touches %s after webResultsModel.remove() destroyed "
            "the delegate — that lookup runs in a dead scope and throws. "
            "Hold the reference in a local before the remove." % name)
    before = code[:cut]
    assert ("= fullRepresentation" in before and "= webRepeater" in before
            and "= webResultsModel" in before), (
        "starThisRow no longer captures its references before the removal; "
        "the next edit that needs one of them will reintroduce the throw")


def test_the_bitrate_fallback_does_not_play_over_a_park():
    """Every other recovery road asks whether the listener still wants sound.
    This one did not: a park stops the timer, but it leaves the player's
    source in place, so an error delivered after the park arms it again and
    600 ms later it plays. The guard sits where the sound would start.
    """
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    start = code.index("id: bitrateFallbackTimer")
    fire = code[start:code.index("playMusic.play()", start)]
    assert "_tsPaused" in fire, (
        "bitrateFallbackTimer plays without asking whether the room is parked")


def test_unticking_timeshift_does_not_wake_a_listener_who_said_quiet():
    """Turning the feature off mid-session sends whoever is behind live back
    to the broadcast before the buffer goes. It did that for a PARKED station
    too, and for one paused inside the buffer: tsPlayLive raises the standing
    order and starts the stream, so a checkbox in the settings put the radio
    back on over a pause. Whoever said quiet gets a stop instead.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "onTimeshiftEnabledChanged"))
    live = body.index("tsPlayLive(")
    line = body[body.rfind("\n", 0, live) + 1:body.index("\n", live)]
    assert "_tsPaused" not in line, (
        "a parked station is sent back to live by the checkbox (%r)" % line.strip())
    before = body[:live]
    assert "_tsPaused" in before and "!isPlaying()" in before and "stopWithFade()" in before, (
        "nothing stands between a paused listener and tsPlayLive in the "
        "settings handler: the park and the paused buffer must end in a stop")


def test_a_standing_order_cannot_outlive_a_night_asleep():
    """The knock budget is counted on QML timers, which stand still while the
    machine sleeps, so an order with knocks left survives the night and the
    network coming back in the morning replays it: a radio that starts on its
    own nine hours after it went quiet, which is issue #13 by another road.
    The relay road can also leave the order standing with no ladder under it.

    Both come through one door. _replayOrder asks the wall clock before it
    plays anything, the ladder stamps the moment the station went quiet, and
    sound arriving clears the stamp.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")

    replay = _code_only(_function_body(src, "_replayOrder"))
    assert "RetryLogic.orderExpired(" in replay, (
        "_replayOrder plays without asking whether the order is still good")
    asked = replay.index("RetryLogic.orderExpired(")
    assert asked < replay.index("refreshServer("), (
        "_replayOrder asks the deadline after it has already replayed")
    line = replay[asked:replay.index("\n", asked)]
    assert "_orderSpent()" in line, (
        "an expired order is refused without being ended (%r); left standing "
        "it is replayed at the next flicker of the network" % line)
    assert "_alarmStandingOrder" in line, (
        "the deadline does not hand an alarm through: a wake-up must ring")

    # The ladder's first knock is dated by the last moment the order was
    # heard, not by now: a death first noticed after a night stamped the
    # morning and the replay found it fresh (2026-09-29).
    stamp = "_orderQuietSince = RetryLogic.orderSince(0, root._orderHeardAt, Date.now())"
    arm = _code_only(_function_body(src, "_healArmRetry"))
    assert stamp in arm, (
        "the ladder no longer dates its first knock from when the order was last heard")
    assert arm.index(stamp) < arm.index("_healRetryAttempts++"), (
        "the stamp is taken after the count moved, so a second death keeps the first one's time")

    spent = _code_only(_function_body(src, "_orderSpent"))
    assert "_orderQuietSince = 0" in spent, "a spent order keeps its stamp"

    code = _code_only(src)
    buffered = code.index("root._healRetryAttempts = 0;\n                healRetryTimer.stop();")
    assert "_orderQuietSince = 0" in code[buffered:buffered + 200], (
        "sound arriving does not clear the stamp: the next outage would be "
        "judged by the age of the last one")


def test_the_deadline_counts_from_when_the_order_was_last_heard():
    """A playing station carries no quiet stamp, so the deadline needs another
    moment to subtract. Measured on 2026-09-27: _replayOrder stamped Date.now()
    when the stamp was missing, which nothing is ever older than, so the guard
    added for the nine-hour report passed every time the radio was playing when
    the lid closed."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    replay = _code_only(_function_body(src, "_replayOrder"))
    assert "RetryLogic.orderSince(" in replay, (
        "_replayOrder no longer dates the order before judging it")
    assert replay.index("RetryLogic.orderSince(") < replay.index("RetryLogic.orderExpired("), (
        "the order is judged before it is dated")
    assert "Date.now()" not in replay[:replay.index("RetryLogic.orderSince(")], (
        "something takes the clock before the order is dated — the stamp that "
        "made the deadline pass was exactly such a line")

    code = _code_only(src)
    buffered = code.index("root._healRetryAttempts = 0;\n                healRetryTimer.stop();")
    assert "_orderHeardAt = Date.now()" in code[buffered:buffered + 260], (
        "sound arriving does not date the order, so a night asleep cannot be "
        "told from a moment ago")

    beat = code[code.index("id: orderHeartbeat"):]
    beat = beat[:beat.index("}")]
    assert "_wantsPlaying" in beat and "isPlaying()" in beat, (
        "the heartbeat runs without an order or without sound, so it would go "
        "on dating an order nothing is serving")
    assert "RetryLogic.beatOnTime(" in beat and "onRunningChanged: beatAt = Date.now()" in beat, (
        "the heartbeat no longer tells a tick after a wake from one on time; a "
        "stream that stops sending stays Playing, so the wake tick would date it")
    assert "interval: 10000" in beat, (
        "the heartbeat ticks slower than the relay writer's curl redials a silent "
        "socket (32 s), so the morning hears last night's station first")
    assert "else if (!root._casting) _orderLapsed();" in beat, (
        "a late tick does not ask the door: a dead stream still showing Playing "
        "gets counted as heard by the next tick and the night comes back")

    for fn in ("_orderSpent", "stopWithFade"):
        body = _code_only(_function_body(src, fn))
        assert "_orderHeardAt = 0" in body, (
            "%s leaves the last-heard moment behind; the next order would "
            "inherit it and could be judged already expired" % fn)


def test_the_player_offers_a_stop_a_listener_can_reach():
    """The big button is a Pause on any station with a buffer behind it and a
    Play between two knocks, so on 2026-09-27 there was no control on the
    Playing tab that meant off — while a pause keeps the connection and the
    capture running."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    assert "TransportLogic.stopOffered(" in code, (
        "the Playing tab no longer asks whether a stop should be offered")
    at = code.index("TransportLogic.stopOffered(")
    window = code[max(0, at - 400):at + 400]
    assert "media-playback-stop" in window, "the control that asks is not a stop"
    assert "stopWithFade()" in window, (
        "the stop offered does not call stopWithFade, the one road that ends "
        "the standing order, the ladder's timer and the network resume")
    assert "visible:" in code[max(0, at - 60):at], (
        "stopOffered no longer decides whether the control is there")


def test_a_spent_budget_takes_the_standing_order_down_with_it():
    """Stopping the knocking is not enough — the order has to end too, on
    BOTH roads that may refuse it.

    netResumeTimer resumes on _wantsPlaying alone, and that is deliberate:
    the connection coming back is the one recovery people asked to keep. The
    cost is that an order which outlives its ladder stays armed forever, so a
    station that died at three in the morning gets put on at seven by an
    unrelated network flicker. That is issue #13 word for word.

    The first version of this fix, 2026-09-18, reached only _healArmRetry and
    left _tryHealStation's refusal a bare return — and that bare return is
    the one the DEFAULT configuration takes: with address healing on, a
    listener who unticks the retry switch never reaches the ladder at all.
    So the teardown lives in one function and both refusal lines call it.

    An alarm reaches neither branch: _mayKnock hands a wake-up through ahead
    of both refusals, which is what keeps the wake-up promise whole.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")

    spent = _code_only(_function_body(src, "_orderSpent"))
    for needed in ("_wantsPlaying = false", "_orphanOrder = null",
                   "_healRetryAttempts = 0", "healRetryTimer.stop()"):
        assert needed in spent, (
            "_orderSpent no longer does %s; an explicit stop clears it and "
            "this is the same end of the same order" % needed)

    for fn in ("_healArmRetry", "_tryHealStation"):
        body = _code_only(_function_body(src, fn))
        i = body.index("if (!_mayKnock(")
        line = body[i:body.index("\n", i)]
        assert "_orderSpent()" in line, (
            "%s refuses to knock without ending the standing order (%r). A "
            "bare return leaves it armed, and the network-back resume will "
            "start the dead station hours later." % (fn, line.strip()))


def test_the_off_the_air_message_says_what_will_actually_happen():
    """One word per outage, and it has to be true.

    The give-up toast promised "trying again in the background" whatever the
    settings said. With the switch off nothing was going to be tried at all,
    and with a budget the knocking now stops on its own — so a listener was
    told to wait for music that had already stopped coming. Found while the
    budget went in, 2026-09-18; it had been wrong since the switch shipped.
    The toast asks the same predicate the ladder does, so the two cannot
    tell the listener different stories.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index('i18n("Station seems to be off the air")')
    # Back up to the enclosing guard, forward past the notify call.
    head = src.rindex("if (root._healRetryAttempts === 0)", 0, i)
    block = _code_only(src[head:src.index('"network-disconnect");', i)])
    assert "_mayKnock(" in block, (
        "the off-the-air message no longer asks whether anything will be "
        "retried, so it can promise a road that is switched off")
    assert "RetryLogic.budgetMs" in block, (
        "the message no longer distinguishes a bounded run from an endless "
        "one, so it cannot tell the listener the knocking will stop")

    # And it stays one message per outage: the backoff rounds are quiet.
    assert src.count('i18n("Station seems to be off the air")') == 1, (
        "the off-the-air toast fires from more than one place; an outage "
        "would nag once per rung of the ladder")


def test_a_stop_still_silences_everything_it_used_to():
    """The parity below measures a park AGAINST a stop, so a line taken out of
    the stop shrinks the yardstick and both stay green — and the stop is the
    road most people take. This is the floor under it: every clock and every
    in-flight generation a stop ended on 2026-09-21, read from the code with
    its comments stripped, because a comment that mentions a timer satisfied
    a grep here once already.

    Each of these was its own road back to sound in issue #13: the retry
    ladder, the directory lookup, the network's return, the stall restart,
    the relay rescue, the 600 ms bitrate fallback, and the replies still in
    the air when the listener pressed the button.
    """
    body = _code_only(_function_body((UI / "main.qml").read_text(encoding="utf-8"),
                                     "stopWithFade"))
    silenced = (set(re.findall(r"(\w+)\.stop\(\)", body))
                | set(re.findall(r"(_\w+Seq)\+\+", body)))
    floor = {"infoTimer", "connectWatchdog", "stallTimer", "relayRescue",
             "healTimer", "healRetryTimer", "netResumeTimer",
             "bitrateFallbackTimer", "_healSeq", "_previewSeq", "_resolveCallSeq"}
    gone = sorted(floor - silenced)
    assert not gone, (
        "a stop no longer ends %s — it keeps running after the listener "
        "pressed Stop, and each of these has started the radio again before"
        % ", ".join(gone))
    # The engine's teardown is one function the station list's stop shares;
    # test_a_servers_write_that_ends_the_order_ends_the_relay_with_it holds
    # what is inside it.
    for order in ("_wantsPlaying = false", "_orphanOrder = null",
                  "_healRetryAttempts = 0", "_tsSessionOver()"):
        assert order in body, (
            "a stop no longer does %s: the standing order outlives the stop" % order)


def test_a_park_inherits_the_stops_teardown():
    """Whatever a full stop silences, a park must silence too.

    This is the root of issue #13's second half. stopWithFade stopped
    thirteen things; timeshiftPause stopped three, and every road that woke a
    parked room ran on one of the ten left behind — the heal ladder on its
    timers, the search preview on an in-flight directory reply, the bitrate
    fallback on a pending 600 ms retry. Guarding each road one at a time is
    how the list got long in the first place, so the parity is the invariant:
    a new timer added to the stop road fails here until the park road has it
    too (measured 2026-09-18, five of thirteen inherited).

    fadeInAnimation is the one allowed difference: it is the visual crossfade,
    not a road to audio, and a park keeps its own fade behaviour.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")

    def body(name):
        return _function_body(src, name)

    def silenced(text):
        return (set(re.findall(r"(\w+)\.stop\(\)", text))
                | set(re.findall(r"(_\w+Seq)\+\+", text)))

    stop = silenced(body("stopWithFade"))
    park = silenced(body("timeshiftPause"))
    allowed = {"fadeInAnimation", "fadeOutAnimation", "playMusic"}

    missing = sorted((stop - park) - allowed)
    assert not missing, (
        "a park no longer inherits the stop's teardown — %s still run(s) "
        "while the listener believes the radio is paused. Either stop it in "
        "timeshiftPause too, or add it to `allowed` with the reason why it "
        "cannot reach audio." % ", ".join(missing))


def test_every_automatic_recovery_road_asks_the_intent_not_the_state():
    """A road that restarts audio by itself must ask _recoveryWanted().

    isPlaying() answers "is sound coming out right now". A parked station
    answers no to that while the listener's standing order is already down,
    so a guard written on the state lets a recovery road run over a park.
    That is issue #13's second half: the retry ladder guarded on the intent
    from the start, the heal ladder guarded on the state at four sites, and
    the relay tap dying at its window cap walked all four — pause before
    lunch, music an hour later (measured 2026-09-18, HEAD b959c81).

    The fix is one shared gate rather than four repeated answers, so this
    invariant pins the gate's definition AND its use. A new recovery road
    that forgets it fails here instead of in somebody's living room.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")

    gate = _function_body(src, "_recoveryWanted")
    for flag in ("_wantsPlaying", "_tsPaused", "_casting"):
        assert flag in gate, (
            "_recoveryWanted no longer reads %s — the gate must answer "
            "'does the listener still want music', and a park (_tsPaused) "
            "is exactly the case isPlaying() cannot see" % flag)

    # Every heal rung, entry and reply side alike. The reply sides matter
    # most: they run after a network round-trip, which is precisely when a
    # park can have landed in the meantime.
    for fn in ("_tryHealStation", "_healNameSearch", "_healAdvance"):
        body = _function_body(src, fn)
        assert "_recoveryWanted()" in body, (
            "%s does not ask _recoveryWanted() — it can run over a parked "
            "station and start playing with nobody asking" % fn)

    # The ladder that was already right must stay right.
    for fn in ("_healArmRetry",):
        body = _function_body(src, fn)
        assert "_wantsPlaying" in body, (
            "%s stopped checking the standing order" % fn)

    # The preview ladder is the exception that proves the rule: an audition
    # never raises the standing order, so the shared gate would switch it off
    # entirely. It carries its own identity check (_previewSeq/_previewUrl)
    # that every rung passes through, and the park rides along there.
    prev = _function_body(src, "_previewRetryByIdentity")
    assert "_tsPaused" in prev, (
        "_previewRetryByIdentity no longer checks the park — a parked "
        "audition can be retried into playing by a late directory reply")

    # The stall timer is the third road and the least obvious: a relay tap
    # dying under a park reaches the player as StalledMedia, and the timer's
    # own answer to a stall is playMusic.play(). It backs off 15 s to 5 min,
    # which is exactly the window the report described.
    stall = src[src.index("id: stallTimer"):]
    stall = stall[:stall.index("\n        }")]
    assert "_tsPaused" in stall, (
        "the stall timer no longer checks the park — a parked station whose "
        "tap died is read as a stall and played again, every backoff round")


def test_every_qml_file_imports_the_js_library_it_calls():
    """A missing .js import is a silent ReferenceError, not a load error.

    Measured 2026-08-10, and it had already shipped: ArtworkEngine.qml called
    SearchLogic five times without importing it. Every call sat inside the
    lookup's own `try { … } catch(e) {}`, so the ReferenceError was swallowed
    and reported as a transient network failure — album art was 100% dead from
    the moment the engine landed, and because "transient" is deliberately not
    cached, it retried on every single track and never once succeeded.

    Nothing in the gate could see it. qmllint does report the five unqualified
    accesses, but dev.sh lint filters [unqualified] out on purpose (Qt6 warns
    on plenty of healthy code), the offscreen smoke test never plays a track,
    and the engine's own tests avoid the network path by design. So the class
    gets its own check: for every shipped QML file, a NamespaceLike. usage in
    real code must have a matching `import "X.js" as X`.
    """
    libs = {p.stem for p in UI.glob("*.js")}
    missing = []
    for qml in sorted((ROOT / "package").rglob("*.qml")):
        src = qml.read_text(encoding="utf-8")
        # Comments name libraries in prose ("gated by HostGuard") without
        # calling them — strip them before deciding anything.
        code = _no_comments(src)
        for lib in libs:
            if re.search(r"\b%s\s*\." % re.escape(lib), code) \
                    and ('as %s' % lib) not in code:
                missing.append("%s calls %s without importing it"
                               % (qml.name, lib))
    assert not missing, (
        "QML file(s) calling a JS library they never import — every call site "
        "throws ReferenceError at runtime:\n" + "\n".join(missing))


def test_every_library_call_names_something_the_library_has():
    """The sister of the check above: the library is imported, and the call
    names a function it does not define.

    The linter cannot be asked. Measured 2026-11-10 with the Qt6 qmllint the
    gate uses: a call on an object that does not exist, planted at the start
    of all 163 member functions of main.qml and in Component.onCompleted, was
    reported zero times; the same plant in a small component was reported
    every time. So a mistyped HealLogic.kinGues( in a branch that runs once a
    year loads, lints and throws when that year comes. The names are checked
    here instead: Library.name( in real code must be a function or a var the
    library declares at its top level.
    """
    has = {}
    for js in UI.glob("*.js"):
        text = js.read_text(encoding="utf-8")
        has[js.stem] = set(re.findall(r"^function\s+(\w+)\s*\(", text, re.M)) \
            | set(re.findall(r"^var\s+(\w+)\s*=", text, re.M))
    assert len(has) >= 20 and all(has.values()), "the libraries were not read: this test checks nothing"
    wrong, seen = [], 0
    for f in sorted(UI.rglob("*.qml")) + sorted(UI.glob("*.js")):
        code = _no_comments(f.read_text(encoding="utf-8"))
        alias = {a: lib for lib, a in re.findall(r'import\s+"(?:\.\./)?(\w+)\.js"\s+as\s+(\w+)', code)}
        for a, name in re.findall(r"\b([A-Z]\w*)\.(\w+)\s*\(", code):
            if a not in alias:
                continue
            seen += 1
            if name not in has[alias[a]]:
                wrong.append("%s calls %s.%s(), which %s.js does not define" % (f.name, a, name, alias[a]))
    assert seen > 300, "only %d library calls were found: the pattern stopped matching" % seen
    assert not wrong, "a call that will throw the first time it runs:\n" + "\n".join(wrong)


def test_the_tz_change_road_retimes_both_schedule_lists():
    """The zone-change handler must keep reaching BOTH lists it promises.

    tst_recordingengine.qml proves applyTzRetime works when called; what it
    cannot see is whether main.qml still calls it. Those are different
    failures (same split as the name-stripper guard above): drop the engine
    logic and the QML test goes red, drop the one call in
    _schedApplyTzChange and nothing does — until the next DST flip quietly
    leaves every recording schedule an hour off while alarms retime fine.
    The call sits at the very end of a function a future alarm extraction
    will rewrite, which is exactly when a trailing line gets lost.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _function_body(src, "_schedApplyTzChange")
    # A commented-out call still contains the string — the first version of
    # this test stayed green with the line commented away, which is half of
    # how refactors actually lose a line. Strip comments before looking.
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    body = "\n".join(re.sub(r"//.*$", "", ln) for ln in body.split("\n"))
    assert "recordingEngine.applyTzRetime(" in body, (
        "_schedApplyTzChange no longer forwards the zone change to the "
        "recording engine — recording schedules drift an hour at every "
        "DST flip while alarms keep retiming")
    assert "alarmEngine.applyTzRetime(" in body, (
        "_schedApplyTzChange no longer forwards the zone change to the "
        "alarm engine — alarms drift an hour at every DST flip, and a "
        "wrong-hour wake-up is the worst bug this feature can have")
    for eng_name in ("RecordingEngine.qml", "AlarmEngine.qml"):
        eng = (UI / eng_name).read_text(encoding="utf-8")
        assert re.search(r"function applyTzRetime\s*\(", eng), (
            "%s lost applyTzRetime while main.qml still calls it — every "
            "zone change now throws inside the schedule tick" % eng_name)
    assert "AlarmLogic.retimeForZone(" in (UI / "AlarmEngine.qml").read_text(encoding="utf-8"), (
        "the alarm engine's retime no longer uses the zone math itself")


def test_the_popup_minimum_width_tracks_the_tab_bar():
    """A hard minimum narrower than the tabs breaks labels mid-word.

    Photographed on the 5K home display (1.75 fractional scale),
    2026-08-10: tab captions clipped mid-word on the 5K desk ("Station",
    half of "Playing", "Podcas"). Measured on the
    bench the same day: the five tabs' implicit width beats a 16 gu
    floor even at scale 1.0 (308 px against 288) — the constant was
    wrong everywhere and fractional scaling only made it visible. The
    minimum must therefore derive from the bar itself; the gridunit
    term may stay as a floor for the tabless first paint.
    """
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    m = re.search(r"Layout\.minimumWidth:([^\n]*)", src)
    assert m, "the popup lost its minimumWidth line"
    assert "_navTabsNeed" in m.group(1), (
        "Layout.minimumWidth no longer tracks the tabs' real need — "
        "the smallest window breaks tab labels mid-word again on any "
        "display whose fonts outgrow the gridunit constant")
    helper = _function_body(src, "_measureNavTabs")
    assert "itemAt" in helper and "implicitWidth" in helper, (
        "_navTabsNeed stopped measuring the widest tab — the bar hands "
        "every tab an equal slice, so widest-times-count is the need; "
        "the sum (bar implicitWidth) was measured too small on the 5K "
        "desk (308 against the 355 the equal split required)")
    assert "Qt.callLater(fullRepresentation._measureNavTabs)" in src, (
        "nothing calls _measureNavTabs any more — the floor stays 0 and "
        "the constant rules again; it must run once, imperatively, after "
        "the bar builds (a live binding here is a binding loop, CI-caught)")


def test_the_wake_up_popup_is_held_inside_the_window():
    """The podcast alarm popup opens leftward and is wider than the room there.

    Measured on a copy at a grid unit of 18: its left edge at -38 px on the
    default 21 gu popup, at -128 px on the 16 gu floor with the hour box
    outside the window. tst_alarmpopup measures the cure on a copy of the
    header; this holds the popup and the copy to the same lines, because a
    copy that passes says nothing once the original has lost them.
    """
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    copy = (TESTS / "qml" / "tst_alarmpopup.qml").read_text(encoding="utf-8")
    for where, text in (("the popup", src), ("tst_alarmpopup's copy", copy)):
        i = text.index("id: podAlarmPopup")
        head = _code_only(text[i:text.index("contentItem:", i)])
        assert re.search(r"^\s*margins:\s*Kirigami\.Units\.smallSpacing\s*$", head, re.M), (
            "%s has no margins, so nothing pushes it back inside the window "
            "when it is wider than the room left of its button" % where)
        assert re.search(r"^\s*width:\s*Math\.min\(implicitWidth,\s*"
                         r"fullRepresentation\.width - 2 \* Kirigami\.Units\.smallSpacing\)\s*$",
                         head, re.M), (
            "%s is no longer capped at the window's width: pushed in from the "
            "left it runs out on the right instead" % where)
        for dial in ("podAlarmHH", "podAlarmMM"):
            j = text.index("id: %s" % dial)
            box = _code_only(text[j:text.index("}", j)])
            assert "Layout.fillWidth: true" in box, (
                "%s: %s keeps its full width inside a capped popup, and the "
                "Set button is what gets cut off" % (where, dial))


def test_the_wake_tone_accepts_flowed_audio_as_life():
    """The tone must never replace a station the sleeper can hear.

    Measured live 2026-08-10 23:08:46 on the home machine, from the
    fallback's own evidence line: playing=true, position=24917,
    mediaStatus=4 (BufferingMedia) — a live stream plays for minutes
    without ever reaching BufferedMedia, and the status-only gate
    replaced an audible station with the chime. Audio having FLOWED
    (position past the floor) is the evidence that counts; a stream
    that dies after starting belongs to the heal road, whose standing
    order the fire path arms.
    """
    src = (UI / "AlarmEngine.qml").read_text(encoding="utf-8")
    check = re.sub(r"\s+", " ", _code_only(_function_body(src, "_fallbackTrigger")))
    # The verdict itself is AlarmLogic.wakeSounds (tst_alarmlogic pins the
    # measured case); what is held here is that the check hands it both.
    assert ("AlarmLogic.wakeSounds(app.isPlaying(), app.playMusicRef.mediaStatus === MediaPlayer.BufferedMedia, "
            "app.playMusicRef.position, fell)") in check, (
        "the wake-tone stand-down lost its flowed-audio evidence — a "
        "status-only gate calls a playing live stream dead (measured: "
        "25 s of audio at BufferingMedia) and the chime replaces it")


def test_the_chime_stays_a_deliberate_choice():
    """The tone as a CHOICE, asked for by the listener 2026-08-10.

    An alarm whose url is the "chime:" sentinel must take its own road:
    no station, no heal orders, straight to the bundled tone. Losing the
    branch would silently turn a chosen ringer into a dead station URL.
    """
    src = (UI / "AlarmEngine.qml").read_text(encoding="utf-8")
    body = _function_body(src, "_alarmFire")
    assert '=== "chime:"' in body, (
        "_alarmFire lost its chime: branch — a chosen ringer would be "
        "played as a station URL and wake nobody")
    chime = _function_body(src, "_alarmFireChime")
    assert "_alarmToneUrl" in chime and "startWithFade" in chime, (
        "_alarmFireChime no longer starts the bundled tone")


def test_the_station_backup_can_be_found_again():
    """Export and import must agree on what a backup file looks like.

    The save dialog's name field is free text, so a listener who types
    "minu jaamad" gets a file with no extension — and the open dialog
    filtered on *.arp only, which made their own backup invisible. Both
    ends are pinned: the save side supplies the suffix, the open side
    also offers an unfiltered view for files that predate it.
    """
    src = (UI / "config" / "configGeneral.qml").read_text(encoding="utf-8")
    save = src[src.index("id: saveFileDialog"):]
    save = save[:save.index("P5Support.DataSource")]
    assert 'defaultSuffix: "arp"' in save, (
        "the save dialog stopped supplying the .arp suffix — a backup "
        "saved under a bare name disappears from the import dialog")
    opendlg = src[src.index("id: openFileDialog"):]
    opendlg = opendlg[:opendlg.index("Labs.FileDialog {", 1)] if "Labs.FileDialog {" in opendlg[1:] else opendlg
    assert "All files (*)" in opendlg, (
        "the open dialog filters to *.arp alone again — older backups "
        "and hand-renamed files become unopenable")


def test_the_two_new_appearance_switches_reach_the_widget():
    """A switch that exists in Settings and changes nothing is worse than
    no switch: it reads as a broken promise.

    Both were asked for in Discussions (2026-08) by a listener who keeps
    a handful of their own stations: the search and discovery row, and
    the row's editing furniture. Each key must be declared, offered in
    Appearance, and actually read where it takes effect.
    """
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    appear = (UI / "config" / "configAppearance.qml").read_text(encoding="utf-8")
    full = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    item = (UI / "MediaListItem.qml").read_text(encoding="utf-8")

    for key in ("showSearchRow", "showDiscoveryRow", "showReorderHandles"):
        assert 'name="%s"' % key in xml, "%s is not declared in main.xml" % key
        assert "cfg_%s" % key in appear, "%s has no switch in Appearance" % key

    assert "Plasmoid.configuration.showSearchRow !== false" in full, (
        "the search field no longer follows its switch")
    assert "Plasmoid.configuration.showDiscoveryRow !== false" in full, (
        "the discovery chips no longer follow their own switch — they "
        "were bundled with the search field once and the listener asked "
        "for them apart the same day")
    assert "Plasmoid.configuration.showReorderHandles !== false" in item, (
        "the row's editing furniture no longer reads its switch")
    assert "listItem.rowEditing" in item, (
        "the remove button stopped travelling with the drag handle — the "
        "ask was the row's whole editing furniture, or none of it")


def test_a_cut_station_name_passes_whole_under_the_pointer():
    """The row's marquee waited for contentWidth to exceed the row, and an
    elided label's contentWidth is what is left after the cut.

    Measured on a 120 px row: contentWidth 117.48, implicitWidth 462.56,
    truncated. The condition had that shape since 2026.1, so a long name
    stayed cut with "…" and nothing ever showed the rest. Changing the
    condition alone is not the cure either: the label is still laid out at
    the row's width, and the marquee then carries the cut name past
    (measured on the copy: running, truncated, 117 px of travel).
    tst_rowmarquee holds the behaviour on a copy; this holds the row and
    the copy to the same three lines.
    """
    row = _code_only((UI / "MediaListItem.qml").read_text(encoding="utf-8"))
    copy = _code_only((TESTS / "qml" / "tst_rowmarquee.qml").read_text(encoding="utf-8"))
    for where, text in (("the station row", row), ("tst_rowmarquee's copy", copy)):
        i = text.index("id: trackName")
        label = text[i:text.index("onStopped", i)]
        assert re.search(r"readonly property bool passing: listItem\.hovered && "
                         r"implicitWidth > trackRect\.width\s*&& Kirigami\.Units\.longDuration > 0",
                         label), (
            "%s: the marquee no longer starts on the name's full length under "
            "the pointer; contentWidth can never exceed the row" % where)
        assert "width: passing ? implicitWidth : parent.width" in label, (
            "%s: the label keeps the row's width while it passes, so what "
            "passes is the cut name" % where)
        assert "to: -trackName.implicitWidth" in label and "running: trackName.passing" in label, (
            "%s: the pass no longer runs the whole name out, or no longer "
            "runs when the label is laid out whole" % where)
        assert "contentWidth" not in label, (
            "%s reads contentWidth again, which is the cut text's width" % where)


def test_a_dragged_row_shows_the_place_it_has_and_not_the_one_it_left():
    """While a row is dragged its number comes back, and it came from
    targetIndex: the place the row had when the list was built. The drag
    moves the row in the model at every step, so the number stood still at
    the start while the row travelled. model.index is the place it has.
    tst_dragbadge moves a row over a real ListView with a copy of the line;
    this holds the row and the copy to the same one. At rest nothing
    changed: a row without a letter still shows targetIndex."""
    line = re.compile(r"text: reorderHover \? \(model\.index \+ 1\)\s*"
                      r": \(avatar\.mono === \"\" \? \(listItem\.targetIndex \+ 1\) : avatar\.mono\)")
    for where, path in (("the station row", UI / "MediaListItem.qml"),
                        ("tst_dragbadge's copy", TESTS / "qml" / "tst_dragbadge.qml")):
        code = _code_only(path.read_text(encoding="utf-8"))
        at = code.index("readonly property bool reorderHover: dragArea.pressed")
        assert line.search(code[at:at + 400]), (
            "%s: the number a dragged row shows is not the place it has now" % where)


def test_the_folder_hint_names_the_folder_the_downloads_go_to():
    """The empty "Save to folder" field said ~/Music/OnAir in grey, typed into
    the page by hand, while the downloads went to the desktop's own music
    folder: Musiikki on a Finnish desktop, Musik on a German one. The hint and
    the download road ask PathLogic.defaultDir (tst_pathlogic holds what it
    answers); this keeps either of them from going back to its own guess."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    page = _code_only((UI / "config" / "configAppearance.qml").read_text(encoding="utf-8"))
    dl = main[main.index("readonly property string downloadDirPath"):]
    dl = dl[: dl.index("\n    }")]
    assert "return PathLogic.defaultDir(" in dl, "the download folder stopped asking PathLogic"
    assert '"/OnAir"' not in dl, "the download road builds its folder by hand again"
    at = page.index("id: dirField")
    field = page[at: page.index("Layout.fillWidth", at)]
    assert "PathLogic.shownDir(PathLogic.defaultDir(" in field, (
        "the folder hint is written by hand again")
    assert "~/Music" not in field


def test_an_alarm_cannot_veto_the_speaker_check_forever():
    """The wake-up window, not the volume override, is the question.

    alarmEngaged is what SyncEngine asks before it measures anything, and
    it used to read the override alone — which survives until the
    listener picks a station, stops, or touches the volume. Someone who
    simply let the wake-up play had their drift check blocked all day
    (measured in the home journal 2026-08-11). The override's answer
    expires with the wake-up window; the loudness itself does not.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    m = re.search(r"readonly property bool alarmEngaged:(.{0,220})", src, re.S)
    assert m, "alarmEngaged is gone"
    body = m.group(1)
    assert "_volumeOverrideAtMs" in body, (
        "alarmEngaged stopped bounding the override in time — a wake-up "
        "nobody dismissed vetoes every speaker measurement from then on")
    # The bound has to be measured off a ticking property. Date.now() in a
    # binding is a plain call, not a dependency: the expiry written on
    # 2026-08-11 evaluated once at fire time and never again, so the veto
    # stood all day exactly as before (found 2026-09-05).
    assert "Date.now()" not in body, (
        "alarmEngaged reads Date.now() inside its binding — that value is "
        "frozen at the last dependency change and the 30-minute window never "
        "closes; take the time from alarmVetoClock.now")
    assert "alarmVetoClock.now" in body and "id: alarmVetoClock" in src, (
        "alarmEngaged lost its ticking clock")
    eng = (UI / "AlarmEngine.qml").read_text(encoding="utf-8")
    assert eng.count("app._volumeOverrideAtMs = Date.now();") == 3, (
        "a fire road stopped stamping when it raised the volume — an "
        "unstamped override is an expired one, and the alarm's own level "
        "would stop counting as engaged immediately")


def test_the_park_stands_the_wake_up_down():
    """Parking IS "I'm up" — every other silencing road says so.

    Without it the 25 s wake-tone net stayed armed over a parked
    station: press pause to quiet the alarm, and half a minute later the
    built-in chime starts over the park.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _function_body(src, "timeshiftPause")
    assert "alarmEngine.standDown()" in body, (
        "the timeshift park no longer stands the wake-up down — the chime "
        "plays over the parked station 25 seconds later")
    assert "_volumeOverridePct = -1" in body, (
        "the park no longer releases the alarm's volume override")


def test_the_frozen_horizon_has_a_watchdog():
    """Qt never delivers EndOfMedia on a growing buffer (measured live on
    the home machine, twice, 2026-08-11): the position pins while the
    player still claims to be playing. playerEndOfMedia() sits behind
    EndOfMedia alone, so without this watchdog the engine's whole
    reopen-or-return machinery is dead code and a resumed pause goes
    silent forever with the widget still showing "playing".

    Since 2026.44 the watchdog is the engine's own, where its rule can be
    called by a test (tst_timeshiftengine.qml); main.qml keeps no second one,
    or a frozen horizon would be reopened twice.
    """
    src = (UI / "TimeshiftEngine.qml").read_text(encoding="utf-8")
    assert "id: tsHorizonWatch" in src, "the horizon watchdog is gone"
    i = src.index("id: tsHorizonWatch")
    body = src[i:i + 400]
    assert "engine._horizonTick(" in body, (
        "the watchdog's timer no longer asks the engine's rule")
    assert "engine.shifted" in body, (
        "the watchdog stopped gating on the shifted state — it would fire "
        "over ordinary live playback")
    assert "playerEndOfMedia(" in _function_body(src, "_horizonTick"), (
        "the watchdog no longer hands the frozen horizon to the engine")
    assert "tsHorizonWatch" not in (UI / "main.qml").read_text(encoding="utf-8"), (
        "main.qml grew a horizon watchdog of its own again beside the engine's")


def test_the_colour_choice_stays_a_measured_set():
    """Three answers, not a colour picker.

    Every shade has to stay readable on both light and dark Plasma
    schemes — the emerald only does because it was measured (8.8:1 on
    dark, and the text variant darkened to 5.4:1 on light). A free
    picker would be a promise nobody measures, so the choice is a list:
    the built-in green, the listener's own system accent, or plain,
    where the widget borrows the theme's text colour and stops having a
    colour of its own.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    assert "_accentMode" in src and "_plainAccent" in src, (
        "the colour modes are gone")
    # Migration: a config written before the list existed still speaks.
    m = re.search(r"readonly property int _accentMode:(.{0,260})", src, re.S)
    assert m and "followSystemAccent" in m.group(1), (
        "the old followSystemAccent boolean no longer migrates — every "
        "listener who had the system accent would snap back to green")
    # Plain mode must reach the theme, not a hard-coded grey.
    for prop in ("accent:", "accentBright:", "accentTeal:", "accentText:", "accentBrightText:"):
        i = src.index("property color " + prop)
        window = src[i:i + 320]
        assert "_plainAccent" in window and "Kirigami.Theme" in window, (
            "%s does not answer plain mode from the theme — a hard-coded "
            "shade there is exactly the unmeasured promise the list "
            "exists to avoid" % prop)
    # The two purely decorative pieces retire in plain mode.
    rep = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    head = (UI / "Heading.qml").read_text(encoding="utf-8")
    assert "root._accentMode !== 2" in rep, (
        "the aurora keeps drifting in plain mode")
    assert "root._accentMode !== 2" in head, (
        "the emerald strip under the title survives plain mode")


def test_the_sync_gates_hold_their_shape():
    """Both walking roads got their gates on 2026-08-11, reconstructed
    exactly from the journal: the settle road read +36/+15/+36 as "flat"
    because only the ends were compared (the map walked 154->190 off a
    room the ear had just called perfect), and the fold road walked
    154->169 on a correction smaller than its own scatter. The settle
    window must bound the WHOLE spread, and the fold must drop one flyer
    and then demand the step stand taller than what remains.
    """
    src = (UI / "SyncEngine.qml").read_text(encoding="utf-8")
    assert "if (hi - lo > _settleFlatMs)" in src, (
        "the settle flatness gate no longer bounds the whole window — "
        "alternating readings pass an ends-only comparison and the median "
        "then returns the outlier pair")
    assert "byDist.pop();" in src and "kept[kept.length - 1] - kept[0]" in src, (
        "the fold road lost its scatter gate — a correction the same size "
        "as the disagreement between its own witnesses is noise voting")


def test_the_volume_road_never_touches_the_sync_maps():
    """Snapcast's most famous regression (#476): a volume change zeroed the
    latency settings. Volume does not change delay physically, so the
    volume road here must never write a lag map, a loopback delay or a
    learned bias — and must never trigger a re-calibration. The research
    round (2026-08-11) named this the one regression class worth a
    standing guard, because the code that makes it possible sits close:
    setUserVolume's persist timer already writes config keys.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _function_body(src, "setUserVolume")
    for key in ("syncOffsetMap", "syncOffsetMs", "syncSweepBiasMap",
                "latency_msec", "syncRefLatMap"):
        assert key not in body, (
            "setUserVolume touches %s — volume must never move sync" % key)
    i = src.index("id: volumePersistTimer")
    timer = src[i:i + 900]
    for key in ("syncOffsetMap", "syncOffsetMs", "syncSweepBiasMap",
                "latency_msec"):
        assert key not in timer, (
            "the volume persist timer touches %s — a volume change would "
            "quietly rewrite the sync the listener tuned" % key)
    # The REVERSE direction is deliberately allowed: the engine restores
    # the user's own level after a calibration mutes and parks the room
    # (their slider move mid-measurement wins). What it must never do is
    # restore anything but the listener's own number.
    eng = (UI / "SyncEngine.qml").read_text(encoding="utf-8")
    calls = [ln for ln in eng.splitlines() if "app.setUserVolume(" in ln]
    assert len(calls) == 1, (
        "the engine grew another volume write — each one is a chance to "
        "overwrite the level the listener chose")


def test_the_panel_wheel_does_not_save_a_level_the_sleep_fade_made():
    """The wheel's step is saved as the default volume, and the panel counted
    it from the output's level. For its last thirty seconds the sleep timer is
    what moves that level: a notch at 30 % of a faded 60 % saved 35 %, and the
    radio came on at 35 % in the morning. The arithmetic is
    TransportLogic.wheelLevel, under tst_transportlogic; what is held here is
    that the panel asks it, with the fade's start level and the pending
    gesture, and has no sum of its own left. Since 2026.44 it is also told
    whether a device plays alone, and the listener's own level to count
    from there (test_one_level_is_the_listeners_own_for_every_device)."""
    src = _code_only((UI / "CompactRepresentation.qml").read_text(encoding="utf-8"))
    wheel = src[src.index("onWheel:"):src.index("onEntered:")]
    flat = re.sub(r"\s+", " ", wheel)
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert "const step = (notch) => root.wheelStep(notch);" in flat, "the panel's wheel has a step of its own"
    assert ("{ setUserVolume(TransportLogic.wheelLevel(playMusicOutput.volume, _volumeBeforeSleepFade, "
            "_pendingUserVolumePct, notch, _casting && !_castLocalPlay, targetVolume()), true); }"
            ) in re.sub(r"\s+", " ", _function_body(main, "wheelStep")), (
        "the panel's wheel steps from the level the output shows, fade or not, heard or not")
    assert "setUserVolume(" not in flat and "step(0.05)" in flat and "step(-0.05)" in flat
    assert not re.search(r"playMusicOutput\.volume\s*[+-]\s*0", wheel), (
        "a wheel step is added to the shown level outside wheelLevel")
    assert "property real _volumeBeforeSleepFade: -1" in main
    assert "property int _pendingUserVolumePct: -1" in main


def test_the_two_discussion_asks_ship_with_their_own_guards():
    """#6: the hover glyph rides a scrim OVER the station logo — the logo
    must stay visible under the pointer, not swap out for a bare glyph.
    #7: the auto-jump to Playing exists, ships OFF, and every disarm the
    discussion reply promised (view change, active search) is real.
    """
    item = (UI / "MediaListItem.qml").read_text(encoding="utf-8")
    assert "status === Image.Ready && !listItem.isCurrent" in item, (
        "the station logo hides on hover again — the row loses its face "
        "right as the pointer reaches it")
    assert "hoverGlyph.visible && faviconImage.visible" in item, (
        "the scrim no longer pairs with the glyph over the logo")
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    i = xml.index('name="autoSwitchToPlaying"')
    assert "<default>false</default>" in xml[i:i + 400], (
        "the auto-jump must ship OFF — it takes the screen away from "
        "someone mid-browse, the discussion said so itself")
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i2 = src.index("id: autoPlayingTimer")
    body = src[i2:i2 + 800]
    assert 'searchFilter !== ""' in body, (
        "the auto-jump no longer yields to an active search")
    assert "autoPlayingTimer.stop();" in src[src.index("onViewChanged:"):
                                             src.index("onViewChanged:") + 300], (
        "a manual tab change no longer disarms the pending auto-jump")


def test_the_stuck_titles_holes_stay_closed():
    """Issue #10's confirmed availability holes, all four. No single one
    explained every report, so all of them closed (2026-08-11): the Qt
    latch waits for a SECOND, different title before retiring the polling
    fallback; a non-fatal error's timer restarts the poll it stopped;
    landing on the Playing page fires one bounded poll (the reporters'
    tab-dance ritual, made real); and reader.py treats 403 as transient -
    a WAF that starts refusing the repeat visitor must not become a
    permanent no-titles verdict.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index("onMetaDataChanged:")
    meta = src[i:i + 2200]
    assert "cleaned !== root._qtMetaFirstTitle" in meta, (
        "the Qt latch fires on the first title again - a backend that "
        "delivers one tag and goes quiet leaves both title sources dead")
    i2 = src.index("id: errorTimer")
    et = src[i2:i2 + 900]
    assert "infoTimer.restart()" in et, (
        "the error timer no longer revives the poll it stopped")
    i3 = src.index("onViewChanged: {")
    vc = src[i3:i3 + 1200]
    assert "getStreamInfo(playMusic.source, root.metadata)" in vc, (
        "arriving on the Playing page no longer refreshes a stopped poll")
    rd = (ROOT / "package" / "contents" / "ui" / "reader.py").read_text(encoding="utf-8")
    assert "(403, 408, 429)" in rd, (
        "403 became a permanent verdict again - a rate-limiting WAF "
        "would permanently silence a station that carries titles")



def test_every_declared_qml_test_lives_inside_its_testcase():
    """A test function outside the TestCase block is never run by
    qmltestrunner, and the suite still reports green — it just quietly counts
    one lower. Two of them had been sitting like that: the podcast engine's
    clearplaying test and the sync engine's departure test, the latter since
    the day it was written, so the Bluetooth deathbed-pause ordering had never
    once been exercised. Brace-count each file and require every test_ to fall
    inside."""
    qmldir = ROOT / "tests" / "qml"
    stray = []
    for f in sorted(qmldir.glob("tst_*.qml")):
        lines = f.read_text(encoding="utf-8").split("\n")
        start = next((i for i, ln in enumerate(lines)
                      if re.match(r"\s*TestCase\s*\{", ln)), None)
        if start is None:
            continue
        depth, end = 0, None
        for i in range(start, len(lines)):
            # Strings first, then comments: these files carry JSON payloads
            # full of braces, and counting them makes every block look open.
            bare = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[i])
            bare = re.sub(r"'(?:\\.|[^'\\])*'", "''", bare)
            bare = re.sub(r"//.*$", "", bare)
            depth += bare.count("{") - bare.count("}")
            if depth <= 0:
                end = i
                break
        if end is None:
            stray.append(f"{f.name}: TestCase block never closes")
            continue
        for i, ln in enumerate(lines):
            if re.match(r"\s*function\s+test_", ln) and not (start < i < end):
                stray.append(f"{f.name}:{i + 1} {ln.strip()[:60]}")
    assert not stray, (
        "these test functions sit outside their TestCase and never run:\n  "
        + "\n  ".join(stray))

def test_a_pause_is_a_pause_whoever_leaves_the_room():
    """A Bluetooth speaker powering off says goodbye with an AVRCP pause, and
    with other speakers still in the room that pause used to be treated as the
    speaker's own: ignored when it arrived after the loss, undone when it had
    arrived up to two minutes before. The second half starts sound nobody
    asked for, and neither half can tell a speaker from a person — the pause
    arrives over MPRIS either way, and so does a keyboard's media key, the
    desktop's media applet and a phone.

    Seen on the desk 2026-09-21: a pause sent over MPRIS, the speaker's link
    dropped eight seconds later, and five seconds after that the radio was
    playing again ("the park was a departing speaker's last breath"). Worse,
    "left the group" also fires when nothing left: the same morning a profile
    switch recreated the speaker's node and the engine logged a departure. A
    pause, a hiccup a minute later, and the room plays — issue #13 again.

    So a pause is a pause. What stays: the engine still notices the loss and
    walks the speaker back in, and a speaker that leaves while music plays
    takes nothing with it, because no pause is involved.
    """
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    eng = _code_only((UI / "SyncEngine.qml").read_text(encoding="utf-8"))

    for gone in ("_deathbedPause", "_btMemberLostAt", "noteBtMemberLost", "_tsParkFromMpris"):
        assert gone not in main, (
            "main.qml still carries %s: a pause is being weighed against who "
            "left the room instead of simply being honoured" % gone)
    assert "noteBtMemberLost" not in eng, (
        "the sync engine still reports a departure to the player; the only "
        "thing the player ever did with that news was start sound")

    # The engine measures and routes. It has no business starting sound.
    for road in ("timeshiftResume(", "startWithFade(", "refreshServer(", "playMusic.play("):
        assert road not in eng, "SyncEngine.qml can start sound through %s" % road

    # Every resume of a park is a person's gesture: the station they clicked,
    # or a Play / PlayPause through transport(), where the media keys and the
    # widget's own button arrive. Nothing else in main.qml may call it.
    src = (UI / "main.qml").read_text(encoding="utf-8")
    inside = sum(_code_only(_function_body(src, fn)).count("timeshiftResume(")
                 for fn in ("refreshServer", "transport"))
    total = main.count("timeshiftResume(") - main.count("function timeshiftResume(")
    assert total == inside, (
        "%d call(s) to timeshiftResume() sit outside the two roads a person "
        "drives (refreshServer, transport)" % (total - inside))


def test_a_park_that_cannot_resume_always_finds_a_way_back_to_sound():
    """A speaker powering off rebuilds the group, the rebuild disarms the
    timeshift, and its stream address empties - so the single-address
    fallback refused and the room stayed silent with the widget still
    showing a station (live, 2026-08-11). The resume walks three roads
    now: the timeshift address, the station's own resolved address, and
    failing both, the row it came from.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _function_body(src, "timeshiftResume")
    assert "tsPlayLive(timeshift.streamUrl)" in body, "the first road is gone"
    assert "_currentResolvedUrl" in body, (
        "the resume lost its second road - a disarmed timeshift leaves "
        "the room silent again")
    assert "refreshServer(lastPlay)" in body, (
        "the resume lost its last resort, the station's own row")


def test_a_parked_stations_row_resumes_instead_of_tearing_the_park_down():
    """The row shows the start glyph while a station is parked - and the
    click used to do the opposite: silently stop the park, so the next
    click cold-restarted the station and wiped a cover it had one second
    earlier (caught live 2026-08-20 by the writer log: REFRESH-SERVER on
    the parked row). The row must honour its own icon.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _function_body(src, "refreshServer")
    i = body.index("if (stopping)")
    stop_branch = body[i:i + 900]
    assert "timeshiftResume()" in stop_branch, (
        "the parked row tears the park down again instead of resuming it")
    assert "_tsPaused && !timeshift.shifted" in stop_branch, (
        "the resume lost its guard - an audibly shifted row must keep "
        "meaning stop")


def test_the_heal_commit_gate_is_the_tested_one_and_the_stopgap_keeps_the_lock():
    """The permanent-write decision lives in HealLogic.commitVerdict, where
    tst_heallogic pins it: uuid row or exact name on the station's own
    NON-SHARED domain, everything else a session stopgap. main.qml once
    made this call inline with a bare base-domain comparison, and a
    contains-match on zeno.fm could rewrite a user's saved station into a
    different tenant for good. This holds the wiring to the tested gate.

    The stopgap branch must also KEEP the 10-minute lookup lock: deleting
    it there let a flapping backup ride the search-and-notify ring with
    no backoff at all. The lock's release moved to the user's own press
    (refreshServer, userInitiated), where the fresh mandate actually is.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")

    commit = src.split("function _healCommit()", 1)[1]
    # The whole stopgap branch, up to where the permanent write begins -
    # slicing at the first notify( once left a lock release AFTER the
    # toast invisible to this test.
    gate = commit.split("try {", 1)[0]
    assert "HealLogic.commitVerdict(" in gate, (
        "the permanent-write decision left the tested gate - an inline "
        "base-domain comparison brought the zeno.fm rewrite back")
    assert "delete _healTried" not in gate, (
        "the stopgap releases the lookup lock again - a flapping backup "
        "loops search-and-notify with no backoff")

    refresh = src.split("function refreshServer(", 1)[1].split("\n    function ", 1)[0]
    # The guard and the delete on ONE line: the same guard phrase exists
    # elsewhere in refreshServer, and two separate substring checks once
    # stayed green with the delete made unconditional.
    assert "if (userInitiated !== false) delete _healTried[origHost];" in refresh, (
        "the user's own press no longer releases the heal-lookup lock "
        "guardedly - either the release is gone (a deliberate replay "
        "knocks on the dead address for ten minutes) or its guard is "
        "(every automated retry resets the backoff's own lock)")

    # The exact-name verdict and the landlord rule are made in
    # HealLogic.ladder, under tst_heallogic (the own-domain test and the
    # shared-host test). What is left to hold here is that the verdict
    # TRAVELS from the ladder to the commit gate: the whole row is pushed and
    # the audition copies its exact flag. Map the rows back to {url, byUuid}
    # and every own-domain repair demotes to a stopgap with the library's
    # tests all green.
    code = _code_only(src)
    assert "run.candidates.push(res.cands[j]);" in _code_only(_function_body(src, "_healNameSearch")), (
        "the name rung no longer pushes the ladder's whole row - the "
        "exact-name verdict stops short of the commit gate")
    assert "root._healPendingExact = next.exact === true;" in _code_only(_function_body(src, "_healAdvance")), (
        "the audition no longer copies the row's exact-name verdict")
    assert code.count("HealLogic.ladder(") == 2, (
        "the list-station heal and the preview rescue must both take their "
        "rows from the tested ladder")
    assert "HealLogic.scoreRow(" not in code and "HealLogic.rank(" not in code, (
        "a road gates, scores or ranks directory rows inline again")

    # rank() hands back row objects; the preview rescue auditions bare
    # urls. The day rank changed shape, this road silently fed
    # "[object Object]" to the player and no test went red.
    assert "ranked.slice(0, 4).map(function(c) { return c.url; })" in src, (
        "the preview rescue consumes rank() rows as urls again")


def test_a_namesake_is_refused_except_for_a_wake_up_and_named_when_it_plays():
    """A name is not an identity: "Rock FM" is five exact-name rows from four
    countries, and the name rung once auditioned the Estonian one for a
    Spanish listener under their station's name. Who may audition is
    HealLogic.ladder's call (tst_heallogic). This holds the wires no unit test
    can reach: the wake-up exception arrives at the ladder and at the query,
    the uuid record's country arrives at all, the preview rescue does not read
    the alarm flag and always asks for the old ladder, and the notice learns
    who is playing BEFORE the pending state is cleared.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    search = _code_only(_function_body(src, "_healNameSearch"))
    assert re.search(r"HealLogic\.ladder\([^;]*run\.cc,\s*root\._alarmStandingOrder === true\);", search), (
        "the wake-up exception no longer reaches the ladder - an alarm whose "
        "station died is refused the namesake that would have rung")
    # One flag for the rows asked for and the rows kept: a wake-up asks the
    # directory exactly as it always has.
    assert "HealLogic.searchTail(root._alarmStandingOrder === true)" in search
    # The RAW body: the tail must not be written by hand beside the tested one.
    assert "hidebroken" not in _function_body(src, "_healNameSearch"), (
        "the heal's name search hides broken rows again - the saved station's "
        "own record is one of them, and it is the witness to its country")
    assert "root._healRun.cc = HealLogic.uuidCountry(uxhr);" in _code_only(
        _function_body(src, "_tryHealStation")), (
        "the uuid record's country is thrown away again")
    rescue = _code_only(_function_body(src, "_previewNameRescue"))
    assert 'pvKey, pvName, "", true).cands;' in rescue and "_alarmStandingOrder" not in rescue
    advance = re.sub(r"\s+", " ", _code_only(_function_body(src, "_healAdvance")))
    assert ("root._healPendingWho = HealLogic.strangerLabel(next, "
            "SearchLogic.countryLabel(next.cc, next.country, Qt.locale().name));") in advance
    assert '_healPendingWho = "";' in _code_only(_function_body(src, "_healClearPending"))
    commit = _code_only(_function_body(src, "_healCommit"))
    # Read after the clear it is "" for ever, and the old wording comes back
    # without a single test noticing.
    assert commit.index("var who = _healPendingWho;") < commit.index("_healClearPending()")
    assert 'who === ""' in commit and "It may be a different station." in commit


def test_the_standing_order_replays_a_url_not_a_row_number():
    """Deleting a DIFFERENT station mid-backoff shifts lastPlay to 0, and
    the retry timer once replayed whatever station had inherited that
    row. _replayOrder resolves the ordered URL to its CURRENT row first,
    and when no row and no orphan copy carries it, the order retires
    instead of guessing.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = src.split("function _replayOrder()", 1)[1].split("\n    function ", 1)[0]
    assert ".hostname === root._currentOrigUrl" in body, (
        "_replayOrder trusts a row number again - a list edit mid-backoff "
        "replays the wrong station")
    assert "_wantsPlaying = false" in body, (
        "an order whose station left the list no longer retires - the "
        "next network edge replays an arbitrary row")


def test_the_no_titles_pin_arms_its_own_recheck():
    """Six blank title polls pin a station as "no titles". Left alone, that pin
    lasted the whole play — the shape behind issue #10, "Now Playing never
    updates unless I pick another station". The pin site must arm the recheck
    timer that lifts it again, and the timer must exist to be armed."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index("root._icyEmptyCount >= 6")
    block = src[i : i + 600]
    assert "noIcyRecheck.restart()" in block, (
        "the six-blank pin no longer arms noIcyRecheck — a station blank at "
        "the first polls stays titleless for the whole play"
    )
    assert "id: noIcyRecheck" in src, "the recheck timer is gone"


def test_a_stop_in_an_episodes_last_seconds_starts_nothing():
    """A Stop is a Stop even when the file was about to end anyway.

    stopWithFade leaves a short fade-out window, and onErrorOccurred already
    refuses to act inside it — "the dying stream's last word, not a reason to
    resurrect it". onMediaStatusChanged had no such line, so an EndOfMedia
    arriving during that window ran the podcast advance: the up-next head, or
    with continuous listening on by default the show's oldest unheard
    download, began playing after the listener had pressed Stop. The sleep
    timer and a headset's Stop reach the same fade. The asymmetry between the
    two handlers was the whole bug; they agree now."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index("What plays next, in order of the listener's own word")
    block = src[i : i + 500]
    assert "fadeOutAnimation.running" in block, (
        "the podcast advance no longer stands down inside a stop's fade — "
        "pressing Stop as an episode ends starts the next one"
    )
    assert block.index("fadeOutAnimation.running") < block.index("_podPlayUpNextHead"), (
        "the fade test must come FIRST: _podPlayUpNextHead starts playback "
        "itself, so guarding after it consumes the queue and plays anyway"
    )


def test_the_budget_counts_every_knock_and_only_a_person_resets_it():
    """The retry budget is a count, so its two ends are the whole of it: every
    knock adds one, and only a person choosing a station takes it back to
    nothing. An automatic replay that reset the count would knock for ever
    under a budget of three; a ladder that forgot to count would never reach
    it. Neither was pinned — the budget's own tests run the arithmetic, not
    the two lines in main.qml that feed it.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    assert code.count("_healRetryAttempts++") == 1, (
        "the knock is counted in %d places; it is one ladder with one arming point"
        % code.count("_healRetryAttempts++"))
    assert "_healRetryAttempts++" in _code_only(_function_body(src, "_healArmRetry")), (
        "the ladder arms without counting the knock — the budget never runs out")
    refresh = _code_only(_function_body(src, "refreshServer"))
    resets = [ln.strip() for ln in refresh.split("\n") if "_healRetryAttempts = 0" in ln]
    assert resets, "refreshServer no longer gives a person's own choice a fresh budget"
    for ln in resets:
        assert "userInitiated !== false" in ln, (
            "refreshServer resets the knock count on an AUTOMATIC replay too (%r): "
            "every retry would start the budget over and the knocking never ends" % ln)


def test_the_promised_three_and_a_half_minutes_is_the_shipped_default():
    """Issue #13 was told in public: a quiet station is tried again for about
    three and a half minutes. That sentence is three knocks (30 s + 1 min +
    2 min, pinned in tst_retrylogic) — and the three lives in a config file no
    test read.
    """
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    m = re.search(r'<entry name="autoRetryKnocks"[^>]*>.*?<default>(\d+)</default>', xml, re.S)
    assert m, "autoRetryKnocks is gone from main.xml"
    assert int(m.group(1)) == 3, (
        "the default is %s knocks; the public promise on issue #13 is three "
        "(three and a half minutes). Change the promise before the number." % m.group(1))


def test_the_mpris_start_empties_the_command_file():
    """Whoever resets the sequence counter clears the file it counts against.

    _mprisStart re-arms the command gate for the daemon it is about to start.
    It used to only `touch` the command file, on the belief that the launcher
    clears it. The launcher does — at line 78, behind a python dbus probe
    (measured 49-50 ms here), an unconditional `sleep 0.3` and two orphan
    sweeps, so about 360 ms in. The watcher's lost-wakeup cat reads at 250 ms.
    A plasmashell that crashed or was restarted by a package upgrade never ran
    _mprisStop, so the last media-key line was still in that file: read at
    250 ms, its sequence beat the reset 0, and Play / PlayPause / Next /
    Previous all start a station from a dead stop. That is a widget beginning
    to play with nobody in the room, which is issue #13's exact complaint, and
    media keys are on by default. Creating the file EMPTY closes the window
    outright: there is nothing to replay by the time anything can read it."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_mprisStart"))
    assert "mprisCmdGate.arm(Date.now());" in body, "the start no longer re-arms the command gate"
    assert "touch '" not in body, (
        "the command file is created without being emptied again — a line left "
        "by a crashed session outruns the launcher's truncate and gets replayed"
    )
    assert ": > '" in body, (
        "_mprisStart no longer empties the command file it is about to watch"
    )


def test_the_title_cleanup_verdict_does_not_lean_on_english():
    """The optional title cleaner's answer is checked by shape, not vocabulary.

    The helper is a CLI, and a CLI answers in whatever language its environment
    steers it to. Measured 2026-09-14 on this machine, handed a station's advert
    banner, it replied in Estonian: "Selles reas ei ole lugu - see on
    reklaamiriba, mitte metaandmed. Vormi `Artist - Title` ei saa siit ausalt
    taita." That string carries " - ", so the separator test passes it, and the
    English refusal list never sees it. Only two things keep it out of the music
    search, and both must stay: a cleaned title is never much LONGER than the
    raw one it came from (a cleaner strips dressing, it does not explain), and
    it has no reason to quote anything in backticks. The same run cleaned real
    titles correctly - "Now Playing: SMILERS - JALGPALL ON PAREM KUI SEKS |
    Radio Tallinn 101.5 FM" came back "SMILERS - Jalgpall on parem kui seks" -
    so the feature earns its place; this is what keeps its bad days harmless."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index('if (cmd.indexOf(": AI_CLEAN;") === 0)')
    block = src[i : i + 1600]
    assert "_dlPendingRaw.length +" in block, (
        "the cleaner's answer is no longer measured against the title it came "
        "from — a refusal in any language now reaches the music search"
    )
    assert 'indexOf("`")' in block, (
        "the backtick test is gone — prose that quotes the wanted format is "
        "exactly what the helper answers with when it refuses"
    )


def test_the_multi_room_toggle_does_not_release_the_devices():
    """Also-play-here must never be read as stop-playing-there.

    startWithFade releases the receivers when a podcast starts locally, which
    is right when the listener picked an episode while a station was on the
    TV. The cast-handback branch made the multi-room toggle reach that same
    release: ticking "This computer" during a cast episode quit every
    receiver, left their rows ticked with _casting false, and the next untick
    stopped the local player too — nothing playing anywhere. The toggle now
    states its intent and the release honours it."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index("if (_podStarting && _castTargets.length > 0 && _casting")
    line = src[i : src.index("\n", i)]
    assert "_castJoinLocal" in line, (
        "the podcast release no longer asks whether the multi-room toggle is "
        "what brought it here — ticking 'This computer' quits the receivers"
    )
    body = _function_body(src, "castToggleLocal")
    assert "_castJoinLocal = true" in body and "_castJoinLocal = false" in body, (
        "castToggleLocal stopped declaring (or stopped clearing) its intent — "
        "a flag left standing would silence the release for every later start"
    )


def test_a_servers_write_only_retires_the_order_it_ends():
    """The standing order outlives a write that is not about it.

    Every add, remove and edit lands in onServersChanged's non-reorder branch,
    which retired the order outright. removeStation's own head guard exists to
    spare an order about a DIFFERENT station — and this line undid that
    decision forty rows later: a dead row tidied out of the popup while a
    stream was mid-recovery left the returning network nothing to resume, with
    the widget silent until someone pressed play. The clear has to ask first;
    an edit that moves the playing URL out of the list still earns it."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index("function onServersChanged")
    block = src[i : i + 1600]
    clears = [ln for ln in block.splitlines() if "_wantsPlaying = false" in ln]
    assert clears, "onServersChanged stopped retiring the order at all"
    for ln in clears:
        assert "if (" in ln, (
            "onServersChanged retires the standing order unconditionally again "
            "— deleting or starring any station kills a recovery in flight: %s"
            % ln.strip()
        )
    assert "_currentOrigUrl" in block, (
        "the guard no longer asks about the order's own station"
    )
    # Both halves, or the fix trades one bug for the other. Asking only "is the
    # station still listed" lets an edit made while the music played keep its
    # order — the road d2585ab closed, reopened here on 2026-09-14 and caught by
    # the issue-13 check. Asking only "was it audible" throws the recovery away.
    assert "isPlaying()" in block, (
        "the guard stopped asking whether the listener HEARD the stop — an edit "
        "in the settings dialog keeps its order and a later blip replays it"
    )


def test_a_servers_write_that_ends_the_order_ends_the_relay_with_it():
    """The timeshift engine goes down in the same breath as the order.

    The write stopped the player with a bare stop() and left the engine armed.
    For a relayed station (FLAC, Ogg, Opus) that was a radio waiting to start:
    the capture writer exits at its window cap, the engine re-armed, the tap's
    UP ack reached tsPlayRelay and a station removed an hour earlier played to
    an empty room. Reproduced behind the engine's mock on 2026-11-10: two relay
    starts where one was asked for, none with the disarm in front.

    It rides the order's own question on purpose. A write that silenced
    nothing has to leave a park resumable and a relay's rebuild in flight;
    tearing those down would end a pause the listener made, or leave an order
    standing with nothing under it."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    stop = _function_body(src, "onServersChanged")
    stop = stop[stop.index("} else {"):]
    ends = [ln.strip() for ln in stop.splitlines() if "_wantsPlaying = false" in ln]
    assert len(ends) == 1 and ends[0].startswith("if (wasAudible || !listed)"), ends
    assert "_tsSessionOver();" in ends[0], (
        "a servers write retires the order and leaves the timeshift engine "
        "armed: a relayed station re-arms at its writer's cap and plays")
    assert stop.count("_tsSessionOver()") == 1, (
        "the engine is also torn down outside the order's question, which "
        "ends a park over a write about some other station")
    over = _function_body(src, "_tsSessionOver")
    for step in ("timeshift.disarm();", "root._tsPaused = false;",
                 'root._tsPendingSeekUrl = "";'):
        assert step in over, "the session's end no longer does %s" % step


def test_the_settings_merge_compares_like_with_like():
    """Whatever the search page injects on load, its merge has to default too.

    Every model row is given a codec, bitrate and uuid at load so the model's
    roles exist before the first append. The three-way merge then compares
    those rows against the stored string — and a station saved before codecs
    were kept carries none of the three. A shape mismatch reads as "edited on
    this page, local wins", which resurrects a station deleted elsewhere and
    refuses a healed hostname: exactly what the merge replaced."""
    src = (UI / "config" / "configSearch.qml").read_text(encoding="utf-8")
    load = src[src.index("Component.onCompleted") :]
    load = load[: load.index("_lastSynced = _servers")]
    injected = [
        f for f in ("codec", "bitrate", "uuid") if "srv.%s === undefined" % f in load
    ]
    assert injected, "the load path stopped defaulting the model's roles"
    norm = src[src.index("const norm = ") :]
    norm = norm[: norm.index("return JSON.stringify(flat)")]
    for field in injected:
        assert "plain.%s === undefined" % field in norm, (
            "load defaults %s but the merge does not — every station stored "
            "before saved codecs now reads as locally edited" % field
        )


def test_a_list_taken_over_from_the_popup_is_no_edit_on_either_page():
    """plasmoidviewer's settings dialog marks a page changed on every
    cfg_*Changed signal, whatever the value (the Plasma 6.7 desktop dialog
    compares values first). The station
    pages took the popup's list over by assigning cfg_servers, so a logo the
    popup found while the settings were open lit Apply and asked "Apply
    Settings?" on the way out. Neither page declares cfg_servers now; edits
    announce themselves through _edited() and saveConfig() writes.
    tst_stationspage drives the Stations page through both dialogs; the Search
    page asks the network as it opens, so it is held to the same shape here."""
    for page in ("configGeneral.qml", "configSearch.qml"):
        code = _code_only((UI / "config" / page).read_text(encoding="utf-8"))
        assert "cfg_servers" not in code, page + " declares or writes cfg_servers again"
        assert "signal configurationChanged()" in code, page
        edited = _function_body(code, "_edited")
        assert "configurationChanged()" in edited, page + ": an edit goes unannounced"
        save = _function_body(code, "saveConfig")
        assert "plasmoid.configuration.servers = _servers" in save, page
        assert "_servers === _lastSynced" in save, page + ": a page with no edits writes its copy back"
        sync = _function_body(code, "onServersChanged")
        quiet = sync[sync.index("root._servers === root._lastSynced"): sync.index("} else {")]
        assert "root._servers = external" in quiet, page
        assert "_edited()" not in quiet and "configurationChanged()" not in quiet, (
            page + ": the takeover announces an edit nobody made")
        assert "JSON.stringify(getServersArray())" not in code.replace(
            "const s = JSON.stringify(getServersArray())", "").replace(
            "if (changed) root._servers = JSON.stringify(getServersArray())", ""), (
            page + ": an edit site serialises the list by hand instead of calling _edited()")


def test_both_station_pages_save_the_rows_and_not_their_wrappers():
    """Both pages keep the list in a dynamicRoles ListModel, whose get() hands
    back a QObject, and JSON.stringify of that wrote "objectName":"" into every
    saved station (read in appletsrc on the bench, 2026-09-23). The flattening
    is ReorderLogic.savedRows, under tst_reorderlogic; the Search page has no
    harness of its own, so this holds both pages to it."""
    for page in ("configGeneral.qml", "configSearch.qml"):
        code = _code_only((UI / "config" / page).read_text(encoding="utf-8"))
        body = _function_body(code, "getServersArray")
        assert "ReorderLogic.savedRows(stationsModel)" in body, (
            page + " serialises the model's rows by hand again")
        assert "stationsModel.get(" not in body, page


def test_a_cast_episode_comes_home_named_and_with_its_show():
    """Unticking the last device hands the episode back to this computer.

    It used to arrive stripped: root.title never carries an episode name (only
    an ICY line or the widget's own), so the episode came home called "On Air",
    and a literal "" for the feed overwrote the show that was still standing —
    losing the show's own playback speed and the up-next chain with it. The
    name lives in currentStation and the show in _currentEpisodeFeed, read
    before the call clears it."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    i = src.index("function _castResumeLocally")
    block = src[i : i + 800]
    call = block[block.index("playPodcastEpisode(") :]
    call = call[: call.index(";") + 1]
    assert "root.currentStation" in call, (
        "the handed-back episode lost its name — root.title is the widget's "
        "own name here, not the episode's"
    )
    assert "root.title" not in call, "root.title is back as the episode's name"
    assert "root._currentEpisodeFeed" in call, (
        "the handed-back episode lost its show — an empty feed costs it the "
        "show's speed and its up-next chain"
    )


def test_the_no_titles_pin_names_the_station_not_the_transport():
    """The pin has to name the station, never the address it is heard on.

    A relayed station — Ogg, FLAC, or an mp3 the rescue put behind the relay —
    plays from a loopback, and every road that lifts the pin asks
    _icyStreamTarget for the station behind it. Written raw, the pin was a
    loopback address compared against a station address: the five-minute
    recheck returned on its first line and the pin stood for the whole play,
    on exactly the stations the same release taught to poll for titles."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    assert "var queryUrl = _icyStreamTarget(playMusic.source)" in src, (
        "the no-titles pin is written raw again — a relayed station's pin "
        "will never match the roads that lift it"
    )
    for cmp_op in ("!==", "==="):
        needle = f"_noIcySource {cmp_op} playMusic.source"
        assert needle not in src, (
            f"a pin comparison went back to the raw source ({needle}) — the "
            "pin is stored as the station and the two can never match"
        )


def test_a_wish_typed_without_the_word_in_reaches_the_tag_list():
    """"rock 80 uk" was asked of the directory as a station NAME, found none,
    and the stem retry answered with French and German "rock 80" stations
    (seen in the running widget, 2026-09-21). SearchLogic.facetQuery reads
    the words and SearchLogic.reading asks it for the fence (tst_searchlogic
    holds both); this pins that the search takes its reading from there,
    scopes by the country it found and sends the tags as a tagList.
    """
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "runWebSearch"))
    assert "SearchLogic.reading(q, fullRepresentation.webSearchMode, _countryCodeOf, plain)" in body, (
        "the search no longer reads a query as facets")
    assert "const cc = read.cc, scoped = read.scoped" in body, (
        "a facet query's country no longer scopes the search")
    logic = _code_only((UI / "SearchLogic.js").read_text(encoding="utf-8"))
    assert "var bare = facetQuery(t, ask);" in _function_body(logic, "reading")
    assert '"tagList=" + facet.tags.map(encodeURIComponent).join(",")' in body, (
        "facet tags are not sent as a tagList")
    assert "|| facet !== null" in body, "a facet query can skip the tag pass again"


def test_a_stale_country_chip_steps_aside_for_an_empty_answer():
    """Seen in the running widget: "jazz united states", then "virgin radio
    uk" answered "No matching stations" with the American chip still up.
    The decision is SearchLogic.emptyNext; this pins that every search road's
    end asks it, and that "unscope" really drops the chip and runs again.
    """
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webFinish"))
    assert "SearchLogic.emptyNext(" in body
    assert "inheritedScope: fullRepresentation._webScopeInherited" in body
    drop = body[body.index('next === "unscope"'):body.index('next === "stems"')]
    assert 'webScopeCc = ""' in drop and "runWebSearch(root.searchFilter, false, next" in drop, (
        "the unscope branch no longer drops the chip and searches again")
    run = _code_only(_function_body(src, "runWebSearch"))
    assert '_webScopeInherited = scopeCc !== "" && scoped === null' in run, (
        "a scope the text itself names would be dropped as if it were inherited")


def test_a_thin_answer_to_a_name_with_a_country_asks_inside_the_country():
    """"retro fm eesti" showed one row with no votes, and name=retro fm inside
    EE answers four, Retro FM Estonia among them (measured 2026-11-10). A
    station word makes the text a name, so the country was never tried as a
    fence. SearchLogic.nameInCountry reads the fallback and emptyNext answers
    "incountry" (tst_searchlogic holds both); this pins the wiring: the
    reading is offered once per search and never under a fence, the request
    is the name inside the country with the page's cap back, and its end
    comes round to _webFinish with the step marked as spent."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webFinish"))
    assert "function _webFinish(q, seq, tail, gotAnswer, askedInCountry)" in src
    assert ('var inCc = (askedInCountry || tail.indexOf("&countrycode=") !== -1)' in body
            and "? null : SearchLogic.nameInCountry(q, _countryCodeOf)" in body), (
        "the fallback is offered under a fence, or more than once")
    assert "inCountry: inCc !== null," in body
    step = body[body.index('if (next === "incountry") {'):body.index('next === "unscope"')]
    assert "fullRepresentation.webResultCap = 30" in step, (
        "the answer goes in under the word pass's frozen cap and shows one row")
    assert ('"/json/stations/search?name=" + encodeURIComponent(inCc.text) + "&countrycode=" + inCc.cc'
            in step)
    assert "root._rbFetch(inQs + tail, 4000, function(xhr) {" in step
    assert "if (seq !== fullRepresentation._webSearchSeq) return" in step
    assert "_webFinish(q, seq, tail, xhr !== null || webResultsModel.count > 0, true)" in step, (
        "the step runs again on its own answer, or an empty answer never reaches the stems")


def test_a_late_mirror_list_leaves_a_search_already_made_alone():
    """The settings search page looks up the directory's mirrors when it
    opens, for up to five seconds, and then loads the default list. A search
    made in that time was answered and then replaced by the default list when
    the mirrors came in, because the look-up's end called getStations() with
    no word whatever was on screen. The page opens a real connection as it is
    created, so no test drives it; this pins that the look-up's end always
    picks the mirror and asks for the default list only while no search has
    been made."""
    code = _code_only((UI / "config" / "configSearch.qml").read_text(encoding="utf-8"))
    body = _function_body(code, "discoverServers")
    end = body[body.index("var finish = () => {"):body.index("if (xhr.status === 200)")]
    assert "getServer()" in end, "the mirror is no longer picked when the look-up ends"
    assert "if (isNoSearch)" in end and end.index("getServer()") < end.index("if (isNoSearch)")
    assert end.count("getStations()") == 1
    assert re.search(r"if \(isNoSearch\)\s+getStations\(\)", end), (
        "the look-up's end loads the default list over a search already made")


def test_the_settings_search_shows_a_codec_one_way():
    """The list row and the station info under it both show the directory's
    codec field in a chip. This pins that both take it through the page's one
    cleaning function and that no chip reads the field as it came."""
    raw = (UI / "config" / "configSearch.qml").read_text(encoding="utf-8")
    code = _code_only(raw)
    assert "function _codecText(raw)" in code
    assert code.count("root._codecText(") == 2, "a codec chip reads the directory's field as it came"
    assert "text: root._codecText(listItem.model.codec)" in code
    assert ('text: mainList.currentIndex !== -1 ? root._codecText(searchModel.get(mainList.currentIndex).codec) : ""'
            in code), "the info chip shows the codec as it came"


def test_the_probes_pass_reads_first_and_marks_afterwards():
    """A remembered "dead" verdict was marked while the pass walked the list,
    and marking sinks the row: on [a, b, DEAD1, DEAD2, c, DEAD3, DEAD4, DEAD5,
    d] with every verdict remembered, DEAD2 and DEAD4 stayed bright and the
    dead came out reversed, so a query typed again within fifteen minutes
    showed dead stations as live. SearchLogic.probePass and markAlive are
    held by tst_searchlogic on a real ListModel; this pins that the popup's
    pass hands them the rows, marks nothing itself while it walks, and that
    one verdict from a finished probe goes the same road."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    kick = _code_only(_function_body(src, "_probeKick"))
    assert "rows.push(webResultsModel.get(i))" in kick
    read = kick.index("const pass = SearchLogic.probePass(rows, {")
    mark = kick.index("SearchLogic.markAlive(webResultsModel, pass.known)")
    knock = kick.index("for (const url of pass.knock) {")
    assert read < kick.index("for (const done of pass.spent)") < mark < knock
    assert "_webSetAlive(" not in kick and "setProperty(" not in kick and "_webSinkDead(" not in kick, (
        "the pass marks a row while it is still walking the list")
    assert "slots: 6 })" in kick, "the probe's six doors at a time are gone"
    one = _code_only(_function_body(src, "_webSetAlive"))
    assert 'SearchLogic.markAlive(webResultsModel, [{ "url": url, "v": verdict }])' in one
    assert "SearchLogic.sinkDead(webResultsModel)" in _code_only(_function_body(src, "_webSinkDead"))


def test_the_first_search_is_read_again_when_the_country_list_arrives():
    """The directory's country list is fetched with the session's first
    search, which goes out before the answer: the first "portugal" listed 27
    stations with Portugal in their name and every later one Portugal's chart
    (measured 2026-11-10). SearchLogic.readingKey says whether the list
    changes the reading (tst_searchlogic); this pins that the key is taken
    before and after the map is set, that the search runs again only when it
    moved and no typing is waiting on the debounce, and that the map a
    session starts on has no prototype and is looked up through
    SearchLogic.countryCode, so "constructor" is no country code."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    assert "property var _countryMapApiFolded: SearchLogic.countryMapFromApi([])" in code, (
        "the session starts on a map with Object's prototype again")
    look = _function_body(code, "_countryCodeOf")
    assert "SearchLogic.countryCode(q, _countryMapFolded, fullRepresentation._countryMapApiFolded)" in look
    assert "[f]" not in look, "a country map is indexed by hand again"
    body = _function_body(code, "_ensureCountryList")
    key = body.index("SearchLogic.readingKey(root.searchFilter, fullRepresentation.webSearchMode, _countryCodeOf)")
    was = body.index("var was = key()")
    put = body.index("fullRepresentation._countryMapApiFolded =")
    again = body.index("if (!webSearchDebounce.running && key() !== was) runWebSearch(root.searchFilter)")
    assert key < was < put < again, "the reading is not compared across the list's arrival"


def test_a_guessed_fence_steps_aside_and_its_namesakes_lead():
    """"new jersey" was read as "new" in Jersey, found nothing there and the
    popup said No matching stations over six stations of that name; "bbc
    wales" asked for name=bbc in GB with "bbc Wales" 39th, past the page
    (measured 2026-11-10). SearchLogic.reading marks the guess, emptyNext
    answers "astyped" and fenceLead picks the leads (tst_searchlogic holds
    all three); this pins the wiring: the search tells emptyNext about the
    guess only while the fence is up, the retry runs the field's text with
    plain set and the chip gone, and the fenced name answer is walked twice,
    leads first, with "Show more" continuing from the second walk."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webFinish"))
    assert "bareScope: fullRepresentation._webScopeBare" in body
    assert 'if (next === "unscope" || next === "astyped") {' in body
    drop = body[body.index('next === "astyped"'):body.index('next === "stems"')]
    assert 'webScopeCc = ""' in drop and 'webScopeName = ""' in drop
    assert 'runWebSearch(root.searchFilter, false, next === "astyped")' in drop, (
        "the retry reads the same guess again and loops, or never runs")
    run = _code_only(_function_body(src, "runWebSearch"))
    assert "function runWebSearch(q, releaseScope, plain)" in src
    assert '_webScopeBare = scopeCc !== "" && read.bareScope' in run, (
        "a released fence is still reported as a guess standing in the way")
    assert ('const own = (mode === "all" && lead === null && fullRepresentation._webScopeBare) '
            "? SearchLogic.fenceLead(qTyped) : null") in run
    walk = run.index("if (gotAnswer && own) _webAppendResults(xhr)")
    assert run.index("_webAppendResults(xhr, lead || own)") < walk
    assert "if (gotAnswer) _webMark(0)" in run[walk:walk + 120], "Show more skips the rows between the two walks"


def test_a_glued_number_is_spelled_apart_before_the_stems():
    """"raadio2" found nothing and its stem "raadio" put Raadio 2 HQ third
    among thirty stations; "raadio 2" is the three Raadio 2 streams (measured
    2026-11-02). SearchLogic.spellings puts the space in; this pins that the
    empty answer's retry asks the spellings first and counts them with the
    stems, so emptyNext still sees a retry to run."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webFinish"))
    assert "var stems = SearchLogic.spellings(q).concat(SearchLogic.stems(q))" in body, (
        "the empty answer's retry no longer spells a glued number apart first")
    assert "stemCount: stems.length" in body


def test_a_genre_beside_a_place_is_asked_before_the_stems():
    """"techno berlin" found nothing in five requests, and the techno tag
    inside the state "berlin" is seventeen stations (measured 2026-11-02).
    SearchLogic.genrePlace reads the pair; this pins that an empty answer asks
    it only once the cap is back at a full page (asked under the word pass's
    frozen cap of count+1, the list showed one station of the seventeen),
    and that its answer's own handler pages that question with "Show more",
    ends the search when no mirror answered and goes on to the stems when the
    answer was empty. The handler is cut out by its braces: the stems call
    for a query that is no genre and place stands right after it."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webFinish"))
    branch = body[body.index('next === "stems"'):]
    assert "SearchLogic.genrePlace(q)" in branch, "an empty genre-and-place answer goes straight to the stems"
    ask = branch.index("SearchLogic.genrePlace(q)")
    assert branch.index("fullRepresentation.webResultCap = 30") < ask, (
        "the genre is asked inside the place under the word pass's frozen cap")
    after = branch[ask:]
    assert '"&state=" + encodeURIComponent(gp.state)' in after
    opening = after.index("{", after.index("root._rbFetch(gpQs + tail"))
    depth, end = 0, opening
    for end in range(opening, len(after)):
        depth += {"{": 1, "}": -1}.get(after[end], 0)
        if depth == 0:
            break
    handler = after[opening:end + 1]
    assert "_webMark(0, gpQs + tail)" in handler, (
        "Show more pages the name query that found nothing")
    assert "webSearchFailed = webResultsModel.count === 0" in handler, (
        "no mirror answering the genre-and-place question reads as no results")
    assert "_webStemChain(q, stems, 0, seq, tail)" in handler, (
        "an empty genre-and-place answer no longer goes on to the stems")


def test_a_result_row_shows_the_short_country_name():
    """The directory files Britain as "The United Kingdom Of Great Britain And
    Northern Ireland"; on a one-line row that pushed bitrate and codec off
    the end for every British and American station."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    assert "SearchLogic.countryLabel(webItem.model.cc" in src


def test_the_station_boxes_on_the_timers_page_remember_their_pick():
    """The alarm's and the scheduled recording's station boxes sit on the
    shared station list, which reloads by clear-and-append. A plain combo
    went empty there and "Add" went grey (seen in the running widget,
    2026-09-21). StationPicker carries the behaviour and its own tests; this
    pins that both boxes are one."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    for ident in ("alarmStation", "schedStation"):
        at = src.index("id: " + ident)
        head = src[src.rfind("\n", 0, src.rfind("{", 0, at)):at]
        assert "StationPicker" in head, ident + " is a plain combo again"


def test_a_return_to_live_keeps_the_header_until_live_speaks():
    """Reported by the listener: back from a pause the cover was gone and had
    to be waited for. "Back to live" lowers the shift flag and stops the
    player in one breath, and the stopped edge wiped title and cover. The
    engine now raises a bounded keep first (tst_timeshiftengine covers that);
    this pins the four places in main.qml that have to honour it: the two
    that clear the header, and the two title roads that tell the engine live
    has spoken — without the second pair a kept title is wiped at the
    deadline although live confirmed it.
    """
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    edge = code[code.index("onPlayingChanged:"):]
    edge = edge[:edge.index("_mprisQueueWrite()")]
    assert "!timeshift.sleeveKept(Date.now())) root.metadata = \"\"" in edge, (
        "the stopped edge wipes the header over a return to live again")
    late = code[code.index("var formattedText = "):]
    late = late[:late.index("__NO_ICY__")]
    assert "!timeshift.sleeveKept(Date.now())" in late, (
        "a reader landing during the return wipes the header")
    assert code.count("timeshift.liveTitleSeen()") >= 2, (
        "a title road no longer tells the engine that live has spoken")
    qt = code[code.index("onMetaDataChanged:"):]
    qt = qt[:qt.index("onMediaStatusChanged:")]
    assert "timeshift.liveTitleSeen()" in qt
    # The header's own line is a third thing the restart resets. Seen in the
    # running widget: cover and title stayed, and the line under the station
    # name went empty until the NEXT song, because an unchanged title sends
    # no change to repaint it from.
    start = _code_only(_function_body((UI / "main.qml").read_text(encoding="utf-8"), "startWithFade"))
    assert "if (!timeshift.sleeveKept(Date.now())) root.title = Plasmoid.title;" in start, (
        "a return to live blanks the header line until the next song")


def test_a_file_does_not_wear_the_radios_last_song():
    """The same keep, seen from the other side. The header is cleared by the
    player's stopped edge, and a park gives no edge at all while a shifted
    listen is told to keep it. _playStation clears for a different station;
    playLocalFile, the road every My Music track and every podcast episode
    takes, cleared nothing, so a file picked over a parked or shifted station
    showed the radio song's title, artist and cover until it ended."""
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert 'root.metadata = ""' in _function_body(code, "_playStation"), (
        "a different station wears its predecessor's song again")
    local = _function_body(code, "playLocalFile")
    start = local.index("startWithFade(")
    assert 'root.metadata = "";' in local[:start], (
        "a file starts without clearing the title line: picked over a park or "
        "a shifted listen it shows the radio's last song for its whole length")


def test_a_file_from_my_music_cannot_be_starred_as_a_station():
    """playLocalFile hands startWithFade the file's display name, and that
    becomes currentStation. The Playing page's star toggled a favourite of
    that name: an entry no station carries, dropped without a word at the
    next list load, and when a station happens to share the name it was that
    station's favourite that flipped. The star is off while a file plays. A
    station heard from its timeshift buffer is a file to the player and
    still a station to the listener, so the flag it asks leaves that out.
    """
    rep = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    star = rep.index("root.toggleFavorite(root.currentStation)")
    opened = rep.rfind("CircleButton {", 0, star)
    head = rep[opened:rep.index("onClicked", opened)]
    assert "root.isFavorite(root.currentStation)" in head, (
        "this is no longer the Playing page's star; the check lost its place")
    assert re.search(r"^\s*enabledState: !fullRepresentation\._localPlayback\s*$", head, re.M), (
        "the Playing page's star is live while a My Music file plays and "
        "makes a favourite out of the file's name")
    flag = rep[rep.index("readonly property bool _localPlayback:"):]
    flag = flag[:flag.index("readonly property bool _podcastPlaying")]
    assert "&& !root.tsShifted" in flag, (
        "a station heard from its buffer counts as a local file again, and "
        "its star is switched off with the files'")


def test_a_stations_first_title_skips_the_flap_window():
    """The 1.5 s debounce protects against a flapping StreamTitle; the first
    title after an empty header has nothing to flap against."""
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert 'var firstTitle = root._artPendingKey === "";' in code
    assert "artworkEngine.debounceRestart(firstTitle)" in code


def test_a_cover_lookup_hands_its_chain_the_way_to_start_over():
    """A chain that ends on a timeout or a refusal is asked once more.
    tst_artworkengine drives that with chains of its own, because the
    engine's real requests cannot be answered inside a test. The real lookup
    still has to hand its chain the way to start over: without that the
    panel never makes the second attempt and every test stays green."""
    src = (UI / "ArtworkEngine.qml").read_text(encoding="utf-8")
    lookup = _code_only(_function_body(src, "lookupAlbumArt"))
    assert "function() { engine.lookupAlbumArt(trackString); }" in lookup, (
        "the lookup's chain can no longer be started over after a timeout")


def test_opening_the_popup_asks_for_the_title_once():
    """The title is polled every five seconds, eight on battery, so a popup
    opened just after a song changed showed the old title for up to that
    long. Opening it now asks once, where RetryLogic.titleOnOpen says so
    (tst_retrylogic holds the rule). main.qml cannot be driven in a test, so
    this pins the wiring: the opening branch asks through getStreamInfo, which
    keeps the single reader and the no-titles pin, and it hands the rule the
    desktop form, the poll's timer and the player's state."""
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    handler = code[code.index("onFaceShownChanged:"):]
    handler = handler[:handler.index("function _pushHistory")]
    assert ("} else if (RetryLogic.titleOnOpen(planar, infoTimer.running, "
            "isPlaying() && !isError && !_qtMetaWorks)) "
            "getStreamInfo(playMusic.source, root.metadata);") in handler, (
        "opening the popup no longer asks for the title, or asks past the rule")
    assert handler.count("getStreamInfo(") == 1, (
        "the popup's opening asks for the title more than once")
    # The closing branch keeps what it had.
    for call in ("_flushHistory()", "_stampPodPosition()", "_flushPodPositions()"):
        assert call in handler[:handler.index("} else if")], call


def test_typing_a_word_that_starts_with_m_does_not_mute_the_radio():
    """On the list page every printable key opens the search — except that M
    was claimed first as an undocumented mute: typing "metal" silenced the
    radio and searched for "etal". M mutes on the other pages only."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = src.index("event.key === Qt.Key_M")
    cond = src[at:src.index("{", at)]
    assert "root.view !== 0" in cond, "M mutes on the list page again and eats the first letter"
    assert src.index("typeToSearch(event)", at) > at


def test_no_key_sends_the_focus_into_a_hidden_search_field():
    """With the search row switched off in Appearance the field still exists,
    and three keys still focused it: any letter, "/" on the list, and Up from
    the first web result over an empty list. The list was then filtered by
    letters nobody could see, and Space typed a space where it used to stop
    the radio. tst_typetosearch presses the keys on a copy and tst_viewrules
    holds the rule; this holds every road to the field to the switch."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    shown = "Plasmoid.configuration.showSearchRow !== false"
    typed = _function_body(src, "typeToSearch")
    ask = typed.find("ViewLogic.typedChar(" + shown)
    leave = typed.find('if (ch === "") return false')
    assert 0 <= ask < leave < typed.index("filterField.forceActiveFocus()"), (
        "open-and-type no longer asks the tested rule, with the row's own "
        "switch, before it touches the field")
    lo = src.index(typed)
    roads = [m.start() for m in re.finditer(r"filterField\.forceActiveFocus\(\)", src)]
    assert len(roads) >= 3, "a road to the search field went missing: %d left" % len(roads)
    for at in roads:
        if lo <= at < lo + len(typed):
            continue
        cond = src[src.rfind("if (", 0, at):at]
        assert shown in cond and cond.count("\n") == 1, (
            "line %d focuses the search field without asking whether its row "
            "is on screen" % (src.count("\n", 0, at) + 1))


def test_a_search_chip_shows_its_ampersand_and_searches_what_was_typed():
    """The genre and history chips are tool buttons, and a button reads "&"
    as the mark of its keyboard shortcut: the history chip for "r&b" read
    "rb" (measured on PlasmaComponents3.ToolButton, and again in
    tst_chiplabel on every run). The label goes through ViewLogic.chipLabel;
    the click and the accessible name keep the text as it was typed, so the
    search that runs is the one the chip names."""
    code = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    clicks = [m.start() for m in re.finditer(r"onClicked: filterField\.text = modelData", code)]
    assert len(clicks) == 2, (
        "expected the genre chip and the history chip to type their own text "
        "into the field, found %d such chips" % len(clicks))
    for at in clicks:
        head = code[code.rfind("PlasmaComponents3.ToolButton {", 0, at):at]
        line = code.count("\n", 0, at) + 1
        assert "text: ViewLogic.chipLabel(modelData)" in head, (
            "the chip near line %d hands the button its raw text, and an "
            "ampersand in it is eaten as a shortcut mark" % line)
        assert "Accessible.name: modelData" in head, (
            "the chip near line %d is no longer named as it was typed" % line)


def test_a_bare_decade_is_not_too_short_to_search():
    """"80" is two characters and the short-query gate dropped it without a
    word; the directory has some 1900 stations tagged with that decade."""
    body = _code_only(_function_body((UI / "FullRepresentation.qml").read_text(encoding="utf-8"), "runWebSearch"))
    assert 'q.length < 3 && cc === "" && SearchLogic.decadeTag(q) === ""' in body


def test_a_saved_new_address_reaches_the_alarm_and_the_scheduled_recording():
    """The heal road saved a moved station's new address to the list and told
    the listener so, while the alarm and the scheduled recording on that
    station kept their own copy of the dead one. The engines do the rewriting
    (tst_alarmengine, tst_recordingengine); this pins that the heal calls
    them, and only once identity is proven — a session stopgap must never
    rewrite an alarm any more than it may rewrite the list.
    """
    body = _code_only(_function_body((UI / "main.qml").read_text(encoding="utf-8"), "_healCommit"))
    gate = body.index('!== "permanent"')
    stopgap_return = body.index("return;", gate)
    for call in ("alarmEngine.retargetStation(oldUrl, newUrl)",
                 "recordingEngine.retargetStation(oldUrl, newUrl)"):
        assert call in body, call + " is gone: the alarm rings the dead address again"
        assert body.index(call) > stopgap_return, call + " runs before identity is proven"




def test_a_logo_found_by_name_passes_the_donor_gate_at_both_doors():
    """A logo looked up by NAME is saved to the list, and a name is not an
    identity: "Rock FM" answered with four exact-name rows from three countries
    in its ten most voted (2026-09-21), and the first of them put the Russian
    station's logo on a Spanish listener's row for good. Who may donate is
    FaviconLogic.donorRows under tst_faviconlogic; what no library test can
    see is whether the two doors hand it what it needs: the saved address,
    without which the station's own record cannot be told from a namesake,
    and the number of rows asked for, without which a full page reads as the
    whole truth.
    """
    main = (UI / "main.qml").read_text(encoding="utf-8")
    backfill = _code_only(_function_body(main, "_favBackfillNext"))
    asked = re.search(r'"&limit=(\d+)&order=votes&reverse=true"', backfill)
    handed = re.search(
        r"FaviconLogic\.pickFavicon\(rows, norm, HealLogic\.normName, st\.host, (\d+)\)",
        backfill)
    assert handed, "the backfill picks a logo without the saved address"
    assert asked and asked.group(1) == handed.group(1), (
        "the backfill asks for one page size and tells the picker another")
    # A station the directory calls broken still has a record, and that
    # record is the one row that proves whose logo this is.
    assert "hidebroken" not in backfill

    page = (UI / "config" / "configGeneral.qml").read_text(encoding="utf-8")
    assert 'import "../FaviconLogic.js" as FaviconLogic' in page
    query = re.sub(r"\s+", " ", _code_only(_function_body(page, "_queryRadioBrowser")))
    asked = re.search(r'"&limit=(\d+)&order=votes&reverse=true"', query)
    handed = re.search(
        r"FaviconLogic\.donorRows\(results, HealLogic\.normName\(cleanName\), "
        r"HealLogic\.normName, job\.hostname, (\d+)\)", query)
    assert handed, "the settings page picks a logo without the saved address"
    assert asked and asked.group(1) == handed.group(1), (
        "the settings page asks for one page size and tells the picker another")
    assert "hidebroken" not in query
    # The page's own loop once fell back to the first row with any icon at
    # all. Both picks must come from the donors and from nowhere else.
    assert "pickedFavicon = _extUrlOrEmpty(donors[d].favicon);" in query
    assert "pickedHomepage = _extUrlOrEmpty(donors[d].homepage);" in query
    assert query.count("pickedFavicon = ") == 2 and query.count("pickedHomepage = ") == 2, (
        "something besides the donor loop assigns the page's pick")


def test_the_popup_reads_a_homepage_only_through_the_guarded_hunt():
    """The popup's backfill now reads a station's homepage and fetches what it
    names with no click at all: Raadio Kadi's directory record had no logo and
    a homepage whose og:image is the logo (2026-11-02). That ladder was the
    settings button's alone because every address it fetches comes from a
    publicly writable catalogue or from a stranger's page. So the popup may
    only reach it through LogoHunt, the one copy of the private-host refusal,
    the check of where Qt's own redirects ended, the timers and the caps, and
    only through its homepage entry, which asks no stream host and no icon
    service. tests/qml/tst_logohunt.qml drives those guards with stand-in
    requests; what no QML test sees is whether the popup goes around them.
    """
    main = (UI / "main.qml").read_text(encoding="utf-8")
    hunt = (UI / "LogoHunt.qml").read_text(encoding="utf-8")
    backfill = _code_only(_function_body(main, "_favBackfillNext"))
    flat = re.sub(r"\s+", " ", backfill)

    # The backfill's only roads out are the directory and the hunt's
    # homepage entry, taken when the record has no logo of its own and the
    # connection is not metered.
    assert "XMLHttpRequest" not in backfill and ".open(" not in backfill
    assert re.findall(r"logoHunt\.\w+\(", backfill) == ["logoHunt.huntHomepage("], (
        "the popup calls into LogoHunt somewhere other than its homepage entry")
    assert ('if (fav !== "" || home === "" || NetworkInformation.isMetered) done(fav); '
            "else logoHunt.huntHomepage(home, done);") in flat
    # The homepage passes the favicon gate, and a name search lends only
    # a donor's page, with the saved address and the page size it asked.
    assert "home = FaviconLogic.webUrlOrEmpty(row.homepage);" in backfill
    assert "home = FaviconLogic.pickHomepage(rows, norm, HealLogic.normName, st.host, 30);" in backfill
    # Two start empty and those two assignments are the only others.
    assert len(re.findall(r"\bhome = ", backfill)) == 4 and flat.count('home = ""') == 2
    assert len(re.findall(r"^\s*LogoHunt \{ id: logoHunt; app: root \}$", main, re.M)) == 1

    # The entry: the page, then what it names and the well-known paths on
    # its own origin. Nothing else is added to the list.
    entry = re.sub(r"\s+", " ", _code_only(_function_body(hunt, "huntHomepage")))
    assert "probe(FaviconLogic.homepageCandidates(images, from || homepage), function(best) {" in entry
    assert entry.count("probe(") == 1 and entry.count("readPage(") == 1
    # Nobody clicked: both steps run strict, and a tab-sized icon is no logo.
    assert entry.endswith("}, true); }, true); }"), "the popup's hunt is not strict"
    assert "var tiny = best && FaviconLogic.logoRank(best.url, best.size) >= 4;" in entry
    pick = re.sub(r"\s+", " ", _code_only(_function_body(hunt, "_fromPublicHost")))
    assert pick == ("{ return strict ? HostGuard.answerKnownPublic(xhr) : "
                    "HostGuard.answerFromPublicHost(xhr); }"), pick

    # Every request the engine sends: gated before it is opened, its timer
    # armed, its answer judged by where it came from, its body capped.
    # Both public doors start nothing in their caller's handler.
    door = re.sub(r"\s+", " ", _code_only(_function_body(hunt, "readPage")))
    assert door == "{ Qt.callLater(function() { hunt._readPageNow(homepage, onDone, strict === true); }); }"
    page = _code_only(_function_body(hunt, "_readPageNow"))
    image = _code_only(_function_body(hunt, "_fetchImage"))
    probe = _code_only(_function_body(hunt, "probe"))
    assert re.sub(r"\s+", " ", probe).endswith("Qt.callLater(step); }") and probe.count("step();") == 1
    assert page.index("var page = FaviconLogic.webUrlOrEmpty(homepage);") < page.index(
        'if (page === "") {') < page.index("xhr.open(\"GET\", page);")
    assert "target = FaviconLogic.webUrlOrEmpty(order[next++]);" in probe
    assert probe.count("_fetchImage(") == 1 and "_fetchImage(target," in probe
    assert "_fetchImage(" not in page and hunt.count("_fetchImage(") == 2
    for body, timeout, cap in ((page, "hunt.pageTimeoutMs", "hunt.pageCap"),
                               (image, "hunt.probeTimeoutMs", "hunt.imageCap")):
        assert "guard = app._armXhrTimeout(xhr, %s);" % timeout in body
        assert "hunt._fromPublicHost(xhr, strict)" in body
        assert cap in body
        # An abort from inside the reply's own handler has crashed
        # plasmashell; every one here is deferred.
        assert body.count("xhr.abort()") == body.count(
            "Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });")
    assert hunt.count(".open(") == 2 and hunt.count("new XMLHttpRequest") == 1
    for prop in ("pageCap", "pageKept", "imageCap", "pageTimeoutMs", "probeTimeoutMs"):
        assert re.search(r"^\s*readonly property int %s: \d+$" % prop, hunt, re.M), (
            prop + " is no longer read-only: a caller could loosen it")

    # Looking for a logo starts no sound and touches no player.
    player = re.compile(r"playMusic|_playStation|startWithFade|previewStation|refreshServer"
                        r"|_wantsPlaying|tsPlayLive|\.play\(")
    for body in (backfill, _code_only(_function_body(main, "_favBackfillCommit")),
                 _code_only(hunt)):
        assert player.search(body) is None


def test_the_settings_list_asks_in_one_spelling_and_lists_a_station_once():
    """The settings page built its two requests by hand, twice, and neither
    named an order: the directory then answers by raw name, and the list
    opened on names that begin with a tab or a space with the stations people
    know hundreds of rows down. Both requests now come from SearchLogic
    (tst_searchlogic holds the order, the page size and the safe parts); this
    keeps a hand-written query string from coming back, and keeps the
    seen-book wired: filled per row, emptied with the list.
    """
    raw = (UI / "config" / "configSearch.qml").read_text(encoding="utf-8")
    code = _code_only(raw)
    # The RAW bodies: _code_only cuts a line at "//", which is also the middle
    # of "https://", so a hand-written URL would hide behind its own scheme.
    for fn in ("_doGetStations", "loadMore"):
        body = _function_body(raw, fn)
        for needle in ("hidebroken", "&limit=", "&offset=", "order=", "radio-browser.info"):
            assert needle not in body, (
                "%s writes its request by hand again (%s)" % (fn, needle))
    assert code.count("SearchLogic.directoryPage(") == 2, "first page and later pages must ask the same way"
    assert "SearchLogic.directoryBase(server, isNoSearch ? null : by, val)" in code
    row = _function_body(code, "_appendRow")
    assert "SearchLogic.firstSight(_seen, srv.stationuuid)" in row
    clear = code.index("searchModel.clear()", code.index("SearchLogic.directoryPage(base"))
    assert "_seen = ({})" in code[clear:clear + 80], "the seen-book outlives the list it describes"
    import re as _re
    m = _re.search(r"property int limit: (\d+)", code)
    assert m and 50 <= int(m.group(1)) <= 200, (
        "a page shorter than the window never scrolls, so page two is never asked for")


def test_a_later_page_that_failed_is_asked_again_without_a_scroll():
    """Page two of the settings list failed once at the end of the list and
    never came: the only trigger was the list moving, and a list at its end
    does not move. Every answer that is no list (SearchLogic.directoryRows,
    held by tst_searchlogic: another status, a page, JSON that is no array)
    goes through _pageFailed, which waits (SearchLogic.pageRetryDelay) and
    asks the next mirror; a good page clears the count and a new search stops
    a retry that belongs to the old list."""
    code = _code_only((UI / "config" / "configSearch.qml").read_text(encoding="utf-8"))
    more = _function_body(code, "loadMore")
    rows = "var servers = SearchLogic.directoryRows(xhr.status, xhr.responseText)"
    assert rows in more and "JSON.parse(" not in more, "loadMore judges the answer itself again"
    assert more.count("_pageFailed()") == 1, (
        "a failed page goes back to waiting for a scroll that may never come")
    assert more.count("stat = 1") == 1, (
        "a failure road only re-opens the scroll trigger again (stat = 1)")
    assert "_pageFailures = 0" in more, "a good page leaves the failure count standing"
    # The cursor and the count move only over a page that was a list: a body
    # of "null" used to move both before it threw.
    assert more.index("_pageFailed()") < more.index("offset = nextOffset") < more.index("_pageFailures = 0")
    failed = _function_body(code, "_pageFailed")
    for needle in ("SearchLogic.pageRetryDelay(_pageFailures)", "if (wait < 0)",
                   "currentUrl = SearchLogic.rehost(currentUrl, server)", "pageRetryTimer.restart()"):
        assert needle in failed, "_pageFailed lost " + needle
    assert "onTriggered: if (root.stat === 1) root.loadMore()" in code
    fresh = _function_body(code, "getStations")
    assert "pageRetryTimer.stop()" in fresh and "_pageFailures = 0" in fresh, (
        "a retry from the last list can land in the new one")


_TEXT_ELEMENT = re.compile(
    r"(?<![\w.])(?:\w+\.)?(?:Label|Heading|Text|TextEdit|TextInput)\s*\{")


_RAW_ACCENT = re.compile(r"\broot\.accent(?:Bright|Teal)?\b")


_NEXT_MEMBER = re.compile(
    r"^(?:[A-Za-z_][\w.]*\s*:(?!:)|[A-Z][\w.]*\s*\{|\}"
    r"|(?:readonly\s+|required\s+|default\s+)?property\b|function\b|signal\b|Behavior\b)")


def _balanced_end(code, i):
    depth = 0
    for j in range(i, len(code)):
        if code[j] == "{":
            depth += 1
        elif code[j] == "}":
            depth -= 1
            if depth == 0:
                return j
    raise AssertionError("unbalanced braces")


def _own_text_colours(src):
    """(line, expression) for the color: of every text element's own body."""
    code = _code_only(src)
    for m in _TEXT_ELEMENT.finditer(code):
        start = m.end() - 1
        end = _balanced_end(code, start)
        depth, k = 0, start
        while k < end:
            ch = code[k]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            elif (depth == 1 and code.startswith("color", k)
                  and not (code[k - 1].isalnum() or code[k - 1] in "._")):
                mm = re.match(r"color\s*:", code[k:])
                if mm:
                    e = k + mm.end()
                    rest = code[e:end]
                    if rest.lstrip().startswith("{"):
                        stop = _balanced_end(code, e + rest.index("{")) + 1
                    else:
                        lines = rest.split("\n")
                        n = len(lines[0])
                        for ln in lines[1:]:
                            if _NEXT_MEMBER.match(ln.strip()):
                                break
                            n += 1 + len(ln)
                        stop = e + n
                    yield code.count("\n", 0, k) + 1, code[e:stop]
                    k = stop
                    continue
            k += 1


def test_no_text_is_written_in_the_raw_accent():
    """The accent as a fill and the accent as text are two colours. The
    emerald pair was chosen against a dark panel; on Breeze Light the playing
    station's name measured 1.33:1 against the popup and 1.23:1 on its own
    row's wash, the footer's status line 1.67:1 — five labels, every one of
    them written after accentText existed. tst_colorlogic proves the text
    variants can be read; it cannot see whether a label uses them. So every
    text element's own colour is read here and none may name the raw accent.
    Fills, borders, icons and equalizer bars are not text and keep it.
    """
    seen, hits = 0, []
    for path in sorted(UI.rglob("*.qml")):
        for line, expr in _own_text_colours(path.read_text(encoding="utf-8")):
            seen += 1
            if _RAW_ACCENT.search(expr):
                hits.append("%s:%d" % (path.name, line))
    # A floor, so a parser gone blind cannot hand back a green result.
    assert seen >= 25, "only %d text colours were read; the parser lost its sight" % seen
    assert not hits, "text written in the raw accent: " + ", ".join(hits)
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    for prop, raw in (("accentText", "accent"), ("accentBrightText", "accentBright")):
        m = re.search(r"readonly property color %s:(.{0,260})" % prop, main, re.S)
        assert m and re.search(r"ColorLogic\.readable\(\s*%s\s*,\s*Kirigami\.Theme\.backgroundColor\s*,\s*accent\s*\)"
                               % raw, m.group(1)), prop + " is no longer measured against the popup and the row's wash"
    # The wash the library measures against is the wash the rows really wear.
    lib = (UI / "ColorLogic.js").read_text(encoding="utf-8")
    found = re.search(r"var ROW_WASH = ([\d.]+);", lib)
    assert found, "ColorLogic.js no longer says which wash it measures against"
    wash = found.group(1)
    for name in ("MediaListItem.qml", "EpisodeListItem.qml"):
        row = _code_only((UI / name).read_text(encoding="utf-8"))
        assert "root.accentBrightText" in row, name + " names the playing row in another colour"
        m = re.search(r"Qt\.alpha\(root\.accent, ([\d.]+)\)", row)
        assert m and float(m.group(1)) == float(wash), (
            "%s washes its playing row at %s, the library measures %s" % (name, m and m.group(1), wash))


def test_live_is_written_in_a_red_measured_against_its_own_pill():
    """LIVE was the theme's negative red on a see-through wash of the same red:
    3.03:1 on Breeze Light and 2.83:1 on Breeze Dark on the bench, where body
    text wants 4.5:1, and a blurred cover under the pill could push it lower.
    The pill is painted opaque in ColorLogic.pillSurface and the letters come
    from ColorLogic.pillText, which tst_colorlogic measures on both Breezes.
    This keeps the page from going back to the raw red or a see-through pill."""
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = full.index('text: i18n("LIVE")')
    pill = full[full.rindex("Rectangle {", 0, full.rindex("RowLayout {", 0, at)): at + 400]
    neg = "Kirigami.Theme.negativeTextColor, Kirigami.Theme.backgroundColor"
    assert "color: ColorLogic.pillSurface(%s)" % neg in pill, "the LIVE pill is see-through again"
    label = full[at: full.index("}", at)]
    assert "color: ColorLogic.pillText(%s)" % neg in label, "LIVE is written in the raw red again"


def test_a_podcast_search_nobody_answered_says_so_and_offers_to_ask_again():
    """With the directories out of reach the podcast search said "No shows
    found", which tells the listener the show does not exist, and nothing on
    the page asked again. tst_podcastengine holds the verdict and
    tst_podcastlogic what counts as an answer; this holds the wiring the tests
    cannot reach: every handler hands its verdict to the settle, the root
    forwards both flags, and both empty states speak and offer "Try again"."""
    engine = _code_only((UI / "PodcastEngine.qml").read_text(encoding="utf-8"))
    for fn, field, eps in (("_podSearchITunes", '"results"', "false"), ("_podSearchFyyd", '"data"', "false"),
                           ("_podSearchGpodder", '""', "false"), ("_podSearchEpisodes", '"results"', "true")):
        body = _function_body(engine, fn)
        assert "PodcastLogic.directoryAnswer(xhr.status, xhr.responseText, %s)" % field in body, fn
        assert "_podSearchSettle(seq, res !== null, %s)" % eps in body, fn + " no longer says whether it was heard"
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    for flag in ("podcastSearchUnreached", "podcastEpSearchUnreached"):
        assert "readonly property alias %s: podcastEngine.%s" % (flag, flag) in main
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    shows = full[full.index('i18n("No shows found")') - 700: full.index('i18n("No shows found")') + 900]
    assert 'root.podcastSearchUnreached\n                                  ? i18n("The podcast directories could not be reached")' in shows
    eps = full[full.index('i18n("No episodes found")') - 700: full.index('i18n("No episodes found")') + 900]
    assert 'root.podcastEpSearchUnreached ? i18n("The episode directory could not be reached")' in eps
    for block, flag in ((shows, "podcastPage.searching && root.podcastSearchUnreached"),
                        (eps, "root.podcastEpSearchUnreached")):
        at = block.index('text: i18n("Try again")')
        button = block[block.rindex("PlasmaComponents3.Button {", 0, at): block.index("}", at)]
        assert "visible: %s" % flag in button
        assert "onClicked: root.podcastSearch(podSearchField.text)" in button


def test_a_genre_word_is_asked_of_the_tags_and_only_its_namesakes_lead():
    """"rock" in the All mode filled the page from station names alone: the
    name answer has 50 rows, the tag pass only ran with room left, and 17 of
    the 30 biggest rock-tagged stations were never shown while "Show more"
    paged more names (measured 2026-09-21). SearchLogic.leadRows decides what
    of the name answer may lead; this pins that the search asks it, that the
    rows it held back return only after the tag list's position was read, and
    that "Show more" pages the tag list from that position."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "runWebSearch"))
    assert 'const lead = (mode === "all" && cc === "") ? SearchLogic.leadRows(q) : null' in body, (
        "a genre word is asked of the station names alone again")
    assert "_webAppendResults(xhr, lead || own)" in body, "the name answer is no longer filtered to its leads"
    tag = body[body.index("_webAppendResults(xhr2)"):]
    at = tag.index("var tagPage = SearchLogic.pageAfter(tagQs + tail, 0, tagRows, ")
    back = tag.index("if (lead && _webAppendResults(xhr)) _webMark(0)")
    page = tag.index("_webMark(0, tagQs + tail, tagPage)")
    assert at < back < page, "the tag list's position is read after the name rows came back in"


def test_the_word_pass_asks_for_the_listeners_own_word():
    """"nova radio" asked the directory for "radio", its longest word, and
    the 50 most voted names holding "radio" held one Radio Nova; asked for
    "nova" they hold twenty-one (measured 2026-09-21). SearchLogic.askWord
    picks the word; this pins that the word pass asks it and nothing else."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webWordPass"))
    assert "encodeURIComponent(SearchLogic.askWord(q)) + tail" in body, (
        "the word pass no longer asks for the word SearchLogic.askWord picks")
    assert "longestWord" not in body, "the word pass asks for the longest word again"


def test_one_mount_under_http_and_https_is_one_station():
    """The directory files the same mount under both schemes as two rows:
    the twin showed as a second result and a star then saved it as a second
    station. SearchLogic.urlKey folds them; this pins every side of the
    search's dedup and the star's known-station check to that one key.
    _code_only cuts a line at "//", which is also the end of the scheme
    regex, so the key lookups stand ahead of the regex on their line."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webAppendResults"))
    for needle in ("seen[SearchLogic.urlKey(webResultsModel.get(j).url)] = true",
                   "if (seenRaw) seen[SearchLogic.urlKey(seenRaw)] = true",
                   "if (!u || seen[uKey] || SearchLogic.knownStation(saved, r, named) ||",
                   "if (rawU && seen[rawKey]) continue",
                   "seen[uKey] = true",
                   "if (rawU) seen[rawKey] = true"):
        assert needle in body, "the search dedup lost a side of its key: " + needle
    assert not re.search(r"\b(existing|seen)\[(u|rawU|seenRaw)\]", body), (
        "a search dedup map is read or written by the exact address again")


def test_a_saved_station_is_known_the_same_way_on_every_road():
    """Of the twenty default stations four came back under "From the web"
    beside their saved selves (measured 2026-11-10): the popup compared the
    saved address alone and the directory had moved the record to another of
    the broadcaster's servers under the same uuid, so a star saved a twin.
    The settings page compared the uuid, the star compared the exact address.
    SearchLogic.knownStationAt is the one answer (tst_searchlogic holds it);
    this pins that the popup's results and the star ask it; the settings page
    is held by test_the_settings_search_knows_a_station_by_any_address_it_has."""
    popup = _code_only(_function_body(
        (UI / "FullRepresentation.qml").read_text(encoding="utf-8"), "_webAppendResults"))
    assert "saved.push(stationsModel.get(i))" in popup
    assert "SearchLogic.knownStation(saved, r, named)" in popup
    star = _code_only(_function_body(
        (UI / "main.qml").read_text(encoding="utf-8"), "addStationToList"))
    assert ('SearchLogic.knownStationAt(servers, { "url_resolved": url, "stationuuid": rbUuid })'
            in star), "the star no longer knows a station by its directory uuid"
    assert '(servers[i].hostname || "") === url' not in star
    assert "keepPlaying && h === held" in star, (
        "a preview handed to a row known by its uuid looks for the row at the preview's address")



def test_the_bitrate_chip_orders_the_page_by_the_honest_number():
    """order=bitrate sorts the directory's raw field, kbps and bps mixed: a
    64000 row led name=rock. SearchLogic.pageOrder tidies the rows a page will
    show; this pins that every answer goes through it with the query that was
    really sent (the chip's own state would re-sort "Popular in ..."), that the
    unit rule lives in one place, and that the name float stands back."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webAppendResults"))
    assert ("SearchLogic.pageOrder(JSON.parse(xhr.responseText) || [], "
            "fullRepresentation._webLastQs,") in body, "an answer is walked in the directory's raw order"
    assert "fullRepresentation.webResultCap - webResultsModel.count)" in body, (
        "the page's room no longer bounds what is reordered, and Show more would skip rows")
    assert '"bitrate": SearchLogic.kbps(r.bitrate),' in body
    assert not re.search(r">=\s*8000", _code_only(src)), (
        "FullRepresentation.qml reads the bitrate's unit on its own again")
    run = _code_only(_function_body(src, "runWebSearch"))
    assert 'cc === "" && !SearchLogic.asksBitrate(tail))' in run, (
        "the exact-name float reorders a list asked by bitrate")
    chain = _code_only(_function_body(src, "_webStemChain"))
    assert 'if (cc === "" && !SearchLogic.asksBitrate(tail)) _webBoostRelevance(stem)' in chain


def test_every_pass_of_a_bitrate_search_lands_in_one_order():
    """One search fills the list from several answers (name, tag, word pass,
    stem, Show more), and each went in under the last, so "nova radio" under
    Bitrate read as two sorted lists. They all come through _webAppendResults;
    this pins that the whole list is sorted there once the walk is done, on
    the query really sent, by the sound rate of the directory's own row."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "_webAppendResults"))
    assert '"rate": SearchLogic.soundRate(r),' in body, "the rows carry no sort key of their own"
    sort = ("if (SearchLogic.asksBitrate(fullRepresentation._webLastQs)) "
            "SearchLogic.rateSort(webResultsModel)")
    assert sort in body, "the passes of a bitrate search are shown as blocks again"
    at = body.index(sort)
    assert body.index("for (const r of results)") < at < body.index("return true"), (
        "the list is sorted before the answer's rows are in it")


def test_a_hidden_rail_hands_the_search_no_fence():
    """The country chip and its x live on the discovery rail, and Appearance
    can switch the rail off. SearchLogic.scopeFor decides what fences a run;
    this pins that the search tells it whether the rail is there."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    run = _code_only(_function_body(src, "runWebSearch"))
    assert "const scopeCc = SearchLogic.scopeFor({" in run
    assert "railShown: Plasmoid.configuration.showDiscoveryRow !== false })" in run, (
        "a hidden rail's pinned country fences the search again")
    assert "pinnedCc: fullRepresentation.webScopeCc," in run
    assert '? fullRepresentation.webScopeCc : "")' not in run, (
        "the pinned scope is read past SearchLogic.scopeFor")


def test_the_rails_bring_their_answer_into_sight():
    """Trending now and Popular in X run with the field empty, so the answer
    goes in under every saved station, below the fold (2026-09-23: seven
    seconds after the tap the screen still showed only the saved list).
    ViewLogic.revealFooter is tested on a real ListView; this pins that both
    rails call it at the tap and again once the answer is in, and that a typed
    search, which filters the saved list itself, leaves the view alone."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    call = "ViewLogic.revealFooter(stationView)"
    for rail in ("runWebTrending", "runWebCountry"):
        body = _code_only(_function_body(src, rail))
        assert body.count(call) == 2, rail + " no longer brings its answer into sight"
        tap, answer = body.index(call), body.rindex(call)
        assert tap < body.index("root._rbFetch(qs, 4000"), rail + " shows nothing until the answer"
        assert body.index("fullRepresentation.webSearching = false", tap) < answer, (
            rail + " scrolls before the answer is in the list")
    for road in ("runWebSearch", "_webWordPass", "_webStemChain", "loadMoreWeb"):
        assert call not in _function_body(src, road), road + " moves the view under the listener"


def test_the_empty_list_asks_the_tested_rule_what_to_say():
    """The favourites view said "No favorite stations yet, tap the star"
    whenever it was empty: to a listener with favourites whose search had
    matched none of them, and when the directory could not be reached. Three
    bindings each asked root.favoritesOnly first. They ask one answer now,
    ViewLogic.emptyList under tst_viewrules, which says so only when nothing
    is typed and nothing is starred."""
    code = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = code.index("id: emptyList")
    blk = code[at:code.index("id: nowPlayingFlick", at)]
    assert re.search(r"readonly property string kind: ViewLogic\.emptyList\(root\.favoritesOnly, "
                     r"root\.favoriteNames\.length,\s*root\.searchFilter, "
                     r"fullRepresentation\.webSearchFailed\)", blk), (
        "the empty list no longer asks the tested rule, or asks it without "
        "the favourites, the search or the directory's answer")
    assert "root.favoritesOnly" not in blk.replace("ViewLogic.emptyList(root.favoritesOnly", ""), (
        "a line of the empty list decides by the favourites view alone again")
    for kind, words in (("favorites", "No favorite stations yet"),
                        ("unreachable", "The station directory is not reachable"),
                        ("nomatch", "No matching stations"),
                        ("favorites", "Tap the star on a station to add it here"),
                        ("unreachable", "Check the connection and type to search again"),
                        ("nomatch", "Try a different search term")):
        assert 'emptyList.kind === "%s" ? i18n("%s")' % (kind, words) in blk, (
            "the empty list says %r for something other than %r" % (words, kind))


def test_the_favourites_hint_names_the_star_it_means():
    """Every favourite toggle is a star (favorite and non-starred-symbolic;
    Breeze draws "favorite" as a star too), and the empty favourites view told
    the listener to tap a heart. The heart the widget has likes a song (the
    Playing tab, the Liked list), so only this hint is held to the star: a
    sentence about liking songs may say heart. The hint stays translated in
    every catalogue."""
    code = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    empty = code[code.index('i18n("No favorite stations yet")'):]
    shown = re.search(r'text:\s*emptyList\.kind === "favorites"\s*\?\s*i18n\("((?:[^"\\]|\\.)*)"\)', empty)
    assert shown, "the empty favourites view lost its hint line"
    assert "heart" not in shown.group(1).lower(), "the favourites hint asks for a heart: %r" % shown.group(1)
    assert "star" in shown.group(1).lower(), "the favourites hint does not name the star: %r" % shown.group(1)
    hint = 'msgid "Tap the star on a station to add it here"'
    for po in sorted((ROOT / "po").glob("*.po")):
        block = next((b for b in po.read_text(encoding="utf-8").split("\n\n") if hint in b), "")
        assert block, po.name + " lost the favourites hint"
        assert not re.search(r"^#,.*\bfuzzy\b", block, re.MULTILINE), po.name + " ships the hint fuzzy"
        assert re.search(r'^msgstr "[^"]+', block, re.MULTILINE), po.name + " ships the hint in English"


def test_the_retry_count_the_release_notes_point_at_has_a_control():
    """2026.38's notes told people to set autoRetryKnocks to 0 "in the widget's
    configuration", and the setting had no control anywhere: the entry sat in
    main.xml and only the code read it."""
    page = _code_only((UI / "config" / "configAutomation.qml").read_text(encoding="utf-8"))
    assert "property alias cfg_autoRetryKnocks: autoRetryKnocks.value" in page
    assert "id: autoRetryKnocks" in page and "enabled: autoRetryCheck.checked" in page
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    assert 'name="autoRetryKnocks"' in xml


def test_the_retry_count_keeps_one_width_whatever_it_says():
    """The Tries box was as wide as its own text: 148 px at "Until it answers"
    and 120 px at "1" on the bench, so the arrows moved out from under the
    pointer and six of seven clicks on "up" went into the text field. It is
    sized by a hidden twin that always shows the widest value, which works in
    any style (Fusion keeps a fixed width anyway, Basic and the KDE style do
    not), so the gate's own style could never show the bug in a UI test."""
    page = _code_only((UI / "config" / "configAutomation.qml").read_text(encoding="utf-8"))
    at = page.index("id: autoRetryKnocks")
    box = page[at: page.index("QQC2.CheckBox", at)]
    assert "Layout.preferredWidth: Math.max(implicitWidth, triesWidest.implicitWidth)" in box, (
        "the Tries box is sized by its current text again")
    tw = page.index("id: triesWidest")
    twin = page[tw: page.index("}", tw)]
    for needle in ("visible: false", "from: autoRetryKnocks.from", "to: autoRetryKnocks.to",
                   "value: 0", "return autoRetryKnocks.textFromValue(v, locale)"):
        assert needle in twin, "the measuring twin lost " + needle


def test_the_output_menu_offers_the_sync_caretaker_once_and_never_by_ear():
    """The same setting stood in the output menu twice under two names, both
    visible while the group was up, and the upper one could be ticked while
    tuning by ear, where the engine ignores it: the config said yes and
    nothing happened. The upper box now stands in only while the group is
    down, and neither is offered by ear."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = src.index('text: i18n("Keep it in tune by itself")')
    upper = re.sub(r"\s+", " ", src[at:src.index("checked:", at)])
    for needle in ("Plasmoid.configuration.syncManualOnly !== true",
                   "!root.sync._combineWantActive",
                   "!(root.sync._combineIdleParked && Plasmoid.configuration.combineWanted === true)"):
        assert needle in upper, "the upper caretaker box lost: " + needle
    low = src.rindex("visible:", 0, src.index('text: i18n("Keep sync tuned automatically")'))
    lower = re.sub(r"\s+", " ", src[low:low + 400])
    assert "Plasmoid.configuration.syncManualOnly !== true" in lower


def test_without_a_cast_bridge_the_network_section_says_nothing():
    """With no cast bridge discovery never runs, and the menu still showed the
    "WiFi & network" heading over "No devices found on your network": a
    verdict about a search that was never made."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = src.index('text: i18n("No devices found on your network")')
    assert "root._castAvailable &&" in src[src.rindex("visible:", 0, at):at]
    head = src.index('text: i18n("WiFi & network")')
    assert "visible: root._castAvailable" in src[src.rindex("RowLayout {", 0, head):head]


def test_a_shared_hosts_own_icon_is_nobodys_logo():
    """Once a name that means several stations lends no logo, such a row falls
    through to the settings page's host and icon-service rungs, and on a
    shared streaming host those answer with the LANDLORD's icon: a tenant of
    zeno.fm would be saved with zeno.fm's favicon."""
    src = (UI / "config" / "configGeneral.qml").read_text(encoding="utf-8")
    for fn in ("_hostnameStdCandidates", "_googleFaviconCandidates"):
        assert "HealLogic.sharedBase(" in _code_only(_function_body(src, fn)), (
            fn + " offers a shared host's own icon again")


def test_a_directory_nobody_reached_is_not_a_dead_station():
    """Every mirror down handed the callbacks null, and both rungs read that
    as "the directory knows nothing": the listener was told the station is
    off the air and the ten-minute lookup lock was taken on the strength of
    a question nobody heard. With the default three knocks (30 + 60 + 120 s,
    all inside the lock) a play pressed before the Wi-Fi was up bounced off
    the lock every time and the order ended with the new address one
    question away. HealLogic.unheard and lockHolds hold the decisions
    (tst_heallogic); this holds the wires.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    heal = _code_only(_function_body(src, "_tryHealStation"))
    assert "HealLogic.lockHolds(_healTried[orig], now)" in heal, (
        "the lookup lock is judged by hand again")
    assert "_healTried[orig] = now;" not in heal, (
        "the lock is taken before anyone answered again")
    assert "_healTried[orig] = Date.now();" in heal, (
        "an answer from the directory no longer takes the lock")
    assert ("HealLogic.uuidRung(uxhr, orig, root._alarmStandingOrder === true,\n"
            "                                              FaviconLogic.webUrlOrEmpty)" in heal), (
        "the identity rung reads the answer by hand, or forgot the wake-up's single door")
    name = _code_only(_function_body(src, "_healNameSearch"))
    assert "run.answered = true; _healTried[run.orig] = Date.now();" in name, (
        "an answered name search no longer marks itself heard")
    adv = _code_only(_function_body(src, "_healAdvance"))
    assert "HealLogic.unheard(run.answered, root._healRetryAttempts," in adv
    assert 'if (deaf.say)' in adv and "_healTried[run.orig] = deaf.stamp;" in adv
    assert (adv.index("HealLogic.unheard(") < adv.index('i18n("Station seems to be off the air")')), (
        "the off-the-air word is spoken before anyone asks whether the directory answered")
    # The stamp is no longer a plain moment: it can be zero or negative, and
    # only HealLogic may read it as time. A leftover "now - stamp" elsewhere
    # would read a telling-mark as ten hours ago and let the lock through.
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    for m in re.finditer(r"_healTried\[[^\]]*\]", code):
        near = re.sub(r"\s+", " ", code[max(0, m.start() - 160):code.find("\n", m.end())])
        assert ("HealLogic.lockHolds(" in near or "HealLogic.unheard(" in near
                or "delete _healTried[" in near
                or re.search(r"_healTried\[[^\]]*\] = (Date\.now\(\)|deaf\.stamp);", near)), (
            "the lookup stamp is read as a plain moment again: " + near[-90:])


def test_the_alarms_tone_box_keeps_the_whole_sentence():
    """In the control column the label was wider than the column and the
    sentence was cut mid-word ("...the built-in tone (no"). It spans both
    columns instead; there is no spacer in front of it any more."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = src.index("id: alarmToneOnly")
    assert "Layout.columnSpan: 2" in src[at:at + 200]
    assert "Item { width: 1; height: 1 }" not in src[src.rindex("QQC2.CheckBox", 0, at) - 400:at]


def test_a_stop_says_which_road_asked_for_it():
    """A radio found quiet in the morning left no trace of why: the stream had
    not died (no heal line), the speaker had not left (no Bluetooth line), and
    nothing wrote down who asked. Fifteen roads call stopWithFade; the stack's
    second frame names the one that did."""
    body = _code_only(_function_body((UI / "main.qml").read_text(encoding="utf-8"), "stopWithFade"))
    assert 'console.log("[ARP] stop: " + String((new Error()).stack || "").split("\\n")[1]);' in body, (
        "a stop no longer names the road that asked for it")
    assert body.index("[ARP] stop:") < body.index("_stampPodPosition()"), (
        "the line is written after the stop has already begun")


def test_every_command_from_outside_names_its_caller():
    """A speaker can send a pause of its own (a JBL Flip 7 did, three times on
    2026-09-20, through the media-key service), and a listener's keypress
    arrives by the same road. Without the sender, a radio that stopped by
    itself and one that was told to read exactly alike in the log."""
    src = (UI / "mpris.py").read_text(encoding="utf-8")
    for name in ("Play", "Pause", "PlayPause", "Stop", "Next", "Previous"):
        at = src.index("    def %s(self" % name)
        head = src[src.rindex("@dbus.service.method", 0, at):at]
        assert 'sender_keyword="sender"' in head, name + "() no longer learns who called it"
        body = src[at:src.index("\n    @", at)]
        assert "self._who(sender)" in body, name + "() no longer names its caller"
    assert "GetConnectionUnixProcessID" in src, "the caller is no longer resolved to a process"


def test_a_command_older_than_ten_seconds_is_never_obeyed():
    """The command file outlives the session that wrote it. A crash leaves the
    last line in place, and the widget's only guard was "a number I have not
    seen" — after a restart it has seen none, so a Stop from yesterday counted
    as new. The number is a moment (mpris.py next_seq, tested there), and an
    old moment is refused however new it looks. The filter lives in
    MprisCommandGate.qml, and the reader must not walk around it."""
    gate = _code_only((UI / "MprisCommandGate.qml").read_text(encoding="utf-8"))
    assert "if (isNaN(seq) || seq <= lastSeq || nowMs - seq > 10000) continue;" in gate, (
        "a stale command can be obeyed again")
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert "mprisCmdGate.take(stdout, Date.now(), _handleMprisCommand);" in code, (
        "the command reader no longer goes through the gate")


def test_the_widget_starts_its_bridge_asking_for_moments():
    """mpris.py counts 1, 2, 3 unless --ms-seq is on its command line. That
    keeps a 2026.39 widget whole when it starts the new file from disk (it
    runs until the next plasmashell start and keeps the number in an int).
    This widget's gate reads the number as a moment, so its one start road
    has to ask for moments, and the launcher has to hand the flag on."""
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    start = _function_body(code, "_mprisStart")
    assert "executable.exec(mprisCmdGate.startLine(" in start, (
        "the bridge is started past the gate's start line")
    assert "MPRIS_START; bash" not in code, "a second bridge start written by hand"
    gate = _code_only((UI / "MprisCommandGate.qml").read_text(encoding="utf-8"))
    assert '" --ms-seq"' in _function_body(gate, "startLine"), (
        "the start line no longer asks for moments")
    launcher = (UI / "start-mpris.sh").read_text(encoding="utf-8")
    assert '"${SEQ_FLAG[@]}" >"$LOG_FILE"' in launcher, (
        "the launcher starts the bridge without the flag it was given")


def test_the_mpris_bridge_is_watched_while_the_widget_wants_one():
    """Nothing supervised the daemon. Killed once — a second widget's launcher
    sweeps stale siblings, and anything can crash — it stayed dead until the
    next playback start: measured on 2026-09-22, the music played on for
    minutes while the bus name was gone, so media keys, the lock screen and
    the speaker's own buttons were quietly dead. The shell that writes the
    state file answers the question for free."""
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    write = code[code.index(': MPRIS_WRITE; sh -c'):]
    write = write[:write.index("\n")]
    assert 'pgrep -f \\"^python3 .*mpris.py $2\\"' in write, (
        "the state write no longer asks whether the daemon is alive, or its pgrep can match its own shell")
    assert "__MPRIS_GONE__" in write
    at = code.index('cmd.indexOf(": MPRIS_WRITE;")')
    branch = code[at:code.index('cmd.indexOf(": MPRIS_START;")', at)]
    for needle in ("__MPRIS_GONE__", "_mprisStarted", "Date.now() - _mprisRevivedAt > 60000",
                   "_mprisStarted = false;", "_mprisStart();"):
        assert needle in branch, "the revive lost: " + needle


def test_a_bare_play_is_answered_in_one_place_that_knows_about_auditions():
    """Play with nothing named: the Playing tab's button, Space, the panel's
    middle click, MPRIS Play and PlayPause. Each carried its own copy of
    "lastPlay, else row 0", and an audition leaves lastPlay at -1, so on the
    bench (2026-09-23) a stopped Radio Swiss Jazz came back as MANGORADIO,
    the first row. The decision is TransportLogic.bareplay now, under
    tst_transportlogic; what is left to hold here is that every road asks it
    and that nothing else does. A recovery road reaching playLast would be a
    radio starting on its own, which is issue #13."""
    main_src = (UI / "main.qml").read_text(encoding="utf-8")
    codes = {p.name: _code_only(p.read_text(encoding="utf-8"))
             for p in sorted(UI.rglob("*.qml"))}
    row_zero = re.compile(r"lastPlay\s*>=\s*0\s*&&\s*lastPlay\s*<\s*stationsModel\.count"
                          r"\s*\?\s*lastPlay\s*:\s*0")
    for name, code in codes.items():
        assert not row_zero.search(code), (
            "%s answers a bare Play with row 0 again, past any audition" % name)
    # The five roads meet in transport() since 2026.44, so playLast has one
    # caller, and the widget's three roads are held to that door at the end
    # of this file.
    calls = {name: code.count("playLast(") - code.count("function playLast(")
             for name, code in codes.items()}
    assert {k: v for k, v in calls.items() if v} == {"main.qml": 1}, (
        "playLast is called from somewhere other than transport(), the door a person's Play comes through: %r" % calls)
    door = _code_only(_function_body(main_src, "transport"))
    assert door.count('else if (act === "bare") playLast();') == 1, "a Play that names nothing lost the shared answer"
    body = _code_only(_function_body(main_src, "playLast"))
    assert ("TransportLogic.bareplay(root._lastAudition !== null, lastPlay, stationsModel.count, "
            "root._pausedFile !== null)") in body
    assert "previewStation(a.name, a.url, a.favicon, a.uuid, a.rawUrl, a.codec, a.bitrate);" in body, (
        "the audition comes back without its codec or bitrate, and an Ogg one wedges on the relay decision")


def test_only_an_audition_is_remembered_and_every_other_start_forgets_it():
    """The memory must mean "an audition was the last thing heard", or the
    precedence it gets in TransportLogic.bareplay turns into a new wrong
    answer: a station picked after the audition and then stopped would come
    back as the audition. previewStation writes it; a station pick drops it
    before its async resolve can fail, and startWithFade drops it for the
    local file, the episode and the alarm, all of which empty _previewUrl
    before they get there."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    assert code.count("_lastAudition = {") == 1, "something other than an audition is remembered as one"
    pv = _code_only(_function_body(src, "previewStation"))
    stop_return = pv.index("stopWithFade();\n            return;")
    at = pv.index("root._lastAudition = {")
    assert at > stop_return, (
        "the audition is remembered before the second tap's stop returns, so the stop re-arms it")
    assert '"rawUrl": rawUrl, "codec": codec, "bitrate": bitrate' in pv[at:]
    rs = _code_only(_function_body(src, "refreshServer"))
    assert "root._lastAudition = null;" in rs, "a station pick leaves the audition standing"
    sw = _code_only(_function_body(src, "startWithFade"))
    assert 'if (root._previewUrl === "") root._lastAudition = null;' in sw, (
        "a local file, an episode or an alarm leaves the audition standing")


def test_the_footer_says_reconnecting_while_the_ladder_waits():
    """Between two knocks of the retry ladder the player sits idle, so the
    footer fell through to its idle sentence: on the bench (2026-09-23) a
    station at a dead address read "Choose a station to start listening" under its own
    name for the whole 30 s before knock #1, which looks like a widget that
    gave up. RetryLogic.betweenKnocks decides, under tst_retrylogic; this pins
    where the footer asks it. The louder states keep their words first:
    offline, the error sentence, a stream that plays or is loading."""
    code = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = code.index("id: subtext")
    text = code[code.index("text: {", at):]
    idle = text.index('return i18n("Choose a station to start listening")')
    text = text[:idle + 50]
    asks = "else if (RetryLogic.betweenKnocks(root._wantsPlaying, root._healRetryAttempts))"
    assert asks in text, "the footer never asks whether the ladder is waiting for its next knock"
    ask = text.index(asks)
    assert 'return i18n("Reconnecting…")' in text[ask:idle], (
        "the footer no longer says the station is being tried again")
    for louder in ('i18n("Check internet connection…")', "root.isError",
                   "fullRepresentation._streamActive", "MediaPlayer.LoadingMedia"):
        assert text.index(louder) < ask, louder + " no longer outranks the wait"


def test_the_history_asks_the_tested_rules_before_it_takes_a_row():
    """The history used to compare a new title with the newest row and
    nothing else. Dance Wave! takes turns between two slogans every 15-20 s,
    so neither ever matched the row above it, and on 2026-09-23 the thirty
    rows were all slogans seven minutes in. The rules (station talk, a repeat
    within ten rows of the same station) live in TrackLogic.historyTakes,
    which tst_tracklogic covers; main.qml cannot be unit-tested, so this pins
    that the one place a row is born asks them first."""
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(code, "_pushHistory")
    ask = body.find("if (!TrackLogic.historyTakes(historyModel, artist, trackName, station)) return;")
    born = body.find("historyModel.insert(")
    assert ask != -1, "_pushHistory no longer asks TrackLogic.historyTakes"
    assert born != -1 and ask < born, "a row is inserted before the rules are asked"
    assert code.count("historyModel.insert(") == 1, (
        "a second road inserts history rows without the rules")


def test_the_rec_counter_on_screen_waits_for_the_file():
    """The REC button, the REC bar and the footer used to read the wall clock
    from the click. On 2026-09-23 a recording's file was born 141 s after the
    click and the counter read 11:50 over 592.6 s of audio. The engine's
    recCounterText says "Connecting…" until the file exists and counts from
    there (tst_recordingengine); the popup cannot be unit-tested, so this pins
    that every counter on it is that one."""
    ui = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    assert "recElapsed" not in ui, "the popup reads the wall clock again"
    shown = re.findall(r'"● REC " \+ ([\w.]+\(\))', ui)
    assert shown == ["root.recCounterText()", "root.recCounterText()"], shown
    tip = ui[ui.index('i18n("Recording %1 — click to stop"') - 200:]
    tip = tip[:tip.index("\n", 200)]
    assert "root.recOnDisk ?" in tip and "root.recCounterText()" in tip, tip


def test_the_about_page_names_yuri_as_the_original_author():
    """Yuri Saurov wrote Advanced Radio Player; he is not a co-author of this
    edition. 2026.1 said so in the Authors list, 2026.2 trimmed both labels
    in a tidy-up, and from then until 2026.40 every Store install showed him
    as a plain second author under "LGPL-2.0+". The home machine's install
    kept the hand-set labels, which is how the difference was spotted on
    2026-09-29. The license string is the SPDX one the file headers use."""
    meta = json.loads((ROOT / "package" / "metadata.json").read_text(encoding="utf-8"))
    kp = meta["KPlugin"]
    names = [a["Name"] for a in kp["Authors"]]
    assert len(names) == 2, names
    assert names[0].startswith("Egon Greenberg (2026 edition"), names[0]
    assert names[1] == "Yuri Saurov (original: Advanced Radio Player)", names[1]
    assert kp["License"] == "LGPL-2.0-or-later", kp["License"]


def _owner_of(src: str, i: int) -> tuple[str, int]:
    """The nearest function or timer id opening before i."""
    best, pos = "", -1
    for rx in (r"function\s+(\w+)\s*\(", r"\bid:\s*(\w+)"):
        for m in re.finditer(rx, src[:i]):
            if m.start() > pos:
                pos, best = m.start(), m.group(1)
    return best, pos


def _owner_span(src: str, pos: int) -> str:
    """From an owner's opening to the next function or timer id."""
    nxt = [m.start() for rx in (r"function\s+\w+\s*\(", r"\bid:\s*\w+")
           for m in re.finditer(rx, src[pos + 1:])]
    return src[pos:pos + 1 + min(nxt)] if nxt else src[pos:]


# One door per road each automatic owner can take: handleExec both goes live
# after a writer died at birth and re-arms after one that lived. Counted,
# because a second door in the same owner hid a missing first one.


_DOORS = {
    "_playStation": 1, "_healAdvance": 1, "stallTimer": 1, "bitrateFallbackTimer": 1,
    "relayPlaybackFell": 1, "handleExec": 2, "_slideFell": 1,
}


def _sound_calls(src: str, pattern: str) -> list[tuple[str, int, int]]:
    out = []
    for m in re.finditer(pattern, src):
        line = src[src.rfind("\n", 0, m.start()) + 1:src.find("\n", m.start())].strip()
        if line.startswith("function"):
            continue
        name, pos = _owner_of(src, m.start())
        out.append((name, pos, m.start()))
    return out


# Every place in main.qml that can start sound, by the function or timer that
# owns it. "asks" means the owner consults _orderLapsed() before the call.


_MAIN_SOUND = {
    "startWithFade": "the sink itself",
    "tsPlayBuffer": "the local capture, played on for a shifted listen",
    "tsPlayRelay": "the engine's UP ack; its re-arms ask before arming",
    "transport": "a person's media key, or the widget's own button, Space or middle click",
    "playLocalFile": "a person's file",
    "tsPlayLive": "a person's Back to live; the engine's fallback asks first",
    "timeshiftResume": "a person's resume",
    "_previewRetryByIdentity": "a preview is nobody's standing order",
    "_previewRescueAudition": "a preview is nobody's standing order",
    "_playStation": "asks",
    "_healAdvance": "asks",
    "stallTimer": "asks",
    "bitrateFallbackTimer": "asks",
    "relayRescue": "a start-time rescue six seconds after a start that asked",
}

# The doors themselves, word for word: a door that is present but can never
# refuse ("&& false", "automated === false") passed a count and a presence check.


_DOOR_LINES = {
    "_tryHealStation": "if (_orderLapsed()) return;",
    "_healAdvance": "if (_orderLapsed()) return;",
    "_playStation": "if (automated === true && (!root._wantsPlaying || _orderLapsed())) return;",
    "stallTimer": "if (root._tsPaused || root._pausedFile !== null || _orderLapsed()) return;",
    "bitrateFallbackTimer": 'if (!fallbackUrl || root._tsPaused || _orderLapsed()) { fallbackUrl = ""; return; }',
}


_ENGINE_DOOR_LINES = {
    "relayPlaybackFell": "if (app._orderLapsed()) return true;",
    "handleExec": "!app._tsPaused && (app.isPlaying() || onTap) && !app._orderLapsed())",
    "_slideFell": 'if (live !== "" && !app._orderLapsed()) app.tsPlayLive(live);',
}

# Who hands _playStation a station, and how the order is dated on that road.


_PLAY_STATION = {
    "refreshServer": "a person's press is dated; the ladder's replay says automated",
    "previewStation": "a preview is nobody's standing order",
    "_castResumeLocally": "a person coming home from a cast, dated first",
    "_replayOrder": "automated",
}

_ENGINE_SOUND = {
    "relayPlaybackFell": "asks",
    "backToLive": "a person's Live, or a shifted listen reaching the live edge",
    "playerEndOfMedia": "a shifted listen; the park before it dropped the order",
    "handleExec": "asks",
    # 2026.44: a list of the sliding buffer failed under a listener, or on a
    # person's Play or step; the broadcast takes over and the single file.
    "_slideFell": "asks",
}


def test_every_automatic_road_to_sound_asks_whether_the_order_lapsed():
    """2026.40 dated the order right and then asked only at the ladder's
    replay. Measured by reading on 2026-09-29: a death first noticed in the
    morning went through the heal lookup, the bitrate fallback or the relay's
    re-arm, none of which asked, and last night's station played. This pins
    who may start sound and that every automatic owner asks first — a new
    play() anywhere fails here until someone decides which kind it is."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    calls = _sound_calls(src, r"playMusic\.play\(\)|\bstartWithFade\(|timeshift\.armRelay\(")
    assert {c[0] for c in calls} == set(_MAIN_SOUND), (
        "the owners of sound in main.qml changed: %s" % sorted({c[0] for c in calls}))
    for name, pos, at in calls:
        if _MAIN_SOUND[name] == "asks":
            assert "_orderLapsed()" in src[pos:at], (
                "%s starts sound without asking whether the order lapsed" % name)
            assert _owner_span(src, pos).count("_orderLapsed()") == _DOORS[name], (
                "%s asks a different number of times than it has roads" % name)
    calls = _sound_calls(src, r"\b_playStation\(")
    assert {c[0] for c in calls} == set(_PLAY_STATION), (
        "the roads into _playStation changed: %s" % sorted({c[0] for c in calls}))
    assert "_orderDated();" in _function_body(src, "_castResumeLocally"), (
        "coming home from a cast leaves the order dated by its start")
    assert "false, true);" in _function_body(src, "_replayOrder"), (
        "the ladder's orphan replay no longer says it is automated")
    for name, line in _DOOR_LINES.items():
        opening = re.search(r"function\s+%s\s*\(|\bid:\s*%s\b" % (name, name), src)
        assert opening, name
        assert line in _owner_span(src, opening.start()), "%s's door is not %r" % (name, line)
    heal = _function_body(src, "_tryHealStation")
    assert "_orderLapsed()" in heal[:heal.index("_healArmRetry")], (
        "the heal lookup starts before asking whether the order lapsed")

    eng = _code_only((UI / "TimeshiftEngine.qml").read_text(encoding="utf-8"))
    calls = _sound_calls(eng, r"\barmRelay\(|app\.tsPlayLive\(")
    assert {c[0] for c in calls} == set(_ENGINE_SOUND), (
        "the owners of sound in the engine changed: %s" % sorted({c[0] for c in calls}))
    for name, pos, at in calls:
        if _ENGINE_SOUND[name] == "asks":
            assert "app._orderLapsed()" in eng[pos:at], (
                "the engine's %s re-arms or goes live without asking" % name)
            assert _owner_span(eng, pos).count("app._orderLapsed()") == _DOORS[name], (
                "the engine's %s asks a different number of times than it has roads" % name)
            assert _ENGINE_DOOR_LINES[name] in _owner_span(eng, pos), (
                "the engine's %s door is not %r" % (name, _ENGINE_DOOR_LINES[name]))
    assert "_relayRestarts < 3 && !app._orderLapsed()) {" in eng, (
        "the capped writer's quiet re-arm no longer asks")


def test_the_order_lapsing_is_torn_down_like_a_stop():
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    door = _function_body(src, "_orderLapsed")
    assert "RetryLogic.orderLapsed(root._wantsPlaying" in door, door
    assert "_alarmStandingOrder" in door, "the door does not hand an alarm through"
    assert "Qt.callLater(function() { if (!root._wantsPlaying) stopWithFade(); });" in door, (
        "a lapsed order is refused without being torn down, or torn down even "
        "after an alarm raised it again; two askers sit in the engine's own "
        "handlers, so the teardown has to come after them")


def test_a_person_giving_the_order_dates_it_afresh():
    """Stamps left from an order a person already set down must not age the
    next one: a click after waking, with last night's order still standing,
    would otherwise be judged lapsed at its first hiccup. A stop clears the
    quiet stamp too, or a Play hours later can be dropped the same way."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    refresh = _function_body(src, "refreshServer")
    assert "if (userInitiated !== false) _orderDated();" in refresh, (
        "a person's press does not date the order it gives")
    dated = src[src.index("function _orderDated()"):]
    dated = dated[:dated.index("}")]
    assert "_orderQuietSince = 0" in dated and "_orderHeardAt = Date.now()" in dated, (
        "a dated order keeps an old quiet stamp or is left with no age at all")
    given = _function_body(src, "_orderGiven")
    assert "if (!root._wantsPlaying) _orderDated();" in given, given
    live = _function_body(src, "timeshiftBackToLive")
    given_live = 'if (timeshift.shifted && !root._tsPaused && root._previewUrl === "") _orderGiven();'
    assert given_live in live and live.index(given_live) < live.index("timeshift.backToLive("), (
        "a person's Live leaves the order down on the relay road, and no door "
        "guards a relayed station through the night")
    for fn in ("tsPlayLive", "timeshiftResume"):
        assert "_orderGiven()" in _function_body(src, fn), (
            "%s re-issues the order without dating it" % fn)
        assert "_wantsPlaying = true" not in _function_body(src, fn), fn
    assert "_orderQuietSince = 0" in _function_body(src, "stopWithFade"), (
        "a stop leaves the quiet stamp behind for the next order")


def test_no_plasma_combo_box_while_its_width_loops():
    """libplasma 6.8 binds the ComboBox's implicitWidth to its own text
    field, and every instance with a model reports a binding loop: a bare one
    in a ColumnLayout did it on 6.8.2 (2026-11-02), and overriding
    implicitWidth only moved the loop to implicitHeight. The public nightly
    went red the day Arch shipped 6.8.0 (2026-10-16; 10-15 was green on
    6.7.5). The runtime check sees the popup only, never the settings pages,
    so the rule is held over the whole package. QQC2.ComboBox has no loop."""
    hits = []
    for path in sorted((ROOT / "package").rglob("*.qml")):
        src = _code_only(path.read_text(encoding="utf-8"))
        aliases = re.findall(r"^import org\.kde\.plasma\.components as (\w+)", src, re.M)
        for alias in aliases:
            for m in re.finditer(r"\b%s\.ComboBox\b" % re.escape(alias), src):
                hits.append("%s:%d" % (path.relative_to(ROOT), src.count("\n", 0, m.start()) + 1))
    assert not hits, hits


def test_station_hosts_are_asked_with_the_widgets_own_name():
    """Qt's request carries "Mozilla/5.0" unless told otherwise, and some
    stream hosts refuse exactly that: SomaFM's ice servers answered 403 to it
    and 206 to OnAir, Lavf and VLC alike, and a zeno.fm mount answered 401
    (2026-11-02, 65 saved addresses scored against ffprobe; the three named
    clients agreed on every one). The search's liveness probe then dimmed a
    station that plays as "not answering" and sank it, and the playlist
    unwrap asks the same hosts. Both go out under the widget's name, as the
    directory requests already do."""
    # Raw source: _code_only cuts "//" inside the unwrap's own URL regex and
    # the body ends after its first line. A comment cannot pass the line test.
    fr = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    main = (UI / "main.qml").read_text(encoding="utf-8")
    for src, fn in ((fr, "_probeOne"), (main, "_unwrapPlaylist")):
        body = _function_body(src, fn)
        assert re.search(r'^\s*xhr\.setRequestHeader\("User-Agent", "OnAir/', body, re.M), (
            "%s asks a station host as Mozilla/5.0" % fn)


def test_a_playlist_on_the_home_server_is_unwrapped():
    """A station saved as http://192.168.x.x:8000/raadio.m3u was handed to the
    player as the playlist itself and never played. The unwrap judged only
    where the answer came from, to keep a public wrapper from redirecting into
    the LAN, and an answer from the home server it had just asked failed the
    same test. It now tells HostGuard which address it asked; the verdicts are
    tst_hostguard's (answerPublicOrAsked)."""
    # Raw source for the same reason as above.
    body = _function_body((UI / "main.qml").read_text(encoding="utf-8"), "_unwrapPlaylist")
    assert re.search(r"^\s*if \(!HostGuard\.answerPublicOrAsked\(url, xhr\)\) \{ cb\(url\); return; \}$",
                     body, re.M), (
        "the unwrap judges an answer without the address it asked: a playlist "
        "on the listener's own server is refused as a redirect into the LAN")
    assert "answerFromPublicHost" not in body


def test_every_station_row_enters_a_model_through_normalize():
    """A ListModel locks a role's shape to the first row it is given, and
    the settings pages write the model back as the stored list. A row that
    went in without prev could take it out of every row after it on the next
    save, so every road into a station model goes through
    DoorLogic.normalize, and both sides of the settings merge compare the
    same shape (a row read as edited is a row whose heal gets refused)."""
    for name in ("main.qml", "config/configGeneral.qml", "config/configSearch.qml"):
        src = _code_only((UI / name).read_text(encoding="utf-8"))
        calls = re.findall(r"stationsModel\.append\(\s*([^\n]*)", src)
        assert calls, name
        for call in calls:
            assert call.startswith("DoorLogic.normalize("), "%s: %s" % (name, call)
    for name in ("config/configGeneral.qml", "config/configSearch.qml"):
        src = _code_only((UI / name).read_text(encoding="utf-8"))
        norms = re.findall(r"const norm = \(o\) => \{\n\s*var plain = ([^\n]*)", src)
        assert norms, "%s has no merge norm" % name
        for plain in norms:
            assert plain.startswith("DoorLogic.normalize("), "%s: %s" % (name, plain)






def test_the_edit_dialog_writes_only_what_was_changed_in_it():
    """The popup writes the station list while the Edit dialog is open (a
    heal's move, a logo found), and an OK wrote the dialog's snapshot back
    over it: a rename put a healed station back on its dead address and lost
    the logo (found 2026-11-02). The row is found again by the address the
    dialog opened on, and only the fields changed in it are written; the
    rules are DoorLogic's, under tst_doorlogic."""
    src = _code_only((UI / "config" / "configGeneral.qml").read_text(encoding="utf-8"))
    assert "_editOpened = {" in _function_body(src, "editServer"), "the dialog forgets what it opened with"
    i = src.index("id: serverDialog")
    ok = src[src.index("onAccepted: {", i):]
    ok = ok[:ok.index("_edited();")]
    assert "DoorLogic.editRowIndex(rows, dialogMode, _editOpened)" in ok
    assert "DoorLogic.editedRow(rows[rowAt], _editOpened, shown, clean)" in ok
    assert "in existing)" not in ok, "the dialog copies its snapshot over the row again"


def test_a_uuid_looked_up_for_a_click_or_a_vote_is_not_saved():
    """_rbResolveUuid finds a station's directory record by its name and the
    address it plays, and used to save that uuid with the station. Neither
    proves which record is the station's: anyone can file a record that
    lists an address, and the heal trusts a saved uuid for good (it asks
    byuuid where the station lives and saves the answer). The uuid now
    serves the click or the vote and is kept for the session only."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_rbResolveUuid")
    assert "Plasmoid.configuration.servers" not in body, "the lookup writes the station list"
    assert "_rbStoreUuid" not in src, "the uuid store is back"
    assert "_uuidResolved[orig] = uuid;" in body, "the session does not keep what it found"


def test_a_play_reads_its_row_before_the_address_is_unwrapped():
    """_playStation is handed the live ListModel row, and a .pls or .m3u is
    unwrapped asynchronously before the play starts. A list write in that
    window (a logo the popup found, a heal) clears and refills the model, and
    the row read after it answers empty: the station played with no name and
    a click on its row started it again instead of stopping it (measured on
    Qt 6.12 with a cleared and refilled model, 2026-11-02). Everything the
    play needs is read from the row before the unwrap."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_playStation")
    after = body[body.index("_unwrapPlaylist(home"):]
    assert "station." not in after, "the play reads the live row after the unwrap"


def test_every_write_that_must_not_stop_playback_writes_something_new():
    """A list write marked as not stopping playback arms _reorderKeepPlaying,
    and the next serversChanged spends it. A write the config skips because
    nothing changed fires no change, so the flag stayed armed and ate the stop
    of the next real add or remove: a click and a vote once raced to save one
    uuid that way, and a heal that "moved" a station onto its own address did
    it again (found 2026-11-03). Every site bails on an unchanged list first."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    lines = src.splitlines()
    sites = [i for i, line in enumerate(lines) if "_reorderKeepPlaying = true;" in line]
    assert len(sites) >= 5, sites
    for i in sites:
        before = "\n".join(lines[max(0, i - 4):i])
        assert "=== Plasmoid.configuration.servers) return" in before, (
            "line %d arms the keep-playing flag without bailing on an unchanged list" % (i + 1))


def test_the_star_and_the_trash_keep_a_file_playing_and_nothing_else():
    """The star's and the trash's write stops the player, and the writer
    starts again what was a row of the list or an audition. A My Music file
    or a podcast episode is neither: it was cut off by a change to a list it
    is not in, and nothing brought it back. Both roads now write through
    _listWrite, which arms the keep-playing flag when
    TransportLogic.listWriteKeepsSound says a file or an episode is what
    sounds (tst_transportlogic), and only then.

    Why that cannot start anything: a file or an episode plays with no
    standing order and a disarmed timeshift engine (playLocalFile clears
    the order, startWithFade's arm refuses a file and disarms for an
    episode), so the teardown the stop branch would have run has nothing
    left to take down. The trash's afterwards returns before it touches
    lastPlay or starts a row, or row 0 would light up as the one playing.
    tst_listwrite stands the write, the change handler and that afterwards
    up around a counting player; this holds main.qml to the same lines.
    """
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    write = _function_body(src, "_listWrite")
    assert "TransportLogic.listWriteKeepsSound(" in write, (
        "the star's and the trash's write decides by itself what keeps playing")
    for fact in ('"audible": isPlaying()', '"preview": root._previewUrl !== ""',
                 '"source": playMusic.source.toString()',
                 '"episode": root._podPlayingKey !== "" ? root._podPlayingUrl : ""',
                 '"tone": root._alarmToneUrl.toString()',
                 '"bufferPath": timeshift.bufPath', '"shifted": timeshift.shifted',
                 '"paused": root._pausedFile !== null'):
        assert fact in write, "the rule is no longer told %s" % fact
    bail = write.index("if (out === Plasmoid.configuration.servers) return false;")
    arm = write.index("if (kept) _reorderKeepPlaying = true;")
    assert bail < arm < write.index("Plasmoid.configuration.servers = out;"), (
        "the flag is armed before the unchanged-list bail or after the write")
    assert write.count("_reorderKeepPlaying") == 1, (
        "the write arms the keep-playing flag on a second road, past the rule")
    assert src.count("_listWrite(") == 4, (
        "something besides the star and the trash writes through _listWrite, "
        "or one of their three writes stopped doing so")
    for road, writes in (("removeStation", 1), ("addStationToList", 2)):
        body = _function_body(src, road)
        assert body.count("_listWrite(servers)") == writes, road
        assert "Plasmoid.configuration.servers =" not in body, (
            "%s writes the list past _listWrite" % road)
        assert "_reorderKeepPlaying" not in body, (
            "%s arms the keep-playing flag itself" % road)
    trash = _function_body(src, "removeStation")
    later = trash[trash.index("Qt.callLater("):]
    kept = later.index("if (kept) return;")
    for after in ("refreshServer(", "lastPlay = 0;", "previewStation("):
        assert kept < later.index(after), (
            "with the sound kept the trash still reaches %s" % after)


def test_a_heal_that_finds_the_saved_address_again_moves_nothing():
    """A directory record whose url is a .pls naming the very address the row
    has unwrapped back to it, and the heal's commit then "moved" the station
    onto itself: a "found at a new address" notice and a write of the same
    list (found 2026-11-03). The saved address answering again is no move."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_healCommit")
    # sameDoor, not addrKey: the key folds http and https into one, and a
    # station that left one for the other was found, played and never saved.
    same = "if (HealLogic.sameDoor(newUrl, oldUrl)) return;"
    assert same in body, "the heal commits the address the row already has"
    assert body.index(same) < body.index("HealLogic.commitVerdict(")
    assert "HealLogic.addrKey(" not in body, (
        "the commit folds the scheme again: a move from https to http is not saved")


def test_one_failure_knocks_on_the_saved_address_before_the_directory_is_asked():
    """The heal used to ask the directory two and a half seconds after any one
    error, and an encoder restarting sent the listener to another mount: for
    a row with a uuid or its own domain, for good. The saved address gets one
    more open first. It is not one of the ladder's knocks, so it comes only
    before the first of them, and only after the switch and the budget had
    their say."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_tryHealStation")
    knock = "if (root._healRetryAttempts === 0 && HealLogic.knockFirst(_healKnocked[orig], now)) {"
    assert knock in body, "a single failure goes straight to the directory again"
    at = body.index(knock)
    assert "_replayOrder();" in body[at:at + 400], "the second knock opens nothing"
    assert body.index("if (!_mayKnock(root._healRetryAttempts)) { _orderSpent(); return; }") < at, (
        "the second knock comes before the switch was asked: a listener who "
        "turned retries off gets one anyway")
    assert at < body.index("_rbFetch("), "the directory is asked before the saved address had its second chance"
    assert at < body.index("_healNameSearch(mySeq)")
    assert "if (!(_healDeadSince[orig] > 0)) _healDeadSince[orig] = now;" in body, (
        "nobody notes when the saved address was first seen down, so no move can ever be proven")


def test_a_heal_is_written_only_over_an_address_that_stayed_dead():
    """Who the station is and whether it moved are two questions. The commit
    answered the first and wrote at the first buffer; a mount that was down
    for a minute lost its row to a sibling for good. The write now waits for
    HealLogic.moveWhen, and the second look five minutes on asks the old
    address itself before anything is saved."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_healCommit")
    gate = 'if (!proven && HealLogic.moveWhen("permanent", _healDeadSince[oldUrl] || 0, Date.now()) !== "now") {'
    assert gate in body, "the heal writes the list at the first buffer again"
    assert body.index(gate) < body.index("Plasmoid.configuration.servers = out;")
    assert body.index(gate) < body.index("alarmEngine.retargetStation("), (
        "an alarm is retargeted before the move is proven")
    wait = body[body.index(gate):body.index(gate) + 600]
    assert "healProofTimer.restart();" in wait and "return;" in wait
    timer = src[src.index("id: healProofTimer"):]
    timer = timer[:timer.index("function _tryHealStation()")]
    assert "kinHunt.proof(m, function(verdict) {" in timer, "the second look does not ask the old address"
    # The answer is the move's own, or nobody's: a Stop and a fresh start of
    # the same station used to pass every other check here.
    assert "if (root._healLater !== m || root._currentOrigUrl !== m.oldUrl" in timer, (
        "an answer asked for one move is taken for whatever plays now")
    again = 'if (verdict === "again") { healProofTimer.interval = HealLogic.DEATH_PROOF_MS; healProofTimer.restart(); return; }'
    keep = 'if (verdict === "keep") {'
    assert again in timer, "an address nobody could vouch for either way is not looked at again"
    assert keep in timer and "return; }" in timer[timer.index(keep):timer.index(keep) + 200]
    assert timer.index(again) < timer.index(keep) < timer.index("root._healCommit();"), (
        "the move is written before the verdict was read")
    assert "aliveAnswer" not in timer, "the timer judges the answer itself again, where no test sees it"
    clear = _function_body(src, "_healClearPending")
    assert "_healLater = null;" in clear and "healProofTimer.stop();" in clear, (
        "a stop or another station leaves a move waiting to be written under it")
    assert ("if (root._healPendingUrl === \"\" && root._healBackupFor === \"\") "
            "delete root._healDeadSince[root._currentOrigUrl];") in src, (
        "a saved address that plays again keeps its old death on the books")


def test_the_kin_rung_runs_before_a_stranger_auditions_and_only_once():
    """The saved mount on another server of its own CDN is the station; a row
    the name search found on some other domain is a guess. So the hunt runs
    before any candidate without a uuid plays, once per heal, and a deleted
    row or an ended order stops an audition whose playlist was still
    unwrapping (the same guard the lookup's own callbacks have)."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_healAdvance")
    rung = "if (run.kin === 0 && HealLogic.kinPossible(run.orig)"
    assert rung in body
    assert body.index(rung) < body.index("var next = run.candidates.shift();")
    assert body.index(rung) < body.index("if (!run.nameSearched) { _healNameSearch(run.seq); return; }")
    assert "root._healByUuid = next.byUuid === true || next.twin === true;" in body
    guard = "if (!_recoveryWanted() || isPlaying() || _orderSubject() === null) return;"
    assert body.count(guard) == 2, (
        "the audition's playlist callback starts a station whose order went meanwhile")
    kin = _function_body(src, "_healKin")
    assert "run.kin = 1;" in kin and "if (run.seq !== _healSeq || root._healRun !== run) return;" in kin
    assert "run.candidates.unshift({ url: found, twin: true });" in kin


def test_an_audition_through_the_relay_is_still_the_audition():
    """A FLAC or Ogg candidate plays through the local relay, and the player's
    source is then the loopback tap. Four places asked whether the source IS
    the pending address and missed: the candidate played, the commit never
    ran and the list kept the dead address."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert "playMusic.source.toString() === root._healPendingUrl" not in src
    assert src.count("_icyStreamTarget(playMusic.source) === root._healPendingUrl") == 3
    # The connect watchdog and the stall timer asked it each in their own
    # words; both hand a dead stream to _streamDied now, which asks it once.
    assert "_icyStreamTarget(playMusic.source) === root._healPendingUrl" in _function_body(src, "_streamDied")
    assert "=== root._healPendingUrl" not in src.replace("_icyStreamTarget(playMusic.source) === root._healPendingUrl", "")


def test_an_automated_play_whose_order_went_meanwhile_does_not_start():
    """The retry ladder's play of a .pls or .m3u station waits for the
    playlist to unwrap. A delete of that station in the meantime retired the
    order but nothing told the waiting play, and the deleted station started
    when the playlist answered (found 2026-11-03). _orderLapsed answers false
    for an order that is gone, so the play asks for the order itself."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_playStation")
    assert "if (automated === true && (!root._wantsPlaying || _orderLapsed())) return;" in body


def test_the_popup_never_writes_a_saved_rows_name_or_uuid():
    """The settings pages find a row of their list in the popup's by its name
    and uuid (ReorderLogic.mergeExternal), because the popup never writes
    either on a row it already has: it moves one, fills a logo, turns one on,
    reorders, adds and removes. A popup write that renamed a row or gave it
    another uuid would make an open settings page lose it."""
    for name in ("main.qml", "FullRepresentation.qml"):
        src = _code_only((UI / name).read_text(encoding="utf-8"))
        hit = re.search(r"\b(servers|list|rows)\[\w+\]\.(name|uuid)\s*=[^=]", src)
        assert hit is None, "%s writes a saved row's %s" % (name, hit.group(2) if hit else "")
        assert not re.search(r"delete\s+\w+\[\w+\]\.(name|uuid)\b", src), name


def test_a_heal_that_moves_a_station_keeps_where_it_was():
    """A permanent heal overwrote the saved address and the old one was
    gone; it now goes to prev. The row keeps its own uuid: a name twin is
    weaker proof than the identity the row has, a byuuid move is trusted for
    good, and so a twin's uuid would hand a stranger's record the station
    (confirmed on 2026-11-02 against a record listing an attacker's
    redirector)."""
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    body = _function_body(src, "_healCommit")
    moved = body[body.index("servers[i].hostname = newUrl;"):]
    assert "servers[i].prev = oldUrl;" in moved
    assert "servers[i].uuid" not in moved, "the heal commit writes a uuid"



def test_a_dead_previews_honest_word_stays_readable():
    """The preview ladder's last word ("The station did not answer — it may
    be offline or not available in your country...") lived only inside the
    5 s error window, and the one-line footer cut it in half (seen
    2026-11-02 on a dead search result: readable for 2-4 s, gone at 6 s).
    It now stays until the next play or stop clears it, on up to two lines."""
    fr = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = fr.index("id: subtext")
    text = fr[fr.index("text: {", at):]
    idle = text.index('return i18n("Choose a station to start listening")')
    word = text.index('else if (root._friendlyError !== "")\n                        return root._friendlyError')
    assert text.index('i18n("Reconnecting…")') < word < idle, "the word does not sit just above the idle sentence"
    i = fr.index("id: subtext")
    label = fr[i:fr.index("text: {", i)]
    assert "wrapMode: Text.Wrap" in label and "maximumLineCount: 2" in label
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    for fn in ("startWithFade", "stopWithFade"):
        assert 'root._friendlyError = "";' in _function_body(main, fn), fn




def test_both_settings_pages_merge_the_popups_writes_the_same_tested_way():
    """The popup writes the station list while a settings page is open (a logo
    found, a heal). Both pages decide
    what to show through ReorderLogic.mergeExternal, which tst_reorderlogic
    holds to: a row removed here stays removed, a moved row stays in its
    place, and a local edit wins without a second row. The Stations page is
    driven for real in tst_stationspage; this keeps the Search page on the
    same road."""
    for name in ("config/configGeneral.qml", "config/configSearch.qml"):
        src = _code_only((UI / name).read_text(encoding="utf-8"))
        assert "ReorderLogic.mergeExternal(base, ReorderLogic.savedRows(stationsModel), ext, norm)" in src, name
        assert "stationsModel.remove(i)" not in src, "%s merges with its own loop again" % name






def test_the_settings_search_knows_a_station_by_any_address_it_has():
    """After a heal a saved row can sit at the station's own address (the
    record's url), while the settings search lists the address its checker
    resolved. Compared on that one alone, Search added a second Raadio Elmar
    with the same uuid (found 2026-11-02). The page asks the same function
    as the popup's search and its star, SearchLogic.knownStationAt, with
    every row it holds and the directory's row as it came."""
    src = _code_only((UI / "config" / "configSearch.qml").read_text(encoding="utf-8"))
    i = src.index("const held = []")
    loop = src[i:i + 400]
    for need in ("held.push(stationsModel.get(di))",
                 "const dupAt = SearchLogic.knownStationAt(held, src)", "if (dupAt < 0)"):
        assert need in loop, need


def test_a_component_asks_for_the_request_timer_by_name():
    """A component behind the app facade reaches main.qml's request timer as
    app._armXhrTimeout, the way its other requests do. The podcast refresh
    called it bare: that resolves only because the engine happens to be
    created inside main.qml, and stops the day it is created anywhere else,
    a test included, which is why that road had no test. A page that defines
    the two helpers itself may call them bare."""
    bare = re.compile(r"(?<![.\w])_(?:arm|clear)XhrTimeout\(")
    for qml in sorted(UI.rglob("*.qml")):
        src = _no_comments(qml.read_text(encoding="utf-8"))
        if "function _armXhrTimeout(" in src:
            continue
        hit = bare.search(src)
        assert hit is None, "%s calls %s without saying whose it is" % (
            qml.name, src[hit.start():hit.end() - 1])



def test_the_heal_takes_only_a_real_answer_for_the_directorys_word():
    """A page behind a 200 from the directory was counted as "asked and found
    nothing": the ten-minute lock was stamped and the listener was told the
    station is nowhere. The name rung asks HealLogic.answered, which
    tst_heallogic holds to a JSON list."""
    body = _function_body(_code_only((UI / "main.qml").read_text(encoding="utf-8")), "_healNameSearch")
    assert "if (HealLogic.answered(xhr)) {" in body
    assert "xhr.status === 200" not in body, "the name rung reads the status by itself again"
    assert body.index("HealLogic.answered(xhr)") < body.index("run.answered = true;")


def test_a_candidate_is_not_started_after_the_switches_were_turned_off():
    """A playlist takes a moment to unwrap, and the settings can change in
    it. The candidate used to be started on the policy that held when the
    hunt began. The one place a candidate starts asks the switches again and
    hands the order back to _tryHealStation, which ends it the way it would
    have ended had the switch been off from the start. A wake-up keeps its
    road through _mayKnock."""
    body = _function_body(_code_only((UI / "main.qml").read_text(encoding="utf-8")), "_healAdvance")
    ask = "if (!Plasmoid.configuration.autoHeal || !_mayKnock(root._healRetryAttempts)) { _tryHealStation(); return; }"
    assert ask in body, "a candidate starts without asking whether healing is still wanted"
    assert body.index(ask) < body.index("root._healPendingUrl = playUrl;")
    assert body.count("startWithFade(") == 1, "a second place starts candidates, past the check"


def test_show_more_goes_by_the_directorys_page_and_not_by_the_rows_left():
    """A full page of fifty that held twenty-five saved stations left
    twenty-five rows under a cap of thirty, and the button, which showed only
    while the rows filled the cap, went with the rest of the list unasked. The
    next offset was the row count too, so it moved with every star.
    SearchLogic.pageAfter reads both from the directory's own page
    (tst_searchlogic holds it); this pins that the popup keeps its answer and
    nothing else: the button and the footer look at it, the next page is asked
    from the place it names, a page that came moves that place and a page
    that failed leaves it for the retry."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    assert "property var _webPage: SearchLogic.pageAfter()" in code
    assert "_webSkipAhead" not in code, "an offset is kept beside the row count again"
    mark = _code_only(_function_body(src, "_webMark"))
    took = mark.index("if (qs) fullRepresentation._webLastQs = qs")
    assert took < mark.index(
        "fullRepresentation._webPage = page || SearchLogic.pageAfter(fullRepresentation._webLastQs, from, "
        "fullRepresentation._webLastParsed, fullRepresentation._webLastConsumed)")
    more = _code_only(_function_body(src, "loadMoreWeb"))
    assert "const from = fullRepresentation._webPage.at" in more
    assert 'root._rbFetch(fullRepresentation._webLastQs + "&offset=" + from, 4000,' in more, (
        "the next page is not asked from the place the last walk reached")
    failed, came = more.split("} else {")
    assert "_webAppendResults(xhr)" in failed and "_webMark(" not in failed, (
        "a page that never came moves the place on, and the retry skips it")
    assert "_webMark(from)" in came, "a page that came leaves the place where it was"
    assert ("fullRepresentation.webResultCap = Math.min(fullRepresentation.webResultCapMax, "
            "webResultsModel.count + 30)") in failed, "rows the dedup dropped come off the next click's thirty"
    at = code.index('text: i18n("Show more results")')
    button = code[code.rindex("PlasmaComponents3.ToolButton {", 0, at):at]
    assert "fullRepresentation._webPage" in button and "!fullRepresentation.webSearching" in button
    assert "webResultsModel.count >=" not in button, "the button waits for the rows to fill the cap again"
    foot = code[code.index("footer: Column {"):code.index("id: webRepeater")]
    assert "|| fullRepresentation._webPage.more" in foot, (
        "a first page of nothing but saved stations hides the button with the footer")


def test_every_road_of_the_search_says_which_list_show_more_pages():
    """One search fills the list from several answers and "Show more" pages
    one of them. Each road that picks it marks the place with the answer it
    has just walked: a mark taken later reads another answer's numbers, which
    is how the tag list once paged from the name rows' count. A new search
    starts with no page at all, before the return that ends a query too
    short to ask, or the old button would stand under the cleared list."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    reset = "fullRepresentation._webPage = SearchLogic.pageAfter()"
    run = _code_only(_function_body(src, "runWebSearch"))
    assert run.index("webResultsModel.clear()") < run.index(reset) < run.index("if (q.length < 3"), (
        "a query too short to ask keeps the last search's button")
    for rail in ("runWebTrending", "runWebCountry"):
        body = _code_only(_function_body(src, rail))
        assert body.index("webResultsModel.clear()") < body.index(reset) < body.index("root._rbFetch(qs, 4000")
        answer = body.index("fullRepresentation.webSearchFailed = !_webAppendResults(xhr)")
        assert "if (!fullRepresentation.webSearchFailed) _webMark(0)" in body[answer:answer + 160], (
            rail + " never says whether its list goes on")
    chip = src.index("The bump is load-bearing")
    assert reset in src[chip:chip + 700], "the chip's x clears the list and leaves its button"
    walk = run.index("if (gotAnswer && own) _webAppendResults(xhr)")
    assert "if (gotAnswer) _webMark(0)" in run[walk:walk + 120]
    finish = _code_only(_function_body(src, "_webFinish"))
    for qs in ("inQs + tail", "gpQs + tail"):
        assert "_webMark(0, " + qs + ")" in finish, "the list asked with " + qs + " is not the one paged"
    assert "_webMark(0, qs + tail)" in _code_only(_function_body(src, "_webStemChain"))
    assert "fullRepresentation._webLastQs = " not in finish, "a list is picked for paging past _webMark"


def test_a_saved_station_the_directory_found_stays_on_the_list():
    """The results drop every station the list already holds, and the list's
    own filter read names alone. "Example FM", saved and filed under Estonia
    and jazz, was dropped from the answer to "estonia" and to "jazz" and
    hidden in the list by its name: it stood nowhere, and a row starred
    under such a search vanished at the click. SearchLogic.knownStation hands
    back the saved rows an answer named and ReorderLogic.buildFilteredRows
    shows them (tst_searchlogic, tst_reorderlogic); this pins the road between
    the two: the walk collects them, the list is rebuilt when they change, a
    star names its own row before the row is removed, and new text or a new
    search starts with none, so yesterday's answer does not pick today's rows."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    assert "property var _webHeld: []" in code
    assert "on_WebHeldChanged: rebuildFilteredModel()" in code, (
        "the answer names a saved station and the list is not built again")
    walk = _code_only(_function_body(src, "_webAppendResults"))
    assert "named = fullRepresentation._webHeld.slice()" in walk
    assert "SearchLogic.knownStation(saved, r, named)" in walk, "a dropped station is not remembered"
    keep = "if (named.length > fullRepresentation._webHeld.length) fullRepresentation._webHeld = named"
    assert walk.index("for (const r of results)") < walk.index(keep) < walk.index("return true")
    build = _code_only(_function_body(src, "rebuildFilteredModel"))
    assert "root.searchFilter, root.favoritesOnly, fullRepresentation._webHeld)" in build, (
        "the list is filtered by name alone again")
    fresh = "fullRepresentation._webHeld = []"
    run = _code_only(_function_body(src, "runWebSearch"))
    assert run.index("webResultsModel.clear()") < run.index(fresh) < run.index("if (q.length < 3"), (
        "a chip that asks the same text another way keeps the last answer's stations")
    typed = _code_only(_function_body(src, "onSearchFilterChanged"))
    assert typed.index(fresh) < typed.index("rebuildFilteredModel()"), (
        "new text is filtered with the old text's stations until the answer comes")
    star = _code_only(_function_body(src, "starThisRow"))
    own = star.index('rep._webHeld = rep._webHeld.concat([{ "url_resolved": webItem.model.url, '
                     '"url": webItem.model.rawUrl, "stationuuid": webItem.model.rbUuid }])')
    assert star.index("var rep = fullRepresentation") < own < star.index(".remove("), (
        "the starred row is named after its delegate is gone, or not at all")


def test_the_settings_search_counts_an_answer_that_is_no_list_as_a_failed_try():
    """The first page of the settings search parsed the body and set its retry
    counter back to 0 before it looked at what it had parsed. A 200 with
    "null" in it threw one line later, counted one, and asked again, without
    end; an error object read as "nothing found". The answer is judged by
    SearchLogic.directoryRows first, and the counter goes back only for a
    list. The retry waits a turn and is dropped if somebody searched
    meanwhile: a request started inside another request's handler is the same
    crash an abort from in there is."""
    code = _code_only((UI / "config" / "configSearch.qml").read_text(encoding="utf-8"))
    body = _function_body(code, "_doGetStations")
    rows = "var servers = SearchLogic.directoryRows(xhr.status, xhr.responseText)"
    assert rows in body and "JSON.parse(" not in body, "the first page judges the answer itself again"
    assert body.index(rows) < body.index("if (servers === null) {") < body.index("_retryCount = 0"), (
        "the retry counter is set back before the answer is known to be a list")
    assert body.count("_retryCount++") == 1 and body.count("_doGetStations(by, val)") == 1
    retry = body[body.index("Qt.callLater(function() {"):body.index("_doGetStations(by, val)")]
    assert "if (asked !== _asked) return" in retry, "a retry can land in a search made after it"
    assert body.index("_asked++") < body.index("busy.running = true")


def test_the_list_show_more_pages_is_read_from_the_two_answers():
    """Under "jazz" the fifty stations of the tag answer were all saved ones.
    The web list leaves those out, so it did not grow, and that was how the
    search told whether the tag list was the one to page: paging stayed with
    the name answer, an empty one, and the genre's fifty-first station could
    not be reached. Two tagged rows, the other way round, took the paging from
    a name list that went on and ended it. SearchLogic.tagListPaged reads the
    two answers (tst_searchlogic holds it); this pins that the search asks it
    with the tag answer's own numbers, taken before the name rows the lead
    filter held back are walked again, and with the name list's verdict taken
    after that walk; and that the listener's own stations count as found, so a
    page of them is not shaved to a stem or asked again without its country."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    run = _code_only(_function_body(src, "runWebSearch"))
    assert "beforeTag" not in run and "tagIn" not in run, (
        "the paged list is told by the web rows that came in again")
    tag = run[run.index("root._rbFetch(tagQs + tail, 4000, function(xhr2) {"):]
    walked = tag.index("var tagOk = _webAppendResults(xhr2), tagRows = fullRepresentation._webLastParsed")
    place = tag.index("var tagPage = SearchLogic.pageAfter(tagQs + tail, 0, tagRows, "
                      "fullRepresentation._webLastConsumed)")
    back = tag.index("if (lead && _webAppendResults(xhr)) _webMark(0)")
    pick = tag.index("if (tagOk && SearchLogic.tagListPaged(lead !== null, fullRepresentation._webPage.more, "
                     "tagRows, tagPage.more))")
    assert walked < place < back < pick, (
        "the tag answer's place is read off the name rows' walk, or the names' verdict before it")
    assert "_webMark(0, tagQs + tail, tagPage)" in tag[pick:pick + 220]
    mark = _code_only(_function_body(src, "_webMark"))
    assert "fullRepresentation._webPage = page || SearchLogic.pageAfter(" in mark
    finish = _code_only(_function_body(src, "_webFinish"))
    assert ("count: webResultsModel.count, own: fullRepresentation._webHeld.length, gotAnswer: gotAnswer,"
            in finish), "a page of saved stations reads as an empty answer"


def test_the_ceiling_counts_the_rows_on_screen_and_not_the_cap_planned_for_them():
    """With 270 rows up, "Show more" planned a cap of 300, the page gave 49
    duplicates and one new station, and at 271 rows the button was gone and a
    click asked nothing: both held the 300 against the planned cap, with the
    directory still holding more. SearchLogic.pageOpen holds it against the
    rows that are shown (tst_searchlogic); this pins that the button and the
    request ask it with the row count, that the cap still ends at the ceiling
    so a page cannot carry the list past it, and that the star, whose row
    leaves the count, has no cap of its own to keep in step any more."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    asks = ("SearchLogic.pageOpen(fullRepresentation._webPage, webResultsModel.count, "
            "fullRepresentation.webResultCapMax)")
    more = _code_only(_function_body(src, "loadMoreWeb"))
    assert more.index("if (!" + asks + ") return") < more.index("root._rbFetch("), (
        "a click asks the directory with the list at its ceiling, or with no page behind it")
    assert "webResultCap >= " not in more, "the request is refused by the planned cap again"
    assert ("fullRepresentation.webResultCap = Math.min(fullRepresentation.webResultCapMax, "
            "webResultsModel.count + 30)") in more, "a page can carry the list past its ceiling"
    at = code.index('text: i18n("Show more results")')
    button = code[code.rindex("PlasmaComponents3.ToolButton {", 0, at):at]
    assert asks in button and "!fullRepresentation.webSearching" in button
    assert "webResultCap " not in button, "the button is held against the planned cap again"
    assert "webResultCap" not in _function_body(src, "starThisRow"), (
        "the star keeps a cap in step that nothing reads between two pages")


def _delegate_of(code, ident, kind="PlasmaComponents3.ItemDelegate"):
    """The delegate that carries `id: <ident>`, braces and all."""
    at = code.index("id: %s\n" % ident)
    start = code.rindex("delegate: %s {" % kind, 0, at)
    i = code.index("{", start)
    return code[i:_balanced_end(code, i) + 1]


def test_a_podcast_row_is_reached_and_pressed_from_the_keyboard():
    """A show on the podcast page and an episode the search found are item
    delegates with the button role, and an item delegate takes no focus by
    itself (focusPolicy 0, measured on PlasmaComponents3.ItemDelegate): Tab
    went from one row's star to the next row's star, and a row given the
    focus anyway did nothing on Return, Enter or Space, because it acted on
    a TapHandler alone. A screen reader's press ended in the delegate's
    clicked(), which nobody heard. Each row now takes the Tab focus and has
    one way to act, its own clicked(): the pointer and the screen reader end
    there by themselves and ViewLogic.pressRow sends the three keys there
    (tst_viewrules, and tst_rowkeys with real key presses on both rows). A
    TapHandler beside it would open the show a second time on every click."""
    code = _no_comments((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    acts = {
        "showRow": "onClicked: root.loadPodcastFeed(showRow.feedUrl, showRow.title, showRow.art)",
        "epsRow": "onClicked: root.playPodcastEpisode(epsRow.url, epsRow.title,",
    }
    for ident, act in acts.items():
        row = _delegate_of(code, ident)
        assert "focusPolicy: Qt.TabFocus" in row, "Tab steps over %s again" % ident
        assert row.count(act) == 1, "%s does not act on its own click" % ident
        assert "Keys.onPressed: (event) => ViewLogic.pressRow(event, %s)" % ident in row, (
            "Return, Enter and Space do nothing on %s" % ident)
        assert "TapHandler" not in row and "Accessible.onPressAction" not in row, (
            "%s has a second way to act: a click or a screen reader's press acts twice" % ident)
        assert "border.width: %s.activeFocus ? 2 : 1" % ident in row, (
            "%s takes the focus and shows nothing for it" % ident)


def test_a_paired_speaker_and_its_forget_are_reached_with_tab():
    """The output menu's Forget button was shown under the pointer and at no
    other time, and a button that is not shown is no Tab stop. The speaker's
    tick beside it is a check delegate, which takes no focus by itself
    (focusPolicy 0, measured), so Tab went past the whole Bluetooth row:
    a paired speaker could be neither connected nor forgotten from the
    keyboard. The tick takes the Tab focus now and Forget is shown while the
    tick or the button itself has it. The tick is declared first, because
    Tab walks in that order and a button shown by its speaker's focus has
    to come after the speaker; the row is laid out from the right so Forget
    keeps its place at the far left. It is there the moment the tick or the
    button has the focus and not one frame of the fade later: a quick second
    Tab ran past it, and one that landed found it hidden for that frame, where
    a press does nothing. The two taps stay, and the first one is taken back when the
    button goes: Escape closed the menu on a standing question, and a press
    inside the next three seconds forgot the speaker. tst_btforget walks a
    copy of the row with real keys."""
    code = _no_comments((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    row = _delegate_of(code, "btRow", "RowLayout")
    tick = row.index("PlasmaComponents3.CheckDelegate {")
    forget = row.index("CircleButton {")
    assert tick < forget, "Forget is declared before the speaker: Tab meets it while it is hidden"
    assert "layoutDirection: Qt.RightToLeft" in row[:tick], (
        "declared second and laid out from the left, Forget stands beside the tick's right edge")
    assert "focusPolicy: Qt.TabFocus" in row[tick:forget], "Tab steps over a paired speaker again"
    btn = row[forget:]
    assert ("opacity: (btRowHover.hovered || armed || activeFocus || btRowDelegate.activeFocus)"
            " ? 0.75 : 0.0") in btn, "Forget is shown under the pointer only"
    assert ('visible: (opacity > 0.0 || activeFocus || btRowDelegate.activeFocus)'
            ' && root._btConnectingMac === ""') in btn, (
        "Forget waits for its fade before Tab can land on it, or goes while it has the focus")
    assert "onVisibleChanged: if (!visible) armed = false" in btn, (
        "a first tap outlives the button it was made on")
    ask = "if (!armed) { armed = visible; btForgetDisarm.restart(); return }"
    assert ask in btn and btn.index(ask) < btn.index("root.btForget(btRow.mac)"), (
        "one tap forgets, or a button nobody can see takes the first one")


def test_the_player_and_the_appearance_page_read_the_accent_the_same_way():
    """A config can hold two keys for the widget's colours: accentMode, and
    followSystemAccent from before the Accent list existed. The player read
    both and the Appearance page showed accentMode alone, so a config with
    accentMode 0 and the old key on wore the system accent under a list
    that said "On Air green". Both ask ColorLogic.accentMode now
    (tst_colorlogic has every pair; tst_appearancepage drives the page).
    The page writes the two keys in one place and nowhere else: a choice
    that left the old yes standing would be outvoted by it at the next
    start, and a list that wrote on opening would turn Apply on by itself."""
    main = _no_comments((UI / "main.qml").read_text(encoding="utf-8"))
    assert re.search(r"readonly property int _accentMode: ColorLogic\.accentMode\("
                     r"Plasmoid\.configuration\.accentMode,\s*"
                     r"Plasmoid\.configuration\.followSystemAccent\)", main), (
        "the player reads the two accent keys its own way again")
    page = _no_comments((UI / "config" / "configAppearance.qml").read_text(encoding="utf-8"))
    assert ("readonly property int _accent: "
            "ColorLogic.accentMode(cfg_accentMode, cfg_followSystemAccent)") in page, (
        "the page shows the accent by a reading of its own")
    assert "currentIndex: root._accent\n" in page, "the Accent list shows the stored number as it is"
    assert "checked: root._accent === 1\n" in page, "the old box shows the old key as it is"
    assert "property alias cfg_followSystemAccent" not in page, (
        "the old key is a control's own state again, and the two controls can disagree")
    choose = _function_body(page, "_chooseAccent")
    assert "cfg_accentMode = mode" in choose and "cfg_followSystemAccent = (mode === 1)" in choose
    assert len(re.findall(r"cfg_accentMode\s*=[^=]", page)) == 1, "the mode is written outside _chooseAccent"
    assert len(re.findall(r"cfg_followSystemAccent\s*=[^=]", page)) == 1, (
        "the old key is written outside _chooseAccent")
    assert page.count("root._chooseAccent(") == 2, "a control does not write its choice through _chooseAccent"


def test_the_transport_words_go_through_one_door_and_a_pause_keeps_its_file():
    """An episode plays, the headset says Pause, and later Play: the first
    station of the list came on. A pause was a stop for anything without a
    timeshift buffer, the stop threw the episode away, and a Play that names
    nothing fell back to row 0. The widget's own button did the same on its
    second press, from its own copy of the same branches.

    What each word does is TransportLogic.mediaKey, and what a pause keeps is
    TransportLogic.filePause (tst_transportlogic). tst_transportroads walks
    the roads from a pause around a counting player, with a copy of the lines
    below; this holds main.qml and the widget's roads to that copy.

    The player pauses where it stands, so the page goes on showing the file,
    and what was kept is one property. The pause writes it; Play, a stop and
    the handoff every other start goes through drop it, so it cannot outlive
    a choice made after it, and a widget that starts fresh holds none."""
    main_src = (UI / "main.qml").read_text(encoding="utf-8")
    main = _code_only(main_src)

    def flat(text):
        return re.sub(r"\s+", " ", text)

    dispatch = _function_body(main, "_mprisDispatch")
    words = 'if (cmd === "Stop" || cmd === "Pause" || cmd === "PlayPause" || cmd === "Play") {'
    assert flat(dispatch[dispatch.index(words) + len(words):]).startswith(" transport(cmd); }"), (
        "a media key's word is answered somewhere other than transport()")
    for own in ("stopWithFade(", "timeshiftPause(", "timeshiftResume(", "playMusic.play(", "playLast("):
        assert own not in dispatch, "the MPRIS dispatch answers a transport word itself: %s" % own

    # What plays, and the facts the words are answered from: one array, read
    # by the transport and by the face of its button.
    told = flat(main[main.index("readonly property var _nowPlays: ({"):main.index("readonly property var _keyFacts:")])
    for fact in ('"audible": isPlaying()', '"preview": _previewUrl !== ""',
                 '"source": playMusic.source.toString()',
                 '"episode": _podPlayingKey !== "" ? _podPlayingUrl : ""',
                 '"tone": _alarmToneUrl.toString()', '"bufferPath": timeshift.bufPath',
                 '"shifted": timeshift.shifted', '"casting": _casting',
                 '"stopping": fadeOutAnimation.running', '"raw": _podPlayingRawUrl',
                 '"title": currentStation', '"key": _podPlayingKey', '"show": _podPlayingShow',
                 '"art": _podPlayingArt', '"feed": _currentEpisodeFeed'):
        assert fact in told, "the pause is no longer told %s" % fact
    assert "playMusic.position" not in told, (
        "what plays is bound to the needle, and the face of the button is worked out again with every tick")
    assert ("readonly property var _keyFacts: [isPlaying(), _casting, _wantsPlaying, _tsPaused, timeshift.shifted, "
            "TransportLogic.ownFile(_nowPlays), _pausedFile !== null, "
            "TransportLogic.inPlace(_pausedFile, playMusic.playbackState === MediaPlayer.PausedState), "
            "_previewComing]") in flat(main), (
        "the transport's facts are not mediaKey's nine, in its order: an audition on its way is what Stop looks at "
        "while nothing of it is audible yet")

    door = flat(_function_body(main, "transport"))
    lines = ("var act = TransportLogic.keyFor(cmd, _keyFacts);",
             'if (act === "pause" && timeshiftPause()) return;',
             'if (act === "stop" || act === "pause") stopWithFade();',
             'else if (act === "keep") {',
             "_stampPodPosition(); _flushPodPositions(); alarmEngine.standDown(); _volumeOverridePct = -1; _abortSleepFade();",
             'root._pausedFile = TransportLogic.filePause(Object.assign({ "positionMs": playMusic.position, '
             '"seekSec": _podPendingSeekUrl === playMusic.source.toString() ? _podPendingSeekSec : -1 }, _nowPlays));',
             "playMusic.pause();",
             '} else if (act === "resume") timeshiftResume();',
             'else if (act === "unpause") { root._pausedFile = null; playMusic.play(); }',
             'else if (act === "bare") playLast();')
    at = [door.index(line) for line in lines]
    assert at == sorted(at), (
        "transport() does its answers in another order: the bookmark is stamped while the file still plays, "
        "and the file is kept before the pause, whose edge arrives at once")
    assert door.count("stopWithFade(") == 1 and door.count("playMusic.pause(") == 1 and door.count("playMusic.play(") == 1

    # The widget's three roads: the Playing tab's button, Space, the panel's
    # middle click. None of them keeps branches of its own.
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    panel = _code_only((UI / "CompactRepresentation.qml").read_text(encoding="utf-8"))
    assert full.count('root.transport("PlayPause")') == 2 and 'onClicked: root.transport("PlayPause")' in full
    assert panel.count('if (Plasmoid.configuration.lastplay) root.transport("PlayPause");') == 1
    for path in sorted(UI.rglob("*.qml")):
        code = _code_only(path.read_text(encoding="utf-8"))
        own = main if path.name == "main.qml" else code
        if path.name != "main.qml":
            for road in ("timeshiftPause(", "timeshiftResume(", "playLast(", "playMusic.pause("):
                assert road not in code, "%s goes round transport() through %s" % (path.name, road)
        writes = len(re.findall(r"_pausedFile\s*=[^=]", own))
        assert writes == (7 if path.name == "main.qml" else 0), (
            "%s writes the kept file %d time(s)" % (path.name, writes))
    assert main.count("timeshiftPause(") - main.count("function timeshiftPause(") == 1, (
        "the pause is asked for outside transport()")
    assert main.count("playMusic.pause(") == 2, (
        "the player is paused somewhere besides the buffer's reader and the kept file")
    # A word reaches the transport from the desk, and from a tap on the row
    # of what is on. No timer and no recovery road sends one.
    senders = {_owner_of(main, m.start())[0] for m in re.finditer(r"(?<!function )\btransport\(", main)}
    # And from a step of the sliding buffer pressed on the broadcast, which is a pause and a play
    # (test_a_step_is_a_pause_and_a_play_through_the_one_door).
    assert senders == {"_mprisDispatch", "playPodcastEpisode", "playLocalFile", "timeshiftStep"}, sorted(senders)
    tap = 'if (TransportLogic.rowTap(%s, isPlaying(), _pausedFile !== null, root._alarmFiring)) { transport("PlayPause"); return; }'
    episode_tap = _function_body(main, "playPodcastEpisode")
    assert ('var isThisOn = playMusic.source.toString() === raw || (_podPlayingRawUrl !== "" && _podPlayingRawUrl === raw);'
            in episode_tap and tap % "isThisOn" in episode_tap), "an episode's row no longer asks whether its tap is the toggle"
    file_tap = _function_body(main, "playLocalFile")
    assert tap % "playMusic.source.toString() === urlStr" in file_tap, "a file's row no longer asks whether its tap is the toggle"
    for body, name in ((episode_tap, "playPodcastEpisode"), (file_tap, "playLocalFile")):
        assert "stopWithFade(" not in body, "%s stops what its row was tapped on, past the transport" % name
    assert file_tap.index("TransportLogic.rowTap(") < file_tap.index("_podHandoff();"), (
        "the handoff drops the kept file before the row's tap could be read as its resume")

    # The kept file: born empty, never read from the configuration, dropped by
    # Play, by a stop and by every other start, and the desk is told when it changes.
    assert "property var _pausedFile: null\n" in main
    assert "on_PausedFileChanged: _mprisQueueWrite()" in main, (
        "a Stop over a paused file changes nothing that plays, so the desk would go on reading Paused")
    for fn in ("stopWithFade", "_podHandoff"):
        assert "_pausedFile = null;" in _function_body(main, fn), "%s keeps a paused file" % fn
    # "Every other start" is the handoff's promise, so the handoff has to be
    # on every road that begins something new: a station or a search result
    # (_playStation, before its resolve can fail), a file or an episode
    # (playLocalFile), and each start the wake-up makes by itself.
    for fn in ("_playStation", "playLocalFile"):
        body = _function_body(main, fn)
        assert body.index("_podHandoff();") < body.index("startWithFade("), (
            "%s starts something without the handoff that ends a pause" % fn)
    alarm = _code_only((UI / "AlarmEngine.qml").read_text(encoding="utf-8"))
    rings = [m.start() for m in re.finditer(r"app\.startWithFade\(", alarm)]
    assert rings, "the wake-up no longer starts anything itself; this check has nothing to hold"
    for at in rings:
        name, opened = _owner_of(alarm, at)
        assert "app._podHandoff();" in alarm[opened:at], (
            "the wake-up's %s starts sound without the handoff, and a paused episode would outlive the alarm" % name)

    # The kept file is started again only by a bare Play, when it streams or
    # the player no longer holds it. It is let go of first: the start would
    # read it as its own row tapped, and send Play round again.
    play = _function_body(main, "playLast")
    play = re.sub(r"\s+", " ", play)
    held = play.index("var held = root._pausedFile, sec = TransportLogic.needle(held.sec, "
                      "playMusic.playbackState === MediaPlayer.PausedState, playMusic.position, "
                      "_podPendingSeekUrl === playMusic.source.toString());")
    episode = "if (held.episode) playPodcastEpisode(held.url, held.title, held.key, held.show, held.art, held.feed);"
    seek = "if (sec >= 0) { _podPendingSeekUrl = playMusic.source.toString(); _podPendingSeekSec = sec; }"
    assert play.index('if (pick.what === "paused") {') < held < play.index("root._pausedFile = null;") \
        < play.index(episode) < play.index("else playLocalFile(held.url, held.title);") < play.index(seek) \
        < play.index('} else if (pick.what === "audition") {'), (
        "the kept file is not let go of before its own start, or its second is set before the start")

    state = _function_body(main, "_mprisWriteState")
    assert ("var status = TransportLogic.playbackStatus(isPlaying(), _casting, _tsPaused, timeshift.shifted, "
            "_pausedFile !== null);") in state
    assert "status: status," in state and 'canPause: status !== "Stopped",' in state, (
        "the desk's status or its CanPause is worked out apart from TransportLogic.playbackStatus")
    assert 'station: root.currentStation || (_pausedFile !== null ? _pausedFile.title : ""),' in state, (
        "a paused file has no name on the desk")


def test_the_desk_is_told_what_play_can_do_by_the_rule_play_follows():
    """CanPlay was "the list has a row", a rule written apart from the action.
    With no station saved, a search result that was playing was announced as
    unplayable, and after its stop the desk's Play stayed dark while the
    widget's own button brought it back (measured 2026-11-11 on main.qml's
    state writer: status Playing, canPlay false).

    The rule is TransportLogic.canPlay, which asks bareplay, the function a
    Play that names nothing obeys (tst_transportlogic). Held here: there is
    one capability, a property of main.qml; it is handed the very facts
    playLast hands bareplay; the desk and the Playing tab's button both read
    it; and the desk is written to when it changes, since a list that gets
    its first station while nothing plays moves nothing else."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    can = re.search(r"readonly property bool canPlay: TransportLogic\.canPlay\(([^\n]*)\)\n", main)
    assert can, "main.qml has no canPlay that TransportLogic decides"
    asked = [a.strip() for a in can.group(1).split(",")]
    assert asked[:4] == ["isPlaying()", "_casting", "_tsPaused", "timeshift.shifted"], asked
    bare = re.search(r"TransportLogic\.bareplay\(([^\n]*)\);", _function_body(main, "playLast"))
    assert bare and asked[4:] == [a.strip().replace("root.", "") for a in bare.group(1).split(",")], (
        "the capability is asked about other facts than the Play it speaks for: %s" % asked[4:])
    assert "onCanPlayChanged: _mprisQueueWrite()" in main, "the desk is not told when Play starts or stops being possible"
    state = _function_body(main, "_mprisWriteState")
    assert "canPlay: root.canPlay," in state and "stationsModel.count > 0" not in state, (
        "the desk's CanPlay is worked out apart from the Play it announces")
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    assert "enabledState: root.canPlay\n" in full, "the Playing tab's button has a rule of its own for when Play can be pressed"
    uses = sum(_code_only(p.read_text(encoding="utf-8")).count("TransportLogic.canPlay(")
               for p in sorted(UI.rglob("*.qml")))
    assert uses == 1, "the capability is worked out in %d places" % uses


def test_the_output_menus_volume_row_turns_what_is_heard():
    """The system default output selected, a television carrying the stream
    and this computer silent: the "Play on" menu's Volume slider and its Mute
    turned this computer's master, because the row asked only how the local
    sound is routed (measured 2026-11-11 on the row's own lines: local=1
    cast=0, and with an output pinned local=0 cast=1). And with the two
    playing together the row on the default sink moved this computer and
    left the television where it stood, while pinned it moved both.

    Which knob the row is, what a gesture on it sends where, and the master a
    device follows are TransportLogic's volumeRoad, masterGesture and
    castMaster, and a device's level is deviceLevel(master, its balance)
    (tst_transportlogic). tst_volumeroad drives a copy of the row and of
    main.qml's volume roads around devices that only write down what they
    are sent. Held here: the row asks those and sends nothing else; a drag
    holds the road it began on; every level a device is sent comes out of
    the one formula; a device that is only ticked is never sent a level; the
    devices follow what the mute answered, not what the icon showed, and are
    not moved by the poll; and a mute does not take the place of a level
    that was still waiting to be saved."""
    def flat(text):
        return re.sub(r"\s+", " ", text)

    full = flat(_code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8")))
    assert 'readonly property bool roomMode: root.masterRoadOf(masterVolumeSlider.dragRoad) === "sink" ' in full, (
        "the volume row decides for itself which output it turns")
    answer = ('function gesture(kind, level) { var to = TransportLogic.masterGesture(kind, roomMode ? "sink" : "player", '
              "root._casting, root._castLocalPlay, level, playMusicOutput.volume, root.targetVolume(), root._ownMuted) "
              "if (to.sink >= 0) root.setSinkMaster(to.sink) "
              "if (to.sinkMute) root.toggleSinkMasterMute(to.castFollows) "
              "if (to.player >= 0) root.setUserVolume(to.player) "
              "if (to.cast >= 0) root._castSetVolume(to.cast) }")
    assert answer in full, "the row's gestures are not what TransportLogic.masterGesture answered, sent as it answered them"
    assert 'onClicked: parent.gesture("mute", 0) ' in full, "the row's mute goes round the row's one answer"
    assert "readonly property bool shownMuted: (roomMode && root._sinkMasterMuted) || shownVol <= 0 " in full, (
        "the speaker button shows the room's mute on the widget's own knob, or forgets it on the room's")
    held = 'property string dragRoad: "" onPressedChanged: dragRoad = pressed ? (parent.roomMode ? "sink" : "player") : "" '
    assert held + 'onMoved: parent.gesture("move", value) ' in full, (
        "the slider does not hold the road its drag began on, or moves past the row's answer")
    for path in sorted(UI.rglob("*.qml")):
        if path.name == "main.qml":
            continue
        code = _code_only(path.read_text(encoding="utf-8"))
        rooms = code.count("setSinkMaster(") + code.count("toggleSinkMasterMute(")
        assert rooms == (2 if path.name == "FullRepresentation.qml" else 0), (
            "%s reaches this computer's master on %d road(s) past the volume row" % (path.name, rooms))
        told = code.count("_castSetVolume(")
        assert told == (1 if path.name in ("FullRepresentation.qml", "AlarmEngine.qml") else 0), (
            "%s sets a device's level on %d road(s)" % (path.name, told))

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert ("function masterRoadOf(dragRoad) { return TransportLogic.volumeRoad(_casting, _castLocalPlay, "
            "sync._combineWantActive || sync._combineActive, "
            '(Plasmoid.configuration.audioOutputDevice || "") === "", dragRoad); }') in flat(main)
    assert ('function castMaster() { return TransportLogic.castMaster(masterRoadOf(""), _sinkMasterPct, _sinkMasterMuted, '
            "_ownMuted, targetVolume()); }") in flat(main)
    user = _function_body(main, "setUserVolume")
    keep = ("if (TransportLogic.muteDisplaces(_pendingUserVolumePct, vol)) "
            "Plasmoid.configuration.defaultVolume = _pendingUserVolumePct;")
    assert user.index(keep) < user.index("_pendingUserVolumePct = Math.round(vol * 100);"), (
        "the waiting level is saved after the mute already took its place")
    assert "if (_casting) _castSetVolume(castMaster());" in user, (
        "a device that is ticked but not playing is sent a level, or a playing one a level past the one master")

    # Every level a device is sent goes out of one function: the debounced master, and its own row.
    tell = _function_body(main, "_castTell")
    assert "var level = TransportLogic.deviceLevel(master, sync.trimOf(dev.uuid)).toFixed(3);" in tell
    assert main.count("TransportLogic.deviceLevel(") == 1 and "* sync.trimOf(" not in main and "* root.sync.trimOf(" not in main, (
        "a device's level is worked out somewhere besides TransportLogic.deviceLevel")
    assert main.count('"CAST_VOL"') == 2 and tell.count('_castExec("CAST_VOL", [') == 2, (
        "a device is sent a level past _castTell, which is where its balance is applied")
    out = _function_body(main, "_castFlush")
    assert "_castTargets.forEach(function (dev) { _castTell(dev, _pendingCastVolumePct / 100); });" in out
    assert out.index("_castTell(") < out.index("_pendingCastVolumePct = -1;")
    assert "onTriggered: root._castFlush()\n" in main[main.index("id: castVolumeTimer"):][:120]
    assert "if (ti >= 0) _castTell(_castTargets[ti], castMaster());" in _function_body(main, "applyCastTrim"), (
        "the device's own row sends it a level past the master: moved under a mute, it wakes the device")
    assert ('var master = TransportLogic.castMaster(root.masterRoadOf(""), root._sinkMasterPct, false, false, '
            "root.targetVolume()); var ratio = parseFloat(adVol[1]) / Math.max(0.05, master);") in flat(main), (
        "a joining device's balance is measured against another master than the one it will follow, or a muted one")

    # The mute: pactl decides, and only the click's own answer is passed on to the devices.
    mute = _function_body(main, "toggleSinkMasterMute")
    assert '${m:-no}" + (tellDevices === true ? " devices" : "") + "\\"; true # "' in mute
    poll = main[main.index("id: sinkMasterPoll"):main.index("function setSinkMaster(")]
    assert "devices" not in poll, "the poll of this computer's master tells the devices to move"
    answer = main[main.index('if (cmd.indexOf(": SINKVOL;") === 0) {'):]
    answer = answer[:answer.index("return;")]
    assert "match(/SINKVOL (-?\\d+) (yes|no)( devices)?/);" in answer
    assert answer.index('root._sinkMasterMuted = svM[2] === "yes";') \
        < answer.index("if (svM[3] && root._casting) root._castSetVolume(root.castMaster());"), (
        "the devices are told before the mute's answer is known, or one that stopped playing is told too")
    assert main.count("_castSetVolume(") - main.count("function _castSetVolume(") == 2, (
        "a device's master is set on a road besides the widget's own volume and the mute's answer")


def test_the_big_button_shows_what_its_press_does_and_a_pause_stays_on_the_page():
    """Since 2026.44 a press on the big button keeps an episode's place, and
    the button still read Stop there: it asked only about the timeshift
    buffer. And a paused episode left the Playing page looking idle, with
    nothing on it that could let go of the pause.

    The face is TransportLogic.face, asked of the facts transport() itself is
    answered from, so the two cannot disagree (tst_transportlogic walks every
    state). Held here: the button takes its glyph and its name from that one
    property; the Stop beside it follows the face; the footer says Paused;
    and the three roads that go on with an episode by themselves stand down
    over a pause, as does the edge that wipes the header."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))

    def flat(text):
        return re.sub(r"\s+", " ", text)

    assert "readonly property string bigFace: TransportLogic.face(_keyFacts, tsPauseAvailable)\n" in main, (
        "the face is asked of other facts than the press")
    assert ('iconName: root.bigFace === "pause" ? "media-playback-pause" '
            ': (root.bigFace === "stop" ? "media-playback-stop" : "media-playback-start")\n') in full
    assert ('tooltipText: root.bigFace === "pause" ? i18n("Pause") '
            ': (root.bigFace === "stop" ? i18n("Stop") : i18n("Play"))\n') in full
    assert "Accessible.name: tooltipText" in (UI / "CircleButton.qml").read_text(encoding="utf-8"), (
        "the round button is no longer named by its tooltip, so the face has no name for a screen reader")
    assert "tsPauseAvailable" not in full, "the Playing page asks the timeshift buffer what its button is, past the face"
    assert ("visible: TransportLogic.stopOffered(isPlaying(), root._casting, root._wantsPlaying, root._tsPaused, "
            'root.tsShifted, root.bigFace === "pause", root._pausedFile !== null)') in flat(full), (
        "the Stop beside the button does not follow the button's face, or lets go of no paused file")

    foot = full[full.index("if (root._tsPaused || root._pausedFile !== null)"):]
    assert 'return root.tsBuffering ? i18n("Paused — still buffering live radio") : i18n("Paused")' in foot[:600]
    assert foot.index('i18n("Paused")') < foot.index('i18n("Connecting…")'), (
        "the footer reads Connecting over a paused file: the loading branch catches a player that is not playing")

    # Nothing goes on by itself over a pause. The queue's head and the show's
    # next episode start from two handlers, and the stall retry from its timer.
    assert main.count("_podPlayUpNextHead()") - main.count("function _podPlayUpNextHead()") == 2
    assert "if (root._pausedFile === null && root._podPlayUpNextHead()) return;" in main
    assert "if (root._pausedFile === null && Plasmoid.configuration.podcastContinuous !== false && deadFeed) {" in main
    assert "if (!fadeOutAnimation.running && root._pausedFile === null && !root._podPlayUpNextHead()" in main
    stall = main[main.index("id: stallTimer"):]
    assert stall.index("if (root._tsPaused || root._pausedFile !== null || _orderLapsed()) return;") < stall.index("playMusic.play()")
    edge = main[main.index("onPlayingChanged:"):]
    assert "if (!isPlaying() && root._pausedFile === null) {" in edge[:edge.index("_mprisQueueWrite()")], (
        "the pause wipes a file's own title off the header, and nothing writes it back")


def test_a_row_and_the_panel_go_on_naming_what_is_paused():
    """A paused episode's row looked like any other row, and the panel's text
    and its tooltip dropped the file the moment it stopped sounding, as if
    nothing were held. What is on, playing or paused, keeps its row's mark;
    the bars a row wears turn into the pause sign (tst_eqbars), and the row
    without bars says Paused in words; the panel's opt-in text stays and its
    tooltip says Paused."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    panel = _code_only((UI / "CompactRepresentation.qml").read_text(encoding="utf-8"))
    row = _code_only((UI / "EpisodeListItem.qml").read_text(encoding="utf-8"))
    bars = _code_only((UI / "EqBars.qml").read_text(encoding="utf-8"))

    assert full.count("readonly property bool isThisPlaying: (isPlaying() || root._pausedFile !== null)") == 3
    assert "&& root.onOrKept\n" in row[row.index("readonly property bool isThisPlaying:"):][:400]
    assert ("readonly property bool onOrKept: playMusic.playbackState === MediaPlayer.PlayingState "
            "|| _casting || _pausedFile !== null\n") in main
    assert full.count("paused: root._pausedFile !== null\n") == 2 and row.count("paused: root._pausedFile !== null\n") == 1
    assert 'if (podDlRow.isThisPlaying && root._pausedFile !== null) bits.push(i18n("Paused"))' in full, (
        "the Downloaded row has no bars, and nothing else there says its episode is paused")
    assert ('Accessible.name: fileItem.isThisPlaying && isPlaying() ? i18n("Pause: %1", displayName) '
            ': i18n("Play: %1", displayName)') in full
    for part in ("property bool paused: false", "readonly property bool _moving: animating && !paused",
                 "function restOf(index) { return paused ? (index < 2 ? maxHeight * 0.7 : 0) : minHeight }",
                 "running: eqRoot._moving", "if (!eqRoot._moving) return eqRoot.restOf(barSlot.index);"):
        assert part in bars, "the bars lost their pause sign: %s" % part

    assert ("TransportLogic.held(isPlaying(), root._casting, root._wantsPlaying, root._tsPaused, root.tsShifted, "
            "root._pausedFile !== null)") in re.sub(r"\s+", " ", panel)
    assert main.count("if (!onOrKept) return ") == 2
    assert 'var line = _pausedFile !== null ? i18n("Paused") : currentStation;' in main


def test_a_key_held_down_is_one_press():
    """A held key repeats some 25 times a second. Space on the Playing page
    and Enter or Space on a file's or an episode's row each toggle the
    transport, so a key held for a second played and paused a dozen times;
    before a pause could keep a file, the same hold stopped and restarted it."""
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    row = _code_only((UI / "EpisodeListItem.qml").read_text(encoding="utf-8"))
    assert "event.key === Qt.Key_Space && !_inputFocused() && !event.isAutoRepeat) {" in full
    assert "if (!event.isAutoRepeat) root.playLocalFile(fileItem.localUrl, fileItem.displayName)" in full
    assert "if (!event.isAutoRepeat) podDlRow._activate()" in full
    assert "if (!event.isAutoRepeat) epItem.primaryAction()" in row


def test_a_tick_on_this_computer_leaves_a_playing_device_where_it_stands():
    """On the default sink a device alone follows the widget's own volume, and
    beside this computer that volume times the room's master. Ticking or
    unticking "This computer" beside a device that plays swaps the one master
    for the other, and a balance read against the old one moves the device
    at the first gesture after it: with the room at 50 % under a widget at
    80 %, a television standing at 0.200 with a balance of 0.5 is sent
    0.75 x 0.5 = 0.375 by one wheel step down after the untick.

    The balance is read against the new master at the tick
    (TransportLogic.rebalance, tst_transportlogic) and stored, and the device
    is told nothing (tst_syncengine asks the engine itself; tst_volumeroad
    walks a copy of the tick). Held here: the tick asks which knob the row
    was before it changes anything, re-reads the balance only when the knob
    changed (it never does for a device that is ticked and idle: volumeRoad
    asks the box only beside a cast), and stores without sending; the rows
    of the menu go on sending."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    tick = _function_body(main, "castToggleLocal")
    tick = re.sub(r"\s+", " ", tick)
    line = ('if (masterRoadOf("") !== was) _castTargets.forEach(function (d) { sync.setDeviceTrim(d.uuid, '
            "TransportLogic.rebalance(sync.trimOf(d.uuid), was, _sinkMasterPct, targetVolume()), true); });")
    assert tick.index('var was = masterRoadOf("");') < tick.index("if (_castLocalPlay) {"), (
        "the tick asks which knob the row was after it already changed it")
    assert tick.index("_castJoinLocal = false;") < tick.index(line), (
        "a device's balance is not read against its new master at the tick, or before this computer joined")
    assert main.count("TransportLogic.rebalance(") == 1, "a balance is read against another master on a second road"

    engine = _code_only((UI / "SyncEngine.qml").read_text(encoding="utf-8"))
    store = _function_body(engine, "setDeviceTrim")
    assert "function setDeviceTrim(id, factor, stored) {" in engine
    assert "if (stored !== true && app.castTrimActive(id)) {" in store, (
        "a balance that is only stored is sent to the device: a tick under a mute silences a television that plays")
    quiet = re.compile(r"setDeviceTrim\([^\n]*, true\)")
    for path in sorted(UI.rglob("*.qml")):
        found = len(quiet.findall(_code_only(path.read_text(encoding="utf-8"))))
        assert found == (1 if path.name == "main.qml" else 0), (
            "%s stores a balance without sending it on %d road(s)" % (path.name, found))


def test_a_device_is_muted_by_the_listener_and_never_by_a_zero_the_widget_passes_through():
    """The master a device follows read a stream at zero as a mute, and the
    widget writes zero by itself: for the length of a calibration
    (SyncEngine parks the stream), for the first 10 to 20 ms of a start with
    the fade (measured with the start's own lines on a stand-in output, with
    fades of 250, 1000 and 3000 ms; the fade is restarted in the same call,
    it does not wait for the stream), and when the sleep timer's fade has
    run out. A click on the slider, a touch of the device's row or an
    unmute's answer in such a moment sent the device 0, and nothing brought
    it back before the next gesture (tst_volumeroad, on a copy: [tv 0.000]
    where [tv 0.400] is due).

    The mute is a fact of its own now, TransportLogic.ownMute
    (tst_transportlogic): a gesture at zero makes it, any other gesture ends
    it, and so does anything that lifts the stream, because a start brings
    this computer's sound back by itself. Held here: the gestures' one door
    and the output's own change are its only two writers, and castMaster is
    given the fact and is not shown the stream."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert "property bool _ownMuted: false\n" in main
    user = _function_body(main, "setUserVolume")
    made = "_ownMuted = TransportLogic.ownMute(_ownMuted, true, vol);"
    assert user.index("playMusicOutput.volume = vol;") < user.index(made) < user.index("if (_casting) _castSetVolume(castMaster());"), (
        "a gesture's mute is decided before its level is written, or after the devices were told")
    assert ("onVolumeChanged: { _mprisQueueWrite(); root._ownMuted = TransportLogic.ownMute(root._ownMuted, false, volume) }\n"
            in main[main.index("id: playMusicOutput"):][:900]), (
        "a start no longer ends the listener's mute: left up, it is back at the next zero the widget writes")
    for path in sorted(UI.rglob("*.qml")):
        writes = len(re.findall(r"_ownMuted\s*=[^=]", _code_only(path.read_text(encoding="utf-8"))))
        assert writes == (2 if path.name == "main.qml" else 0), (
            "%s writes the listener's mute on %d road(s)" % (path.name, writes))
    assert "playMusicOutput.volume" not in _function_body(main, "castMaster"), (
        "the master a device follows is read off the stream again: a start's zero is taken for a mute")


def test_the_rooms_reading_is_kept_fresh_while_a_device_follows_it():
    """Beside this computer on the room's knob a device follows the widget's
    volume times the room's master, and the room's master is what the widget
    last READ: the poll ran only while the face was watched. With the popup
    closed, the panel's wheel, the M key and an MPRIS volume worked from a
    reading as old as the popup's last visit, and a mute of the room that
    something else had lifted since was still believed.

    The poll now also runs while a device follows the reading
    (TransportLogic.roomFollowed, tst_transportlogic), and at the unwatched
    rate when nobody looks: a tick is a shell with two pactl, two grep, head
    and tr, 6.5 ms of CPU measured, and every two seconds for as long as a
    pair plays is the shape of issue #2. The poll still never moves a device
    (test_the_output_menus_volume_row_turns_what_is_heard)."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    poll = main[main.index("id: sinkMasterPoll"):main.index("function setSinkMaster(")]
    assert "interval: playerWindow.faceWatched ? 2000 : 30000\n" in poll, (
        "the reading is polled every two seconds while nobody looks: 1800 shells an hour for as long as a pair plays")
    assert 'running: root.faceShown || TransportLogic.roomFollowed(root._casting, root.masterRoadOf(""))\n' in poll, (
        "the reading a device follows goes stale while the popup is closed")


def test_a_start_goes_by_what_the_stream_is_and_asks_beside_itself():
    """The start chose the relay by the address's ending and, for an audition,
    by the directory's label, and both mislead (KindLogic.js has the numbers):
    plain FLAC and Opus lost seconds and titles to a relay they do not need,
    and a saved Ogg FLAC station at a bare address stood silent for the
    rescue's six seconds. StreamKind decides now, under tst_streamkind. This
    pins the road into it: every start tells it, with "" for one the relay has
    no part in so that a question still out ends there; the plain start is on
    its way before the question can go out; the answer is what arms the relay
    in an Ogg shell; and neither the ending nor the label is read here."""
    body = _code_only(_function_body((UI / "main.qml").read_text(encoding="utf-8"), "startWithFade"))
    ask = 'var tsOgg = streamKind.start(tsLocal ? tsUrl : "", station.name || "", root._previewCodec);'
    assert ask in body, "the start no longer asks StreamKind"
    arm = 'timeshift.armRelay(tsUrl, station.name || "", Date.now(), tsOgg)'
    assert body.index("playMusic.play();") < body.index(ask) < body.index(arm), (
        "the question goes out before the plain start, or after the relay was chosen")
    assert "if (tsLocal && (tsOgg || streamKind.proven(tsUrl))) {" in body
    for old in ("streamFormat(tsUrl)", "tsSaid", "station.codec", "_previewCodec.indexOf", "relayExtension"):
        assert old not in body, "the start reads the address or the label again: %s" % old
    assert 'if (tsLocal && !tsOgg && tsUrl.indexOf("http") === 0' in body, (
        "the rescue no longer stands by for every stream not known to be Ogg FLAC")
    src = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert ("StreamKind { id: streamKind; app: root; cfg: Plasmoid.configuration; "
            "engine: timeshift; player: playMusic }") in src
    route = "if (streamKind.handleExec(cmd, stdout)) return;"
    assert src.count(route) == 1, "the helper's answer has no way home, or two"
    rescue = src[src.index("id: relayRescue"):]
    rescue = rescue[:rescue.index("id: stallTimer")]
    learn = "streamKind.rescued(src, root._currentOrigUrl);"
    assert learn in rescue and rescue.index(learn) < rescue.index("timeshift.armRelay(src,"), (
        "the rescue no longer tells StreamKind which address needed it")


def test_what_stream_kind_may_move_is_asked_about_first():
    """StreamKind is the one place outside main.qml and the timeshift engine
    that can send a playing station somewhere, and it does so on the helper's
    answer: a plain start to the relay when the stream is Ogg FLAC, and a
    start that took the relay on a guess back to the plain one when it is
    plain FLAC or no Ogg at all. Like every automatic road it may move only
    the order that asked, never over a stop, a park or a night; the way back
    is taken only while the player is not playing, and the check and the
    start sit in one function with nothing between them that waits."""
    src = _code_only((UI / "StreamKind.qml").read_text(encoding="utf-8"))
    assert src.count("engine.armRelay(") == 1, "StreamKind arms the relay from more than one place"
    move = _function_body(src, "_toRelay")
    assert move.index("if (!_alive()) return;") < move.index("engine.armRelay(_url, _name, Date.now(), true);")
    assert src.count("app.startWithFade(") == 1, "StreamKind starts playback from more than one place"
    back = _function_body(src, "_toPlain")
    guess = "if (!_pull || !(engine.relay && engine.active && engine.streamUrl === _url)) return;"
    quiet = "if (app.isPlaying() || !_alive()) return;"
    assert back.index(guess) < back.index(quiet) < back.index("engine.disarm();") < back.index("app.startWithFade("), (
        "the way back to the plain start is taken unasked, or with the relay still armed")
    # The one clock in there holds a question back; nothing waits between an
    # answer and what it moves.
    assert src.count("later.restart();") == 1 and "later.restart();" in _function_body(src, "_wait")
    for part in ("handleExec", "_toRelay", "_toPlain", "_alive"):
        for wait in ("Qt.callLater", "later.", "setTimeout"):
            assert wait not in _function_body(src, part), "%s waits before it moves: %s" % (part, wait)
    alive = _function_body(src, "_alive")
    for door in ("if (app._tsPaused) return false;",
                 "app._previewUrl !== _audition",
                 "app._wantsPlaying !== true",
                 "if (String(app._icyStreamTarget(player.source)) !== _url) return false;",
                 "return !app._orderLapsed();"):
        assert door in alive, "StreamKind's door lost %r" % door
    assert alive.rindex("return") == alive.index("return !app._orderLapsed();"), (
        "the lapse is asked before the order is known to be the one that asked")
    answer = _function_body(src, "handleExec")
    assert "if (_seq < 0 || KindLogic.seqOf(mine) !== _seq) return true;" in answer, (
        "an answer is taken without asking whose question it was")
    assert answer.index("_seq = -1;") < answer.index("_toRelay();") < answer.index("_toPlain();")
    for sound in ("playMusic", "tsPlayLive", "tsPlayRelay", "executable", ".play()"):
        assert sound not in src, "StreamKind reaches for %s" % sound
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    entry = re.search(r'<entry name="streamKinds" type="String">.*?</entry>', xml, flags=re.S)
    assert entry and "<default>{}</default>" in entry.group(0), "the remembered kinds have no config entry"


def test_an_address_written_for_a_question_does_not_outlive_it():
    """StreamKind writes a stream's address into a file and runs the helper,
    which removes the file, on the write's acknowledgement. A question ended
    between the two left the file behind (measured with a real shell: there
    after the late write, gone after the sweep). The sweep's command and its
    cases are under tst_kindlogic and tst_streamkind; held here is that the
    late write is swept by its own number before anything else is asked of
    it, and that the widget's last command takes whatever is still left."""
    src = (UI / "StreamKind.qml").read_text(encoding="utf-8")
    answer = _function_body(src, "handleExec")
    late = answer[answer.index('": SK_URL;"'):answer.index('if (_run === "") return true;')]
    assert "var wrote = KindLogic.seqOf(mine);" in late
    assert "if (_seq < 0 || wrote !== _seq) {" in late
    assert 'KindLogic.buildSweep(base + ".kind" + wrote, wrote)' in late, (
        "a late write is swept by a number other than its own")
    assert "_seq + " not in late and '".kind" + _seq' not in late
    assert 'if (mine.indexOf(": SK_RM;") === 0) return true;' in answer
    ask = _function_body(src, "_ask")
    assert 'urlPath: base + ".kind" + seq' in ask, "the question's file is no longer named by its number"
    main = (UI / "main.qml").read_text(encoding="utf-8")
    icy = r"""_icyUrlFile.replace(/'/g, "'\\''")"""
    last = 'executable.exec("rm -f \'" + ' + icy + """ + "' '" + """ + icy + """ + "'.kind*\""""
    assert last in main, "the widget's last command leaves a question's address file behind"


def test_a_relayed_streams_titles_are_asked_for_on_one_road_at_a_time():
    """A relayed Ogg stream's titles are read from its buffer file. A plain
    FLAC station that ended up in an Ogg shell has none there and sends its
    titles in ICY, so after three empty reads running the poll goes to the ICY
    reader instead (TimeshiftLogic.titleRoad, the engine's titlesInBuffer and
    titleAnswer, under their tests). This pins the two places main.qml hands
    that decision over: which reader a poll starts, and every answer passing
    the engine before it can pin the station as one with no titles."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    poll = _code_only(_function_body(src, "getStreamInfo"))
    assert "if (timeshift.titlesInBuffer(u)) {" in poll
    assert "timeshift.relayOggFamily" not in poll, "the poll picks its reader past the engine"
    code = _code_only(src)
    seen = 'if (timeshift.titleAnswer(cmd.indexOf("--oggbuf") !== -1, formattedText, queryUrl)) return;'
    assert code.count(seen) == 1
    at = code.index(seen)
    assert code.rindex("if (!isPlaying()) {", 0, at) > code.rindex('if (cmd.indexOf("reader.py") < 0) return;', 0, at)
    assert at < code.index('if (formattedText === "__NO_ICY__") {', at) < at + 400, (
        "ICY's no is acted on before the engine has seen it")


def test_m_held_down_is_one_mute():
    """M on the Playing page toggles the mute, and a held key repeats some 25
    times a second: a hold muted, unmuted and muted again, and where it ended
    was the luck of the count (tst_heldkey, on a copy: 26 toggles for a
    second's hold). One press is one toggle. The repeats are swallowed, not
    passed on: the press was the mute's, and what sits above the popup has
    no more claim on its repeats than on the press. On the stations page M
    stays a letter of the search, and a text field keeps it, as before."""
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    branch = full[full.index("} else if (event.key === Qt.Key_M && !_inputFocused() && root.view !== 0) {"):]
    branch = re.sub(r"\s+", " ", branch[:branch.index("} else if (root.view === 0")])
    assert ("{ if (!event.isAutoRepeat) root.setUserVolume(playMusicOutput.volume > 0 ? 0 : root.targetVolume()) "
            "event.accepted = true }") in branch + "}", "a held M toggles the mute with every repeat, or lets its repeats through"


def test_next_previous_and_seek_from_the_desk_stay_inside_an_episode_that_is_held():
    """Next, Previous, Seek and SetPosition asked "an episode's key stands and
    the player plays". An episode paused in place is not playing, so a
    headset's Next put a radio station on over it, and Seek and SetPosition
    did nothing while CanSeek was published as true (on main.qml's own
    functions around a counting player: Pause, Next gave "radio:0").

    Where the four go is TransportLogic.skipRoad, and where the needle lands
    deskNeedle (tst_transportlogic). tst_transportroads walks them through
    the WHOLE dispatcher, and its copy is held here to main.qml's text word
    for word, every branch of it, so a road added to one of the two fails
    here. Held as well: the desk is told it may go next, go back and seek
    from the same answer the dispatch acts on, and the second a pause keeps
    follows a needle that was moved under it."""
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    copy = _code_only((TESTS / "qml" / "tst_transportroads.qml").read_text(encoding="utf-8"))
    for fn in ("_mprisDispatch", "podcastSkip", "transport", "playLast"):
        assert flat(_function_body(main, fn)) == flat(_function_body(copy, fn)), (
            "tst_transportroads walks another %s than main.qml has" % fn)

    asked = ("TransportLogic.skipRoad(_nowPlays, _pausedFile, playMusic.playbackState === MediaPlayer.PausedState, "
             "playMusic.seekable);")
    dispatch = flat(_function_body(main, "_mprisDispatch"))
    state = flat(_function_body(main, "_mprisWriteState"))
    assert "var road = " + asked in dispatch and "var road = " + asked in state, (
        "the dispatch and what the desk is told are answered from different facts")
    assert main.count("TransportLogic.skipRoad(") == 2
    moved = ('var to = road === "skip" ? TransportLogic.deskNeedle(cmd, playMusic.position, playMusic.duration) : -1; '
             "if (to >= 0) { playMusic.position = to; "
             "if (_pausedFile !== null) _pausedFile = TransportLogic.keptAt(_pausedFile, to); _mprisQueueWrite(); }")
    assert moved in dispatch, "a needle moved from the desk leaves the kept second behind, or the desk is not told"
    assert ('} else if (road === "station" && (cmd === "Next" || cmd === "Previous")) { '
            "var k = TransportLogic.stationStep(cmd, lastPlay, stationsModel.count); "
            "if (k >= 0) { lastPlay = k; refreshServer(k); }") in dispatch, (
        "Next or Previous reaches a station on a road that does not ask whether an episode is held")
    assert dispatch.count("refreshServer(") == 1 and "isPlaying()" not in dispatch, (
        "the dispatch asks the player whether it plays, past the one answer")
    for told in ('canGoNext: road === "skip" || (road === "station" && stationsModel.count > 1),',
                 'canGoPrevious: road === "skip" || (road === "station" && stationsModel.count > 1),',
                 'canSeek: road === "skip"'):
        assert told in state, "the desk is told %s apart from what the dispatch does" % told.split(":")[0]
    assert ("if (_pausedFile !== null) _pausedFile = TransportLogic.keptAt(_pausedFile, playMusic.position);"
            in _function_body(main, "podcastSkip")), "the popup's skip buttons leave the kept second behind the needle"


def test_one_level_is_the_listeners_own_for_every_device():
    """What a device is told is worked out from the listener's own level, and
    that was targetVolume(), which read the SAVED level. The save waits a
    second after a gesture. Pair, room 60 %, widget 80 %, balance 0.5: the
    wheel takes the widget to 20 % and the device to 0.060; inside that
    second the room's slider goes to 50 % and the device is sent 0.200, the
    product of the 80 (tst_volumeroad, on a copy; 0.050 is due). The
    device's own row and an unmute inside the second went the same way.

    And after the wake-up alarm on a device that plays alone, the panel's
    wheel counted its notch from the widget's output, which the alarm does
    not touch there: one notch down took the device from 0.200 to 0.375.

    targetVolume() is the one source now, answered by TransportLogic.ownLevel
    (tst_transportlogic): a gesture counts before it is saved, a mute is no
    level, the alarm's level stands, and the stream is never asked. Held
    here: targetVolume is that call; everything that works out a device's
    level reads it; and the wheel is given it where a device plays alone."""
    def flat(text):
        return re.sub(r"\s+", " ", text)

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    full = flat(_code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8")))
    assert flat(_function_body(main, "targetVolume")).strip() == (
        "{ return TransportLogic.ownLevel(_pendingUserVolumePct, _volumeOverridePct, "
        "Plasmoid.configuration.defaultVolume); }"), (
        "the listener's level is worked out past TransportLogic.ownLevel, or from the stream")
    assert main.count("TransportLogic.ownLevel(") == 1
    # The readers: the master's wrapper, the row's answer, a joining device's measure, the tick's re-read.
    assert "_ownMuted, targetVolume()); }" in flat(_function_body(main, "castMaster"))
    assert "playMusicOutput.volume, root.targetVolume(), root._ownMuted)" in full
    assert "root._sinkMasterPct, false, false, root.targetVolume());" in flat(main)
    assert "was, _sinkMasterPct, targetVolume()), true);" in flat(_function_body(main, "castToggleLocal"))
    for fn in ("castMaster", "applyCastTrim", "_castTell", "castToggleLocal"):
        body = _function_body(main, fn)
        assert "defaultVolume" not in body and "playMusicOutput.volume" not in body, (
            "%s works a device's level out of the saved level or the stream, past the listener's own" % fn)
    assert "if (_casting) _castSetVolume(castMaster());" in _function_body(main, "setUserVolume")


def test_a_balance_the_widget_works_out_may_lie_below_the_sliders_five_per_cent():
    """A device's balance was held to 0.05..1 in five places, because 5 % is
    where the row's slider starts. Room 10 %, widget 80 %, balance 0.1: the
    device stands at 0.008; "This computer" is unticked, the exact balance
    against the widget alone is 0.01, the store made it 0.05, and one notch
    DOWN sent the device 0.038. And a balance under 0.05, had one been
    stored, was read back as full level.

    The range of what is stored is 0.001..1 now, and every place that holds
    it agrees: TransportLogic.deviceLevel and rebalance, the engine's
    trimOf, and its two automatic writers, the tick's store-only write and
    the adoption, which take what TransportLogic.balanceBelow cut for them
    and round nothing. The row's slider keeps its own 5 % and its whole per
    cents, for network devices and local sync outputs alike."""
    lib = (UI / "TransportLogic.js").read_text(encoding="utf-8")
    assert lib.count('(typeof balance === "number" && balance >= 0.001 && balance <= 1) ? balance : 1;') == 2, (
        "deviceLevel and rebalance read another range than the store holds")
    assert "return balanceBelow(b * was / now);" in lib and "0.05" not in lib[lib.index("function rebalance("):][:700]
    assert "return Math.max(0.001, Math.min(1, Math.floor(exact * 1e6 + 1e-3) / 1e6));" in lib, (
        "a balance the widget works out is rounded up, or held above what was worked out")

    engine = _code_only((UI / "SyncEngine.qml").read_text(encoding="utf-8"))
    assert 'return (typeof t === "number" && t >= 0.001 && t <= 1) ? t : 1.0;' in _function_body(engine, "trimOf")
    row = _function_body(engine, "setDeviceTrim")
    for line in ("var f = Math.max(stored === true ? 0.001 : 0.05, Math.min(1, factor));",
                 "if (f >= (stored === true ? 1 : 0.995)) delete m[id];",
                 "else m[id] = stored === true ? f : Math.round(f * 100) / 100;"):
        assert line in row, "the row's slider lost its 5 % or its whole per cents, or a stored balance is rounded: %s" % line
    adopt = _function_body(engine, "adoptTrim")
    assert "var f = Math.max(0.001, Math.min(1, factor));" in adopt and "if (f >= 1) return;" in adopt
    assert "Math.round(" not in adopt, "a joining device's share is rounded again, up as often as down"

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert "if (isFinite(ratio)) sync.adoptTrim(adM[1], TransportLogic.balanceBelow(ratio));" in main
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    for key in ("balanceRow.trimKey", "castRow.uuid"):
        at = full.index("onMoved: root.sync.setDeviceTrim(%s, value / 100)" % key)
        assert "from: 5\n" in full[at - 400:at], "the balance slider of %s starts somewhere else than at 5 %%" % key
    assert len(re.findall(r"setDeviceTrim\([^\n]*, true\)", full)) == 0


def test_a_tick_on_this_computer_does_not_reinterpret_a_level_that_still_waits():
    """What a device is told waits 400 ms, and it waits as a MASTER: the
    balance is multiplied in when it goes out. A tick of "This computer"
    inside that window reads the balance against another master, and the
    timer then multiplied the old master by the new balance. Pair, room
    50 %, balance 0.5: the wheel takes the widget to 40 %, the device is due
    0.100, the box is unticked inside the window, and it was sent
    0.20 x 0.25 = 0.050 (tst_volumeroad, on a copy); ticked the other way it
    was sent 0.200.

    The tick sends what waits before it changes anything: a level already
    asked for goes out as it was asked, whoever asked, the alarm's level
    past the room's master and a mute's zero included, and nothing has to
    turn a waiting master into another one. Held here: the timer and the
    tick send through the one function, and the tick does so first."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    tick = _function_body(main, "castToggleLocal")
    assert tick.index("_castFlush();") < tick.index('var was = masterRoadOf("");') < tick.index("if (_castLocalPlay) {"), (
        "the tick changes the balance while a level still waits to be multiplied by it")
    assert main.count("_castFlush()") - main.count("function _castFlush()") == 2, (
        "what waits for the devices is sent on a road besides the timer and the tick")
    assert main.count("_pendingCastVolumePct = -1;") == 1 and main.count("_pendingCastVolumePct / 100") == 1


def test_an_audition_counts_as_coming_until_it_sounds_or_its_ladder_has_spoken():
    """Stop has to see a search result that is on its way to sound, and the
    fact it was given for that was "the result's address stands". The retry
    ladder's last word leaves the address standing, for the row's mark and
    the Playing page's star, and nothing clears it afterwards. A result that
    was dead for good went on counting as coming: on TransportLogic's own
    answers the face was Stop, Play "none" and PlayPause "stop" over a
    widget with nothing on and nothing coming, where an idle widget says
    Play, "bare", "bare".

    The end is marked by the last word itself, the one sentence the ladder
    sets and a start or a stop clears: TransportLogic.auditionComing
    (tst_transportlogic; tst_transportroads walks the roads through
    transport()). The address is not cleared, so everything else that reads
    it after a failure does what it did. Held here: the ninth fact is that
    answer; the ladder's last word is the only thing that ever sets the
    sentence, so no other message can end an audition that is still coming;
    and a new result's click takes the last one's sentence down before
    anything of the new one is on its way."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert ("readonly property bool _previewComing: TransportLogic.auditionComing(_previewUrl, _friendlyError)\n"
            in main), "an audition is on its way for as long as its address stands, dead or not"
    assert main.count("_previewComing") == 2 and main.count("TransportLogic.auditionComing(") == 1

    said = [m.start() for m in re.finditer(r"_friendlyError\s*=[^=]", main)]
    spoken = [at for at in said if not main[at:].startswith('_friendlyError = "";')]
    assert len(spoken) == 1 and _owner_of(main, spoken[0])[0] == "_previewRescueAudition", (
        "something besides the audition's last word sets the sentence that ends an audition")
    owners = sorted(_owner_of(main, at)[0] for at in said if at not in spoken)
    assert owners == ["previewStation", "startWithFade", "stopWithFade"], owners

    click = _function_body(main, "previewStation")
    assert click.index("stopWithFade();") < click.index('root._friendlyError = "";') < click.index("root._previewUrl = url;") \
        < click.index("_playStation("), "the last result's word stands over the next one while it arms"
    word = _function_body(main, "_previewRescueAudition")
    assert "_previewUrl = " not in word, (
        "the last word takes the address with it: the row's dead mark and the Playing page's star read it afterwards")


def test_the_panels_right_click_menu_is_four_entries_on_the_widgets_own_roads():
    """The panel icon's right-click menu has the big button's press, the next
    station, mute and the sleep timer. What an entry shows is
    TransportLogic.panelAction (tst_transportlogic) and what a click does is
    PanelAction.qml against a stand-in (tst_panelaction). Neither test loads
    main.qml, so held here is the list itself, that an entry only calls the
    roads the same controls take elsewhere, and that every name it reads off
    the widget is one the widget has: a renamed property would leave an
    entry silently dead, which no test of the stand-in can see."""
    main = (UI / "main.qml").read_text(encoding="utf-8")
    flat = re.sub(r"\s+", " ", _code_only(main))
    assert ('Plasmoid.contextualActions: [ PanelAction { kind: "key"; app: root }, '
            'PanelAction { kind: "next"; app: root; stations: stationsModel.count }, '
            'PanelAction { kind: "mute"; app: root }, PanelAction { kind: "sleep"; app: root } ]') in flat, (
        "the panel's menu is not the four entries, in their order")
    entry = _code_only((UI / "PanelAction.qml").read_text(encoding="utf-8"))
    assert "TransportLogic.panelAction(kind, app ? {" in entry
    for road in ('app.transport("PlayPause")', 'app._mprisDispatch("Next")', "app.setUserVolume(0)",
                 "app.setUserVolume(app.targetVolume())", "app.startSleepTimer(sleepSeconds)", "app.cancelSleepTimer()"):
        assert road in entry, "the menu no longer takes the road %s" % road
    for past in ("playMusic", "refreshServer", "stopWithFade", "executable", "Plasmoid.configuration"):
        assert past not in entry, "a menu entry reaches for %s past the roads the controls take" % past
    read = set(re.findall(r"\bapp\.(\w+)", entry))
    assert read == {"bigFace", "canPlay", "_podPlayingKey", "_ownMuted", "sleepRemainingSec", "_casting", "isPlaying",
                    "transport", "_mprisDispatch", "setUserVolume", "targetVolume", "startSleepTimer", "cancelSleepTimer"}, read
    for name in sorted(read):
        has = re.search(r"^    (?:readonly )?property [\w<>]+ %s\b|^    function %s\(" % (name, name), main, flags=re.M)
        assert has, "main.qml has no %s for the menu to read" % name


def test_the_output_menus_volume_row_says_what_it_turns():
    """On the default output the row is the system's volume and moves every
    application's sound; it used to say "Volume" and nothing else. Which of
    the three names applies is TransportLogic.volumeName, under its tests.
    Held here: the caption asks that function with the row's own facts, each
    name has its words, and the slider is announced by the same name, so a
    screen reader's user is told what a sighted one reads."""
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    code = _code_only(src)
    assert ("readonly property string word: TransportLogic.volumeName(root.masterRoadOf(\"\"), "
            "root._casting, root._castLocalPlay)") in code, "the caption names the row from other facts than the row's"
    assert ('text: word === "system" ? i18n("System volume") : (word === "device" ? i18n("Device volume") '
            ': i18n("On Air volume"))') in code
    row = code[code.index("id: masterVolumeSlider"):]
    row = row[:row.index("PlasmaComponents3.Label")]
    assert "Accessible.name: volumeCaption.text" in row, "the slider is announced by another name than the one shown"
    assert code.index("id: volumeCaption") < code.index("id: masterVolumeSlider"), "the name stands under the row it names"



def test_the_stations_factor_sits_in_one_place_and_in_no_number_a_listener_sees():
    """Stations differ by up to 13 dB, and a loud one is turned down by a
    factor (LoudLogic.js has the measurement). Some thirty places read and
    write the player's volume as the listener's own level: the slider, the
    wheel, M, MPRIS, the saved default, three fades, the calibration's mute, a
    device's master. Had the factor gone into any of them it would have shown
    in a slider, been saved as somebody's default or been sent to a
    television. So the name they all use is the listener's level and nothing
    else, and the output itself is bound to that level times the factor, in
    one line that nobody writes. Held here: the one line, that the real
    output has no other reader or writer, and that the factor is read
    nowhere else in the widget."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    bound = "audioOutput: AudioOutput { id: playMusicSink; volume: playMusicOutput.volume * loudness.gain }\n"
    assert bound in main, "the output no longer plays the listener's level times the station's factor"
    assert main.count("AudioOutput {") == 1, "the player has a second output, or one the factor is not on"
    assert main.count("playMusicSink") == 2, "something beside the level's own device alias reaches the real output"
    level = main[main.index("    QtObject {\n        id: playMusicOutput\n"):]
    level = level[:level.index("\n    }\n")]
    for line in ("property alias device: playMusicSink.device\n", "property real volume: 1\n",
                 "Component.onCompleted: volume = root.targetVolume()\n"):
        assert line in level, "the listener's level lost %r" % line.strip()
    assert "loudness" not in level and "gain" not in level, "the factor is in the listener's own level"
    assert main.count("loudness.gain") == 1, "the factor is read a second time in main.qml"
    for path in sorted(UI.rglob("*.qml")):
        code = _code_only(path.read_text(encoding="utf-8"))
        if path.name == "main.qml":
            assert sorted(set(re.findall(r"\bloudness\.(\w+)", code))) == ["gain", "handleExec"], (
                "main.qml asks the loudness engine for more than its factor and its exec answers")
        elif path.name != "Loudness.qml":
            assert "playMusicSink" not in code, "%s reaches the real output" % path.name
            assert not re.search(r"\bloudness\.\w", code), "%s reads the station's factor" % path.name
    assert "            volume: playMusicOutput.volume,\n" in _function_body(main, "_mprisWriteState"), (
        "the desk is told another level than the listener's own")


def test_the_loudness_engine_has_its_instance_its_answers_and_its_sweep():
    """Loudness.qml asks a helper how loud a station is, in two commands,
    and ends a reading by removing its file. Its rules are under
    tst_loudlogic and its behaviour under tst_loudness, both against
    stand-ins; held here is that main.qml gives it the real neighbours, that
    a command's answer reaches it once, and that the widget's last command
    removes whatever file a reading still had: a helper holds on to that
    file, so with the file gone no helper outlives the widget either."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert ("Loudness { id: loudness; app: root; cfg: Plasmoid.configuration; kind: streamKind; "
            "engine: timeshift; player: playMusic }") in main
    route = "if (loudness.handleExec(cmd, stdout)) return;"
    assert main.count(route) == 1, "the helper's answer has no way home, or two"
    assert main.index("if (streamKind.handleExec(cmd, stdout)) return;") < main.index(route)
    last = _function_body(main[main.index("Component.onDestruction:"):].replace("Component.onDestruction:", "function last()", 1), "last")
    sweep = '+ " " + PodcastLogic.shQuote(_icyUrlFile) + ".loud* \'"'
    assert sweep in last, "the widget's last command leaves a reading's file, and with it its helper, behind"
    for fact in ("exec", "nextSeq", "_icyUrlFile", "_currentOrigUrl", "_previewUrl", "_podPlayingKey", "_podStarting",
                 "_volumeOverridePct", "_wantsPlaying", "_tsPaused", "_healPendingUrl", "_healBackupFor", "recording",
                 "_casting", "_castLocalPlay", "isPlaying", "_icyStreamTarget"):
        has = re.search(r"^    (?:readonly )?property [\w<>]+ %s\b|^    function %s\(" % (fact, fact), main, flags=re.M)
        assert has, "main.qml has no %s for the loudness engine to read" % fact
    src = _code_only((UI / "Loudness.qml").read_text(encoding="utf-8"))
    read = set(re.findall(r"\bapp\.(\w+)", src))
    assert read == {"exec", "nextSeq", "_icyUrlFile", "_currentOrigUrl", "_previewUrl", "_podPlayingKey", "_podStarting",
                    "_volumeOverridePct", "_wantsPlaying", "_tsPaused", "_healPendingUrl", "_healBackupFor", "recording",
                    "_casting", "_castLocalPlay", "isPlaying", "_icyStreamTarget"}, read
    assert "casting: app._casting, local: app._castLocalPlay," in src, (
        "the factor no longer stands aside while a device plays along")
    assert "readonly property bool busy: _seq >= 0 || _waitUrl !== \"\"\n" in (UI / "StreamKind.qml").read_text(encoding="utf-8")
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    switch = re.search(r'<entry name="evenLoudness" type="Bool">.*?</entry>', xml, flags=re.S)
    assert switch and "<default>false</default>" in switch.group(0), "evening out is on unasked, or has no entry"
    kept = re.search(r'<entry name="stationLoudness" type="String">.*?</entry>', xml, flags=re.S)
    assert kept and "<default>{}</default>" in kept.group(0), "the readings have no config entry"


def test_the_loudness_engine_moves_no_sound_and_writes_no_command_of_its_own():
    """The engine's one output is a number. It starts nothing, stops
    nothing and sets no volume: a reading that arrives late, or for a station
    the listener has left, must not be able to do more than change that
    number, and the number is eased while the player plays. Every command it
    runs is built by LoudLogic, where the quoting is PodcastLogic.shQuote's
    and under tests; and an answer is taken only for the reading in flight,
    so one that was ended cannot write a number down or stamp a station as
    silent."""
    src = _code_only((UI / "Loudness.qml").read_text(encoding="utf-8"))
    for reach in ("playMusic", ".volume", "executable", ".play()", "player.stop", "startWithFade", "setUserVolume", "targetVolume"):
        assert reach not in src, "the loudness engine reaches for %s" % reach
    assert set(re.findall(r"\bplayer\.(\w+)", src)) == {"source"}, "the engine asks more of the player than its source"
    assert len(re.findall(r"(?<![\w.])cutNow\s*=[^=]", src)) == 1, "the cut is set outside _follow"
    follow = _function_body(src, "_follow")
    assert "cutNow = wanted;" in follow and 'property: "cutNow"' in src
    assert "    readonly property real gain: LoudLogic.factor(cutNow)\n" in src, (
        "the factor is no longer made of the eased cut alone")
    assert follow.index("if (atOnce || !app || !app.isPlaying()) {") < follow.index("ease.restart();"), (
        "the factor is eased under a silent player, or set in one step under a playing one")
    assert "function onSourceChanged() {\n            loud._follow(true);" in src, "a new source no longer has its factor at once"
    assert "onWantedChanged: _follow(false)\n" in src
    for raw in ("rm -f", "printf", "python3", "umask", "replace(/'/g", "shQuote"):
        assert raw not in src, "the loudness engine writes shell of its own: %s" % raw
    sent = re.findall(r"app\.exec\(([^)]*)\)", src)
    assert sorted(sent) == ["cmd", "cmds.write", "run", "sweep"], sent
    logic = (UI / "LoudLogic.js").read_text(encoding="utf-8")
    assert "replace(/'/g" not in logic and logic.count("PodcastLogic.shQuote") == 2, (
        "LoudLogic quotes for the shell by hand")
    answer = _function_body(src, "handleExec")
    guard = "if (_seq < 0 || KindLogic.seqOf(mine) !== _seq) return true;"
    assert answer.index(guard) < answer.index("_remember(_key, LoudLogic.answerOf(stdout));"), (
        "an answer is written down without asking whose reading it was")
    late = answer[answer.index('": LD_URL;"'):answer.index('if (_run === "") return true;')]
    assert "if (_seq < 0 || wrote !== _seq) {" in late
    assert 'LoudLogic.buildEnd(base + ".loud" + wrote, wrote)' in late, "a late write is swept by a number other than its own"
    assert "_seq + " not in late and "_path" not in late
    assert 'path = base + ".loud" + seq;' in _function_body(src, "_ask"), "a reading's file is no longer named by its number"
    begin = _function_body(src, "_begin")
    assert begin.index("if (!mayAsk) return;") < begin.index("if (_seq >= 0) {") < begin.index("if (kind && kind.busy)") \
        < begin.index("LoudLogic.due(") < begin.index("_ask("), "a station is asked about out of turn"
    assert src.count("_ask(") == 2 and src.count("_end()") == 4, "a reading starts or ends on a road nobody listed"


def test_the_words_about_loudness_say_the_numbers_the_rules_use():
    """The option's sentence and the config entry's label name twenty
    seconds, -18 LUFS, 15 dB and five readings. Those are LoudLogic's
    constants, which rest on a measurement; a constant changed without its
    words would have the settings page promise one thing and the widget do
    another. The sentence said "once" while a station was read once; it is
    read on several days now, and at most once a day is what stays true."""
    logic = (UI / "LoudLogic.js").read_text(encoding="utf-8")

    def number(name):
        found = re.search(r"^var %s = (-?\d+);" % name, logic, flags=re.M)
        assert found, "LoudLogic.js names no %s" % name
        return found.group(1)

    def said(pattern, text, what):
        found = re.search(pattern, text)
        assert found, "%s has no words" % what
        return found.group(1)

    page = (UI / "config" / "configAppearance.qml").read_text(encoding="utf-8")
    assert "property alias cfg_evenLoudness: evenLoudnessCheck.checked\n" in page
    audio = page[page.index('Kirigami.FormData.label: i18n("Audio")'):page.index('Kirigami.FormData.label: i18n("Visuals")')]
    box = audio[audio.index("id: evenLoudnessCheck"):audio.index("id: autoBitrateCheck")]
    assert 'text: i18n("Even out loudness between stations")' in box
    words = said(r'QQC2\.Label \{\s*text: i18n\("([^"]+)"\)', box, "the option")
    assert "for %s seconds" % number("LISTEN_S") in words and "on this computer" in words, words
    assert "at most once a day" in words and "listened to once" not in words, words
    assert number("RETRY_S") == "86400", "a day is no longer what lies between two readings"
    assert words.count(".") == 1 and words.endswith("."), "the option is explained in more than one sentence"
    xml = (ROOT / "package" / "contents" / "config" / "main.xml").read_text(encoding="utf-8")
    label = said(r'<entry name="evenLoudness" type="Bool">\s*<label>([^<]+)</label>', xml, "the option's entry")
    for part in ("louder than %s LUFS" % number("TARGET_LUFS"), "by %s dB at most" % number("MAX_CUT_DB"),
                 "for %s seconds" % number("LISTEN_S"), "none is turned up", "at most once a day",
                 "until %s readings are kept" % number("KEEP")):
        assert part in label, "the entry's label no longer says %r" % part
    kept = said(r'<entry name="stationLoudness" type="String">\s*<label>([^<]+)</label>', xml, "the readings' entry")
    assert "At most %s addresses" % number("CAP") in kept and "up to %s readings" % number("KEEP") in kept


# ───────────────────────── the sliding buffer (2026.44) ─────────────────────
#
# An MP3 or AAC station's pause buffer is a folder of two-second segments and
# the player is handed a list of them. Measured on Qt 6.12 with FFmpeg 9: a
# player stopped on a list whose reader has run out of segments returns from
# stop() and then holds the whole widget until the list grows; with the
# source cleared first it lets go in 4 to 13 ms. What main.qml owes that
# road cannot be called by a test, so it is pinned here as text.


def test_a_device_that_refused_the_stream_is_not_cast_to():
    """"Casting" was raised when the play command went out and nothing took
    it down: a Ruark R5se that refused two stations (UPnP 716, 2026-11-11)
    left "Casting to Ruark R5se" over a silent room for more than four
    minutes. Who was asked and who answered is CastLogic (tst_castlogic);
    tst_castroads walks main.qml's own cast functions through the refusals,
    and its copy is held here to main.qml's text word for word. Held as
    well, because the copy cannot see them: every play answer goes to
    _castAnswer, every play command is recorded as an attempt, the flag is
    raised and lowered in one place each, an unticked device leaves the
    record, and the footer names the refusal while nothing sounds here.

    Two more roads, met the same evening. With a television playing and
    the Ruark refused, unticking the television left the flag up over an
    empty record and "Casting to Ruark R5se" came back: the flag follows
    the record now, also when ticks are still up. And the refusal's name
    outlived the attempt it was about: a file from My Music played and
    paused afterwards read "Could not cast to Ruark R5se" where it should
    read "Paused". The name is not kept when the station sounds here, and
    the player being handed something else, or starting, takes it down (it
    is only ever kept over silence, so the handler need not ask which way
    the player moved)."""
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    copy = _code_only((TESTS / "qml" / "tst_castroads.qml").read_text(encoding="utf-8"))
    for fn in ("_castEnd", "_castPlayOn", "_castPlay", "_castAnswer", "castToggleDevice", "castDisconnect", "castRefused"):
        assert flat(_function_body(main, fn)) == flat(_function_body(copy, fn)), (
            "tst_castroads walks another %s than main.qml has" % fn)

    assert main.count('if (cmd.indexOf(": CAST_PLAY;") === 0) { root._castAnswer(cmd, stdout); return; }') == 1, (
        "a play command's answer is read past _castAnswer")
    assert main.count("_castAnswer(") == 2, "_castAnswer is called from somewhere the record does not know"

    asked = flat(_function_body(main, "_castPlayOn"))
    assert main.count('_castExec("CAST_PLAY"') == 2 and asked.count('_castExec("CAST_PLAY"') == 2, (
        "a play command goes out past _castPlayOn, so its answer would find nobody waiting")
    assert asked.endswith('_castSession = CastLogic.tried(_castSession, dev.uuid, _execSeq); _castFailedName = ""; }'), (
        "a device is asked to play without the attempt being recorded")

    assert len(re.findall(r"\b_casting = false\b", main)) == 1 and "_casting = false;" in _function_body(main, "_castEnd"), (
        "the casting flag is lowered past _castEnd, which also ends the record")
    assert len(re.findall(r"\b_casting = true\b", main)) == 1 and "_casting = true;" in _function_body(main, "_castPlay")

    toggle = flat(_function_body(main, "castToggleDevice"))
    assert '_castSession = CastLogic.left(_castSession, dev.uuid); _castFailedName = "";' in toggle, (
        "an unticked device stays in the record and its late answer is believed")
    assert toggle.index("CastLogic.left(") < toggle.index("if (!CastLogic.carried(_castSession)) _castEnd();") < toggle.index(
        "if (targets.length === 0) {"), "the flag is asked about the ticks, not about who still carries the stream"

    heard = 'root._castFailedName = "";'
    for handler, end in (("onSourceChanged: {", "onErrorOccurred:"), ("onPlayingChanged: {", "_mprisQueueWrite()")):
        edge = main[main.index(handler):]
        assert heard in edge[:edge.index(end)], "the player's %s leaves a device's old refusal standing" % handler[:-3]
        assert "%s %s }" % (handler, heard) in copy, "tst_castroads no longer says what main.qml's player says in %s" % handler[:-3]

    face = flat(_code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8")))
    word = ('if (root._casting || (root._castFailedName !== "" && !isPlaying())) { return root._casting '
            '? i18n("Casting to %1", root._castName) '
            ': root._castFailedRefused ? i18n("%1 cannot play this station", root._castFailedName) '
            ': i18n("Could not cast to %1", root._castFailedName) }')
    assert word in face, "the footer does not say that the device refused, or says it of one that could not be reached"
    assert word in flat(copy), "tst_castroads reads another footer than the popup shows"


def _flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def test_a_pause_inside_the_sliding_buffer_lets_the_player_go_source_first():
    src = (UI / "main.qml").read_text(encoding="utf-8")
    body = _function_body(src, "timeshiftPause")
    assert "if (!timeshift.parkInPlace()) playMusic.pause();" in body, (
        "a pause inside the buffer no longer asks the engine whether it is on a list")
    assert ('else { root._tsPaused = true; alarmEngine.standDown(); playMusic.source = ""; playMusic.stop(); }'
            in body), (
        "the park inside a list no longer clears the source before the stop: stopped "
        "first, a reader that has run dry holds the widget until the list grows")
    assert body.index("timeshift.parkInPlace()") < body.index("if (_casting || _podPlayingKey"), (
        "the shifted branch is no longer the first answer of the pause")
    # A new open and a new start leave a list the same way round they always
    # did, in one turn of the loop, which the reader survives (6 to 150 ms).
    for owner in ("tsPlayBuffer", "startWithFade"):
        assert 'playMusic.stop(); playMusic.source = "";' in _flat(_function_body(src, owner)), (
            "%s no longer clears the source right after the stop" % owner)


def test_the_player_is_asked_about_a_list_before_it_is_sought():
    src = (UI / "main.qml").read_text(encoding="utf-8")
    line = "if (timeshift.sourceLoaded(playMusic.seekable, playMusic.duration)) playMusic.position = seekMs;"
    assert src.count(line) == 1, "the pending seek no longer goes through the engine's one check"
    assert "playMusic.position = root._tsPendingSeekMs" not in src, (
        "a pending seek is made without asking whether this player can search a list")
    # The raw text here: _code_only cuts a line at the "//" of "file://".
    fell = ('if (playMusic.source.toString() === "file://" + timeshift.bufPath '
            "&& timeshift.listPlaybackFell(Date.now())) return;")
    assert src.count(fell) == 1, "a player error on a list no longer goes to the engine"
    at = src.index("onErrorOccurred: {")
    handler = src[at:at + 6000]
    assert handler.index("if (fadeOutAnimation.running) return;") < handler.index(fell) < handler.index("healTimer.restart()"), (
        "the list's error is no longer taken after Stop's fade and before the heal ladder")


def test_how_far_behind_is_read_off_the_engine():
    src = (UI / "main.qml").read_text(encoding="utf-8")
    assert ("function tsBehindText(posMs) { return timeshift.behindText(_tsPaused ? timeshift.shiftPosMs : posMs, Date.now()); }"
            in src), "the pill no longer reads the engine's clock"
    assert "behindLiveMs" not in src, "main.qml does the single file's sum itself again"
    assert "function tsKnownKind(url) { return streamKind.known(url); }" in src, (
        "the engine can no longer ask what StreamKind learnt of an address")
    assert "var pos = timeshift.pauseGesture(Date.now(), playMusic.position);" in _function_body(src, "timeshiftPause"), (
        "a pause no longer tells the engine where the player is: the park would be "
        "the writer's clock, which ran 4.2 s ahead of the sound on the bench")
    assert "timeshift.noteLivePlayback(Date.now());" in _function_body(src, "startWithFade"), (
        "a start that keeps its buffer no longer dates the player's new beginning")
    eng = (UI / "TimeshiftEngine.qml").read_text(encoding="utf-8")
    # goneMs: the broadcast goes on after a capture has ended, and the pill
    # reads the distance to it, not to the end of what was kept.
    assert ("if (slide) return SlideLogic.clockText(SlideLogic.behindMs(runMs + goneMs - liveLagMs, shifted ? placeMs : shiftPosMs));"
            in _function_body(eng, "behindText"))


def test_the_sleep_timer_ends_a_park_in_the_sliding_buffer():
    """The single file's writer ends by its window's cap. The segment writer
    has none: a park left over a night would be cut and deleted until Stop."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    assert ("if (isPlaying() || _casting || _wantsPlaying || (root._tsPaused && timeshift.slide)) stopWithFade();"
            in src), "the sleep timer's end leaves a park in the sliding buffer recording"


def test_the_engine_leaves_a_list_by_its_own_clock_and_stops_through_the_folders_own_command():
    eng = (UI / "TimeshiftEngine.qml").read_text(encoding="utf-8")
    beat = _function_body(eng, "_beat")
    assert "if (SlideLogic.mustLeave((listLast + 1) * SlideLogic.SEG_MS, placeMs)) {" in beat, (
        "the engine no longer leaves a list before its reader runs dry")
    assert beat.index("SlideLogic.mustLeave(") < beat.index("backToLive("), "leaving a list is no longer a return to live"
    assert "if (app.isPlaying()) placeMs += heard;" in beat, "the place moves while the player is silent"
    assert "if (writerUp) runMs += ran;" in beat, "the writer's clock runs on after the writer ended"
    for other in ("Date.now()", "player.position", "playMusicRef"):
        assert other not in _code_only(beat), "the beat reads %s instead of the clock it is handed" % other
    stop = _function_body(eng, "disarm")
    assert stop.index("SlideLogic.buildStop(") < stop.index("TimeshiftLogic.buildStopCommand("), (
        "a cutting arm is no longer stopped by the command that takes its lists first")
    assert "var looks = !isRelay && !slideOff && _slideDead[url] !== true" in _function_body(eng, "armCommon"), (
        "the fallback is no longer remembered for the session, or for the station whose writer ended")
    fell = _function_body(eng, "_slideFell")
    assert fell.index("slideOff = true;") < fell.index("disarm()") < fell.index("app.tsPlayLive(live)"), (
        "the fallback no longer gives the road up before it plays the broadcast")
    at = eng.index("id: tsHorizonWatch")
    assert "running: engine.shifted && !engine.slide" in eng[at:at + 200], (
        "the single file's watchdog runs over a list, whose position stands still by design")


def test_a_step_is_a_pause_and_a_play_through_the_one_door():
    """Thirty seconds back from the broadcast is a park and a resume with the
    park moved in between. Both go through transport(), so that a step takes
    down and puts up exactly what a pause and a play do: the recovery timers,
    the standing order, the wake-up. A step that parked on its own would be a
    second pause to keep in step with the first."""
    main = (UI / "main.qml").read_text(encoding="utf-8")
    body = _function_body(main, "timeshiftStep")
    guard = "if (live && (ms > 0 || !tsPauseAvailable || !isPlaying())) return;"
    assert guard in body, (
        "a step from the broadcast is taken where the pause would be a stop, or forward, where there is nothing ahead")
    order = [body.index(guard), body.index('if (live) transport("Pause");'),
             body.index("timeshift.stepGesture(ms, Date.now())"), body.index('transport("Play")')]
    assert order == sorted(order), "the step no longer parks, moves the park and plays, in that order"
    assert 'if (timeshift.stepGesture(ms, Date.now()) && live) transport("Play");' in body, (
        "a step the engine refused is played anyway, or a step inside the buffer is played twice")
    for road in ("timeshiftPause(", "timeshiftResume(", "playMusic.", "startWithFade(", "tsPlayLive(", "tsPlayBuffer("):
        assert road not in body, "the step goes round transport() through %s" % road
    assert main.count("timeshiftStep(") == 1, "something in main.qml steps on its own: a timer, a key, the desk"
    callers = []
    for path in sorted(UI.rglob("*.qml")):
        if path.name != "main.qml":
            callers += [(path.name, line.strip()) for line in path.read_text(encoding="utf-8").split("\n")
                        if "timeshiftStep(" in line]
    assert callers == [("FullRepresentation.qml", "onStep: (ms) => root.timeshiftStep(ms)")], callers


def test_the_steps_are_offered_where_a_sliding_buffer_can_take_them():
    main = _flat((UI / "main.qml").read_text(encoding="utf-8"))
    assert ('readonly property bool tsStepReady: timeshift.steppable && !_casting && _podPlayingKey === "" '
            "&& (tsPauseAvailable || timeshift.shifted || _tsPaused)") in main, (
        "the steps are offered over a cast, an episode or a buffer no open can land in")
    full = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    assert full.count("ShiftPill {") == 1 and "tsPill" not in full, "the Playing page has two pills, or the old one"
    at = full.index("ShiftPill {")
    pill = full[at:at + 700]
    for line in ("shifted: root.tsShifted", "parked: root._tsPaused", "stepReady: root.tsStepReady",
                 "behindOf: function() { return root.tsBehindText(playMusic.position) }",
                 "onLive: root.timeshiftBackToLive()", "onStep: (ms) => root.timeshiftStep(ms)"):
        assert line in pill, "the pill is no longer told %r" % line
    # Whether the page is on screen is told by whatever the page itself goes
    # by; only that the pill is told is held here, not in which words.
    assert re.search(r"\n\s+open: root\.\w+\n", pill), "the pill is no longer told whether its page is shown"


def test_the_face_asks_whether_it_is_on_screen_in_one_place():
    """The face priced its animations and timers by root.expanded, which is
    Plasma's popup and nothing else, in 21 places over four files. In a
    window of its own it would have stood still, and kept running in a
    popup that only holds a placeholder. They all read root.faceShown, and
    the one rule behind it is WindowLogic.faceShown (tst_windowlogic), fed
    by the window house with the popup's state; the panel icon still writes
    expanded, because the popup is what a click on it opens."""
    for path in sorted(UI.rglob("*.qml")):
        if path.name in ("main.qml", "CompactRepresentation.qml"):
            continue
        assert "root.expanded" not in path.read_text(encoding="utf-8"), (
            "%s asks Plasma's popup whether the face is on screen" % path.name)
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert "    readonly property bool faceShown: playerWindow.faceShown\n" in main, (
        "main.qml answers for itself whether the face is on screen")
    assert re.findall(r".*\bexpanded\b.*", main) == [
        "        popupOpen: root.expanded; planar: root.planar; cfg: Plasmoid.configuration; hovered: root.faceHovered"], (
        "main.qml reads the popup's state somewhere besides the line that hands it to the window house")
    house = (UI / "PlayerWindow.qml").read_text(encoding="utf-8")
    assert "    readonly property bool faceShown: WindowLogic.faceShown(popupOpen, visible)\n" in house, (
        "the house no longer asks the tested rule, or asks it about something other than its own visibility")
    assert "root.faceShown" in (UI / "FullRepresentation.qml").read_text(encoding="utf-8")


def test_the_popup_is_given_a_seat_and_the_house_builds_one_face():
    """Plasma parents, sizes and focuses whatever main.qml names as the full
    representation. That item is the seat (PopupFace.qml), so the face is
    free to sit in the window instead. The face is built by the window house
    (PlayerWindow.qml), which lives as long as the applet; tst_playerwindow
    holds how the two seats take it in turn. Two faces would be two search
    fields, two sets of probes and two key handlers on one player, and two
    houses two windows, so main.qml names one of each and nobody else any."""
    main = _no_comments((UI / "main.qml").read_text(encoding="utf-8"))
    assert main.count("fullRepresentation:") == 1 and "    fullRepresentation: PopupFace { house: playerWindow }\n" in main, (
        "Plasma's popup is handed something other than the seat, or the seat no house")
    assert len(re.findall(r"\bFullRepresentation \{", main)) == 1, "main.qml builds no face, or more than one"
    assert len(re.findall(r"\bPlayerWindow \{", main)) == 1 and "        id: playerWindow\n" in main
    assert "        face: FullRepresentation { anchors.fill: parent; focus: true }\n" in main, (
        "the face no longer fills its seat, or no longer takes the keyboard the seat hands it")
    for path in sorted(UI.rglob("*.qml")):
        if path.name == "main.qml":
            continue
        code = _no_comments(path.read_text(encoding="utf-8"))
        assert not re.search(r"\b(PlayerWindow|FullRepresentation|PopupFace) \{", code), (
            "%s builds a face, a seat or a window house of its own" % path.name)


def test_the_headers_corner_moves_the_face_and_keeps_the_pin():
    """FullRepresentation.qml cannot be driven in a test. The corner's two
    buttons are SeatButtons.qml, under tst_seatbuttons; this pins what the
    face tells them and what their two signals do. The window button flips
    the house's wish, which is the one thing that moves the face; the pin
    writes the config key main.qml's hideOnWindowDeactivate reads."""
    full = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    assert full.count("SeatButtons {") == 1 and "pinButton" not in full
    at = full.index("SeatButtons {")
    corner = full[at:full.index("}", at)]
    for line in ("planar: root.planar", 'inWindow: playerWindow.seat === "window"', "pinned: Plasmoid.configuration.pin",
                 "onPinToggled: (on) => Plasmoid.configuration.pin = on",
                 "onMoveAsked: playerWindow.detached = !playerWindow.detached"):
        assert line in corner, "the corner is no longer told %r" % line
    assert "anchors.rightMargin: Kirigami.Units.smallSpacing * 1.5 + seatButtons.width\n" in full, (
        "the heading runs under the corner's buttons")
    assert full.count("playerWindow.detached") == 2, "something else in the face moves it between its seats"
    assert "    hideOnWindowDeactivate: !Plasmoid.configuration.pin\n" in (UI / "main.qml").read_text(encoding="utf-8")


def test_the_windows_three_keys_start_as_no_window_and_no_size():
    """The house keeps three config keys (tst_playerwindow drives it with a
    stand-in config): whether the face was in the window, and the window's
    width and height. The names it reads have to be the names the schema
    declares, or the wish and the size are forgotten at every restart with
    nothing to say why. A fresh install starts in the popup, and 0 is the
    size nobody has chosen yet (WindowLogic.sizeFor falls back to the
    face's own wish)."""
    xml = (UI.parent / "config" / "main.xml").read_text(encoding="utf-8")
    house = _code_only((UI / "PlayerWindow.qml").read_text(encoding="utf-8"))
    for key, kind, default in (("detached", "bool", "false"), ("windowWidth", "Int", "0"), ("windowHeight", "Int", "0")):
        head = '<entry name="%s" type="%s">' % (key, kind)
        assert xml.count(head) == 1, "the schema has no %s, or two" % key
        entry = xml[xml.index(head):]
        assert "<default>%s</default>" % default in entry[:entry.index("</entry>")], (
            "a fresh install starts with %s set" % key)
        assert "cfg.%s" % key in house, "the house no longer reads or writes %s" % key
    assert set(re.findall(r"\bcfg\.(\w+)", house)) == {"detached", "windowWidth", "windowHeight"}, (
        "the house touches a config key this test does not know")


def test_the_faces_tooltips_are_drawn_in_the_window_the_face_is_in():
    """PlasmaCore.ToolTipArea shows its tip as a window of its own and places
    it by the item's position inside its window, read as a place on the
    screen. That is right in Plasma's popup; in the player's own window the
    Stop button at (800, 686) got its tip at (162, 473). Every tip of the
    face is a PlasmaComponents3.ToolTip now, drawn inside whichever window
    the face sits in (the round button's is under tst_buttontip). The panel
    icon keeps its ToolTipArea: it never leaves the panel.

    A row's own tip stands back while the pointer is on one of the row's
    buttons, or the two tips would lie on top of each other; the old kind
    showed one at a time by itself."""
    users = sorted(path.name for path in UI.rglob("*.qml")
                   if "ToolTipArea {" in _no_comments(path.read_text(encoding="utf-8")))
    assert users == ["CompactRepresentation.qml"], "a ToolTipArea in the face: %s" % users
    full = _flat((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    for tip in ("PlasmaComponents3.ToolTip { visible: webHover.hovered && !webStar.pointed text: webItem.isPreviewing",
                "PlasmaComponents3.ToolTip { visible: histHover.hovered && !histGet.pointed && !histDrop.pointed text: i18n(",
                'PlasmaComponents3.ToolTip { text: i18n("Playback speed — tap to change") }',
                'PlasmaComponents3.ToolTip { text: i18n("Results are limited to %1 — tap to search everywhere again", '
                "fullRepresentation.webScopeName) }"):
        assert tip in full, "the face lost a tip, or a row's tip no longer stands back for its buttons: %r" % tip[:60]
    for ident in ("id: webStar", "id: histGet", "id: histDrop"):
        assert full.count(ident) == 1, ident


def test_a_pause_a_window_old_ends_the_capture_and_the_footer_says_what_is_true():
    """2026.44: a parked station's writer used to run until Stop. It ends when
    the pause is about to leave the window, what was cut stays, and the
    footer stops saying that live radio is being buffered."""
    eng = (UI / "TimeshiftEngine.qml").read_text(encoding="utf-8")
    beat = _function_body(eng, "_beat")
    ends = ('if (slide && writerUp && !shifted && _stage === "" '
            "&& SlideLogic.parkEndsCapture(shiftPosMs, runMs, keepMs)) _endCapture();")
    assert ends in beat, "a parked place is pushed out of the window again, or a listener inside the buffer loses its writer"
    assert "else if (slideFrozen) goneMs += ran;" in beat, "the pill of a buffer that no longer grows stands still"
    assert beat.index("if (writerUp) runMs += ran;") < beat.index(ends) < beat.index("if (!slide || !shifted) return;"), (
        "the park is looked at before the clock has moved, or only for a listener inside the buffer")
    end = _function_body(eng, "_endCapture")
    order = [end.index("SlideLogic.buildEnd("), end.index("writerUp = false;"), end.index("slideFrozen = true;")]
    assert order == sorted(order), "the capture's end no longer signals the writer and keeps the folder for the park"
    for gone in ("disarm(", "buildStop(", "reset("):
        assert gone not in end, "the capture's end takes the buffer away (%s): Play would have nothing to come back to" % gone
    assert "keepMs = SlideLogic.listSize(windowMin) * SlideLogic.SEG_MS;" in _function_body(eng, "armCommon"), (
        "the engine no longer knows how much its folder keeps")
    main = (UI / "main.qml").read_text(encoding="utf-8")
    assert "readonly property bool tsBuffering: _tsPaused && timeshift.writerUp" in main
    full = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    assert full.count('i18n("Paused — still buffering live radio")') == 1 and "keeps recording" not in full, (
        "the footer calls the buffer a recording, which is the word for files the listener keeps")


def test_the_picture_a_device_is_sent_is_chosen_in_one_place():
    """A station's start sent station.favicon, the list icon. One station's
    was measured on 2026-11-11: a JPEG of 32 by 32 pixels, 1010 bytes,
    stretched over a television. The other road, _castArt, gave up when its
    first candidate was no http(s) address instead of trying the next.

    Which picture goes out is CastLogic.picture (tst_castlogic). What
    main.qml owes it is that every stream sent to a device asks it, and is
    handed only what belongs to that stream: the episode's cover while the
    episode is the source, and at a station's start the cover on screen only
    when the station starting is the one already on. A switch to another
    station finds the previous station's track still up there.
    """
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    art = flat(_function_body(main, "_castArt"))
    assert "&& playMusic.source.toString() === _podPlayingUrl;" in art, (
        "an episode's cover is cast without asking whether the episode is what plays")
    assert art.endswith('return CastLogic.picture(isPod ? _podPlayingArt : "", trackArtUrl, currentStationFavicon); }'), (
        "_castArt chooses the picture itself again")

    start = flat(_function_body(main, "startWithFade"))
    assert ('_castPlay(castUrl, station.name || "", CastLogic.picture("", station.name === root.currentStation '
            '? root.trackArtUrl : "", station.favicon));') in start, (
        "a station's start sends its devices a picture CastLogic.picture did not choose, "
        "or a cover that belongs to the station before it")

    sent = re.findall(r"\b_castPlay(?:On)?\((?!dev, url, name, art\) \{|url, name, art\) \{)[^;]*;", flat(main))
    assert len(sent) == 4, "a stream is sent to a device from a place this test does not know: %r" % sent
    own = "_castPlayOn(_castTargets[i], url, name, art);"
    assert sorted(s for s in sent if s != own) == sorted(s for s in sent if "_castArt()" in s or "CastLogic.picture(" in s), (
        "a stream goes to a device with a picture nobody chose")
    assert main.count("CastLogic.picture(") == 2 and main.count("_castArt()") == 3


def test_the_cover_answers_a_click_without_asking_the_network():
    """The cover on the Playing page shows itself larger on a click and
    carries the links for the artist on air. What it does is CoverTouch
    (tst_covertouch) and MusicLinks (tst_musiclinks); what the page owes
    them is pinned here.

    The larger picture is a second Image, and Qt hands two Images one
    decoded picture only when address, size and fill mode all agree.
    Measured against a counting server: PreserveAspectFit beside a cover
    read with PreserveAspectCrop fetched the picture twice
    (test_cover_larger_fetch runs that measurement; these lines say what
    it hangs on). Neither Image names a fill mode now: asked to crop or
    fit, Qt enlarges a small picture to the source size while it reads it
    (measured in Qt 6.12: a PNG of 32 by 32 came back as 600 by 600), and
    the larger view could not keep a 32-pixel logo from being drawn at 600.
    Read as it is, the picture says its own size, which the page hands on.
    A link is opened by the listener's click and
    in one place, and neither file asks the network for anything itself. An
    episode's title line names a show, not an artist, so a podcast gets no
    links.
    """
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    face = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    touch = _code_only((UI / "CoverTouch.qml").read_text(encoding="utf-8"))
    links = _code_only((UI / "MusicLinks.js").read_text(encoding="utf-8"))

    assert ('CoverTouch { anchors.fill: parent face: fullRepresentation accent: root.accent '
            'art: artImage.status === Image.Ready ? artImage.source : "" '
            'natural: artImage.natural '
            'kind: fullRepresentation._bestArtUrl === root.albumArtUrl ? root.albumArtKind : "" '
            'corner: playingEq.visible ? playingEq.width + Kirigami.Units.smallSpacing * 3 : 0 '
            'trackArtist: fullRepresentation._podcastPlaying ? "" : root.trackArtist '
            'station: root.currentStation }') in flat(face), (
        "the cover is no longer handed the picture the page shows, its size and what it is of, "
        "or an episode's show is offered as an artist")
    assert face.count("CoverTouch {") == 1

    # Both are CoverImage with the page's address and nothing that changes how it is asked for.
    cover = face[face.index("id: artImage"):]
    cover = flat(cover[:cover.index("onStatusChanged")])
    larger = touch[touch.index("id: largerImage"):]
    larger = flat(larger[:larger.index("}")])
    assert flat(face).count("CoverImage { id: artImage anchors.fill: parent anchors.margins: 1 "
                            "source: fullRepresentation._bestArtUrl visible: status === Image.Ready") == 1, (
        "the page's cover is no longer the shared cover picture")
    assert flat(touch).count("CoverImage { id: largerImage ") == 1 and larger.endswith(
            'height: touch.natural.height * by source: touch.larger ? touch.art : ""'), (
        "the larger view no longer shows the cover's own picture")
    for own in ("sourceSize", "fillMode", "asynchronous"):
        assert own not in cover and own not in larger, (
            "the cover or its larger view sets %s itself: asked for differently, the picture is fetched twice" % own)
    picture = _code_only((UI / "CoverImage.qml").read_text(encoding="utf-8"))
    assert "fillMode: cover._box.width > 0 ? Image.PreserveAspectCrop : Image.Stretch\n" in picture, (
        "a raster is read with a fitting mode again, which enlarges a small picture as it is read")
    assert "sourceSize: cover._box.width > 0 ? Qt.size(cover._box.width, cover._box.height) : Qt.size(600, 600)\n" in picture, (
        "the picture is no longer read inside the source size")
    # The one read whose size follows the picture's shape: 16 pixels on the short side, and Qt refuses a long side over 65535.
    assert picture.count("sourceSize:") == 2 and "id: sketch visible: false" in flat(picture) and (
        "fillMode: Image.PreserveAspectCrop sourceSize: Qt.size(16, 16) asynchronous: true }") in flat(picture), (
        "the copy a drawing's shape is read off is no longer a small one")
    # A picture that fails to load is remembered, so the next candidate gets its turn (CoverLogic.marked, tst_coverlogic).
    failed = face[face.index("id: artImage"):]
    failed = flat(failed[:failed.index("id: vinyl")])
    assert ('if (status === Image.Error && source.toString() !== "") { fullRepresentation._brokenArtUrls = '
            'CoverLogic.marked(fullRepresentation._brokenArtUrls, source.toString())') in failed, (
        "a cover that failed to load is no longer set aside for the next candidate")
    assert 'source: touch.larger ? touch.art : ""' in larger, "the larger cover shows something other than the cover's picture"

    assert touch.count("Qt.openUrlExternally(") == 1 and (
        "property var open: function(address) { Qt.openUrlExternally(address) }") in touch, (
        "an address is opened past the one door the tests can stand in")
    assert flat(touch).count("touch.open(") == 1 and "if (address !== \"\") touch.open(address)" in touch
    for name, src in (("CoverTouch.qml", touch), ("MusicLinks.js", links), ("CoverImage.qml", picture)):
        assert "XMLHttpRequest" not in src and "executable" not in src, "%s asks for something by itself" % name
    # Read from the file as it is: stripped of comments, an address loses everything from its two slashes on.
    assert re.findall(r'"(https?://[^"]*)"', (UI / "MusicLinks.js").read_text(encoding="utf-8")) == [
        "https://www.last.fm/search/artists?q=", "https://www.discogs.com/search/?type=artist&q="], (
        "MusicLinks builds an address this test does not know")


def test_the_level_is_asked_at_full_rate_only_while_somebody_is_at_the_face():
    """Every tick of the level poll is a shell asking the sound server. A
    popup pays for it only while it is open, and a desktop face only under
    the pointer; the player's own window was on screen and so "watched" all
    day, minimised or not: 1800 shells an hour beside other work. What
    counts as somebody being there is WindowLogic.watched (tst_windowlogic),
    asked by the window house (tst_playerwindow); main.qml cannot be driven
    in a test, so this pins that the poll, the output menu's Bluetooth beat
    and the catch-up on arrival all go by that one answer."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    poll = main[main.index("id: sinkMasterPoll"):main.index("function setSinkMaster(")]
    assert "interval: playerWindow.faceWatched ? 2000 : 30000\n" in poll, (
        "the level poll's rate goes by something other than somebody being at the face")
    assert "onFaceHoveredChanged" not in main and main.count("sinkMasterPoll.restart()") == 1, (
        "the poll is re-armed from somewhere besides the arrival")
    assert "        onArrived: if (sinkMasterPoll.running) sinkMasterPoll.restart()\n" in main, (
        "somebody arriving at a window or a desktop face waits up to half a minute for the slider to catch up")
    assert "hovered: root.faceHovered\n" in main, "the house is not told where the pointer is"
    house = (UI / "PlayerWindow.qml").read_text(encoding="utf-8")
    assert "    readonly property bool faceWatched: WindowLogic.watched(seat, planar, popupOpen, hovered, active)\n" in house, (
        "the house answers past the tested rule, or about another window's keyboard")
    assert "    onFaceWatchedChanged: if (faceWatched && WindowLogic.standing(seat, planar)) arrived()\n" in house
    full = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    assert "running: castMenu.opened && root.faceShown\n" in full
    assert "interval: playerWindow.faceWatched ? 5000 : 15000\n" in full, (
        "an output menu left open in a window nobody is at asks about Bluetooth every five seconds")
    assert "root.faceHovered" not in full.replace("root.faceHovered = ", ""), (
        "the face reads the pointer by itself where the house's answer was meant")


def test_the_output_box_is_the_tested_one_and_only_a_pick_moves_the_sound():
    """With a Bluetooth and a USB speaker connected, the group of all
    outputs was switched off and on again: sound and config came back to
    the group and the box went on reading "System default output" for more
    than a minute. A ComboBox puts itself on its first row whenever its
    model is replaced, and the face worked the row out in a binding that
    sometimes ran before that. The box is OutputBox.qml now (the row's rule
    in OutputLogic.js, both under tests with a list that changes); this pins
    what the face hands it and that the one road from the box to the sound
    is the listener's pick."""
    full = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    assert full.count("OutputBox {") == 1, "the face has no output box, or two"
    code = _no_comments(full)
    for m in re.finditer(r"\bComboBox \{", code):
        block = code[m.start():_balanced_end(code, m.end() - 1)]
        assert "audioOutputs" not in block and "audioOutputDevice" not in block, (
            "a ComboBox in the face is wired to the output list by hand again")
    at = full.index("OutputBox {")
    box = full[at:full.index("}", at)]
    for line in ("visible: mediaDevices.audioOutputs.length > 1", 'firstRow: i18n("System default output")',
                 "outs: mediaDevices.audioOutputs", 'wanted: Plasmoid.configuration.audioOutputDevice || ""',
                 "onChosen: (id) => root.setAudioOutputDevice(id)"):
        assert line in box, "the output box is no longer told %r" % line
    assert full.count("setAudioOutputDevice(") == 1, "something besides the listener's pick sets the output from the face"
    own = _code_only((UI / "OutputBox.qml").read_text(encoding="utf-8"))
    assert own.count("chosen(") == 2 and "onActivated: (index) => chosen(OutputLogic.idAt(outs, index))" in own, (
        "the box reports a choice the listener did not make")
    assert "onModelChanged: currentIndex = Qt.binding(function() { return row })" in own, (
        "the row is no longer asked again after the list has been replaced")


def test_the_way_out_of_a_measurement_stands_where_its_button_stood():
    """A calibration started in a smaller window left its Stop button out of
    sight. The row that carries it stood below the caretaker's lines and the
    two microphone switches, some 165 lines of the face further down: the
    button that started the run went away and the one that ends it was
    behind the scroll. The row takes the button's own place now. Its first
    line also names the sound the run makes: it read "clicks through every
    speaker" while the sweep nobody hears was playing."""
    code = _no_comments((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    assert code.count('visible: root.sync.calibPhase !== ""') == 1, "the measurement's row is gone, or there are two"
    button = code.index('text: i18n("Calibrate with the microphone")')
    row = code.index('visible: root.sync.calibPhase !== ""')
    stop = code.index("onClicked: root.sync.calibrateCancel()")
    below = code.index("visible: root.sync._combineWantActive", button)
    assert button < row < stop < below, "the row with Stop no longer stands right under the button that starts a measurement"
    said = code[row:stop]
    assert ': Plasmoid.configuration.syncUltrasonic !== false ? i18n("Round 1 of 2 — measuring with a tone too high to hear…")' in said, (
        "the first round is not named after the sweep when the sweep is what plays")
    assert ': i18n("Round 1 of 2 — clicks through every speaker…")' in said, "the first round with clicks lost its line"
    assert 'root.sync.calibPhase !== "clicks" ? i18n("Round 2 of 2 — quiet, checking the result…")' in said, (
        "the second round lost its line")


def test_a_failed_cast_says_which_kind_it_was_and_names_only_who_carries_the_stream():
    """The Ruark that refused three stations played a fourth (2026-11-12):
    716 is its word on an address, and "Could not cast to …" over it read as
    if the speaker were broken or off. And with a television playing beside
    it the footer said "Casting to 2 devices", because the name was counted
    from the ticks.

    What an answer means is CastLogic.verdict, and who is named is
    CastLogic.carriers (tst_castlogic); tst_castroads walks the words
    through main.qml's own _castAnswer. Held here, because that copy cannot
    see them: the name is made from the record and not from the ticks, in
    the copy as in main.qml; every place that says "Casting to" uses that
    name; the answer is read by verdict and by nothing else; the refusal's
    flag is written where its name is; and the one line the answer leaves
    in the journal is made of the fields the helper named, never of the
    helper's words or of the command, which holds the stream's address."""
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = flat(_code_only((UI / "main.qml").read_text(encoding="utf-8")))
    copy = flat(_code_only((TESTS / "qml" / "tst_castroads.qml").read_text(encoding="utf-8")))
    face = flat(_code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8")))

    name = ('readonly property string _castName: { var on = CastLogic.carriers(_castSession, _castTargets); '
            'return on.length === 1 ? on[0].name : (on.length > 1 ? i18np("%1 device", "%1 devices", on.length) : ""); }')
    assert name in main, "the devices are named from the ticks, so one that refused is counted as cast to"
    assert name in copy, "tst_castroads names the devices another way than main.qml does"
    assert main.count("CastLogic.carriers(") == 1
    assert main.count('i18n("Casting to %1", _castName)') == 1 and main.count('"Casting to %1') == 1, (
        "the panel's hint names devices past the one name")
    assert face.count('i18n("Casting to %1", root._castName)') == 1 \
        and face.count('i18n("Casting to %1 — click to choose or stop", root._castName)') == 1 \
        and face.count('"Casting to %1') == 2, "the popup names devices past the one name"

    answer = flat(_function_body(main, "_castAnswer"))
    assert answer.startswith("{ var castWhy = CastLogic.verdict(stdout);") and main.count("CastLogic.verdict(") == 1, (
        "a play command's answer is read past CastLogic.verdict")
    for sentinel in ("__CAST_OK__", "__CAST_FAIL__", "__NO_PYCHROMECAST__"):
        assert sentinel not in answer, "_castAnswer reads %s by itself" % sentinel
    assert answer.count("console.") == 1 and 'console.warn("[ARP] cast: " + castWhy.log);' in answer, (
        "the journal gets more of a failed cast than the fields the helper named")
    words = ('notify(castNo ? i18n("%1 cannot play this station", castName) : i18n("Could not cast to %1", castName), '
             'castNo ? i18n("The device refused this station\'s address. Another station may work.") '
             ': i18n("The device could not play this station."), "dialog-error");')
    assert words in answer, "a refusal and a device out of reach are told in the same words"
    assert 'var castNo = castWhy.kind === "refused", castName = castWho || i18n("the device");' in answer
    kept = 'root._castFailedName = root.isPlaying() ? "" : castWho; root._castFailedRefused = castNo; root._castEnd();'
    assert kept in answer and main.count("_castFailedRefused = ") == 1, (
        "the footer's name and the kind of its failure are written apart, so one can outlive the other")


def test_a_level_is_sent_only_to_a_device_that_plays():
    """Every ticked device was sent the widget's level: the slider, the
    mute, the alarm's level, the room's mute. A device that refused the
    stream stays ticked, and it may be playing something of its own. A
    Ruark in that place, beside a television that played, went from 10 to
    6 during a test whose commands never named it (2026-11-12).

    Who may be sent a level is CastLogic.plays, and what a device still
    being asked is owed is CastLogic.owing and answered's owed
    (tst_castlogic). tst_castroads and tst_volumeroad walk copies of
    main.qml's level roads. Held here: the question is asked in _castTell,
    ahead of both commands, and every level goes out through _castTell;
    what waits is recorded as owed after it was sent to those that play; a
    device that takes the stream is sent what it is owed in place of
    adopting the loudness it had, since the level asked for is the one that
    was wanted; and the copies are main.qml's lines."""
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    tell = flat(_function_body(main, "_castTell"))
    gate = "if (!CastLogic.plays(_castSession, dev.uuid)) return;"
    assert tell.startswith("{ " + gate) and main.count("CastLogic.plays(") == 1, (
        "a device is sent a level without being asked whether it plays the stream")
    assert tell.count('_castExec("CAST_VOL", [') == 2 and main.count('"CAST_VOL"') == 2, "a level goes out past _castTell"
    assert main.count("_castTell(") - main.count("function _castTell(") == 3, (
        "a device is told a level on a road besides the timer's, its own row's and its answer's")

    flush = flat(_function_body(main, "_castFlush"))
    assert flush.endswith("_castTargets.forEach(function (dev) { _castTell(dev, _pendingCastVolumePct / 100); }); "
                          "_castSession = CastLogic.owing(_castSession, _pendingCastVolumePct); _pendingCastVolumePct = -1; }"), (
        "a level asked for while a device is still being asked is dropped: an alarm's level never reaches a slow device")
    assert main.count("CastLogic.owing(") == 1

    answer = flat(_function_body(main, "_castAnswer"))
    assert ("if (castIdx >= 0 && castAns.owed >= 0) root._castTell(root._castTargets[castIdx], castAns.owed / 100); "
            "else if (castIdx >= 0) root._castAdoptTrim(root._castTargets[castIdx]); return; }") in answer, (
        "a device that took the stream is not sent what it is owed, or adopts its old loudness over it")

    roads = _code_only((TESTS / "qml" / "tst_castroads.qml").read_text(encoding="utf-8"))
    for fn in ("_castTell", "_castFlush", "_castSetVolume", "applyCastTrim"):
        assert flat(_function_body(main, fn)) == flat(_function_body(roads, fn)), (
            "tst_castroads walks another %s than main.qml has" % fn)
    row = _code_only((TESTS / "qml" / "tst_volumeroad.qml").read_text(encoding="utf-8"))
    for fn in ("_castTell", "_castFlush", "applyCastTrim", "castTrimActive"):
        assert flat(_function_body(main, fn)) == flat(_function_body(row, fn)), (
            "tst_volumeroad walks another %s than main.qml has" % fn)


def test_a_device_that_refused_says_so_on_its_own_row():
    """A device that refuses stays ticked, so the next station is offered to
    it again. The tick is then all its row shows, and a Ruark that had
    refused sat in the output menu beside a television that played with
    nothing to tell the two apart (2026-11-12). The record keeps who
    refused (CastLogic, tst_castlogic) until the device is asked again or
    unticked, and tst_castroads walks that through main.qml's own
    functions. Held here: the end of a cast keeps the marks and only "This
    computer" drops them all; the answer hands its kind to the record; and
    the row reads the mark for its icon and its hint while the tick goes on
    following the selection alone."""
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = flat(_code_only((UI / "main.qml").read_text(encoding="utf-8")))
    assert "function castRefused(uuid) { return CastLogic.refusedBy(_castSession, uuid); }" in main
    assert main.count("CastLogic.refusedBy(") == 1
    assert ('function _castEnd() { _casting = false; _castCurrentUrl = ""; '
            "_castSession = CastLogic.ended(_castSession); }") in main, "the end of a cast forgets who refused"
    assert main.count("CastLogic.ended(") == 1
    assert main.count("CastLogic.fresh()") == 2 and '_castEnd(); _castSession = CastLogic.fresh(); _castFailedName = "";' in flat(
        _function_body(main, "castDisconnect")), "a mark outlives \"This computer\", and the next tick finds it"
    assert ('CastLogic.answered(root._castSession, castUuid, CastLogic.seqOf(cmd), castWhy.kind === "ok", castWhy.kind);'
            in flat(_function_body(main, "_castAnswer"))), "the record is not told what kind of answer it was"

    face = flat(_code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8")))
    row = face[face.index("id: castRow"):]
    row = row[:row.index("id: castBalanceSlider")]
    assert "readonly property bool refused: root.castRefused(uuid) " in row
    assert ('icon.name: castRow.refused ? "dialog-warning" : castRow.isGroup ? "audio-speakers-symbolic" : "network-wireless" '
            "checked: castRow.isTarget ") in row, "the row of a device that refused looks like any other, or its tick follows the refusal"
    assert 'PlasmaComponents3.ToolTip { text: castRow.refused ? i18n("Cannot play this station") : "" }' in row, (
        "the warning on the row has no words, or has them on a device that did not refuse")
    assert face.count("castRefused(") == 1 and row.count("castRow.refused") == 2


def test_a_stream_that_stands_is_handed_to_the_road_every_other_death_takes():
    """Measured 2026-11-12 on Qt 6.12 with FFmpeg 9: a station that closed the
    connection, and one that held it and sent nothing, left the player in
    PlayingState with the position at 29976 ms for as long as it was watched
    (170 s). The error the player reports arms the heal, and the heal turns
    back at its door because the player says it plays; no EndOfMedia comes.

    When a standing position is a dead stream is StandLogic.js
    (tst_standlogic), and StandWatch.qml looks every five seconds while a
    live stream plays (tst_standwatch). tst_standroads walks main.qml's own
    _streamDied beside the real watch, and its copy is held here to
    main.qml's text word for word. Held as well: the connect watchdog and
    the stall timer take the same function instead of a routing of their
    own, the watch is built with the widget, the engine and the player, it
    asks whether the order lapsed before it hands anything over, and it has
    no way to start sound by itself."""
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    copy = _code_only((TESTS / "qml" / "tst_standroads.qml").read_text(encoding="utf-8"))
    assert flat(_function_body(main, "_streamDied")) == flat(_function_body(copy, "_streamDied")), (
        "tst_standroads walks another _streamDied than main.qml has")

    stall = main[main.index("id: stallTimer"):main.index("id: connectWatchdog")]
    connect = main[main.index("id: connectWatchdog"):main.index("id: errorTimer")]
    for name, block in (("the stall timer", stall), ("the connect watchdog", connect)):
        assert block.count("_streamDied();") == 1, "%s no longer hands a dead stream to _streamDied" % name
        for own in ("healTimer.restart()", "_healAdvance()", "_previewRetryByIdentity()"):
            assert own not in block, "%s routes a dead stream by itself again (%s)" % (name, own)
    assert main.count("_streamDied()") == 3, "a road hands a stream to _streamDied that nobody decided about"

    assert main.count("StandWatch {") == 1, "main.qml has no watch over a standing position, or two"
    assert "    StandWatch { id: standWatch; app: root; engine: timeshift; player: playMusic }\n" in main, (
        "the watch is not handed the widget, the engine and the player")

    watch = _code_only((UI / "StandWatch.qml").read_text(encoding="utf-8"))
    assert "        running: watch.watching\n" in watch and "        interval: StandLogic.TICK_MS\n" in watch, (
        "the watch's timer runs by another word than the tested one")
    assert "        if (seen.stoodMs <= 0 || app._orderLapsed()) return false;\n" in watch, (
        "a stream is handed over without asking whether its order lapsed")
    assert watch.count("app._streamDied()") == 1 and watch.index("app._orderLapsed()") < watch.index("app._streamDied()")
    for sound in (".play()", "startWithFade(", "armRelay(", "tsPlayLive(", "refreshServer("):
        assert sound not in watch, "the watch starts sound by itself (%s)" % sound


def test_space_after_a_click_on_the_cover_is_still_the_pages():
    """Seen on the panel on 2026-11-12: a click on the cover's menu button
    and one more to shut it, and the next Space opened the menu again, the
    one after it a link in the browser. The listener had pressed it to pause.
    CoverTouch gave the focus to its own button whenever its menu or the
    larger view shut. It returns the focus to where it was now, or to its
    face (tst_covertouch drives both with real clicks and keys).

    The page cannot be driven in a test. What it owes is pinned here: the
    face it hands CoverTouch is the item whose key handler turns Space into
    play and pause, and CoverTouch names neither of its buttons as the place
    the focus goes to.
    """
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    face = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    touch = _code_only((UI / "CoverTouch.qml").read_text(encoding="utf-8"))
    assert "CoverTouch { anchors.fill: parent face: fullRepresentation " in flat(face)
    assert "PlasmaExtras.Representation {\n    id: fullRepresentation\n" in face, (
        "fullRepresentation is no longer the page's root, where its key handler sits")
    keys = face[face.index("\n    Keys.onPressed: (event) => {"):]
    keys = flat(keys[:keys.index("\n    }\n")])
    assert ('} else if (event.key === Qt.Key_Space && !_inputFocused() && !event.isAutoRepeat) { '
            'root.transport("PlayPause") event.accepted = true }') in keys, (
        "the face no longer turns Space into play and pause, so handing it the focus proves nothing")
    for button in ("linksButton", "coverButton"):
        assert "%s.forceActiveFocus" % button not in touch, (
            "CoverTouch puts the focus on %s by itself again: a click with the mouse would leave Space there" % button)
    assert "onLinksOpenChanged: if (!linksOpen) _handBack(linksPanel)" in touch
    # The larger view's limit counts the screen's pixels, and the page tells it nothing: the ratio is the screen's own.
    assert "property real ratio: Screen.devicePixelRatio\n" in touch and "ratio:" not in face[face.index("CoverTouch {"):][:900], (
        "the cover no longer takes the screen's pixel ratio from the screen")
    assert "onLargerChanged: if (!larger) _handBack(largerView)" in touch


def test_the_cover_and_what_it_is_of_are_written_in_one_place():
    """The picture beside a song is the song's cover, a picture of the artist
    or the sleeve of another record, and what may be done with it hangs on
    which. That only holds while the address and the kind are never written
    apart. ArtworkEngine._artShow writes both (tst_artworkengine drives it);
    this pins that nobody else does. main.qml used to write the address
    through an alias in four places; it reads through read-only aliases now
    and asks the engine to clear a cover or to show a local file's own.
    """
    engine = _code_only((UI / "ArtworkEngine.qml").read_text(encoding="utf-8"))
    show = _function_body(engine, "_artShow")
    for name in ("albumArtUrl", "albumArtKind", "_albumArtKey"):
        written = re.compile(r"\b%s\s*=(?!=)" % name)
        assert written.search(show), "_artShow no longer writes %s" % name
        assert len(written.findall(engine)) == len(written.findall(show)), (
            "the engine writes %s outside _artShow, where the other two do not follow" % name)
    for qml in sorted(UI.glob("*.qml")):
        if qml.name == "ArtworkEngine.qml":
            continue
        code = _code_only(qml.read_text(encoding="utf-8"))
        assert not re.search(r"\balbumArt(?:Url|Kind)\s*=(?!=)", code), (
            "%s writes the cover past the engine" % qml.name)
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    for alias in ("albumArtUrl", "albumArtKind"):
        assert "readonly property alias %s: artworkEngine.%s\n" % (alias, alias) in main, (
            "main.qml can write %s again" % alias)
    assert main.count("artworkEngine.artLocal(") == 1, (
        "a local file's sidecar cover is no longer handed to the engine as that file's own")


def test_only_the_songs_own_cover_leaves_the_playing_page():
    """A picture of the artist, or the sleeve of another record of theirs,
    stands in on the Playing page with a line that says what it is. The lock
    screen, the media controls and a television have no such line. Measured
    on 2026-11-12: MPRIS carried the sleeve of "Nüüd taas sajab lund" as the
    cover of "Päiksepoolsel tänaval", and a cast would have sent it on.

    The engine keeps trackArtUrl empty for such a picture (tst_artworkengine).
    main.qml cannot be driven in a test, so this pins that it hands on that
    address and never the other: its one mention of albumArtUrl is the alias
    the Playing page reads, and the MPRIS state is written again when the
    address that goes out changes.
    """
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert main.count("albumArtUrl") == 2 and (
        "readonly property alias albumArtUrl: artworkEngine.albumArtUrl\n") in main, (
        "main.qml hands the picture on somewhere without asking what it is of")
    assert "readonly property alias trackArtUrl: artworkEngine.trackArtUrl\n" in main
    state = flat(_function_body(main, "_mprisWriteState"))
    assert 'art: root.trackArtUrl || root.imageurl || root.faviconSrc(root.currentStationFavicon) || "",' in state, (
        "MPRIS is handed a picture that may not be the song's cover")
    assert re.search(r"^\s*onTrackArtUrlChanged: _mprisQueueWrite\(\)\s*$", main, re.M), (
        "the MPRIS state is no longer written again when the cover that goes out changes")
    assert "onAlbumArtUrlChanged" not in main and "onAlbumArtKindChanged" not in main
    assert main.count("trackArtUrl") == 5, (
        "the song's cover goes somewhere this test does not know: the five are the alias, "
        "which names it twice, MPRIS and the two cast roads")


def test_a_resume_of_the_single_file_is_given_the_clock():
    """The single file's reader is opened twelve seconds behind its writer,
    the distance the sliding buffer opens at. Measured 2026-11-12: after a
    pause of four seconds it was 7.8 s behind, met the file's unfinished end
    four times in 21 s and was reopened each time with about a second heard
    twice. Where the file is opened is TimeshiftLogic.openPlaceMs
    (tst_timeshiftlogic), and the engine asks it on a resume and on a reopen
    (tst_timeshiftengine). It can only measure that distance with a clock:
    given none it opens at the park, as it always did. So the one call
    main.qml makes is held to handing the clock over."""
    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert main.count("timeshift.resumeGesture(") == 1, "a second road resumes the buffer, and nobody decided what clock it has"
    assert "        if (!timeshift.resumeGesture(Date.now())) {\n" in main, (
        "the resume is given no clock: a short pause is opened at the park again, seven seconds behind the writer")


def test_the_footer_says_playing_for_sound_and_not_for_a_title():
    """A station played back from its buffer after a pause read
    "Connecting…" in the footer for all of 44 seconds of music, with the big
    button on Pause and the pill counting 0:12 behind (a real panel,
    2026-11-12). The footer took a title or a bitrate for the sign that sound
    had begun, and a buffer has neither; a live station without titles read
    the same. The word comes from ViewLogic.streamSounds now, which also
    takes a position that has left zero. The face reads the position in one
    property of its own, so the footer's long text is not worked out again
    at every tick of the player."""
    code = _no_comments((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    assert ("readonly property bool _sounds: "
            "ViewLogic.streamSounds(root.title !== Plasmoid.title, _localPlayback, playMusic.position)") in code, (
        "the face no longer asks ViewLogic whether the stream sounds, or hands it something else")
    assert 'return fullRepresentation._sounds ? "♪ " + i18n("Playing") : i18n("Connecting…")' in code, (
        "the footer's word over a stream with no bitrate is not decided by the sound any more")
    assert "root.title !== Plasmoid.title || fullRepresentation._localPlayback" not in code, (
        "a title decides the footer's word again")
    foot = code[code.index('i18n("Paused — still buffering live radio")'):code.index('i18n("Choose a station to start listening")')]
    assert "playMusic.position" not in foot, "the footer's text reads the player's position itself and is redone at every tick"


def test_an_alarm_whose_station_falls_silent_has_its_tone_asked_about_again():
    """Measured 2026-11-12 on the bench: an alarm's station held its
    connection and sent nothing 8 s in. The tone's one check, 25 s after the
    fire, read playing=true position=7968 and stood down; the heal road
    knocked 30, 82 and 165 s into the silence, and in the 188 s that were
    watched no tone came. With the station's server gone 41 s into the alarm
    it was 155 s the same way.

    The rules are AlarmLogic.js (wakeRings, wakeGraceLeftMs, wakeSounds) and
    StandLogic.limitMs under their own tests; what the engine and the watch
    do with them is tst_alarmengine and tst_standwatch. main.qml cannot be
    run in a test, so tst_standroads walks the head of its _tryHealStation,
    down to the line that tells the alarm, beside the real watch and the
    real engine. Held here to main.qml's text: that head, the one line that
    hands the watch's question to the engine, and that nothing else in
    main.qml tells the alarm about a fall."""
    def flat(text):
        return re.sub(r"\s+", " ", text).strip()

    main = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    copy = _code_only((TESTS / "qml" / "tst_standroads.qml").read_text(encoding="utf-8"))
    told = "alarmEngine.stationFell(Date.now());"
    head = flat(_function_body(copy, "_tryHealStation"))
    assert head.endswith(told + ' log.push("knock"); }'), (
        "tst_standroads' head of _tryHealStation no longer ends at the line that tells the alarm")
    head = head[:head.index(told) + len(told)]
    assert flat(_function_body(main, "_tryHealStation")).startswith(head), (
        "tst_standroads walks another head of _tryHealStation than main.qml has: "
        "the alarm is told at another place, or not at all")
    assert main.count("alarmEngine.stationFell(") == 1, "the alarm is told about a fall from a place nobody decided about"

    asks = "function _alarmRings(nowMs) { return alarmEngine.rings(nowMs); }"
    assert asks in flat(main) and asks in flat(copy), (
        "the watch's question does not reach the alarm engine, or tst_standroads asks it another way")
