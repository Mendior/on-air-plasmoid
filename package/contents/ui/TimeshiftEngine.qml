/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
import QtQuick

import "TimeshiftLogic.js" as TimeshiftLogic
import "SlideLogic.js" as SlideLogic

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
    // ── The sliding buffer ──────────────────────────────────────────────
    // A plain arm whose address does not rule MP3 and AAC out gets a writer
    // that looks at the stream first (SlideLogic.buildWriter): bare MP3 or
    // AAC is cut into two-second segments in a folder that keeps the last
    // window, anything else goes into the single file as before. `cut` says
    // the arm has that writer, `slide` that it answered with segments.
    // Until it answers, nothing can be parked.
    property bool cut: false
    property bool slide: false
    // The folder holds enough for an open to land in: the Playing page
    // offers its steps (SlideLogic.STEP_READY_MS).
    property bool steppable: false
    property string slideDir: ""
    property string filePath: ""
    property string headPath: ""
    property string kindPath: ""
    readonly property string slideScriptPath: Qt.resolvedUrl("tsslide.sh").toString().substring(7)
    readonly property string probeScriptPath: Qt.resolvedUrl("streamkind.py").toString().substring(7)
    // What this session has learnt about the new road; reset() leaves these
    // alone. slideOff: the player could not open or search a list once, and
    // every arm takes the single file from then on. _slideDead: stations
    // whose cutting writer ended, which it never does by itself.
    // slideProven: one list has loaded and could be searched.
    property bool slideOff: false
    property var _slideDead: ({})
    property bool slideProven: false
    // The engine's own clock, in beats of a second (SlideLogic.beat). The
    // player's position on a list is no use: it stops at the length the
    // list had when it was opened while the sound goes on (measured). runMs
    // is how long this arm's writer has run, which is where in the buffer
    // "now" is; placeMs is where the listener is while shifted.
    property double runMs: 0
    property double placeMs: -1
    property double _runAt: 0
    property double _placeAt: 0
    // How far the listener on the broadcast is behind the writer's clock,
    // as the last park from live found it (SlideLogic.parkAt). The pill
    // counts "behind live" from there, not from the clock.
    property double liveLagMs: 0
    // The writer's clock at the moment the player last joined the
    // broadcast: 0 for the start both made together, the clock's reading
    // at each return to live after that. The player's position counts from
    // there. -1 when a return was not dated, and the position says nothing.
    property double liveBaseMs: 0
    // The list the player is on: its name and the last segment it names.
    property string listName: ""
    property int listLast: -1
    property int _listN: 0
    // A wish for a place, on its way through the folder: "have" while the
    // folder is asked what it holds, "list" while the list is written. One
    // at a time; a press that comes meanwhile only moves the wish.
    property double _wantMs: -1
    property string _stage: ""
    property bool _wishIsResume: false
    property var _plan: null
    property double _planWant: -1
    property int _haveSeq: -1
    property int _listSeq: -1
    property int _growSeq: -1
    property int _growBeats: 0
    property int _kindSeq: -1
    property int _kindTries: 0
    // The cutting writer ended while a listener sat in what it had caught:
    // the segments stay for them and nothing new comes.
    property bool slideFrozen: false
    property bool _toldOld: false
    // How much the arm's folder keeps (the window it was started with),
    // and how long ago its writer ended, counted by the same beats as the
    // clock: the broadcast went on, and the pill has to say so.
    property double keepMs: 0
    property double goneMs: 0

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

    // The writer's guard and the startup sweep (tsguard.sh) live beside this
    // file. A path is not a touch on the world, so it is not the facade's.
    readonly property string guardScriptPath: Qt.resolvedUrl("tsguard.sh").toString().substring(7)

    // The start clears what a host that died without its teardown left in
    // this widget's own directory. nowMs is the age line, so the caller runs
    // this before anything can arm: a url file written first would count as
    // the dead session's and be taken from under its own writer.
    function startup(nowMs) {
        var dir = app.tsBufferDir();
        if (!dir) return;
        app.exec(TimeshiftLogic.buildSweepCommand(guardScriptPath, dir, nowMs / 1000, app.nextSeq()));
    }

    function _seqOf(cmd) {
        var m = /#\s*(\d+)\s*$/.exec(String(cmd));
        return m ? parseInt(m[1]) : -1;
    }
    // The last position a horizon reopen aimed at — a second EndOfMedia
    // landing there again means the reopen gained nothing and the buffer
    // is truly drained.
    property double _lastReopenPosMs: -1
    // The last place the single file's reader was seen at, which is where
    // an open sent it until a tick has seen it further on. An end that
    // names no place is judged by this one (TimeshiftLogic.endPlaceMs).
    property double _heardPosMs: -1

    // The horizon watchdog. Qt estimates a growing buffer's duration when it
    // OPENS the file and never revises it — and on this stack (Qt 6.11.1 +
    // FFmpeg 9, measured live on the home machine 2026-08-11, twice) the
    // player reaching that frozen horizon does NOT deliver EndOfMedia: the
    // position pins, playbackState stays PlayingState and mediaStatus stays
    // BufferedMedia. Since playerEndOfMedia() sits behind EndOfMedia alone,
    // the engine's whole reopen-or-return machinery was dead code on this
    // road: a resumed pause played its parked minutes and then went silent
    // FOREVER while the widget still said "playing". Nothing else watches —
    // the buffer road deliberately stops the stall timer, the connect
    // watchdog and the heal road, because an ending buffer is the engine's
    // business. So the engine has to notice the freeze itself.
    // It watches the single file only. On a list the position stands still
    // by design while the sound goes on, and the engine's own clock is what
    // says when the list runs short (_beat).
    property double _tsLastPosMs: -1
    property double _tsFrozenSinceMs: 0
    Timer {
        id: tsHorizonWatch
        interval: 1000
        repeat: true
        running: engine.shifted && !engine.slide
        onTriggered: {
            var player = engine.app.playMusicRef;
            if (player) engine._horizonTick(engine.app.isPlaying(), player.position, Date.now());
        }
    }

    // A fresh open means a fresh horizon: the watchdog starts counting from
    // this reader, not from the one it just replaced.
    function _freshHorizon() {
        _tsLastPosMs = -1;
        _tsFrozenSinceMs = 0;
        _heardPosMs = shiftPosMs;
    }

    // What the single file can hold by now: wall time since its writer
    // started, or what it held when the writer ended.
    function _captured(nowMs) {
        return windowFull ? frozenCapturedMs : (nowMs - bufStartMs);
    }

    // Contract: true when the frozen horizon was handed to playerEndOfMedia.
    function _horizonTick(playing, pos, now) {
        // The watch is for a player that says it plays: one that is paused
        // in place stands still for a good reason, and starts counting anew.
        if (!shifted || slide || playing !== true) {
            _tsLastPosMs = -1;
            _tsFrozenSinceMs = 0;
            return false;
        }
        // Forward only: for a moment after an open the player still stands
        // at the file's start, and that is not where the listener is.
        _heardPosMs = Math.max(_heardPosMs, TimeshiftLogic.endPlaceMs(pos, _captured(now), _heardPosMs));
        // Any forward movement is a healthy reader; only a position that
        // stands still while the player claims to be playing counts.
        if (pos !== _tsLastPosMs) {
            _tsLastPosMs = pos;
            _tsFrozenSinceMs = now;
            return false;
        }
        if (_tsFrozenSinceMs <= 0) { _tsFrozenSinceMs = now; return false; }
        // Three seconds of a pinned position: a live decoder does not
        // sit that still, and the cost of being wrong is one reopen at
        // the same spot, which the engine's own stall guard absorbs.
        if (now - _tsFrozenSinceMs < 3000) return false;
        console.log("[ARP] timeshift: horizon reached without EndOfMedia — "
                    + "position frozen at " + pos + " for "
                    + (now - _tsFrozenSinceMs) + " ms; handing to the engine");
        _tsFrozenSinceMs = 0;
        _tsLastPosMs = -1;
        playerEndOfMedia(pos, now);
        return true;
    }

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
        // A relay buffer used to be hard-coded to an Ogg shell — right
        // for every codec the road was BUILT for (FLAC, Vorbis, Opus all
        // have Ogg mappings), and fatally wrong for everything the
        // rescue road later started feeding it: ffmpeg refuses to mux
        // mp3 into Ogg, the writer died at birth with zero bytes on
        // disk, and the player was handed a tap serving an empty file
        // (issue #11, measured live against the reporter's station —
        // "Unsupported codec id in stream 0", rc 234, 0 bytes; the same
        // stream into an .mka shell wrote 131 KB in eight seconds).
        // Matroska holds every codec either road can meet, so the relay
        // trusts it for anything that is not known to be Ogg-family.
        var ext = isRelay ? (relayOggFamily ? "ogg" : "mka")
                          : TimeshiftLogic.bufferExtension(url);
        // A plain arm that may be MP3 or AAC gets the writer that looks at
        // the stream before it cuts; until that writer has answered, there
        // is no buffer path to speak of. Whatever the address or a kind
        // already learnt rules out keeps the writer it always had, command
        // for command.
        var looks = !isRelay && !slideOff && _slideDead[url] !== true
                    && SlideLogic.mayCut(url, typeof app.tsKnownKind === "function" ? app.tsKnownKind(url) : "");
        filePath = dir + "/buffer-" + seq + ".mka";
        bufPath = looks ? "" : dir + "/buffer-" + seq + "." + ext;
        cfgFilePath = dir + "/url-" + seq + ".cfg";
        pidPath = dir + "/writer-" + seq + ".pid";
        var windowMin = Math.max(5, Math.min(240, cfg.timeshiftWindowMin || 60));
        var cmds = TimeshiftLogic.buildBufferCommands({
            url: url, cfgPath: cfgFilePath, outPath: looks ? filePath : bufPath, pidPath: pidPath,
            dirPath: dir, windowSec: windowMin * 60, guardPath: guardScriptPath,
            needKiB: TimeshiftLogic.bufferNeedKiB(windowMin, isRelay === true), seq: seq
        });
        var looking = "";
        if (looks) {
            slideDir = dir + "/buffer-" + seq + ".hls";
            keepMs = SlideLogic.listSize(windowMin) * SlideLogic.SEG_MS;
            headPath = dir + "/head-" + seq + ".bin";
            kindPath = dir + "/kind-" + seq + ".txt";
            looking = SlideLogic.buildWriter({
                cfgPath: cfgFilePath, dirPath: dir, slidePath: slideDir, outPath: filePath, pidPath: pidPath,
                headPath: headPath, kindPath: kindPath, probePath: probeScriptPath, guardPath: guardScriptPath,
                windowMin: windowMin, needKiB: TimeshiftLogic.bufferNeedKiB(windowMin, false), seq: seq
            });
            // A writer that could not be built leaves the arm on the single file.
            if (looking === "") { looks = false; bufPath = filePath; }
            else cmds.run = looking;
        }
        cut = looks;
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
    // What the FIRST arm learned about the stream's family. The address
    // often cannot say (radiomast serves FLAC from a path with no
    // extension — the relay's original clientele, issue #3), so the
    // caller who read the directory's codec passes the verdict in, and
    // every internal re-arm of the same stream reuses it instead of
    // re-deriving a worse answer from the bare URL.
    property bool relayOggFamily: false
    // A stream whose relay writer died at birth — a shell no container
    // fits, a server that refuses the second connection. Re-arming it
    // would loop: freeze, rescue, birth-death, live, freeze again, each
    // round audible. One death is the verdict for the session.
    property string _relayBirthDeathUrl: ""
    // When it died. A transient failure (a wifi handover, a server that
    // refused one connection) used to ban the station until the widget
    // restarted; ten minutes is long enough to break the loop and short
    // enough that the evening is not lost to one bad second.
    property double _relayBirthDeathAt: 0

    function armRelay(url, name, nowMs, oggFamily) {
        if (url === _relayBirthDeathUrl && nowMs - _relayBirthDeathAt < 10 * 60 * 1000) {
            console.log("[ARP] timeshift: this stream's relay writer died"
                        + " at birth once already — not re-arming");
            return false;
        }
        if (oggFamily !== undefined) relayOggFamily = (oggFamily === true);
        else if (url !== streamUrl)
            relayOggFamily = (TimeshiftLogic.relayExtension(url) === "ogg");
        if (!armCommon(url, name, nowMs, true)) return false;
        return true;
    }

    // How many times running the buffer had no title for the reader, and
    // whether ICY has answered that it has none (TimeshiftLogic.titleRoad).
    property int _bufTitleMisses: 0
    property bool _icyRefused: false

    // Contract: true when a title poll for url is to read the buffer file.
    function titlesInBuffer(url) {
        return relay && relayOggFamily && active && bufPath !== "" && url === streamUrl
               && TimeshiftLogic.titleRoad(_bufTitleMisses, _icyRefused) === "buffer";
    }

    // Every title answer for url passes here: fromBuffer says which reader
    // it came from, text is what it printed.
    // Contract: true when the answer is to be dropped, which is ICY's "no
    // titles here" about the Ogg stream this relay carries: the buffer goes
    // on being read, and the station is not written off.
    function titleAnswer(fromBuffer, text, url) {
        if (fromBuffer) {
            _bufTitleMisses = text === "" ? _bufTitleMisses + 1 : 0;
            return false;
        }
        if (text !== "__NO_ICY__" || !(relay && relayOggFamily && active && url === streamUrl)) return false;
        _icyRefused = true;
        return true;
    }

    // Playback of the tap fell over (serve died, port stolen, the player
    // erred out). Returns whether the engine took the recovery: a bounded
    // burst of quiet re-arms, then the caller's heal road owns it.
    function relayPlaybackFell(nowMs) {
        if (!relay || !active) return false;
        // A park owns the silence. The tap's own death arrives as a player
        // error against a source that was already stopped, and rebuilding it
        // here brought the room back up over the listener's pause — the same
        // terminus as the window-cap re-arm, by a second entrance.
        if (app._tsPaused) return false;
        // Nor does a night: the order has lapsed and is being taken down.
        if (app._orderLapsed()) return true;
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
        // The looking writer's arm has more to take away than one file: the
        // segments' folder with the lists in it, the bytes it looked at and
        // the word it left, and the single file if that is what it wrote.
        if (cut && slideDir !== "" && (active || writerUp || windowFull || slideFrozen))
            app.exec(SlideLogic.buildStop({ pidPath: pidPath, slidePath: slideDir, cfgPath: cfgFilePath, headPath: headPath,
                                            kindPath: kindPath, outPath: filePath, seq: app.nextSeq() }));
        else if (bufPath !== "" && (active || writerUp || windowFull))
            app.exec(TimeshiftLogic.buildStopCommand(pidPath, bufPath, cfgFilePath, app.nextSeq(),
                                                     srvPidPath, srvPortPath));
        reset(false);
    }

    function reset(quiet) {
        // A list's path is no buffer once its folder is gone.
        if (cut) bufPath = "";
        cut = false;
        slide = false;
        steppable = false;
        slideFrozen = false;
        keepMs = 0;
        goneMs = 0;
        runMs = 0;
        liveLagMs = 0;
        liveBaseMs = 0;
        placeMs = -1;
        _runAt = 0;
        _placeAt = 0;
        listName = "";
        listLast = -1;
        _growSeq = -1;
        _growBeats = 0;
        _kindSeq = -1;
        _kindTries = 0;
        _toldOld = false;
        _endWish();
        openGuard.stop();
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
        _bufTitleMisses = 0;
        _icyRefused = false;
        if (!quiet) { streamUrl = ""; stationName = ""; }
    }

    // The player went back to the live stream by a road that keeps the
    // buffer (a replay of the same station): the shifted state ends —
    // what plays now is the broadcast — but the caught minutes stay for
    // the next pause. Mirrors backToLive's bookkeeping without touching
    // the player.
    function noteLivePlayback(nowMs) {
        // The player joins the broadcast anew and counts its position from
        // nought; the writer's clock at this moment is where that nought is.
        liveBaseMs = nowMs > 0 ? _runNow(nowMs) : -1;
        shifted = false;
        shiftPosMs = -1;
        _lastReopenPosMs = -1;
        if (cut) {
            _endWish();
            openGuard.stop();
            placeMs = -1;
            listName = "";
            listLast = -1;
            if (slide) bufPath = "";
        }
        // A cutting writer that ended left its segments for the listener
        // who was in them. That listener is back on the broadcast now, and
        // the station's next buffer is a new one: the single file.
        if (slideFrozen) {
            armCommon(streamUrl, stationName, 0, false);
            return;
        }
        // An arm whose address write has not answered has no writer yet,
        // and is not a dead one: the widget's own start of the station
        // comes here a moment after the arm above, and retired it.
        if (windowFull || (!writerUp && _pendingRun === "")) active = false;
    }

    // The pause button while live. Returns the parked file position, or
    // -1 when this pause is not timeshift's to own (feature off, buffer
    // too young, writer never started) — the caller then stops plainly.
    // Whether a park is possible right now — the pause BUTTON asks this,
    // so the icon stops promising what the gesture refuses. A PROPERTY,
    // not a function of the clock: a binding that reads Date.now() is
    // evaluated once and never again, so the first version of this froze
    // the button on "stop" for the whole session while the gesture
    // underneath happily parked (caught by the listener within the hour,
    // 2026-08-11). The timer below is what makes time move for it.
    property bool parkable: false

    Timer {
        id: parkableTimer
        interval: minShiftMs
        repeat: false
        // A looking writer's arm has a buffer once it has said the single
        // file; a sliding one is timed by its own clock, in _beat.
        onTriggered: engine.parkable = engine.active && engine.writerUp
                                       && engine.bufStartMs > 0
                                       && (!engine.cut || (!engine.slide && engine.bufPath !== ""))
    }

    // Called wherever the buffer's life changes: the writer coming up
    // starts the countdown, everything else takes the promise away.
    function _reviseParkable(armedNow) {
        if (armedNow) {
            parkableTimer.restart();
            return;
        }
        parkableTimer.stop();
        parkable = false;
    }

    onWriterUpChanged: _reviseParkable(writerUp)
    onActiveChanged: if (!active) _reviseParkable(false)

    // livePosMs is the player's position on the broadcast, which only the
    // sliding buffer reads.
    function pauseGesture(nowMs, livePosMs) {
        var ran;
        // The looking writer has not said what it cuts: nothing to park in.
        if (cut && !slide && bufPath === "") return -1;
        if (slide) {
            // The place is where the player is on the broadcast, which is a
            // place in the buffer because both joined the station together
            // (SlideLogic.parkAt). Where exactly an open may land is the
            // folder's to say, when Play comes.
            if (!active || !writerUp || runMs < minShiftMs) return -1;
            ran = _runNow(nowMs);
            shiftPosMs = SlideLogic.parkAt(ran, liveBaseMs >= 0 && livePosMs > 0 ? liveBaseMs + livePosMs : 0);
            liveLagMs = ran - shiftPosMs;
            _toldOld = false;
            console.log("[ARP] timeshift: parked at " + shiftPosMs + " ms of the sliding buffer");
            return shiftPosMs;
        }
        // writerUp stays required, and the frozen-capture branch below
        // stays unreachable for a live listener ON PURPOSE — checked
        // 2026-08-11 rather than assumed: the writer's exit ack retires
        // `active` for anyone not already shifted, so an hour-capped
        // station loses its pause icon honestly instead of offering a
        // park it cannot serve.
        if (!active || !writerUp || bufStartMs <= 0) return -1;
        var captured = _captured(nowMs);
        if (captured < minShiftMs) return -1;
        shiftPosMs = TimeshiftLogic.clampSeekMs(captured, captured, edgeGuardMs);
        console.log("[ARP] timeshift: parked at " + shiftPosMs + " ms of "
                    + captured + " captured" + (windowFull ? " (window full)" : ""));
        return shiftPosMs;
    }

    // Play resumes: hand the player the buffer at the parked sentence. nowMs
    // is the caller's clock, which only the single file reads: its reader is
    // opened no nearer to the writer than the sliding buffer's opens are
    // (TimeshiftLogic.OPEN_GAP_MS), so after a pause of less than nine
    // seconds Play lands that far behind the broadcast and not at the park.
    // Without a clock the park is all there is to go by.
    function resumeGesture(nowMs) {
        if (!active || shiftPosMs < 0) {
            console.log("[ARP] timeshift: resume refused — active=" + active
                        + " shiftPos=" + shiftPosMs);
            return false;
        }
        if (slide) {
            // The folder is asked what it holds, a list is written for the
            // place, and the player opens that: two answers away.
            _wish(shiftPosMs, true);
            return true;
        }
        shifted = true;
        shiftPosMs = _openPlace(shiftPosMs, typeof nowMs === "number" ? _captured(nowMs) : NaN);
        _lastReopenPosMs = -1;
        _freshHorizon();
        app.tsPlayBuffer("file://" + bufPath, shiftPosMs);
        return true;
    }

    // Where the single file is opened for the place asked. A file whose
    // writer has ended has no unfinished end to keep clear of.
    function _openPlace(placeMs, capturedMs) {
        return TimeshiftLogic.openPlaceMs(placeMs, capturedMs, windowFull ? 0 : TimeshiftLogic.OPEN_GAP_MS);
    }

    // The listener jumps back to the broadcast. The writer keeps running —
    // the next pause lands in the same, longer buffer. A relayed stream
    // has no live to go back TO (the direct socket is the thing that
    // wedges) — its catch-up is a fresh buffer at today's edge.
    // nowMs is the caller's clock, like everywhere else in here. It used to
    // hand armRelay a literal 0, and once the ten-minute birth-death window
    // arrived that 0 made `nowMs - _relayBirthDeathAt` a large NEGATIVE
    // number — under the window forever, so a station that lost its writer
    // once could never be caught back up to live again.
    // The header over a return to live — see TimeshiftLogic.sleeveKept.
    // Whoever hears a title from the broadcast calls liveTitleSeen(); a
    // return nobody confirmed in time gives the header back empty.
    property double liveReturnAt: 0
    function sleeveKept(nowMs) {
        return TimeshiftLogic.sleeveKept(liveReturnAt, nowMs, app._wantsPlaying === true);
    }
    function liveTitleSeen() {
        liveReturnAt = 0;
        sleeveGuard.stop();
    }
    function _sleeveExpired() {
        if (liveReturnAt <= 0) return;
        liveReturnAt = 0;
        if (!app._tsPaused && !shifted) app.metadata = "";
    }
    Timer {
        id: sleeveGuard
        interval: TimeshiftLogic.SLEEVE_KEEP_MS
        onTriggered: engine._sleeveExpired()
    }

    function backToLive(nowMs) {
        if (!shifted && shiftPosMs < 0) return;
        // Before anything else: the flag below goes down and the player is
        // stopped in the same breath, and the stopped edge wipes the header
        // unless the keep is already up.
        liveReturnAt = nowMs > 0 ? nowMs : 0;   // no clock, no keep
        sleeveGuard.restart();
        if (relay) {
            armRelay(streamUrl, stationName, nowMs);
            return;
        }
        // Held before the note: a frozen sliding buffer is replaced there.
        var live = streamUrl;
        noteLivePlayback(nowMs);
        app.tsPlayLive(live);
    }

    // The player hit the duration Qt froze at open. If the file has grown
    // past it, reopen and carry on from the same place; if the buffer is
    // drained for real, the shift is over and live takes back over.
    function playerEndOfMedia(posMs, nowMs) {
        if (!shifted) return false;
        // A list has no end mark, so the player only ends on one that was
        // taken away or never grew: whatever the buffer held is played.
        if (slide) {
            backToLive(nowMs);
            return true;
        }
        var captured = _captured(nowMs);
        // The player's position is not always a place (endPlaceMs says when).
        var place = TimeshiftLogic.endPlaceMs(posMs, captured, _heardPosMs);
        console.log("[ARP] timeshift: horizon at " + place + " ms, captured " + captured + " — " + (captured - place)
                    + " ms behind" + (place === posMs ? "" : "; the player gave " + posMs + ", which is past the capture"));
        var stalled = _lastReopenPosMs >= 0 && place - _lastReopenPosMs < 500;
        if (!stalled && place >= 0 && captured - place > edgeGuardMs + 1000) {
            shiftPosMs = _openPlace(place - reopenOverlapMs, captured);
            _lastReopenPosMs = shiftPosMs;
            _freshHorizon();
            app.tsPlayBuffer("file://" + bufPath, shiftPosMs);
            return true;
        }
        // A drained relay buffer (window cap, writer death) starts over
        // with a fresh capture — the direct stream is not an option.
        if (relay) {
            armRelay(streamUrl, stationName, nowMs);
            return true;
        }
        backToLive(nowMs);
        return true;
    }

    // ── The sliding buffer's gestures ───────────────────────────────────

    // Contract: how far behind the broadcast the place posMs is, as "m:ss".
    // posMs is the single file's position; while the buffer slides it is
    // not read, the engine's own clock answers.
    function behindText(posMs, nowMs) {
        if (slide) return SlideLogic.clockText(SlideLogic.behindMs(runMs + goneMs - liveLagMs, shifted ? placeMs : shiftPosMs));
        // A reset engine (bufStartMs 0) would read as an epoch of lag.
        if (bufStartMs <= 0 || posMs < 0) return "0:00";
        return SlideLogic.clockText(TimeshiftLogic.behindLiveMs(bufStartMs, nowMs, posMs));
    }

    // A pause pressed by a listener who is inside the sliding buffer.
    // Contract: true when the place was parked (the caller stops the player
    // and raises its own park flag); false on the single file, where the
    // player pauses in place as it always did.
    function parkInPlace() {
        if (!slide || !shifted) return false;
        // A list cannot be paused on: the writer removes its oldest
        // segments under a player that stands still, and a player kept on
        // a list is one more thing that could run out of it.
        shiftPosMs = _stage !== "" ? _wantMs : placeMs;
        shifted = false;
        _toldOld = false;
        _endWish();
        openGuard.stop();
        return true;
    }

    // One press of a step button; deltaMs is negative for back.
    // Contract: true when the engine took the press. Parked, the park moves
    // and nothing sounds. Shifted, the place moves and the player is given a
    // new list, or the broadcast when the step lands at its edge. False
    // when there is no sliding buffer to step in.
    function stepGesture(deltaMs, nowMs) {
        if (!slide || !active || typeof deltaMs !== "number" || !isFinite(deltaMs) || deltaMs === 0) return false;
        if (shifted || _stage !== "") {
            // A press that comes while a wish is on its way steps on from
            // the wish, not from a place the player has not reached yet:
            // ten presses are five minutes, and one open.
            _wish(Math.max(0, (_stage !== "" ? _wantMs : placeMs) + deltaMs), _stage !== "" && _wishIsResume);
            return true;
        }
        // Live, with nothing parked: the caller parks first.
        if (shiftPosMs < 0) return false;
        // Parked: the park moves, between the buffer's start and where the
        // broadcast is, and stays silent.
        shiftPosMs = Math.max(0, Math.min(runMs - liveLagMs, shiftPosMs + deltaMs));
        return true;
    }

    // The player has loaded what tsPlayBuffer gave it.
    // Contract: true when the caller may send it to its place. False when
    // it was a list and the player cannot search one: the session's single
    // check, after which the station is back on the broadcast and its next
    // buffer is the single file.
    function sourceLoaded(seekable, durationMs) {
        if (!slide || !shifted || slideProven) return true;
        // Measured on Qt 6.12 with FFmpeg 9: a list of this kind loads with
        // its length and can be searched. Whether an older pair does was
        // not measured, so the first list of a session is asked.
        if (seekable === true && durationMs > 0) {
            slideProven = true;
            return true;
        }
        _slideFell("this player cannot search a list");
        return false;
    }

    // The player reported an error.
    // Contract: true when it was on a list of the sliding buffer, which the
    // engine has then left for the broadcast and the single file.
    function listPlaybackFell(nowMs) {
        if (!slide || !shifted) return false;
        _slideFell("the player gave up on a list");
        return true;
    }

    // One beat of the clock; the timer calls it once a second while a
    // cutting writer's arm is alive.
    function _beat(nowMs) {
        var ran = SlideLogic.beat(_runAt, nowMs);
        _runAt = nowMs;
        // A writer that has ended cut nothing in this second, and the
        // broadcast went on by it.
        if (writerUp) runMs += ran;
        else if (slideFrozen) goneMs += ran;
        // A parked place is not pushed out of the window: the capture ends
        // just before, and what was cut stays for Play (PARK_END_MS).
        if (slide && writerUp && !shifted && _stage === "" && SlideLogic.parkEndsCapture(shiftPosMs, runMs, keepMs)) _endCapture();
        if (slide && !parkable && active && writerUp && runMs >= minShiftMs) parkable = true;
        if (slide && !steppable && active && writerUp && runMs >= SlideLogic.STEP_READY_MS) steppable = true;
        if (!slide || !shifted) return;
        var heard = SlideLogic.beat(_placeAt, nowMs);
        _placeAt = nowMs;
        if (app.isPlaying()) placeMs += heard;
        if (_stage !== "") return;
        // One question to the folder at a time; one that got no answer in
        // five beats is asked again.
        if (_growSeq >= 0 && ++_growBeats >= 5) _growSeq = -1;
        var more = _growSeq < 0 ? SlideLogic.growBy(listLast, placeMs) : null;
        if (more) {
            _growSeq = app.nextSeq();
            _growBeats = 0;
            app.exec(SlideLogic.buildGrow({ scriptPath: slideScriptPath, slidePath: slideDir, seq: _growSeq, listName: listName,
                                            text: SlideLogic.entriesText(more.from, more.upto), from: more.from, upto: more.upto }));
        }
        // The writer has stalled or ended and the list is running short.
        // The player is taken off it while its reader still has list to
        // read: stopped once the reader waits for more, it would hold the
        // whole shell (SlideLogic.LEAVE_GAP_MS).
        if (SlideLogic.mustLeave((listLast + 1) * SlideLogic.SEG_MS, placeMs)) {
            console.log("[ARP] timeshift: the buffer has no more — back to the broadcast");
            backToLive(nowMs);
        }
    }

    // The capture ends and the folder stays, as after a writer that ended by
    // itself under a park: Play finds the place, what was kept is heard out,
    // and the broadcast that follows gets a new buffer (noteLivePlayback).
    function _endCapture() {
        console.log("[ARP] timeshift: the pause is a window old; the capture ends and what was cut stays");
        app.exec(SlideLogic.buildEnd({ pidPath: pidPath, seq: app.nextSeq() }));
        writerUp = false;
        slideFrozen = true;
    }

    // The writer's clock to the millisecond, between two beats.
    function _runNow(nowMs) {
        return runMs + (writerUp ? SlideLogic.beat(_runAt, nowMs) : 0);
    }

    // The folder has not answered a wish in time (wishGuard).
    function _wishLate() {
        if (_stage !== "") _slideFell("the folder did not answer");
    }

    // A list was opened a while ago (openGuard): does it sound?
    function _openLate() {
        if (slide && shifted && _stage === "" && !app.isPlaying()) _slideFell("a list did not start to sound");
    }

    // A place is wished for: a park's on Play, a step's. resume says the
    // wish is a park's own place, which is the one a notice is owed for
    // when the window has slid past it.
    function _wish(wantMs, resume) {
        _wantMs = wantMs;
        _wishIsResume = resume === true;
        if (_stage === "") _askFolder();
    }

    function _askFolder() {
        _stage = "have";
        _haveSeq = app.nextSeq();
        wishGuard.restart();
        app.exec(SlideLogic.buildHave({ scriptPath: slideScriptPath, slidePath: slideDir, seq: _haveSeq }));
    }

    function _endWish() {
        _stage = "";
        _wantMs = -1;
        _plan = null;
        _planWant = -1;
        _haveSeq = -1;
        _listSeq = -1;
        wishGuard.stop();
    }

    // Something about the new road failed. The folder goes, the listener
    // who was in it or on the way into it is given the broadcast (one gap,
    // the length of a station's start), and for the rest of the session
    // every buffer is the single file.
    function _slideFell(why) {
        console.log("[ARP] timeshift: the sliding buffer gave way to the single file — " + why);
        slideOff = true;
        var live = streamUrl;
        disarm();
        if (live !== "" && !app._orderLapsed()) app.tsPlayLive(live);
    }

    Timer {
        id: beatTimer
        interval: SlideLogic.TICK_MS
        repeat: true
        running: engine.cut && engine.active
        onTriggered: engine._beat(Date.now())
    }
    // The folder's two answers come in a few hundredths of a second; three
    // seconds without one is a helper that will not answer.
    Timer {
        id: wishGuard
        interval: 3000
        onTriggered: engine._wishLate()
    }
    // A list sounded 0.1 s after it was opened on the bench.
    Timer {
        id: openGuard
        interval: 4000
        onTriggered: engine._openLate()
    }

    // Acks from the two shell roads. nowMs rides in as a parameter so the
    // tests own the clock, the same convention AlarmLogic settled on.
    // exitCode is additive (2026-08-09) — see SyncEngine.handleExec.
    function handleExec(cmd, stdout, nowMs, exitCode) {
        var word, have, plan, upto, put, at, tell, grown;
        if (cmd.indexOf(": TS_URL;") === 0) {
            // Another arm's leftover ack changes nothing here.
            if (_seqOf(cmd) !== _armSeq || _armSeq < 0) return true;
            if (stdout.indexOf("__TS_URL_OK__") !== -1 && active && _pendingRun !== "") {
                var run = _pendingRun;
                _pendingRun = "";
                bufStartMs = nowMs;
                writerUp = true;
                app.exec(run);
                if (cut) {
                    // The looking writer says what it cuts once it has the
                    // stream's first bytes; this waits for the word.
                    _runAt = nowMs;
                    _kindTries = 0;
                    _kindSeq = app.nextSeq();
                    app.exec(SlideLogic.buildKindWait({ kindPath: kindPath, seq: _kindSeq }));
                }
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
                // A park that landed while the tap was coming up must not be
                // undone by its UP ack: tsPlayRelay clears _tsPaused and plays.
                if (relay && active && !shifted && !app._tsPaused) {
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
            if (slide && stdout.indexOf("__TS_EXIT__") !== -1) {
                // A cutting writer has no cap and never ends by itself: it
                // was killed, the station closed, or the stream stood still
                // for half a minute. One that has to be started again starts
                // a new buffer with a new clock. It slides again unless this
                // writer ended in its first minute: then it could not cut
                // this station, and the single file takes it for the session.
                console.log("[ARP] timeshift: the segment writer ended — " + String(stdout).trim());
                if (SlideLogic.endedYoung(runMs)) _slideDead[streamUrl] = true;
                // A listener parked in the segments, or hearing them, keeps
                // every one that was cut.
                if (shifted || shiftPosMs >= 0 || _stage !== "") {
                    slideFrozen = true;
                    return true;
                }
                // Replaced only under a listener who hears the station; a
                // room nobody is in is left without a buffer. A writer is
                // not sound, so the order is not asked about here.
                if (app.isPlaying() && !app._tsPaused) armCommon(streamUrl, stationName, nowMs, false);
                else disarm();
                return true;
            }
            if (stdout.indexOf("__TS_EXIT__") !== -1) {
                // The ack carries the writer's own evidence, and a birth
                // death must not be filed as a filled window: zero bytes
                // on disk means "this stream cannot be relayed", not "an
                // hour of audio is waiting". The listener gets the truth
                // and the player is sent back to the direct stream it
                // came from instead of a tap serving an empty file
                // forever (issue #11 — the interruption WAS this filing
                // error, silence with a playing icon behind it).
                var exitBytes = -1;
                var ebM = stdout.match(/__TS_EXIT__ rc=\d+ bytes=(\d+)/);
                if (ebM) exitBytes = parseInt(ebM[1], 10);
                if (relay && exitBytes === 0) {
                    console.log("[ARP] timeshift: relay writer died at birth"
                                + " — zero bytes; returning to the direct"
                                + " stream");
                    // The direct stream is the one that wedged in the first
                    // place, so a listener left with silence has to be told
                    // why (found 2026-09-05: no word reached them at all).
                    app.notify(i18n("The stream could not be relayed — trying it directly"),
                               stationName, "dialog-warning");
                    var backTo = streamUrl;
                    var wasShifted = shifted;
                    // The tap usually answers before a refused shell kills
                    // the writer: measured on an MP3 stream the directory
                    // called FLAC, the UP ack at 0.26 s and this one at
                    // 0.35 s. The player had been sent to the tap by then
                    // and was still opening it, which is not "playing".
                    var onTap = serveUp;
                    reset(true);
                    active = false;
                    _relayBirthDeathUrl = backTo;
                    _relayBirthDeathAt = nowMs;
                    // Live sound only for a room that was audibly playing,
                    // or one this arm itself had just sent to its tap: a
                    // parked or shifted listener chose silence, and a
                    // writer's death is no licence to override them. Left
                    // on the dead tap the player stood silent until the tap
                    // gave up ten seconds on, and what came after was the
                    // heal road's knock (15 s on the bench) or, for an
                    // audition, nothing at all.
                    if (backTo !== "" && !wasShifted && !app._tsPaused && (app.isPlaying() || onTap) && !app._orderLapsed())
                        app.tsPlayLive(backTo);
                    return true;
                }
                // A relayed LIVE listener loses their audio source when the
                // writer stops (window cap after an hour, upstream restart):
                // re-arm quietly — the player coasts on the server burst it
                // holds while the fresh tap comes up. Only a writer that
                // lived a while earns this; one that died at birth is a dead
                // stream, and re-arming it forever would spin.
                // …but not over a PARK. The engine's own `shifted` only turns
                // true on a resume, so a parked relay looks exactly like a live
                // one from here — and the hour cap then re-armed it, brought the
                // tap up and played the room awake with nobody asking. The park
                // lives on the app side, so that is where the question goes.
                // Nor for a room nobody is in. A bare stop() carries no park
                // flag, so a relay left armed behind one looked live from here
                // too: at the cap it re-armed, took its UP ack and played a
                // station that had been silent for an hour. The birth-death
                // branch above already asks the player, and this one must.
                if (relay && !shifted && !app._tsPaused
                    && bufStartMs > 0 && nowMs - bufStartMs >= 60000
                    && app.isPlaying()
                    && _relayRestarts < 3 && !app._orderLapsed()) {
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
        // The signal's own answer says nothing; the writer's end comes by TS_RUN.
        if (cmd.indexOf(": TS_END;") === 0) return true;
        if (cmd.indexOf(": TS_KIND;") === 0) {
            if (!cut || !active || _seqOf(cmd) !== _kindSeq) return true;
            word = SlideLogic.parseKind(stdout);
            if (word === "file") {
                // Neither MP3 nor AAC: the single file, and from here on
                // the arm is the one it always was.
                bufPath = filePath;
                if (writerUp) _reviseParkable(true);
            } else if (word !== "") {
                slide = true;
                // The clock starts here, with the stream's first bytes, and
                // not with the command: a writer armed while the station is
                // silent waits for them, and so does the player. A start the
                // widget made in that wait was dated on a clock not begun.
                runMs = 0;
                _runAt = nowMs;
                if (liveBaseMs > 0) liveBaseMs = 0;
                console.log("[ARP] timeshift: the buffer slides, in segments of " + word);
            } else if (writerUp && ++_kindTries < 3) {
                // No word in twenty seconds: a station that is slow to send.
                // Asked twice more, then left without a buffer to park in.
                _kindSeq = app.nextSeq();
                app.exec(SlideLogic.buildKindWait({ kindPath: kindPath, seq: _kindSeq }));
            }
            return true;
        }
        if (cmd.indexOf(": TS_HAVE;") === 0) {
            if (_stage !== "have" || _seqOf(cmd) !== _haveSeq) return true;
            have = SlideLogic.parseHave(stdout);
            plan = have ? SlideLogic.openPlan(_wantMs, have.first, have.last) : null;
            // Too little in the folder to open anything, or a step forward
            // that lands where the broadcast is: live is the honest answer.
            if (!plan || !plan.ok || (shifted && SlideLogic.stepWhat(placeMs, _wantMs - placeMs,
                                                                     (have.last + 1) * SlideLogic.SEG_MS) === "live")) {
                backToLive(nowMs);
                return true;
            }
            _plan = plan;
            _planWant = _wantMs;
            _stage = "list";
            _listSeq = app.nextSeq();
            _listN++;
            // The list reaches as far past the place as it is kept filled
            // later, not to the newest segment: it only has to stay ahead
            // of the player's reader.
            upto = Math.min(have.last, SlideLogic.segOf(plan.startMs + SlideLogic.AHEAD_MS - 1));
            app.exec(SlideLogic.buildWrite({ scriptPath: slideScriptPath, slidePath: slideDir, seq: _listSeq,
                                             listName: "play-" + _listN + ".m3u8",
                                             text: SlideLogic.listText(plan.firstSeg, upto), upto: upto }));
            return true;
        }
        if (cmd.indexOf(": TS_LIST;") === 0) {
            if (_stage !== "list" || _seqOf(cmd) !== _listSeq) return true;
            put = SlideLogic.parseList(stdout);
            if (!put) {
                _slideFell("a list could not be written");
                return true;
            }
            // A press came while the list was being written: the wish has
            // moved, and this list is for a place nobody wants any more.
            if (_wantMs !== _planWant) {
                _askFolder();
                return true;
            }
            at = _plan;
            tell = _wishIsResume && at.clamped === "old" && !_toldOld;
            _endWish();
            listName = "play-" + _listN + ".m3u8";
            listLast = put.last;
            placeMs = at.startMs;
            _placeAt = nowMs;
            shiftPosMs = at.startMs;
            shifted = true;
            // The list's path is the buffer's path for everyone who asks
            // whether what the player holds is the buffer.
            bufPath = slideDir + "/" + listName;
            _growSeq = -1;
            _growBeats = 0;
            openGuard.restart();
            if (tell) {
                _toldOld = true;
                app.notify(i18n("The paused place is no longer kept — playing from the oldest moment"), stationName, "dialog-information");
            }
            app.tsPlayBuffer("file://" + bufPath, at.seekMs);
            return true;
        }
        if (cmd.indexOf(": TS_GROW;") === 0) {
            if (_seqOf(cmd) !== _growSeq) return true;
            _growSeq = -1;
            grown = SlideLogic.parseList(stdout);
            if (grown && slide && shifted && grown.last > listLast) listLast = grown.last;
            return true;
        }
        if (cmd.indexOf(": TS_SWEEP;") === 0) {
            // Nothing to act on — the sweep is done when it answers. A line
            // in the journal when it found something, so a crash that left a
            // writer behind can be told from one that did not.
            var sw = /__TS_SWEEP__ stopped=(\d+) removed=(\d+)/.exec(stdout || "");
            if (sw && (sw[1] !== "0" || sw[2] !== "0"))
                console.log("[ARP] timeshift: the last session left " + sw[1]
                            + " writer(s) running and " + sw[2] + " file(s) behind — cleared");
            return true;
        }
        return false;
    }
}
