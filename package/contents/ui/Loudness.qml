/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Evens out loudness between saved stations: one factor on this computer's
// output, and a few short listens to a station to know what the factor is.
//
// The factor is `gain`, and main.qml multiplies the listener's level by it
// where the sound leaves the player and nowhere else. So the slider, MPRIS,
// the saved default, the wheel and a device's level go on meaning the
// listener's own level, and a fade or a mute of theirs ends at zero whatever
// the factor is.
//
// The factor never moves under a listener in one step. A start takes its
// station's factor while the player is still silent: every start gives the
// player a new source before it plays, and the factor follows the source at
// once. A reading that arrives while its station plays, the option ticked
// or unticked under a playing station, and a device that joins or leaves
// are eased in over eight seconds, at one pace in dB.
//
// While a device plays along with this computer the factor is 1: the device
// takes the stream itself and nobody turns it down, so this computer cut
// beside it would shift the balance between the two with every station.
// Readings are taken and kept all the same.
//
// A station is listened to once it has sounded for ten seconds, by a helper
// that makes one more connection to it for twenty seconds of its stream.
// One at a time, never while the question what the stream is still stands,
// and once a day at most: on five days it is played, and from then on when
// the newest of the five readings is a month old. The rules are
// LoudLogic.js; here are the factor, the helper's two commands and the map.
import QtQuick

import "KindLogic.js" as KindLogic
import "LoudLogic.js" as LoudLogic

