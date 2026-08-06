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


def test_device_supplied_names_are_stripped_at_the_model_door():
    src = (UI / "main.qml").read_text(encoding="utf-8")
    # The cast device dict, the paired list and the scan list each sanitize
    # LAN/BT-supplied display text through _sanitizeDeviceName. Three
    # sites; losing one reopens the rich-text beacon door.
    assert "function _sanitizeDeviceName" in src, (
        "_sanitizeDeviceName helper missing from main.qml")
    helper = re.search(
        r"function _sanitizeDeviceName[\s\S]{0,200}?replace\(/\[([^\]]+)\]/g",
        src)
    assert helper, "_sanitizeDeviceName no longer strips a character class"
    for needed in ("<>&", "\\u0000-\\u001f", "\\u202a-\\u202e"):
        assert needed in helper.group(1), (
            "_sanitizeDeviceName class lost %r (markup / control / bidi)"
            % needed)
    strips = src.count("_sanitizeDeviceName(")
    assert strips >= 4, (  # 3 model-door call sites + the definition itself
        "expected >=4 _sanitizeDeviceName mentions (3 call sites + def), "
        "found %d" % strips)


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
    src = (UI / "main.qml").read_text(encoding="utf-8")
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
    for p in sorted((ROOT / "package").rglob("*.qml")) \
            + sorted((ROOT / "package").rglob("*.js")):
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            if decl.search(line):
                hits.append("%s:%d: %s" % (p.name, i, stripped[:70]))
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

    if lookup._theme_dir("breeze") is None:          # noqa: SLF001
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
