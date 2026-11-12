// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// StreamKind against stand-ins for the widget, the config, the timeshift
// engine and the player: who is asked, what an answer may move, and what is
// remembered where.
import QtQuick
import QtTest

import "../../package/contents/ui" as Ui
import "../../package/contents/ui/KindLogic.js" as KL

TestCase {
    id: tc
    name: "StreamKind"

    readonly property string flac: "https://stream.example.org/rock-flac"
    readonly property string other: "https://cdn.example.net/live?token=abc123"

    Component { id: kindComp; Ui.StreamKind {} }

    Component {
        id: appComp
        QtObject {
            property var execLog: []
            property int seqN: 40
            // The real facade puts an export after the sentinel, so an ack
            // never equals the command that was sent.
            function exec(cmd) {
                var m = /^(:[^;]*;\s*)/.exec(String(cmd));
                execLog.push(m[1] + "export LC_ALL=C LANGUAGE=C; " + String(cmd).slice(m[1].length));
            }
            function nextSeq() { return ++seqN; }
            property string _icyUrlFile: "/run/user/1000/arp-icy-src-7"
            property string _previewUrl: ""
            property bool _wantsPlaying: true
            property bool _tsPaused: false
            property bool lapsed: false
            property int lapsedAsked: 0
            function _orderLapsed() { lapsedAsked++; return lapsed; }
            // The player's state, and the tap translated back to its station
            // the way main.qml does it.
            property bool playing: false
            function isPlaying() { return playing; }
            property string tap: "http://127.0.0.1:34567/"
            property string tapOf: ""
            function _icyStreamTarget(src) { return String(src) === tap ? tapOf : String(src); }
            property string currentStationFavicon: "https://logo.example/l.png"
            property var started: []
            property var engine: null
            // Whether the relay was still armed when the start was made.
            function startWithFade(station) { started.push({ hostname: station.hostname, name: station.name, favicon: station.favicon, armed: engine.relay }); }
        }
    }

    Component { id: cfgComp; QtObject { property string servers: "[]"; property string streamKinds: "{}" } }
    Component { id: playerComp; QtObject { property url source; signal playbackStateChanged() } }

    Component {
        id: engineComp
        QtObject {
            property bool relay: false
            property bool active: false
            property string streamUrl: ""
            property var armed: []
            property bool refuse: false
            function armRelay(url, name, nowMs, ogg) {
                armed.push({ url: url, name: name, ogg: ogg });
                if (refuse) return false;
                relay = true; active = true; streamUrl = url;
                return true;
            }
            property int disarmed: 0
            function disarm() { disarmed++; relay = false; active = false; streamUrl = ""; }
            property string _relayBirthDeathUrl: ""
            property double _relayBirthDeathAt: 0
        }
    }

    // A widget with one saved row, flac, labelled as given; the player is on it.
    function rig(label) {
        var r = { app: appComp.createObject(tc), cfg: cfgComp.createObject(tc),
                  engine: engineComp.createObject(tc), player: playerComp.createObject(tc) };
        var row = { "name": "Rock", "hostname": flac, "favicon": "", "active": true };
        if (label !== undefined) row.codec = label;
        r.cfg.servers = JSON.stringify([row]);
        r.player.source = flac;
        r.app.engine = r.engine;
        r.k = kindComp.createObject(tc, { app: r.app, cfg: r.cfg, engine: r.engine, player: r.player });
        return r;
    }

    // What main.qml does when start() answers true: the relay is armed, its
    // tap comes up and the player is sent to it.
    function onTap(r, url) {
        r.engine.relay = true; r.engine.active = true; r.engine.streamUrl = url;
        r.app.tapOf = url;
        r.player.source = r.app.tap;
    }

    // An audition of `url`, labelled as the directory labels it.
    function audition(r, url, label) {
        r.app._previewUrl = url; r.app._wantsPlaying = false; r.player.source = url;
        return r.k.start(url, "Heard", label);
    }

    // The player reaches sound.
    function plays(r) {
        r.app.playing = true;
        r.player.playbackStateChanged();
    }

    // Walk a question from its write to the helper's answer.
    function answer(r, word) {
        // A question that waits its turn is let go first.
        if (r.k._waitUrl !== "") r.k._waitOver();
        var n = r.app.execLog.length;
        verify(n > 0 && r.app.execLog[n - 1].indexOf(": SK_URL;") === 0, "no question is out")
        verify(r.k.handleExec(r.app.execLog[n - 1], "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, n + 1)
        verify(r.app.execLog[n].indexOf(": SK_RUN;") === 0)
        verify(r.k.handleExec(r.app.execLog[n], word))
    }

    function test_it_says_so_while_its_question_stands() {
        // Loudness.qml makes one more connection to the station, and waits
        // for this one to be over first.
        var r = rig("ogg");
        verify(!r.k.busy)
        r.k.start(flac, "Rock", "");
        verify(r.k.busy, "a question that waits its turn does not count")
        plays(r);
        verify(r.k.busy, "a question that is out does not count")
        answer(r, "ogg\n");
        verify(!r.k.busy, "busy after its answer")
        // A start that asks nothing leaves nothing standing.
        var plain = rig();
        plain.k.start(flac, "Rock", "");
        verify(!plain.k.busy)
    }

    function test_a_hinted_address_is_asked_about_beside_its_start() {
        var r = rig("ogg");
        compare(r.k.start(flac, "Rock", ""), false)
        // Not in the start's way: the question goes when the player plays.
        compare(r.app.execLog.length, 0)
        r.player.playbackStateChanged();
        compare(r.app.execLog.length, 0, "asked on a state that is not playing")
        plays(r);
        compare(r.app.execLog.length, 1)
        r.player.playbackStateChanged();
        compare(r.app.execLog.length, 1, "asked again on the next state change")
        verify(r.app.execLog[0].indexOf(": SK_URL;") === 0)
        verify(r.app.execLog[0].indexOf("printf '%s' '" + flac + "' > '/run/user/1000/arp-icy-src-7.kind41'") !== -1)
        compare(r.engine.armed.length, 0)
        answer(r, "ogg-flac\n");
        // The helper was handed the file, not the address.
        verify(r.app.execLog[1].indexOf("streamkind.py' '/run/user/1000/arp-icy-src-7.kind41'") !== -1)
        verify(r.app.execLog[1].indexOf("example.org") === -1)
        // The player moves to the relay, in an Ogg shell, under the row's name.
        compare(r.engine.armed.length, 1)
        compare(r.engine.armed[0].url, flac)
        compare(r.engine.armed[0].name, "Rock")
        compare(r.engine.armed[0].ogg, true)
        compare(KL.kindAt(r.cfg.streamKinds, flac), "ogg-flac")
        verify(r.app.lapsedAsked > 0, "the move did not ask whether the order lapsed")
    }

    function test_a_remembered_address_is_not_asked_about_again() {
        var r = rig("ogg");
        r.k.start(flac, "Rock", "");
        answer(r, "ogg-flac\n");
        var n = r.app.execLog.length;
        // Ogg FLAC: the relay at once. Any other kind: plain. No question.
        compare(r.k.start(flac, "Rock", ""), true)
        compare(r.app.execLog.length, n)
        compare(r.k.known(flac), "ogg-flac")
        var kinds = ["flac", "other"];
        for (var i = 0; i < kinds.length; i++) {
            r.cfg.streamKinds = KL.mapWith("{}", flac, kinds[i]);
            compare(r.k.start(flac, "Rock", "FLAC"), false)
            compare(r.app.execLog.length, n)
            compare(r.k.known(flac), kinds[i])
        }
        // Vorbis or Opus: the road it had, plain for a saved row at a bare
        // address and the relay for an audition with a label.
        r.cfg.streamKinds = KL.mapWith("{}", flac, "ogg");
        compare(r.k.start(flac, "Rock", ""), false)
        compare(r.k.start(flac, "Rock", "OGG"), true)
        compare(r.app.execLog.length, n)
    }

    function test_no_hint_no_question() {
        var r = rig();
        compare(r.k.start(flac, "Rock", ""), false)
        compare(r.k.start(flac, "Rock", "mp3"), false)
        compare(r.k.start(other, "Other", ""), false)
        compare(r.app.execLog.length, 0)
        compare(r.k.known(flac), "")
        // An Ogg ending is the relay as ever, and no answer would change
        // that, so nothing is asked.
        compare(r.k.start("http://x.example/live.ogg", "X", ""), true)
        compare(r.k.start("http://x.example/live.opus", "X", "FLAC"), true)
        compare(r.app.execLog.length, 0)
        // The audition's own label is a hint, and so is a .flac ending; both
        // start on the relay, as they did, and are asked about a second on.
        r.app._previewUrl = flac;
        compare(r.k.start(flac, "Rock", "FLAC"), true)
        compare(r.app.execLog.length, 0)
        r.k._waitOver();
        compare(r.app.execLog.length, 1)
        r.app._previewUrl = "";
        compare(r.k.start("http://x.example/live.flac", "X", ""), true)
        compare(r.app.execLog.length, 1)
        r.k._waitOver();
        compare(r.app.execLog.length, 2)
        r.k._waitOver();
        compare(r.app.execLog.length, 2, "one wait asked twice")
    }

    function test_a_question_that_waits_is_asked_only_of_the_start_still_standing() {
        // Another start in the meantime, whatever it is.
        var r = rig();
        audition(r, other, "FLAC");
        r.k.start("", "", "");
        r.k._waitOver();
        compare(r.app.execLog.length, 0)
        r = rig();
        audition(r, other, "FLAC");
        r.k.start(flac, "Rock", "");
        r.k._waitOver();
        compare(r.app.execLog.length, 0)
        // The audition was stopped, so nothing is ordered at all.
        r = rig();
        audition(r, other, "FLAC");
        r.app._previewUrl = "";
        r.k._waitOver();
        compare(r.app.execLog.length, 0)
        // A saved station at a .flac address, stopped or parked.
        var klasu = "https://x.example/klasu.flac";
        r = rig();
        r.k.start(klasu, "Klasu", "");
        r.app._wantsPlaying = false;
        r.k._waitOver();
        compare(r.app.execLog.length, 0)
        r = rig();
        r.k.start(klasu, "Klasu", "");
        r.app._tsPaused = true;
        r.k._waitOver();
        compare(r.app.execLog.length, 0)
        // The same station started again, as after a writer that died at
        // birth: one question, a second after the second start.
        r = rig();
        r.k.start(klasu, "Klasu", "");
        r.k.start(klasu, "Klasu", "");
        r.k._waitOver();
        compare(r.app.execLog.length, 1)
        // Nothing waiting.
        r = rig();
        r.k._waitOver();
        compare(r.app.execLog.length, 0)
    }

    function test_the_wait_runs_on_its_own_clock() {
        var r = rig();
        compare(r.k.waitMs, 1000)
        audition(r, other, "FLAC");
        wait(700)
        compare(r.app.execLog.length, 0)
        tryCompare(r.app.execLog, "length", 1, 1500)
        // A plain start's question has no clock: it waits for the player.
        var s = rig("ogg");
        s.k.start(flac, "Rock", "");
        wait(1300)
        compare(s.app.execLog.length, 0)
        plays(s);
        compare(s.app.execLog.length, 1)
        // A player that already plays when the start is told is asked about at once.
        s = rig("ogg");
        s.app.playing = true;
        s.k.start(flac, "Rock", "");
        compare(s.app.execLog.length, 1)
        // And a start on the relay is not asked about for playing early.
        s = rig();
        audition(s, other, "FLAC");
        plays(s);
        compare(s.app.execLog.length, 0)
    }

    function test_any_other_answer_leaves_the_plain_start_alone() {
        var words = ["ogg\n", "flac\n", "other\n"];
        for (var i = 0; i < words.length; i++) {
            var r = rig("flac");
            r.k.start(flac, "Rock", "");
            answer(r, words[i]);
            compare(r.engine.armed.length, 0, words[i])
            compare(r.k.known(flac), words[i].trim())
        }
    }

    function test_no_answer_and_a_garbled_one_change_nothing() {
        var words = ["", "\n", "ogg-flac ogg\n", "OGG-FLAC\n", "Traceback (most recent call last):\n", new Array(50000).join("x")];
        for (var i = 0; i < words.length; i++) {
            var r = rig("ogg");
            r.k.start(flac, "Rock", ""); plays(r);
            answer(r, words[i]);
            compare(r.engine.armed.length, 0, String(i))
            compare(r.cfg.streamKinds, "{}", String(i))
            compare(r.k.known(flac), "", String(i))
        }
        // The address could not even be written down: no helper is run.
        var w = rig("ogg");
        w.k.start(flac, "Rock", ""); plays(w);
        verify(w.k.handleExec(w.app.execLog[0], "__SK_URL_FAIL__\n"))
        compare(w.app.execLog.length, 1)
        verify(w.k.handleExec(w.app.execLog[0], "__SK_URL_OK__\n"))
        compare(w.app.execLog.length, 1, "a question that failed was taken up again")
        // The write's answer delivered twice runs one helper, and the
        // helper's answer delivered twice moves the player once.
        w = rig("ogg");
        w.engine.refuse = true;
        w.k.start(flac, "Rock", ""); plays(w);
        verify(w.k.handleExec(w.app.execLog[0], "__SK_URL_OK__\n"))
        verify(w.k.handleExec(w.app.execLog[0], "__SK_URL_OK__\n"))
        compare(w.app.execLog.length, 2)
        verify(w.k.handleExec(w.app.execLog[1], "ogg-flac\n"))
        verify(w.k.handleExec(w.app.execLog[1], "ogg-flac\n"))
        compare(w.engine.armed.length, 1)
        // A command that is nobody's is not swallowed.
        verify(!w.k.handleExec(": TS_RUN; export LC_ALL=C LANGUAGE=C; true # 41", "ogg-flac"))
        verify(!w.k.handleExec("", ""))
        verify(!w.k.handleExec(null, null))
    }

    function test_an_answer_for_an_order_that_ended_moves_nothing() {
        // Stop: the standing order is down.
        var r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        r.app._wantsPlaying = false;
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
        // What the stream is stays true, and saves the next start its question.
        compare(r.k.known(flac), "ogg-flac")
        // A park.
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        r.app._tsPaused = true;
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
        // A night: the order lapsed, and the door is asked.
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        r.app.lapsed = true;
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
        verify(r.app.lapsedAsked > 0)
        // The player was sent elsewhere without a start (the bitrate fallback).
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        r.player.source = other;
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        r.player.source = "";
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
        // A saved station's question, and an audition has begun since.
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        r.app._previewUrl = other;
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
    }

    function test_another_start_ends_the_question_that_was_out() {
        var r = rig("ogg");
        r.cfg.servers = JSON.stringify([{ "hostname": flac, "codec": "ogg" }, { "hostname": other, "codec": "ogg" }]);
        r.k.start(flac, "Rock", ""); plays(r);
        var first = r.app.execLog[0];
        // Another station is picked while the first question is out.
        r.player.source = other;
        r.k.start(other, "Other", ""); plays(r);
        compare(r.app.execLog.length, 2)
        // The first question's acks are swallowed: no helper run, nothing
        // remembered, nothing moved. Only the address it wrote down goes.
        verify(r.k.handleExec(first, "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 3)
        verify(r.app.execLog[2].indexOf(": SK_RM;") === 0)
        r.app.execLog.pop();
        verify(r.k.handleExec(": SK_RUN; export LC_ALL=C LANGUAGE=C; timeout 6 python3 'x' 'y'; true # 41", "ogg-flac\n"))
        compare(r.engine.armed.length, 0)
        compare(r.cfg.streamKinds, "{}")
        // The second one is answered as usual.
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 1)
        compare(r.engine.armed[0].url, other)
        compare(r.k.known(flac), "")
        // The same station started again while its question is out: a new
        // question, and the old answer is nobody's.
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        r.k.start(flac, "Rock", ""); plays(r);
        compare(r.app.execLog.length, 2)
        verify(r.k.handleExec(r.app.execLog[0], "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 3)
        verify(r.app.execLog.pop().indexOf("arp-icy-src-7.kind41'") !== -1)
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 1)
        // The same for a start on the relay: the first question's "flac"
        // makes no restart once a second start has asked its own.
        r = rig();
        audition(r, other, "FLAC");
        onTap(r, other);
        audition(r, other, "FLAC");
        verify(r.k.handleExec(": SK_RUN; export LC_ALL=C LANGUAGE=C; timeout 6 python3 'x' 'y'; true # 41", "flac\n"))
        compare(r.app.started.length, 0)
        compare(r.k.known(other), "")
    }

    // The address is written down before the helper is run, and a question
    // can be ended between the two. The helper is what removes the file, so
    // a write that comes home to nobody left it lying: owner-only, but an
    // address with a listener's token in a folder that outlives the session.
    function test_a_question_nobody_waits_for_removes_the_address_it_wrote() {
        var r = rig("ogg");
        r.cfg.servers = JSON.stringify([{ "hostname": flac, "codec": "ogg" }, { "hostname": other, "codec": "ogg" }]);
        r.k.start(flac, "Rock", ""); plays(r);
        var first = r.app.execLog[0];
        r.player.source = other;
        r.k.start(other, "Other", ""); plays(r);
        compare(r.app.execLog.length, 2)
        // The old write lands: one command, for its own file and no other.
        verify(r.k.handleExec(first, "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 3)
        var sweep = r.app.execLog[2];
        verify(sweep.indexOf(": SK_RM;") === 0)
        verify(sweep.indexOf("rm -f '/run/user/1000/arp-icy-src-7.kind41'") !== -1, sweep)
        verify(sweep.indexOf("kind42") === -1, "the question in flight lost its file")
        verify(sweep.indexOf("streamkind.py") === -1, "the old question was run after all")
        verify(sweep.indexOf("stream.example.org") === -1, "the address is on the line again")
        verify(/# 41\s*$/.test(sweep))
        // The sweep's own ack is this component's, and is the end of it.
        verify(r.k.handleExec(sweep, ""))
        compare(r.app.execLog.length, 3)
        // The question in flight is untouched: its write runs its helper,
        // on its own file, and its answer is taken.
        verify(r.k.handleExec(r.app.execLog[1], "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 4)
        verify(r.app.execLog[3].indexOf(": SK_RUN;") === 0)
        verify(r.app.execLog[3].indexOf("arp-icy-src-7.kind42'") !== -1)
        verify(r.k.handleExec(r.app.execLog[3], "ogg-flac\n"))
        compare(r.engine.armed.length, 1)
        compare(r.engine.armed[0].url, other)

        // A write that failed may have left half a file: swept all the same.
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        first = r.app.execLog[0];
        r.k.start("", "", "");
        verify(r.k.handleExec(first, "__SK_URL_FAIL__\n"))
        compare(r.app.execLog.length, 2)
        verify(r.app.execLog[1].indexOf("rm -f '/run/user/1000/arp-icy-src-7.kind41'") !== -1)

        // A stop between the write and its ack: nobody is asked, and the
        // file goes.
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        first = r.app.execLog[0];
        r.k.start("", "", "");
        verify(r.k.handleExec(first, "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 2)
        verify(r.app.execLog[1].indexOf(": SK_RM;") === 0)
        verify(r.app.execLog[1].indexOf("streamkind.py") === -1)

        // The write of the question that IS waited for sweeps nothing.
        r = rig("ogg");
        r.k.start(flac, "Rock", ""); plays(r);
        verify(r.k.handleExec(r.app.execLog[0], "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 2)
        verify(r.app.execLog[1].indexOf(": SK_RUN;") === 0)
        // And its ack seen twice does not run the helper twice or sweep.
        verify(r.k.handleExec(r.app.execLog[0], "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 2)

        // A write with no number, and a widget with no place for the file:
        // claimed, and nothing is removed on a guess.
        r = rig("ogg");
        verify(r.k.handleExec(": SK_URL; export LC_ALL=C LANGUAGE=C; printf '%s' 'x' > 'y'; true", "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 0)
        r.app._icyUrlFile = "";
        verify(r.k.handleExec(": SK_URL; export LC_ALL=C LANGUAGE=C; printf '%s' 'x' > 'y'; true # 41", "__SK_URL_OK__\n"))
        compare(r.app.execLog.length, 0)
    }

    function test_a_start_the_relay_has_no_part_in_ends_the_question_too() {
        var none = ["", "file:///home/me/a.flac", "http://x.example/list.m3u", "http://x.example/hls/a.m3u8",
                    "http://x.example/live.ogg"];
        for (var i = 0; i < none.length; i++) {
            var r = rig("ogg");
            r.k.start(flac, "Rock", ""); plays(r);
            compare(r.k.start(none[i], "X", "FLAC"), i === 4)
            compare(r.app.execLog.length, 1, none[i])
            // No helper is run for it; the address it wrote is removed.
            verify(r.k.handleExec(r.app.execLog[0], "__SK_URL_OK__\n"))
            compare(r.app.execLog.length, 2, none[i])
            verify(r.app.execLog[1].indexOf(": SK_RM;") === 0, none[i])
            verify(r.app.execLog[1].indexOf("streamkind.py") === -1, none[i])
        }
        // Not even an address once written down as Ogg FLAC.
        var p = rig();
        p.cfg.servers = JSON.stringify([{ "hostname": "http://x.example/list.m3u" }]);
        p.cfg.streamKinds = "{\"http://x.example/list.m3u\":\"ogg-flac\"}";
        compare(p.k.start("http://x.example/list.m3u", "X", "FLAC"), false)
    }

    function test_an_answer_after_the_relay_is_already_carrying_the_stream() {
        // The six-second rescue got there first.
        var r = rig("ogg");
        r.k.start(flac, "Rock", "");
        r.engine.relay = true; r.engine.active = true; r.engine.streamUrl = flac;
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
        compare(r.k.known(flac), "ogg-flac")
        // A relay refused (its writer died at birth minutes ago) is not the
        // player's to worry about: the plain start goes on.
        r = rig("ogg");
        r.engine.refuse = true;
        r.k.start(flac, "Rock", "");
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 1)
        verify(!r.engine.relay)
    }

    function test_plain_flac_on_the_relay_by_its_label_goes_back_to_the_plain_start() {
        var words = ["flac\n", "other\n"];
        for (var i = 0; i < words.length; i++) {
            var r = rig();
            compare(audition(r, other, "FLAC"), true)
            onTap(r, other);
            answer(r, words[i]);
            compare(r.app.started.length, 1, words[i])
            compare(r.app.started[0].hostname, other)
            compare(r.app.started[0].name, "Heard")
            compare(r.app.started[0].favicon, "https://logo.example/l.png")
            // The relay is down before the plain start is made, or that
            // start would keep the arm and the tap would take the player back.
            compare(r.engine.disarmed, 1)
            compare(r.app.started[0].armed, false)
            compare(r.k.known(other), words[i].trim())
            compare(r.engine.armed.length, 0)
            verify(r.app.lapsedAsked > 0, "the correction did not ask whether the order lapsed")
            // The start it made finds the kind remembered: plain, no question.
            var n = r.app.execLog.length;
            compare(r.k.start(other, "Heard", "FLAC"), false)
            compare(r.app.execLog.length, n)
        }
        // A saved station at a .flac address, the same way.
        var s = rig();
        var klasu = "https://x.example/klasu.flac";
        s.cfg.servers = JSON.stringify([{ "hostname": klasu }]);
        s.player.source = klasu;
        compare(s.k.start(klasu, "Klasu", ""), true)
        onTap(s, klasu);
        answer(s, "flac\n");
        compare(s.app.started.length, 1)
        compare(s.app.started[0].hostname, klasu)
        compare(KL.kindAt(s.cfg.streamKinds, klasu), "flac")
        // Still on the stream itself, its tap not up yet: the same.
        s = rig();
        compare(audition(s, other, "FLAC"), true)
        s.engine.relay = true; s.engine.active = true; s.engine.streamUrl = other;
        answer(s, "flac\n");
        compare(s.app.started.length, 1)
    }

    function test_a_stream_that_already_plays_is_left_where_it_is() {
        // The player reached sound through the tap before the answer was
        // read: this start stays on the relay, and the next one is plain.
        var r = rig();
        compare(audition(r, other, "FLAC"), true)
        onTap(r, other);
        r.k._waitOver();
        verify(r.k.handleExec(r.app.execLog[0], "__SK_URL_OK__\n"))
        r.app.playing = true;
        verify(r.k.handleExec(r.app.execLog[1], "flac\n"))
        compare(r.app.started.length, 0)
        compare(r.engine.disarmed, 0)
        verify(r.engine.relay)
        compare(r.k.known(other), "flac")
        compare(r.k.start(other, "Heard", "FLAC"), false)
    }

    function test_vorbis_and_opus_are_never_moved() {
        // An audition the directory files as OGG: on the relay, and it stays.
        var r = rig();
        compare(audition(r, other, "OGG"), true)
        onTap(r, other);
        answer(r, "ogg\n");
        compare(r.app.started.length, 0)
        compare(r.engine.armed.length, 0)
        compare(r.k.known(other), "ogg")
        // Its next audition is on the relay again, and asks nothing.
        var n = r.app.execLog.length;
        compare(r.k.start(other, "Heard", "OGG"), true)
        compare(r.app.execLog.length, n)
        // The same stream as a saved row at a bare address: plain, as it was.
        r = rig("ogg");
        compare(r.k.start(flac, "Rock", ""), false)
        answer(r, "ogg\n");
        compare(r.engine.armed.length, 0)
        compare(r.app.started.length, 0)
        n = r.app.execLog.length;
        compare(r.k.start(flac, "Rock", ""), false)
        compare(r.app.execLog.length, n)
        // Ogg FLAC on the relay already: nothing to do but remember.
        r = rig();
        compare(audition(r, other, "FLAC"), true)
        onTap(r, other);
        answer(r, "ogg-flac\n");
        compare(r.app.started.length, 0)
        compare(r.engine.armed.length, 0)
        compare(r.k.known(other), "ogg-flac")
    }

    function test_only_the_order_that_asked_is_taken_back_to_the_plain_start() {
        // Each of these ends the order after its question went out.
        // The audition was stopped.
        var r = rig();
        audition(r, other, "FLAC");
        onTap(r, other);
        r.k._waitOver();
        r.app._previewUrl = "";
        answer(r, "flac\n");
        compare(r.app.started.length, 0)
        // Another result is being auditioned.
        r = rig();
        audition(r, other, "FLAC");
        onTap(r, other);
        r.k._waitOver();
        r.app._previewUrl = flac;
        answer(r, "flac\n");
        compare(r.app.started.length, 0)
        // A saved station that was stopped, parked, or left for the night.
        var ends = ["stop", "park", "night", "elsewhere"];
        var klasu = "https://x.example/klasu.flac";
        for (var i = 0; i < ends.length; i++) {
            r = rig();
            r.cfg.servers = JSON.stringify([{ "hostname": klasu }]);
            r.player.source = klasu;
            compare(r.k.start(klasu, "Klasu", ""), true)
            onTap(r, klasu);
            r.k._waitOver();
            if (ends[i] === "stop") r.app._wantsPlaying = false;
            if (ends[i] === "park") r.app._tsPaused = true;
            if (ends[i] === "night") r.app.lapsed = true;
            if (ends[i] === "elsewhere") r.player.source = other;
            answer(r, "flac\n");
            compare(r.app.started.length, 0, ends[i])
            compare(r.engine.disarmed, 0, ends[i])
            compare(r.k.known(klasu), "flac", ends[i])
        }
        verify(r.app.lapsedAsked === 0, "the lapse was asked for a player that is elsewhere")
    }

    function test_a_start_that_is_not_on_the_relay_on_a_guess_is_never_taken_off_it() {
        // The relay refused at the start (its writer died at birth minutes
        // ago): the plain start is what plays, and there is nothing to undo.
        var r = rig();
        compare(audition(r, other, "FLAC"), true)
        answer(r, "flac\n");
        compare(r.app.started.length, 0)
        // The rescue put the stream on the relay because it froze, and what
        // the helper says about it afterwards does not take it off.
        r = rig();
        r.k.start(flac, "Rock", "");
        // The frozen player counts as playing, and the rescue's question
        // still goes by the clock.
        r.app.playing = true;
        r.k.rescued(flac, flac);
        compare(r.app.execLog.length, 0, "the rescue's question went out with the rescue")
        r.player.playbackStateChanged();
        compare(r.app.execLog.length, 0, "the rescue's question went out on a state change")
        r.app.playing = false;
        onTap(r, flac);
        answer(r, "other\n");
        compare(r.app.started.length, 0)
        compare(r.k.known(flac), "other")
        // A plain start that was asked about on its row's label.
        r = rig("flac");
        compare(r.k.start(flac, "Rock", ""), false)
        answer(r, "flac\n");
        compare(r.app.started.length, 0)
        compare(r.engine.armed.length, 0)
        // The relay carries another stream by now.
        r = rig();
        compare(audition(r, other, "FLAC"), true)
        onTap(r, flac);
        r.app.tapOf = other;
        answer(r, "flac\n");
        compare(r.app.started.length, 0)
    }

    function test_a_saved_address_is_kept_in_the_config_and_any_other_for_the_session() {
        var r = rig("ogg");
        r.k.start(flac, "Rock", "");
        answer(r, "ogg-flac\n");
        compare(r.cfg.streamKinds, "{\"" + flac + "\":\"ogg-flac\"}")
        // An audition of an address nobody saved.
        audition(r, other, "OGG");
        answer(r, "ogg\n");
        compare(r.cfg.streamKinds, "{\"" + flac + "\":\"ogg-flac\"}")
        compare(r.k.known(other), "ogg")
        // An audition of the saved station: its address is the listener's already.
        r = rig();
        r.app._previewUrl = flac;
        r.k.start(flac, "Rock", "FLAC");
        answer(r, "flac\n");
        compare(KL.kindAt(r.cfg.streamKinds, flac), "flac")
        // A token in a saved address is in the list already, spelled the same.
        r = rig();
        r.cfg.servers = JSON.stringify([{ "hostname": other, "codec": "ogg" }]);
        r.player.source = other;
        r.k.start(other, "Other", "");
        answer(r, "ogg-flac\n");
        compare(r.cfg.streamKinds, "{\"" + other + "\":\"ogg-flac\"}")
    }

    function test_the_config_map_follows_the_saved_list_and_its_cap() {
        var r = rig("ogg");
        // A row that was removed, or moved by a heal, leaves its entry behind;
        // the next write takes it out.
        r.cfg.streamKinds = KL.mapWith("{}", "http://gone.example/old", "ogg-flac");
        r.k.start(flac, "Rock", "");
        answer(r, "ogg\n");
        compare(r.cfg.streamKinds, "{\"" + flac + "\":\"ogg\"}")
        // 64 saved stations known, and a 65th learned.
        var rows = [], m = "{}";
        for (var i = 0; i < 65; i++) rows.push({ "hostname": flac + "/" + i, "codec": "ogg" });
        for (i = 0; i < 64; i++) m = KL.mapWith(m, flac + "/" + i, "ogg");
        r.cfg.servers = JSON.stringify(rows);
        r.cfg.streamKinds = m;
        r.player.source = flac + "/64";
        r.k.start(flac + "/64", "N", "");
        answer(r, "ogg-flac\n");
        compare(Object.keys(JSON.parse(r.cfg.streamKinds)).length, 64)
        compare(r.k.known(flac + "/0"), "")
        compare(r.k.known(flac + "/1"), "ogg")
        compare(r.k.known(flac + "/64"), "ogg-flac")
    }

    function test_a_config_entry_that_is_not_a_map_is_no_trouble() {
        var bad = ["", "not json", "[1,2]", "null", "{\"" + flac + "\":\"mp3\"}"];
        for (var i = 0; i < bad.length; i++) {
            var r = rig("ogg");
            r.cfg.streamKinds = bad[i];
            compare(r.k.known(flac), "")
            compare(r.k.start(flac, "Rock", ""), false)
            answer(r, "ogg-flac\n");
            compare(r.cfg.streamKinds, "{\"" + flac + "\":\"ogg-flac\"}", bad[i])
        }
    }

    function test_a_relay_that_dies_at_birth_takes_the_memory_with_it() {
        // Ogg FLAC yesterday, MP3 today: the remembered kind was wrong.
        var r = rig("ogg");
        r.cfg.streamKinds = KL.mapWith("{}", flac, "ogg-flac");
        compare(r.k.start(flac, "Rock", ""), true)
        r.engine._relayBirthDeathUrl = flac;
        r.engine._relayBirthDeathAt = 1000;
        compare(r.k.known(flac), "")
        compare(r.cfg.streamKinds, "{}")
        // The next start is the restart the death makes. It asks once it
        // plays, not in the instant the station is connected to for the
        // third time; what comes back is the new truth.
        var n = r.app.execLog.length;
        compare(r.k.start(flac, "Rock", ""), false)
        compare(r.app.execLog.length, n, "the restart's question went out with the restart")
        answer(r, "other\n");
        compare(r.k.known(flac), "other")
        // An audition's entry, in the session's memory, goes the same way.
        r = rig();
        audition(r, other, "FLAC");
        answer(r, "ogg-flac\n");
        compare(r.k.known(other), "ogg-flac")
        r.engine._relayBirthDeathUrl = other;
        r.engine._relayBirthDeathAt = 2000;
        compare(r.k.known(other), "")
        // Another address's death is not this one's, and forgetting what
        // was never kept writes nothing to the config.
        r = rig("ogg");
        r.cfg.streamKinds = KL.mapWith("{}", flac, "ogg-flac");
        r.engine._relayBirthDeathUrl = other;
        r.engine._relayBirthDeathAt = 3000;
        compare(r.k.known(flac), "ogg-flac")
        r.cfg.streamKinds = "not json";
        r.k.forget(flac);
        compare(r.cfg.streamKinds, "not json")
    }

    function test_the_rescue_proves_an_address_and_asks_what_it_is() {
        // A row added by hand: no label, no ending, so nobody asked.
        var r = rig();
        compare(r.k.start(flac, "Rock", ""), false)
        compare(r.app.execLog.length, 0)
        verify(!r.k.proven(flac))
        r.k.rescued(flac, flac);
        verify(r.k.proven(flac))
        verify(!r.k.proven(other))
        verify(!r.k.proven(""))
        // The rescue arms the relay itself; this only asks.
        compare(r.engine.armed.length, 0)
        r.engine.relay = true; r.engine.active = true; r.engine.streamUrl = flac;
        answer(r, "ogg-flac\n");
        compare(r.engine.armed.length, 0)
        compare(r.k.known(flac), "ogg-flac")
        // So the second start goes through the relay at once, with no question.
        var n = r.app.execLog.length;
        compare(r.k.start(flac, "Rock", ""), true)
        compare(r.app.execLog.length, n)
    }

    function test_a_remembered_kind_that_needed_the_rescue_is_forgotten() {
        var r = rig("flac");
        r.cfg.streamKinds = KL.mapWith("{}", flac, "flac");
        compare(r.k.start(flac, "Rock", ""), false)
        r.k.rescued(flac, flac);
        compare(r.cfg.streamKinds, "{}")
        verify(r.k.proven(flac))
        // The player's spelling, the row's and the start's own all count.
        r = rig();
        r.k.start(flac, "Rock", "");
        r.k.rescued("https://stream.example.org/rock%2Dflac", other);
        verify(r.k.proven("https://stream.example.org/rock%2Dflac"))
        verify(r.k.proven(other))
        verify(r.k.proven(flac))
        // The address of the start is the one asked about.
        r.k._waitOver();
        verify(r.app.execLog[0].indexOf("'" + flac + "'") !== -1)
        // A rescue with nothing to its name.
        r = rig();
        r.k.rescued("", "");
        r.k.rescued(null, undefined);
        compare(r.app.execLog.length, 0)
        verify(!r.k.proven(undefined))
        verify(!r.k.proven(null))
        verify(!r.k.proven(""))
    }

    function test_no_place_for_the_address_no_question() {
        var r = rig("ogg");
        r.app._icyUrlFile = "";
        compare(r.k.start(flac, "Rock", ""), false)
        plays(r);
        compare(r.app.execLog.length, 0)
        r.k.rescued(flac, flac);
        r.k._waitOver();
        compare(r.app.execLog.length, 0)
        verify(r.k.proven(flac))
    }
}
