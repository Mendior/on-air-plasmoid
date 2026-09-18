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
        for m in re.finditer(r'/json/stations/byuuid/"\s*\+\s*', src):
            tail = src[m.end():m.end() + 60].lstrip()
            assert tail.startswith("encodeURIComponent"), (
                "%s: byuuid concatenation without encodeURIComponent: %r"
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
    assert "root._relayProven[src] = true;" in src, (
        "the rescue no longer records the stream it relayed - every "
        "start replays the six frozen seconds")
    assert "tsOgg || root._relayProven[tsUrl] === true" in src, (
        "the arm road no longer consults the rescue's session record")


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
    """This poll runs ONLY while the face is watched: with a popup that
    means `running: root.expanded`; on a desktop containment, where
    expanded is pinned true for the applet's life, the pointer stands in
    and the unattended face coasts at thirty seconds instead.

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
    body = _function_body(src, "_ensureViewVisible")
    assert "view = 0" in body, (
        "the walk lost its floor — Stations is the page that is always "
        "there to land on")
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
        code = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
        code = "\n".join(re.sub(r"//.*$", "", ln) for ln in code.split("\n"))
        for lib in libs:
            if re.search(r"\b%s\s*\." % re.escape(lib), code) \
                    and ('as %s' % lib) not in code:
                missing.append("%s calls %s without importing it"
                               % (qml.name, lib))
    assert not missing, (
        "QML file(s) calling a JS library they never import — every call site "
        "throws ReferenceError at runtime:\n" + "\n".join(missing))


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
    i = src.index("_alarmFallbackArmed = false;")
    window = src[i:i + 2500]
    assert "playMusicRef.position" in window and "BufferedMedia" in window, (
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
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    assert "id: tsHorizonWatch" in src, "the horizon watchdog is gone"
    i = src.index("id: tsHorizonWatch")
    body = src[i:i + 2000]
    assert "timeshift.playerEndOfMedia(" in body, (
        "the watchdog no longer hands the frozen horizon to the engine")
    assert "timeshift.shifted" in body, (
        "the watchdog stopped gating on the shifted state — it would fire "
        "over ordinary live playback")


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
    for prop in ("accent:", "accentBright:", "accentTeal:", "accentText:"):
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
    assert "getStreamInfo()" in vc, (
        "arriving on the Playing page no longer refreshes a stopped poll")
    rd = (ROOT / "package" / "contents" / "ui" / "reader.py").read_text(encoding="utf-8")
    assert "(403, 408, 429)" in rd, (
        "403 became a permanent verdict again - a rate-limiting WAF "
        "would permanently silence a station that carries titles")


def test_a_dying_speakers_pause_never_silences_the_room():
    """A Bluetooth speaker powering off sends an AVRCP Pause as its last
    breath (JBL, measured live 2026-08-11). With the combine active and
    other speakers still playing, that pause is not the listener's word.
    Both arrival orders are guarded: a pause inside the departure window
    is ignored, and a park landed just before the departure is resumed.
    """
    src = (UI / "main.qml").read_text(encoding="utf-8")
    assert "_deathbedPause" in src and "_btMemberLostAt < 4000" in src, (
        "the MPRIS handler honours a departing speaker's pause again")
    body = _function_body(src, "noteBtMemberLost")
    assert "timeshiftResume()" in body, (
        "a park that was the speaker's farewell no longer resumes")
    assert "_tsParkFromMpris" in body and "120000" in body, (
        "the resume lost its origin check or its wide window - Bluetooth "
        "admits a loss 5-20 s late, and only an MPRIS-born park may be "
        "resumed over (the widget's own pause button is the listener)")
    eng = (UI / "SyncEngine.qml").read_text(encoding="utf-8")
    assert "app.noteBtMemberLost()" in eng, (
        "the engine no longer reports a member lost without being asked")


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

    # The candidate rows must carry the exact-name verdict into the
    # ladder, or every legitimate own-domain repair demotes to a stopgap.
    assert "exact: rowNorm === run.norm" in src, (
        "the name-search rows lost their exact-name verdict")
    assert src.count("!HealLogic.sharedBase(origBase)") >= 2, (
        "a scoring site no longer excludes shared streaming hosts - "
        "a landlord in common outranks the station's real name again "
        "(both the list-station heal and the preview rescue score rows)")

    # rank() hands back row objects; the preview rescue auditions bare
    # urls. The day rank changed shape, this road silently fed
    # "[object Object]" to the player and no test went red.
    assert "ranked.slice(0, 4).map(function(c) { return c.url; })" in src, (
        "the preview rescue consumes rank() rows as urls again")


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


def test_the_mpris_origin_flag_cannot_outlive_its_dispatch():
    """The "this park came over MPRIS" mark lasts exactly one command.

    A Bluetooth speaker powering off sends an AVRCP Pause as its last breath,
    and the widget undoes such a park for the speakers still in the room. That
    only works while the mark is honest. It was not: the dispatch has six ways
    out and four of them — both podcast skips and both empty-list returns —
    jumped over the single clearing line at the bottom, so the mark stayed true
    for the rest of the session. Every later park then wore it, including one
    pressed on the widget's own button, on the panel icon or with Space; a
    speaker leaving within the next two minutes resumed the music over it.
    The dispatch sits behind a try/finally now, which no future return can
    escape, and the body must not carry the flag itself again."""
    src = (UI / "main.qml").read_text(encoding="utf-8")
    outer = _function_body(src, "_handleMprisCommand")
    assert "_mprisCmdActive = true" in outer, "the origin mark is no longer raised"
    assert "finally" in outer and "_mprisCmdActive = false" in outer, (
        "the origin mark is cleared on some paths only — the leak that made a "
        "hand-made park read as a dying speaker's breath is back"
    )
    inner = _function_body(src, "_mprisDispatch")
    assert "_mprisCmdActive" not in inner, (
        "the dispatch touches the origin mark again; it leaked precisely "
        "because its own early returns owned the clearing"
    )


def test_the_mpris_start_empties_the_command_file():
    """Whoever resets the sequence counter clears the file it counts against.

    _mprisStart sets _mprisCmdSeq to 0 because a fresh daemon numbers from 1.
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
    body = _function_body(src, "_mprisStart")
    assert "_mprisCmdSeq = 0" in body, "the sequence reset is gone"
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
    load = load[: load.index("_lastSynced = cfg_servers")]
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
