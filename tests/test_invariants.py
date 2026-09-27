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

    arm = _code_only(_function_body(src, "_healArmRetry"))
    assert "_orderQuietSince = Date.now()" in arm, (
        "the ladder no longer stamps the moment the station went quiet")
    assert arm.index("_orderQuietSince = Date.now()") < arm.index("_healRetryAttempts++"), (
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
    assert "_orderHeardAt = Date.now()" in beat, "the heartbeat writes no moment"

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
    for order in ("_wantsPlaying = false", "_orphanOrder = null",
                  "_healRetryAttempts = 0", "timeshift.disarm()"):
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
    # or Play / PlayPause over MPRIS. Nothing else in main.qml may call it.
    src = (UI / "main.qml").read_text(encoding="utf-8")
    inside = sum(_code_only(_function_body(src, fn)).count("timeshiftResume(")
                 for fn in ("refreshServer", "_mprisDispatch"))
    total = main.count("timeshiftResume(") - main.count("function timeshiftResume(")
    assert total == inside, (
        "%d call(s) to timeshiftResume() sit outside the two roads a person "
        "drives (refreshServer, _mprisDispatch)" % (total - inside))


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
    the words; this pins that the search actually asks it, scopes by the
    country it found and sends the tags as a tagList.
    """
    src = (UI / "FullRepresentation.qml").read_text(encoding="utf-8")
    body = _code_only(_function_body(src, "runWebSearch"))
    assert "SearchLogic.facetQuery(q, _countryCodeOf)" in body, (
        "the search no longer reads a query as facets")
    assert "cc: bare.cc" in body, "a facet query's country no longer scopes the search"
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
    assert 'webScopeCc = ""' in drop and "runWebSearch(root.searchFilter)" in drop, (
        "the unscope branch no longer drops the chip and searches again")
    run = _code_only(_function_body(src, "runWebSearch"))
    assert '_webScopeInherited = scopeCc !== "" && scoped === null' in run, (
        "a scope the text itself names would be dropped as if it were inherited")


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


def test_a_stations_first_title_skips_the_flap_window():
    """The 1.5 s debounce protects against a flapping StreamTitle; the first
    title after an empty header has nothing to flap against."""
    code = _code_only((UI / "main.qml").read_text(encoding="utf-8"))
    assert 'var firstTitle = root._artPendingKey === "";' in code
    assert "artworkEngine.debounceRestart(firstTitle)" in code


def test_typing_a_word_that_starts_with_m_does_not_mute_the_radio():
    """On the list page every printable key opens the search — except that M
    was claimed first as an undocumented mute: typing "metal" silenced the
    radio and searched for "etal". M mutes on the other pages only."""
    src = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = src.index("event.key === Qt.Key_M")
    cond = src[at:src.index("{", at)]
    assert "root.view !== 0" in cond, "M mutes on the list page again and eats the first letter"
    assert src.index("typeToSearch(event)", at) > at


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


def test_a_repointed_station_row_lets_go_of_the_old_stations_uuid():
    """A row edited by hand kept its directory uuid whatever it was pointed
    at. The heal then asked byuuid where "this" station lives, was handed the
    OLD station's address, called it identity-proven and saved it over the
    edit for good; logos and votes followed the same id. The verdict lives in
    HealLogic.editKeepsIdentity under tst_heallogic; this holds the wire: the
    dialog asks before it writes the row, and a no empties the uuid.
    """
    src = (UI / "config" / "configGeneral.qml").read_text(encoding="utf-8")
    assert 'import "../HealLogic.js" as HealLogic' in src
    code = re.sub(r"\s+", " ", _code_only(src))
    # The whole guard as one sentence: a missing "!" turns it inside out — a
    # rename would lose the uuid and a repointed row would keep it — and no
    # test of the library can see that.
    guard = ('if (existing.uuid && !HealLogic.editKeepsIdentity(existing.name, existing.hostname, '
             'itemObject.name, itemObject.hostname)) itemObject.uuid = "";')
    assert guard in code, "the edit dialog's uuid guard changed shape"
    assert code.index(guard) < code.index("stationsModel.set(dialogMode, itemObject)", code.index(guard)), (
        "the verdict comes after the row was already written")


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
    does not move. Both failure roads of loadMore now go through _pageFailed,
    which waits (SearchLogic.pageRetryDelay, held by tst_searchlogic) and asks
    the next mirror; a good page clears the count and a new search stops a
    retry that belongs to the old list."""
    code = _code_only((UI / "config" / "configSearch.qml").read_text(encoding="utf-8"))
    more = _function_body(code, "loadMore")
    assert more.count("_pageFailed()") == 2, (
        "a failed page goes back to waiting for a scroll that may never come")
    assert more.count("stat = 1") == 1, (
        "a failure road only re-opens the scroll trigger again (stat = 1)")
    assert "_pageFailures = 0" in more, "a good page leaves the failure count standing"
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
    assert "_webAppendResults(xhr, lead)" in body, "the name answer is no longer filtered to its leads"
    tag = body[body.index("_webAppendResults(xhr2)"):]
    at = tag.index("var tagAt = webResultsModel.count > beforeTag ? fullRepresentation._webLastConsumed : -1")
    back = tag.index("if (lead) _webAppendResults(xhr)")
    page = tag.index("fullRepresentation._webSkipAhead = tagAt - webResultsModel.count")
    assert at < back < page, "the tag list's position is read after the name rows came back in"
    assert "if (tagAt >= 0) {" in tag


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
    for needle in ("existing[SearchLogic.urlKey(stationsModel.get(i).hostname)] = true",
                   "seen[SearchLogic.urlKey(webResultsModel.get(j).url)] = true",
                   "if (seenRaw) seen[SearchLogic.urlKey(seenRaw)] = true",
                   "if (!u || existing[uKey] || seen[uKey] ||",
                   "if (rawU && (existing[rawKey] || seen[rawKey])) continue",
                   "seen[uKey] = true",
                   "if (rawU) seen[rawKey] = true"):
        assert needle in body, "the search dedup lost a side of its key: " + needle
    assert not re.search(r"\b(existing|seen)\[(u|rawU|seenRaw)\]", body), (
        "a search dedup map is read or written by the exact address again")



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


def test_the_favourites_hint_names_the_star_it_means():
    """Every favourite toggle is a star (favorite and non-starred-symbolic;
    Breeze draws "favorite" as a star too), and the empty favourites view told
    the listener to tap a heart. The heart the widget has likes a song (the
    Playing tab, the Liked list), so only this hint is held to the star: a
    sentence about liking songs may say heart. The hint stays translated in
    every catalogue."""
    code = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    empty = code[code.index('i18n("No favorite stations yet")'):]
    shown = re.search(r'text:\s*root\.favoritesOnly\s*\?\s*i18n\("((?:[^"\\]|\\.)*)"\)', empty)
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
    calls = {name: code.count("playLast(") - code.count("function playLast(")
             for name, code in codes.items()}
    assert {k: v for k, v in calls.items() if v} == {
        "main.qml": 2, "FullRepresentation.qml": 2, "CompactRepresentation.qml": 1}, (
        "playLast is called from somewhere other than the five roads a person drives: %r" % calls)
    dispatch = _code_only(_function_body(main_src, "_mprisDispatch"))
    assert dispatch.count("playLast();") == 2, "MPRIS Play or PlayPause lost the shared answer"
    body = _code_only(_function_body(main_src, "playLast"))
    assert "TransportLogic.bareplay(root._lastAudition !== null, lastPlay, stationsModel.count)" in body
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
    station at a dead address read "Choose station and enjoy…" under its own
    name for the whole 30 s before knock #1, which looks like a widget that
    gave up. RetryLogic.betweenKnocks decides, under tst_retrylogic; this pins
    where the footer asks it. The louder states keep their words first:
    offline, the error sentence, a stream that plays or is loading."""
    code = _code_only((UI / "FullRepresentation.qml").read_text(encoding="utf-8"))
    at = code.index("id: subtext")
    text = code[code.index("text: {", at):]
    idle = text.index('return i18n("Choose station and enjoy…")')
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