Item {
    id: loud

    // main.qml: exec, nextSeq, _icyUrlFile, _currentOrigUrl, _previewUrl,
    // _podPlayingKey, _podStarting, _volumeOverridePct, _wantsPlaying,
    // _tsPaused, _healPendingUrl, _healBackupFor, recording, _casting,
    // _castLocalPlay, isPlaying() and _icyStreamTarget().
    property var app
    // Plasmoid.configuration: evenLoudness, stationLoudness and servers.
    property var cfg
    // StreamKind: busy.
    property var kind
    // The timeshift engine: bufPath.
    property var engine
    // The MediaPlayer: source.
    property var player

    // The cut in force, in dB: 0, or below it for a saved station louder
    // than the target. It is what is eased, so that a change is one pace in
    // dB all the way; _follow and the ease are its only writers.
    property real cutNow: 0
    // What the output multiplies the listener's level by.
    readonly property real gain: LoudLogic.factor(cutNow)
    // The saved address the stream on the player belongs to, "" when it is
    // no saved station's.
    readonly property string subject: !app || !cfg || !player ? "" : LoudLogic.subject({
        station: app._currentOrigUrl, source: String(player.source), preview: app._previewUrl,
        episode: app._podPlayingKey !== "" || app._podStarting === true, buffer: engine ? engine.bufPath : "", saved: cfg.servers })
    // Where the cut is going.
    readonly property real wanted: !app || !cfg ? 0 : LoudLogic.cut({
        on: cfg.evenLoudness, subject: subject, alarmPct: app._volumeOverridePct, casting: app._casting, local: app._castLocalPlay,
        lufs: LoudLogic.lufsAt(cfg.stationLoudness, cfg.servers, subject) })
    // The station that plays may be listened to (LoudLogic.asks).
    readonly property bool mayAsk: !!app && !!cfg && !!player && LoudLogic.asks({
        on: cfg.evenLoudness, subject: subject, playing: app.isPlaying(), wanted: app._wantsPlaying, paused: app._tsPaused,
        healing: app._healPendingUrl !== "" || app._healBackupFor !== "", alarmPct: app._volumeOverridePct,
        recording: app.recording, at: String(app._icyStreamTarget(player.source)) })
    readonly property bool _on: !!cfg && cfg.evenLoudness === true
    readonly property bool easing: ease.running
    readonly property bool waiting: settle.running
    property int easeMs: LoudLogic.EASE_MS
    property int settleMs: LoudLogic.SETTLE_MS

    // The reading in flight, -1 when there is none.
    property int _seq: -1
    // The saved address it is kept for, and the file its address went into.
    property string _key: ""
    property string _path: ""
    property string _run: ""
    property double _askedAt: 0

    onWantedChanged: _follow(false)
    // A station is asked about once it has sounded settleMs without a break:
    // a new station, a new source and every pause start the count again.
    onMayAskChanged: mayAsk ? settle.restart() : settle.stop()
    onSubjectChanged: if (mayAsk) settle.restart()
    // Unticked, the option makes no more connections on its own behalf.
    on_OnChanged: if (!_on) _end()

    // Contract: true when the command was one of a reading's two, or the
    // end of one.
    function handleExec(cmd, stdout) {
        var mine = typeof cmd === "string" ? cmd : "", wrote, base, sweep, run;
        if (mine.indexOf(": LD_URL;") === 0) {
            wrote = KindLogic.seqOf(mine);
            if (_seq < 0 || wrote !== _seq) {
                // This write's reading was ended before the address was
                // down, and the end's own rm may have run first. No helper
                // comes for the file now, so it goes here, by the number
                // the write carries and never the one in flight.
                base = String(app._icyUrlFile || "");
                sweep = base === "" ? "" : LoudLogic.buildEnd(base + ".loud" + wrote, wrote);
                if (sweep !== "") app.exec(sweep);
                return true;
            }
            if (_run === "") return true;
            run = _run;
            _run = "";
            // An address that could not be written down is no reading and
            // no verdict on the station: nothing is kept of it.
            if (String(stdout).indexOf("__LD_URL_OK__") !== -1) app.exec(run);
            else _seq = -1;
            return true;
        }
        if (mine.indexOf(": LD_END;") === 0) return true;
        if (mine.indexOf(": LD_RUN;") !== 0) return false;
        if (_seq < 0 || KindLogic.seqOf(mine) !== _seq) return true;
        _seq = -1;
        _remember(_key, LoudLogic.answerOf(stdout));
        // Whoever plays now has waited for this one to come home.
        if (mayAsk) settle.restart();
        return true;
    }

    // settleMs after the station began to sound.
    function _begin() {
        if (!mayAsk) return;
        if (_seq >= 0) {
            // One at a time. A reading that never came home is ended here,
            // so that it cannot stand in the way for the rest of the session.
            if (Date.now() - _askedAt > (LoudLogic.HELPER_LIMIT_S + 15) * 1000) _end();
            settle.restart();
            return;
        }
        if (kind && kind.busy) { settle.restart(); return; }
        if (LoudLogic.due(cfg.stationLoudness, subject, Date.now() / 1000)) _ask(subject, String(app._icyStreamTarget(player.source)));
    }

    function _ask(key, url) {
        var base = String(app._icyUrlFile || "");
        if (base === "") return;
        var seq = app.nextSeq(), path = base + ".loud" + seq;
        var cmds = LoudLogic.buildAsk({ url: url, urlPath: path, scriptPath: Qt.resolvedUrl("loudness.py").toString().substring(7), seq: seq });
        if (cmds.write === "") return;
        _seq = seq;
        _key = key;
        _path = path;
        _run = cmds.run;
        _askedAt = Date.now();
        app.exec(cmds.write);
    }

    // Ends the reading in flight: its file goes, and the helper, which
    // holds on to that file, goes with it. Nothing is kept of the address,
    // because the station did not fail to answer.
    function _end() {
        if (_seq < 0) return;
        var cmd = LoudLogic.buildEnd(_path, _seq);
        _seq = -1;
        _run = "";
        if (cmd !== "") app.exec(cmd);
    }

    // A reading is kept for a saved address only, beside the ones it has,
    // and every write drops what the list no longer holds. No number is
    // kept too, as the second it was tried. An answer for a station the listener has left is as good as
    // any: it is written, and what plays now is not this address.
    function _remember(key, lufs) {
        if (!LoudLogic.isSaved(cfg.servers, key)) return;
        var kept = LoudLogic.kept(cfg.stationLoudness, cfg.servers), now = Date.now() / 1000;
        cfg.stationLoudness = lufs === null ? LoudLogic.withMiss(kept, key, now) : LoudLogic.withAnswer(kept, key, lufs, now);
    }

    // The cut goes where it is wanted: at once while nothing sounds and
    // with every new source, eased while the player plays.
    function _follow(atOnce) {
        if (atOnce || !app || !app.isPlaying()) {
            ease.stop();
            cutNow = wanted;
        } else if (cutNow === wanted) {
            ease.stop();
        } else if (!ease.running || ease.to !== wanted) {
            ease.stop();
            ease.from = cutNow;
            ease.to = wanted;
            ease.restart();
        }
    }

    NumberAnimation {
        id: ease
        target: loud
        property: "cutNow"
        duration: loud.easeMs
    }

    Timer {
        id: settle
        interval: loud.settleMs
        repeat: false
        onTriggered: loud._begin()
    }

    Connections {
        target: loud.player || null
        ignoreUnknownSignals: true
        function onSourceChanged() {
            loud._follow(true);
            if (loud.mayAsk) settle.restart();
        }
    }

    // A stop, a pause and a file of the listener's take the standing order
    // down, and nobody is listened to behind a listener's back after that.
    // A switch to another station leaves the order up and the reading runs
    // to its end: the number is the address's, whoever plays by then.
    Connections {
        target: loud.app || null
        ignoreUnknownSignals: true
        function on_WantsPlayingChanged() { if (loud.app._wantsPlaying !== true) loud._end(); }
    }
}
