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
    // tsPlayRelay(relayUrl) — point the player at the loopback tap
    // tsServeScriptPath() — where the tap's python lives on disk
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
    // from issue #3, position frozen at 256 ms). The same curl that feeds
    // the buffer fetches WITHOUT whatever the socket road trips on, and a
    // small loopback HTTP tap re-serves those clean bytes to the player —
    // which then treats them as the live stream they are (duration stays
    // 0, so the horizon machinery never enters; measured 90 s without a
    // stall where the file road stopped dead at its frozen duration every
    // few seconds). Relay arms no matter what the timeshift checkbox says
    // — this is playability, not a feature — and "back to live" re-arms a
    // fresh capture instead of handing the player back to a stream it
    // cannot drink.
    property bool relay: false
    // The loopback tap answered on its port — the player may connect.
    property bool serveUp: false
    // Known only from the tap's UP ack: the kernel assigns the port at
    // bind. (An early scheme derived one from the global exec counter,
    // which every metadata poll advances — the 180-slot range recycled
    // within minutes and a collision was a silently dead tap.)
    property int relayPort: 0
    readonly property string relayUrl: relayPort > 0 ? "http://127.0.0.1:" + relayPort + "/" : ""
    property string srvPidPath: ""
    property string srvPortPath: ""
    property string _srvPendingRun: ""
    // The tap gets ONE quiet relaunch per arm — a crash at bind can be
    // transient, but a python that is missing or broken outright would
    // answer every retry with the same DOWN forever.
    property bool _srvRetried: false
    // The tap died mid-listen (client hiccup, port stolen, writer capped):
    // a bounded number of quiet re-arms keeps the music going; past the
    // cap the stream itself is the problem and the heal road owns it.
    property int _relayRestarts: 0
    Timer {
        id: relayRestartDecay
        interval: 60000
        repeat: false
        onTriggered: engine._relayRestarts = 0
    }
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
        // A relay buffer is always an Ogg shell: every codec this road
        // exists for (FLAC, Vorbis, Opus) has an Ogg mapping, and the tap
        // needs ONE input format it can trust — the address often cannot
        // say (radiomast serves FLAC from a path with no extension).
        var ext = isRelay ? "ogg" : TimeshiftLogic.bufferExtension(url);
        bufPath = dir + "/buffer-" + seq + "." + ext;
        cfgFilePath = dir + "/url-" + seq + ".cfg";
        pidPath = dir + "/writer-" + seq + ".pid";
        var windowMin = Math.max(5, Math.min(240, cfg.timeshiftWindowMin || 60));
        var cmds = TimeshiftLogic.buildBufferCommands({
            url: url, cfgPath: cfgFilePath, outPath: bufPath, pidPath: pidPath,
            dirPath: dir, windowSec: windowMin * 60,
            needKiB: TimeshiftLogic.bufferNeedKiB(windowMin, isRelay === true), seq: seq
        });
        active = true;
        relay = isRelay === true;
        if (relay) {
            srvPidPath = dir + "/serve-" + seq + ".pid";
            srvPortPath = dir + "/serve-" + seq + ".port";
            _srvPendingRun = _serveRun(seq);
        }
        _pendingRun = cmds.run;
        _armSeq = seq;
        app.exec(cmds.writeUrl);
        return true;
    }

    // The tap's launch command for THIS arm — built from the arm's own
    // paths so the DOWN retry re-runs the same identity, not a new one
    // (a fresh seq would fail the ack's identity check and go ignored).
    function _serveRun(seq) {
        return TimeshiftLogic.buildServeCommands({
            bufPath: bufPath, srvPidPath: srvPidPath, portPath: srvPortPath,
            scriptPath: app.tsServeScriptPath(), seq: seq
        }).run;
    }

    // A stream the backend cannot play directly: same arm, three
    // differences — no config gate, the relay flag, and the player is
    // pointed at the loopback tap the moment its port answers.
    function armRelay(url, name, nowMs) {
        if (!armCommon(url, name, nowMs, true)) return false;
        return true;
    }

    // Playback of the tap fell over (serve died, port stolen, the player
    // erred out). Returns whether the engine took the recovery: a bounded
    // burst of quiet re-arms, then the caller's heal road owns it.
    function relayPlaybackFell(nowMs) {
        if (!relay || !active) return false;
        if (_relayRestarts >= 3) {
            disarm();
            return false;
        }
        _relayRestarts++;
        relayRestartDecay.restart();
        armRelay(streamUrl, stationName, nowMs);
        return true;
    }

    // A station starts playing: begin catching it, if the feature is on
    // and the stream is the recordable kind. Returns whether a buffer is
    // being built — the caller changes nothing either way.
    function armForStation(url, name, nowMs) {
        return armCommon(url, name, nowMs, false);
    }

    // Playback of this station is over (stop, station switch, cast): the
    // buffer's reason to exist is gone with it. The stop command goes out
    // whenever a buffer was ever built this arm — a writer that already
    // exited leaves a file worth removing all the same.
    function disarm() {
        if (bufPath !== "" && (active || writerUp || windowFull))
            app.exec(TimeshiftLogic.buildStopCommand(pidPath, bufPath, cfgFilePath, app.nextSeq(),
                                                     srvPidPath, srvPortPath));
        reset(false);
    }

    function reset(quiet) {
        active = false;
        writerUp = false;
        shifted = false;
        relay = false;
        serveUp = false;
        relayPort = 0;
        srvPidPath = "";
        srvPortPath = "";
        _srvPendingRun = "";
        _srvRetried = false;
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
                if (relay && _srvPendingRun !== "") {
                    // The tap launches beside the writer; its UP ack — not a
                    // guessed timer — is what points the player at the port.
                    var srv = _srvPendingRun;
                    _srvPendingRun = "";
                    app.exec(srv);
                }
            } else {
                reset(false);
            }
            return true;
        }
        if (cmd.indexOf(": TS_SRV;") === 0) {
            if (_seqOf(cmd) !== _armSeq || _armSeq < 0) return true;
            // The port arrives IN the ack — the kernel picked it at bind,
            // nobody here ever guessed it. An UP that lost its number is
            // treated as a fall: pointing the player at a guess is exactly
            // the silent-death road this handshake replaced.
            var pm = /__TS_SRV_UP__ port=(\d+)/.exec(stdout);
            var port = pm ? parseInt(pm[1], 10) : 0;
            if (port > 0 && port < 65536) {
                if (relay && active && !shifted) {
                    relayPort = port;
                    serveUp = true;
                    app.tsPlayRelay(relayUrl);
                }
                return true;
            }
            if (relay && active && !shifted && !_srvRetried) {
                // One quiet relaunch: a crash at bind can be transient,
                // and the writer beside the tap is perfectly healthy.
                _srvRetried = true;
                app.exec(_serveRun(_armSeq));
                return true;
            }
            // The tap never answered twice (the command reaped its own
            // children). The player stays where it is: worst case is
            // exactly the pre-relay status quo.
            serveUp = false;
            return true;
        }
        if (cmd.indexOf(": TS_RUN;") === 0) {
            // The previous station's writer, killed by the re-arm's
            // disarm, still reports its exit — that death is old news
            // and must not tear the CURRENT arm down.
            if (_seqOf(cmd) !== _armSeq || _armSeq < 0) return true;
            writerUp = false;
            if (stdout.indexOf("__TS_EXIT__") !== -1) {
                // A relayed LIVE listener loses their audio source when the
                // writer stops (window cap after an hour, upstream restart):
                // re-arm quietly — the player coasts on the server burst it
                // holds while the fresh tap comes up. Only a writer that
                // lived a while earns this; one that died at birth is a dead
                // stream, and re-arming it forever would spin.
                if (relay && !shifted && bufStartMs > 0 && nowMs - bufStartMs >= 60000
                    && _relayRestarts < 3) {
                    _relayRestarts++;
                    relayRestartDecay.restart();
                    armRelay(streamUrl, stationName, nowMs);
                    return true;
                }
                // The window cap or the stream's end — the caught audio
                // stays servable. Live-side listeners just lose the arm.
                windowFull = true;
                frozenCapturedMs = bufStartMs > 0 ? nowMs - bufStartMs : 0;
                if (!shifted && shiftPosMs < 0) active = false;
            } else {
                // No tool, no space, no dir: for a plain arm timeshift is
                // a bonus, not a broken promise — fold quietly. A relay
                // arm IS the playback road, and a full disk there means
                // the station cannot play at all: say why, or the silence
                // reads as a dead stream.
                if (relay && stdout.indexOf("__TS_NOSPACE__") !== -1)
                    app.notify(i18n("Not enough free disk space"),
                               stationName, "dialog-error");
                if (!shifted) reset(false);
            }
            return true;
        }
        if (cmd.indexOf(": TS_STOP;") === 0) return true;
        return false;
    }
}
