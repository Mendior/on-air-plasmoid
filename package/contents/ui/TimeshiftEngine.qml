/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
import QtQuick

import "TimeshiftLogic.js" as TimeshiftLogic

// Pausing live radio, as a state machine and nothing else. A background
// writer (curl|ffmpeg, built in TimeshiftLogic) copies the stream into a
// local file; this engine decides when that file is worth playing, where
// in it a pause resumes, and what to do when the player hits the horizon
// Qt froze at open (measured 2026-08-03: duration never grows after open,
// EndOfMedia stops the player, a reopen+seek carries on). Every touch on
// the world goes through the app facade — the same seam that made the
// sync engine testable.
Item {
    id: engine

    // exec(cmd) / nextSeq() / notify(t, x, i) / tsBufferDir()
    // tsPlayBuffer(fileUrl, posMs) / tsPlayLive(streamUrl)
    required property var app
    // timeshiftEnabled (bool), timeshiftWindowMin (int)
    required property var cfg

    // A writer is running (or being launched) for the current station.
    property bool active: false
    // The run command is actually out — before this, there is no buffer.
    property bool writerUp: false
    // The player is drinking from the buffer file, not the stream.
    property bool shifted: false
    // Relay mode: the stream is one the ffmpeg backend cannot play off the
    // socket at all (live Ogg-family — FLAC/Vorbis/Opus — wedges within
    // the first frames; measured on Qt 6.11 with the frequence3 stream
    // from issue #3, position frozen at 256 ms). The same buffer pipeline
    // makes them playable: curl fetches WITHOUT the ICY interleaving that
    // breaks the Ogg framing, and the file plays clean. Relay arms no
    // matter what the timeshift checkbox says — this is playability, not
    // a feature — and "back to live" re-arms a fresh buffer instead of
    // handing the player back to a stream it cannot drink.
    property bool relay: false
    // The writer has exited (window cap, stream end): the file is frozen
    // but intact — a shifted listener keeps every second already caught.
    property bool windowFull: false
    property double bufStartMs: 0
    // Wall-time size of the buffer at the moment the writer exited; the
    // reopen decision must judge a frozen file by this, not by a wall
    // clock that keeps running past it.
    property double frozenCapturedMs: -1
    property string streamUrl: ""
    property string stationName: ""
    property string bufPath: ""
    property string pidPath: ""
    property string cfgFilePath: ""
    // Where a pause parked, in file-ms; -1 = nothing parked.
    property double shiftPosMs: -1
    property string _pendingRun: ""
    // THIS arm's sequence number, matched against the "# <seq>" tail every
    // command carries. Acks need an identity, not just the sentinel prefix:
    // the previous arm's writer — killed by disarm moments before a re-arm
    // — still delivers its __TS_EXIT__, and a prefix match would land that
    // exit on the NEW arm's state (writerUp down, pause icon dead). The
    // tail is the identity rather than the whole string because the app's
    // exec facade rewrites the command body (an LC_ALL export lands after
    // the sentinel) — full-string equality silently matched NOTHING and
    // seven arms in a row left their url files orphaned before the writer
    // ever ran once.
    property int _armSeq: -1

    function _seqOf(cmd) {
        var m = /#\s*(\d+)\s*$/.exec(String(cmd));
        return m ? parseInt(m[1]) : -1;
    }
    // The last position a horizon reopen aimed at — a second EndOfMedia
    // landing there again means the reopen gained nothing and the buffer
    // is truly drained.
    property double _lastReopenPosMs: -1

    // The writer is mid-frame at the file's very end; the last moments
    // stay out of reach (matches the flush cadence measured on the bench).
    readonly property int edgeGuardMs: 3000
    // A reopen steps back a touch so no frame is skipped across the seam.
    readonly property int reopenOverlapMs: 300
    // A pause younger than this is not worth a shift — the plain stop
    // road serves it better than a two-second buffer would.
    readonly property int minShiftMs: 5000

    function armCommon(url, name, nowMs, isRelay) {
        // The previous station's writer dies first — re-arming with only a
        // state reset would leave its ffmpeg copying a stream nobody plays.
        disarm();
        if (!isRelay && cfg.timeshiftEnabled !== true) return false;
        if (!TimeshiftLogic.canTimeshift(url)) return false;
        var dir = app.tsBufferDir();
        if (!dir) return false;
        streamUrl = url;
        stationName = name || "";
        // Every arm names its own files. Fixed names let the OUTGOING
        // arm's delayed stop (sleep 1; rm) delete the incoming arm's
        // fresh buffer out from under its writer.
        var seq = app.nextSeq();
        bufPath = dir + "/buffer-" + seq + "." + TimeshiftLogic.bufferExtension(url);
        cfgFilePath = dir + "/url-" + seq + ".cfg";
        pidPath = dir + "/writer-" + seq + ".pid";
        var windowMin = Math.max(5, Math.min(240, cfg.timeshiftWindowMin || 60));
        var cmds = TimeshiftLogic.buildBufferCommands({
            url: url, cfgPath: cfgFilePath, outPath: bufPath, pidPath: pidPath,
            dirPath: dir, windowSec: windowMin * 60,
            needKiB: windowMin * 2048, seq: seq
        });
        active = true;
        relay = isRelay === true;
        _pendingRun = cmds.run;
        _armSeq = seq;
        app.exec(cmds.writeUrl);
        return true;
    }

    // A stream the backend cannot play directly: same arm, three
    // differences — no config gate, the relay flag, and playback starts
    // from the file by itself once a few seconds are on disk.
    function armRelay(url, name, nowMs) {
        if (!armCommon(url, name, nowMs, true)) return false;
        return true;
    }

    // A station starts playing: begin catching it, if the feature is on
    // and the stream is the recordable kind. Returns whether a buffer is
    // being built — the caller changes nothing either way.
    function armForStation(url, name, nowMs) {
        return armCommon(url, name, nowMs, false);
    }

    Timer {
        id: relayStart
        // Enough file for the reader to sit a steady ~3 s behind the
        // writer — the gap stays constant at 1x, so the horizon reopen
        // almost never fires in relay play.
        interval: 3000
        repeat: false
        onTriggered: {
            if (!engine.relay || !engine.active || !engine.writerUp || engine.shifted) return;
            engine.shifted = true;
            engine._lastReopenPosMs = -1;
            engine.app.tsPlayBuffer("file://" + engine.bufPath, 0);
        }
    }

    // Playback of this station is over (stop, station switch, cast): the
    // buffer's reason to exist is gone with it. The stop command goes out
    // whenever a buffer was ever built this arm — a writer that already
    // exited leaves a file worth removing all the same.
    function disarm() {
        if (bufPath !== "" && (active || writerUp || windowFull))
            app.exec(TimeshiftLogic.buildStopCommand(pidPath, bufPath, cfgFilePath, app.nextSeq()));
        reset(false);
    }

    function reset(quiet) {
        active = false;
        writerUp = false;
        shifted = false;
        relay = false;
        relayStart.stop();
        windowFull = false;
        bufStartMs = 0;
        frozenCapturedMs = -1;
        shiftPosMs = -1;
        _pendingRun = "";
        _armSeq = -1;
        _lastReopenPosMs = -1;
        if (!quiet) { streamUrl = ""; stationName = ""; }
    }

    // The player went back to the live stream by a road that keeps the
    // buffer (a replay of the same station): the shifted state ends —
    // what plays now is the broadcast — but the caught minutes stay for
    // the next pause. Mirrors backToLive's bookkeeping without touching
    // the player.
    function noteLivePlayback() {
        shifted = false;
        shiftPosMs = -1;
        _lastReopenPosMs = -1;
        if (windowFull || !writerUp) active = false;
    }

    // The pause button while live. Returns the parked file position, or
    // -1 when this pause is not timeshift's to own (feature off, buffer
    // too young, writer never started) — the caller then stops plainly.
    function pauseGesture(nowMs) {
        if (!active || !writerUp || bufStartMs <= 0) return -1;
        var captured = windowFull ? frozenCapturedMs : (nowMs - bufStartMs);
        if (captured < minShiftMs) return -1;
        shiftPosMs = TimeshiftLogic.clampSeekMs(captured, captured, edgeGuardMs);
        return shiftPosMs;
    }

    // Play resumes: hand the player the buffer at the parked sentence.
    function resumeGesture() {
        if (!active || shiftPosMs < 0) return false;
        shifted = true;
        _lastReopenPosMs = -1;
        app.tsPlayBuffer("file://" + bufPath, shiftPosMs);
        return true;
    }

    // The listener jumps back to the broadcast. The writer keeps running —
    // the next pause lands in the same, longer buffer. A relayed stream
    // has no live to go back TO (the direct socket is the thing that
    // wedges) — its catch-up is a fresh buffer at today's edge.
    function backToLive() {
        if (!shifted && shiftPosMs < 0) return;
        if (relay) {
            armRelay(streamUrl, stationName, 0);
            return;
        }
        noteLivePlayback();
        app.tsPlayLive(streamUrl);
    }

    // The player hit the duration Qt froze at open. If the file has grown
    // past it, reopen and carry on from the same place; if the buffer is
    // drained for real, the shift is over and live takes back over.
    function playerEndOfMedia(posMs, nowMs) {
        if (!shifted) return false;
        var captured = windowFull ? frozenCapturedMs : (nowMs - bufStartMs);
        var stalled = _lastReopenPosMs >= 0 && posMs - _lastReopenPosMs < 500;
        if (!stalled && captured - posMs > edgeGuardMs + 1000) {
            shiftPosMs = Math.max(0, posMs - reopenOverlapMs);
            _lastReopenPosMs = shiftPosMs;
            app.tsPlayBuffer("file://" + bufPath, shiftPosMs);
            return true;
        }
        // A drained relay buffer (window cap, writer death) starts over
        // with a fresh capture — the direct stream is not an option.
        if (relay) {
            armRelay(streamUrl, stationName, nowMs);
            return true;
        }
        backToLive();
        return true;
    }

    // Acks from the two shell roads. nowMs rides in as a parameter so the
    // tests own the clock, the same convention AlarmLogic settled on.
    function handleExec(cmd, stdout, nowMs) {
        if (cmd.indexOf(": TS_URL;") === 0) {
            // Another arm's leftover ack changes nothing here.
            if (_seqOf(cmd) !== _armSeq || _armSeq < 0) return true;
            if (stdout.indexOf("__TS_URL_OK__") !== -1 && active && _pendingRun !== "") {
                var run = _pendingRun;
                _pendingRun = "";
                bufStartMs = nowMs;
                writerUp = true;
                app.exec(run);
                if (relay) relayStart.restart();
            } else {
                reset(false);
            }
            return true;
        }
        if (cmd.indexOf(": TS_RUN;") === 0) {
            // The previous station's writer, killed by the re-arm's
            // disarm, still reports its exit — that death is old news
            // and must not tear the CURRENT arm down.
            if (_seqOf(cmd) !== _armSeq || _armSeq < 0) return true;
            writerUp = false;
            if (stdout.indexOf("__TS_EXIT__") !== -1) {
                // The window cap or the stream's end — the caught audio
                // stays servable. Live-side listeners just lose the arm.
                windowFull = true;
                frozenCapturedMs = bufStartMs > 0 ? nowMs - bufStartMs : 0;
                if (!shifted && shiftPosMs < 0) active = false;
            } else {
                // No tool, no space, no dir: timeshift is a bonus, not a
                // broken promise — fold quietly, playback is untouched.
                if (!shifted) reset(false);
            }
            return true;
        }
        if (cmd.indexOf(": TS_STOP;") === 0) return true;
        return false;
    }
}
