/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Looks at a live stream's position every few seconds, and hands a stream
// whose position stands to the road every other death takes.
//
// StandLogic.js says what is watched and when standing is a verdict. Here
// are the timer, which runs while a live stream plays and at no other time,
// what is remembered between two looks, and the question asked before the
// stream is handed over: a station whose order went unheard through a night
// is taken down at that door and not opened again.
import QtQuick
import QtMultimedia

import "StandLogic.js" as StandLogic

Item {
    id: watch

    // main.qml: isPlaying(), _tsPaused, _casting, _podPlayingKey,
    // _previewUrl, _alarmRings(), _orderLapsed() and _streamDied().
    property var app
    // The timeshift engine: relay, relayUrl, shifted and disarm().
    property var engine
    // The MediaPlayer: source, position, mediaStatus and errorOccurred.
    property var player

    readonly property bool watching: !!app && !!engine && !!player && StandLogic.watched({
        playing: app.isPlaying(), source: String(player.source), relayUrl: engine.relayUrl, relay: engine.relay,
        shifted: engine.shifted, parked: app._tsPaused, casting: app._casting,
        episode: app._podPlayingKey !== "", audition: app._previewUrl !== "" })
    // The timer's own word on whether it runs, for the tests and the bench.
    readonly property alias ticking: beat.running
    property var _mem: null
    // Verdicts since the last ten minutes of unbroken sound.
    property int _strikes: 0

    // A watch is of one run of sound: what the player did before it began
    // vouches for nothing, and what it does after is another watch's.
    onWatchingChanged: _mem = watching ? StandLogic.begin(player.position, Date.now()) : null

    // One look at the position.
    // Contract: true when the stream was handed over as dead.
    function _look(nowMs) {
        if (!watching) return false;
        var full = player.mediaStatus === MediaPlayer.BufferedMedia || player.mediaStatus === MediaPlayer.BufferingMedia;
        // An alarm that rings: no verdict lengthens the wait for its next,
        // and none is counted against the listening that comes after it.
        var waking = app._alarmRings(nowMs) === true;
        var seen = StandLogic.look(_mem, player.position, nowMs, full, _strikes, waking);
        _mem = seen.mem;
        if (seen.forgiven) _strikes = 0;
        if (seen.stoodMs <= 0 || app._orderLapsed()) return false;
        if (!waking) _strikes++;
        console.log("[ARP] position stood still for " + Math.round(seen.stoodMs / 1000)
                    + " s with a full buffer — the stream is taken for dead");
        // The buffer's writer drinks from the same station, and goes first:
        // the start that follows then arms a new one. Left up, it ended on
        // its own while that start was still waiting for the station, the
        // engine found nobody playing and the station came back with no
        // buffer at all (bench, a stall of forty seconds).
        engine.disarm();
        app._streamDied();
        return true;
    }

    // The player reported an error at nowMs.
    function _erred(nowMs) {
        _mem = StandLogic.erred(_mem, nowMs);
    }

    Timer {
        id: beat
        interval: StandLogic.TICK_MS
        repeat: true
        running: watch.watching
        onTriggered: watch._look(Date.now())
    }

    Connections {
        target: watch.player
        ignoreUnknownSignals: true
        function onErrorOccurred() { watch._erred(Date.now()); }
    }
}
