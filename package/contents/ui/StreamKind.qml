/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Asks what a stream is, beside the start that plays it, and remembers.
//
// A start is never held up and never begins differently than it used to:
// it is already on its old road when the question goes out. The answer may
// correct that road in two places. "ogg-flac" sends a plain start to the
// relay, instead of leaving it to the rescue six seconds on. "flac" and
// "other" take a start that went to the relay on a label or a .flac ending
// back to the plain one, as long as nothing is playing yet. "ogg", no answer
// and a late answer move nothing. Either correction is made only for the
// order that asked. The rules are KindLogic.js; here are the question's two
// commands, the two corrections and the two memories.
import QtQuick

import "KindLogic.js" as KindLogic

Item {
    id: kind

    // main.qml: exec, nextSeq, _icyUrlFile, _previewUrl, _wantsPlaying,
    // _tsPaused, _orderLapsed(), isPlaying(), _icyStreamTarget(),
    // startWithFade() and currentStationFavicon.
    property var app
    // Plasmoid.configuration: servers and streamKinds.
    property var cfg
    // The timeshift engine: relay, active, streamUrl, armRelay, disarm and
    // the two birth-death properties.
    property var engine
    // The MediaPlayer: source and playbackStateChanged.
    property var player

    // Kinds of addresses that are not the listener's to keep: an audition's
    // address can carry a token. Gone with the session.
    property string _sessionKinds: "{}"
    // Addresses the six-second rescue had to hand to the relay this session.
    // The next start of one arms the relay at once instead of replaying the
    // frozen seconds (the hiccup issue #11's reporter measured). Written to
    // the config it would outlive the backend quirk that caused it.
    property var _proven: ({})
    // The question in flight, -1 when there is none.
    property int _seq: -1
    property string _url: ""
    property string _name: ""
    // app._previewUrl when the question went out: an audition is nobody's
    // standing order, so its own address is what says it is still on.
    property string _audition: ""
    // The start that asked is on the relay on a guess (KindLogic.plan).
    property bool _pull: false
    property string _run: ""
    // The address of the last start, which is the one a rescue belongs to.
    property string _last: ""
    // Every question waits its turn, because the helper is one more
    // connection to the station and must not get in the start's way.
    // Measured on 2026-11-11 on a station that limits connections: asked in
    // the same instant as a plain start, the question took that start from
    // 0.5 s to 1.5 s; and at five connections inside one second (a start on
    // the relay, its writer dying at birth, the restart, two questions) the
    // player was answered "429 Too Many Requests" and an audition that had
    // played after 2.4 s stayed silent. So a plain start is asked about
    // once it plays, and a start on the relay and a rescue a second on,
    // which is after a writer that dies at birth has died.
    readonly property int waitMs: 1000
    property string _waitUrl: ""
    property string _waitName: ""
    property bool _waitPull: false
    property bool _waitForSound: false
    // A question waits its turn or is out: Loudness.qml makes no connection
    // of its own to the station until this one is over.
    readonly property bool busy: _seq >= 0 || _waitUrl !== ""

    // Contract: the kind remembered for this address, "" when none.
    function known(url) {
        return KindLogic.kindAt(cfg.streamKinds, url) || KindLogic.kindAt(_sessionKinds, url);
    }

    // A start is being made at url ("" for one the relay has no part in: an
    // episode, a cast group). Ends whatever question was out.
    // Contract: true when this start goes through the relay at once.
    function start(url, name, brought) {
        _seq = -1;
        _last = typeof url === "string" ? url : "";
        var todo = KindLogic.plan(_last, known(_last), brought, KindLogic.labelFor(brought, cfg.servers, _last));
        if (todo.ask) _wait(_last, name, todo.pull);
        return todo.relay;
    }

    // Contract: true when the rescue relayed this address this session.
    function proven(url) {
        return typeof url === "string" && url !== "" && _proven[url] === true;
    }

    // The six-second rescue fired for the player's src; orig is the row's
    // own address. Whatever was remembered of them was wrong, and the
    // address of this start is asked about so its next start knows.
    function rescued(src, orig) {
        var spelled = [src, orig, _last], i;
        for (i = 0; i < spelled.length; i++) {
            _proven[spelled[i]] = true;
            forget(spelled[i]);
        }
        // No hint is needed now: the freeze was one. KindLogic.buildAsk
        // refuses what is no web address. Whatever comes back, the stream
        // stays where the rescue put it.
        _wait(_last, "", false, true);
    }

    // Contract: nothing is remembered of this address afterwards.
    function forget(url) {
        if (KindLogic.kindAt(cfg.streamKinds, url) !== "")
            cfg.streamKinds = KindLogic.mapWithout(cfg.streamKinds, url);
        _sessionKinds = KindLogic.mapWithout(_sessionKinds, url);
    }

    // Contract: true when the command was one of a question's two, or the
    // sweep after one that was ended.
    function handleExec(cmd, stdout) {
        var mine = typeof cmd === "string" ? cmd : "";
        if (mine.indexOf(": SK_URL;") === 0) {
            var wrote = KindLogic.seqOf(mine);
            if (_seq < 0 || wrote !== _seq) {
                // This write's question was ended before the address was
                // down. The helper is what removes the file, and no helper
                // comes for it now, so it goes here: its own file, by the
                // number the write carries, never the one in flight.
                var base = String(app._icyUrlFile || "");
                var sweep = base === "" ? "" : KindLogic.buildSweep(base + ".kind" + wrote, wrote);
                if (sweep !== "") app.exec(sweep);
                return true;
            }
            if (_run === "") return true;
            var run = _run;
            _run = "";
            // An address that could not be written down is a question with
            // no answer: the start stays on the road it took.
            if (String(stdout).indexOf("__SK_URL_OK__") !== -1) app.exec(run);
            return true;
        }
        if (mine.indexOf(": SK_RM;") === 0) return true;
        if (mine.indexOf(": SK_RUN;") !== 0) return false;
        if (_seq < 0 || KindLogic.seqOf(mine) !== _seq) return true;
        // The question ends here, before anything is moved: a correction
        // makes a start of its own, and that start may ask again.
        _seq = -1;
        var word = KindLogic.answerOf(stdout);
        if (word === "") return true;
        _remember(_url, word);
        if (word === "ogg-flac") _toRelay();
        else if (word !== "ogg") _toPlain();
        return true;
    }

    // pull: the start is on the relay on a guess, so the answer has to come
    // before it plays and the clock is what lets the question go. A plain
    // start's question goes when the player plays, which may be now.
    function _wait(url, name, pull, clocked) {
        _waitUrl = url;
        _waitName = name || "";
        _waitPull = pull;
        _waitForSound = !pull && clocked !== true;
        if (!_waitForSound) later.restart();
        else if (app.isPlaying()) _waitOver();
    }

    // waitMs after _wait. A start made since, or an order taken down, ends
    // the wait: nobody is asked about a station that was stopped.
    function _waitOver() {
        var url = _waitUrl;
        _waitUrl = "";
        if (url === "" || url !== _last || app._tsPaused || (app._previewUrl === "" && app._wantsPlaying !== true)) return;
        _ask(url, _waitName, _waitPull);
    }

    function _ask(url, name, pull) {
        var base = String(app._icyUrlFile || "");
        if (base === "") return;
        var seq = app.nextSeq();
        var cmds = KindLogic.buildAsk({ url: url, urlPath: base + ".kind" + seq,
                                        scriptPath: Qt.resolvedUrl("streamkind.py").toString().substring(7), seq: seq });
        if (cmds.write === "") return;
        _seq = seq;
        _url = url;
        _name = name || "";
        _audition = String(app._previewUrl || "");
        _pull = pull;
        _run = cmds.run;
        app.exec(cmds.write);
    }

    // The saved list's addresses are the listener's and go to the config;
    // every write also drops what the list no longer holds, so a station
    // removed, or moved by a heal, leaves nothing behind under its old address.
    function _remember(url, word) {
        if (KindLogic.isSaved(cfg.servers, url))
            cfg.streamKinds = KindLogic.mapWith(KindLogic.mapKept(cfg.streamKinds, cfg.servers), url, word);
        else
            _sessionKinds = KindLogic.mapWith(_sessionKinds, url, word);
    }

    // Is the order that asked still the one playing? A stop takes the
    // standing order down and empties the audition's address; a park, a
    // night and a player sent to another address each end it too. The
    // player may be on the stream itself or on its tap. The lapse is asked
    // last, because asking takes a lapsed order down.
    function _alive() {
        if (app._tsPaused) return false;
        if (_audition !== "" ? app._previewUrl !== _audition : (app._previewUrl !== "" || app._wantsPlaying !== true)) return false;
        if (String(app._icyStreamTarget(player.source)) !== _url) return false;
        return !app._orderLapsed();
    }

    // Ogg FLAC on a plain start: to the relay, in an Ogg shell, unless it
    // is carrying this stream already (the rescue got there first).
    function _toRelay() {
        if (engine.relay && engine.active && engine.streamUrl === _url) return;
        if (!_alive()) return;
        engine.armRelay(_url, _name, Date.now(), true);
    }

    // Plain FLAC, or no Ogg at all, on a start that took the relay on a
    // guess: back to the plain start, which this time finds the kind
    // remembered. Not once the player plays: the answer is read in the same
    // turn it arrives in, and a stream that sounds is left to finish this
    // start where it is. The next start is plain.
    function _toPlain() {
        if (!_pull || !(engine.relay && engine.active && engine.streamUrl === _url)) return;
        if (app.isPlaying() || !_alive()) return;
        // The relay goes first. A start of the stream an arm is already
        // carrying keeps that arm, and its tap would take the player back.
        engine.disarm();
        app.startWithFade({ "name": _name, "hostname": _url, "favicon": app.currentStationFavicon, "active": true });
    }

    Timer {
        id: later
        interval: kind.waitMs
        repeat: false
        onTriggered: kind._waitOver()
    }

    Connections {
        target: kind.player
        ignoreUnknownSignals: true
        function onPlaybackStateChanged() { if (kind._waitForSound && kind._waitUrl !== "" && kind.app.isPlaying()) kind._waitOver(); }
    }

    // A relay that dies at birth proves whatever sent the stream there
    // wrong, the remembered kind included: Ogg FLAC yesterday, MP3 today.
    Connections {
        target: kind.engine
        ignoreUnknownSignals: true
        function on_RelayBirthDeathAtChanged() { kind.forget(kind.engine._relayBirthDeathUrl); }
    }
}
