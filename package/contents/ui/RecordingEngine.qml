/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick

import "AlarmLogic.js" as AlarmLogic
import "PodcastLogic.js" as PodcastLogic
import "RecLogic.js" as RecLogic
import "StreamLogic.js" as StreamLogic

// ── The recording engine ─────────────────────────────────────────────────────
// A SECOND ffmpeg connection captures the raw stream bit-exactly (-c copy),
// one at a time, personal use only. Two kinds: instant (follows playback) and
// scheduled (independent of it). Everything here is engine-owned; the widget
// reaches in only through the facade for the handful of PLAYER facts a capture
// needs — is a stream playing, what is its source, is a stop fade running —
// plus exec/notify/nextSeq and the run-dir the pid and url files live in.
Item {
    id: engine

    // main.qml's root. Used: exec, nextSeq, notify, downloadDirPath,
    // _mprisRunDir, _mprisId, isPlaying(), upstreamSourceString(),
    // currentStation, fadeStopInProgress.
    required property var app
    // Plasmoid configuration in production; a plain object in tests.
    required property var cfg

    property bool recording: false
    // Whether the current recording was started by the scheduler
    property bool _recScheduled: false
    property string _recUrl: ""
    property string _recStationName: ""
    property string _recFilePath: ""
    property string _recTracksPath: ""
    property int recElapsedSec: 0
    // Requested length of the current recording — the completion handler
    // compares the actual elapsed time against it to tell "ran to the end"
    // from "the stream died halfway through".
    property int _recDurationSec: 0
    // Identifies the schedule entry being recorded (url + nextRun), so the
    // completion handler can advance exactly that entry — and only after the
    // recording actually finished, not when it started.
    property string _recActiveSchedKey: ""
    // Consecutive-failure backoff for scheduled recordings, keyed by
    // schedule key: how many times in a row it failed, and the epoch ms
    // before which the tick must not retry it. Cleared when it succeeds or
    // the occurrence advances. Without this a persistently-failing entry
    // (ffmpeg missing, disk full, stream refusing) relaunched every 30 s.
    property var _recRetryCount: ({})
    property var _recRetryAfter: ({})
    // Same stable-id pattern as the MPRIS files: two widget instances must
    // never kill each other's recording via a shared pid file.
    readonly property string _recPidFile: app._mprisRunDir + "/arp-rec-" + app._mprisId + ".pid"
    // The recording's own curl config, same owner-only road the podcast
    // downloads take. A recording runs for minutes or hours, so a stream URL
    // on ffmpeg's argv was the LONGEST-lived leak in the widget: anyone with
    // a shell on the machine could read a per-listener token out of
    // /proc/<pid>/cmdline the whole time. curl fetches from the file and
    // pipes the bytes to ffmpeg, which never learns the address.
    readonly property string _recUrlFile: app._mprisRunDir + "/arp-rec-url-" + app._mprisId
    // The recording waiting for its config file to land (the write is its
    // own short command — putting it in the same string as the recording
    // would park the URL on THAT shell's argv for the whole session).
    property var _recPending: null
    property var recSchedules: []

    // Set when the user (or a station switch) asked the recording to stop —
    // ffmpeg then exits via SIGINT with a nonzero code that is NOT an error.
    // Without this flag the completion handler can't tell a requested stop
    // from a stream that died on its own.
    property bool _recStopRequested: false

    // in the list for its whole window now (see below), so without this the
    // 30 s tick would repeat "skipped"/"failed" notifications until it closes.
    property var _recSchedNotified: ({})

    function _pad2(n) { return ("0" + n).slice(-2); }

    // All three live in RecLogic.js with their tests.
    function recElapsedText() {
        return RecLogic.elapsedText(recElapsedSec);
    }

    function _recSanitizeName(name) {
        return RecLogic.sanitizeStationName(name);
    }

    function canRecordUrl(url) {
        return RecLogic.canRecordUrl(url);
    }

    // REC button: record what is playing right now.
    function recStartCurrent() {
        // app.fadeStopInProgress = a stop is in progress; playbackState is
        // still Playing then, and a recording started now would survive the stop.
        if (recording || !app.isPlaying() || app.fadeStopInProgress) return;
        // The station's own address, not the player's: while the timeshift
        // tap feeds the player the source reads 127.0.0.1, and that port has
        // exactly one seat (traced 2026-09-03, __REC_EMPTY__ on a FLAC station).
        var url = app.upstreamSourceString();
        if (!canRecordUrl(url)) return;
        var maxMin = Math.max(1, cfg.recordMaxMinutes || 180);
        _recStart(app.currentStation, url, maxMin * 60, false);
    }

    // A recording that ends BEFORE its shell ever ran never reaches the
    // completion handler — and that handler is the only place the scheduled
    // bookkeeping is settled. Without this, a scheduled occurrence that fails
    // this early keeps its key marked active with no backoff written, so the
    // 30 s tick relaunches it (and notifies) for the whole window.
    // stopped: the user called it off, so the occurrence is spent rather than
    // retried — the same distinction the completion handler draws.
    function _recFinishAborted(stopped) {
        var key = _recActiveSchedKey;
        var wasScheduled = _recScheduled;
        recording = false;
        _recScheduled = false;
        _recStopRequested = false;
        _recActiveSchedKey = "";
        _recUrl = "";
        _recFilePath = "";
        _recTracksPath = "";
        _recPending = null;
        // The address may already be on disk with nothing left to read it.
        app.exec(": REC_URLCLEAN; rm -f '"
                        + _recUrlFile.replace(/'/g, "'\\''") + "'; true # " + (app.nextSeq()));
        if (!wasScheduled || key === "") return;
        if (stopped) {
            delete _recRetryCount[key];
            delete _recRetryAfter[key];
            _recSchedAdvance(key);
            return;
        }
        var n = (_recRetryCount[key] || 0) + 1;
        _recRetryCount[key] = n;
        _recRetryAfter[key] = n >= 6
            ? Date.now() + 3600000
            : Date.now() + Math.min(240000, 30000 * Math.pow(2, n - 1));
    }

    function recStop() {
        if (!recording) return;
        _recStopRequested = true;
        // A stop can land in the gap between the url-file write and its ack,
        // where there is no pid yet and nothing to signal. The pending job is
        // dropped here so the ack cannot start a recording the user (or a
        // station switch) has already called off — it used to start anyway,
        // and on a station switch it recorded the PREVIOUS station.
        if (_recPending !== null) {
            _recFinishAborted(true);
            return;
        }
        var safePid = _recPidFile.replace(/'/g, "'\\''");
        // The pid is the pipeline's ffmpeg — SIGINT (not KILL) is what lets it
        // finish the container. Verify it is really ours before signalling: a
        // hard-killed wrapper can leave a stale pid file, and after pid reuse
        // a blind kill would hit an unrelated process.
        app.exec(": REC_STOP; p=$(cat '" + safePid + "' 2>/dev/null);"
            + " [ -n \"$p\" ] && ps -o cmd= -p \"$p\" 2>/dev/null | grep -q 'ffmpeg.*pipe:0'"
            + " && kill -INT \"$p\" 2>/dev/null; true");
    }

    function _recStart(stationName, url, durationSec, scheduled) {
        if (recording) return;
        // Format choice. "original" (-c copy) is the professional default: the
        // stream is already lossy-compressed, so a bit-exact copy is the best
        // quality that exists. MP3 re-encodes for maximum device compatibility
        // (high-quality VBR); WAV decodes to uncompressed PCM — huge files,
        // NO quality gain over the stream, offered for editing workflows only.
        var recFmt = (cfg.recordFormat || "original").toLowerCase();
        var codecArgs, ext;
        // strict format: a container written to disk must be judged on the
        // extension alone — a fuzzy "probably mp3" re-encodes (safe) instead
        // of -c copy'ing an unknown codec into a .mp3 shell.
        if (recFmt === "mp3" && StreamLogic.streamFormat(url, true) !== "mp3") {
            codecArgs = "-c:a libmp3lame -q:a 0";
            ext = "mp3";
        } else if (recFmt === "wav") {
            codecArgs = "-c:a pcm_s16le";
            ext = "wav";
        } else {
            // "original" — and also "mp3" when the stream already IS mp3
            // (an mp3→mp3 re-encode would only lose quality).
            codecArgs = "-c copy";
            var extMap = { "mp3": "mp3", "aac": "aac", "ogg": "ogg", "opus": "opus", "flac": "flac" };
            ext = extMap[StreamLogic.streamFormat(url, true)] || "mka";
        }
        var d = new Date();
        var stamp = d.getFullYear() + "-" + _pad2(d.getMonth() + 1) + "-" + _pad2(d.getDate())
                    + " " + _pad2(d.getHours()) + "." + _pad2(d.getMinutes()) + "." + _pad2(d.getSeconds());
        var cleanName = _recSanitizeName(stationName);
        var base = "REC " + cleanName + " " + stamp;
        recording = true;
        _recScheduled = scheduled;
        if (!scheduled) _recActiveSchedKey = "";
        _recStopRequested = false;
        recElapsedSec = 0;
        _recDurationSec = Math.max(60, Math.floor(durationSec));
        _recUrl = url;
        _recStationName = cleanName;
        _recFilePath = app.downloadDirPath + "/" + base + "." + ext;
        _recTracksPath = app.downloadDirPath + "/" + base + ".tracks.txt";
        var safeDir = app.downloadDirPath.replace(/'/g, "'\\''");
        var safeOut = _recFilePath.replace(/'/g, "'\\''");
        var safeTracks = _recTracksPath.replace(/'/g, "'\\''");
        var safePid = _recPidFile.replace(/'/g, "'\\''");
        // ffmpeg runs as a CHILD (&, wait) — the pid file holds the timeout
        // wrapper's pid for SIGINT (GNU timeout forwards it, so a user stop
        // still finalizes the container), the wrapper cleans up and reports
        // via sentinels, and the attached process gives us a free completion
        // event in onExited. "-t" caps recorded MEDIA time; wall-clock is
        // bounded by the timeout prefix (~1.1× the requested duration), so even
        // an orphaned recording can neither fill the disk nor run forever. A
        // fixed grace was too tight — a stream that stalls burns wall time with
        // no media progress, and -t counts only media, so a long recording got
        // SIGINT'd before -t completed. The VLC user agent matches
        // reader.py (some stations block ffmpeg's default UA).
        // Pre-flight free-space check: refusing up front beats ffmpeg dying
        // mid-file on a full disk. WAV ≈10 MiB/min, compressed ≈2 MiB/min;
        // an empty/odd df answer fails open (the check is best-effort).
        // Instant REC carries the full cap (up to 180 min) as its "duration"
        // with no known length, so size its estimate against a modest floor —
        // else an ordinary short capture is refused under ~2 GiB free. A truly
        // full disk still trips this; mid-recording disk-full is caught later.
        var recEstMin = scheduled ? Math.ceil(_recDurationSec / 60)
                                  : Math.min(30, Math.ceil(_recDurationSec / 60));
        var recNeedKiB = recEstMin * (ext === "wav" ? 10240 : 2048);
        var safeCfg = _recUrlFile.replace(/'/g, "'\\''");
        // A control character would smuggle a second directive into the curl
        // config — the same guard the podcast download applies to its own.
        if (/[\x00-\x1f\x7f]/.test(url)) {
            app.notify(i18n("Recording failed"), stationName, "dialog-error");
            _recFinishAborted(false);
            return;
        }
        // Everything the recording command needs EXCEPT the address. It waits
        // for the config write below, which is deliberately its own short
        // command: one string carrying both would put the URL on the
        // recording shell's argv for the whole recording — the very leak.
        _recPending = {
            // Every early exit takes the config file with it — the address
            // must not outlive the recording that never started.
            "cmd": ": REC_START; cln() { rm -f '" + safeCfg + "'; }; "
                + "if ! command -v ffmpeg >/dev/null 2>&1; then cln; echo __NO_FFMPEG__; exit 0; fi; "
                + "if ! command -v curl >/dev/null 2>&1; then cln; echo __NO_CURL__; exit 0; fi; "
                + "mkdir -p '" + safeDir + "' || { cln; echo __REC_EMPTY__; exit 0; }; "
                + "avail=$(df -Pk '" + safeDir + "' 2>/dev/null | awk 'NR==2{print $4}'); "
                + "if [ -n \"$avail\" ] && [ \"$avail\" -lt " + recNeedKiB + " ] 2>/dev/null; then cln; echo __REC_NOSPACE__; exit 0; fi; "
                // curl owns the network now, so its flags carry what ffmpeg's
                // used to: -A is the VLC agent (some stations refuse ffmpeg's
                // own), --retry replaces -reconnect, and --speed-time is the
                // -rw_timeout twin — a server that holds the socket open
                // while sending nothing is given up on after 30 s instead of
                // blocking a recording for days.
                //
                // ONE shell, no nested `sh -c "…"`. A double-quoted inner
                // command would be expanded by the OUTER shell first, and a
                // station name is catalogue text: measured, "Cash $Money FM"
                // lost its word and "Radio $(id -un) FM" ran the command.
                // Single quotes on one level keep every name literal, exactly
                // as they did before the URL moved off the argv.
                //
                // The wall-clock cap wraps CURL, and the pid written down is
                // the pipeline's last member — ffmpeg. Stopping it finalizes
                // the container directly and curl leaves with the broken pipe
                // (measured: a valid file, the dollar intact, nothing left
                // running).
                + " timeout --signal=INT --kill-after=30 " + (_recDurationSec + Math.max(300, Math.ceil(_recDurationSec * 0.10)))
                // --http0.9: a Shoutcast v1 server answers "ICY 200 OK", which
                // is not an HTTP status line, and curl has refused those by
                // default since 7.66 — exit 1, no retry, no bytes. ffmpeg's own
                // client parsed them, so these stations recorded fine until the
                // fetch moved to curl and then failed instantly while playback
                // kept working. Measured against a real ICY responder: with the
                // flag the recording is a valid file, the ICY header does not
                // leak into it, and an ordinary HTTP station is unaffected.
                + " curl -sS -L --http0.9 -K '" + safeCfg + "'"
                + " -A 'VLC/3.0.20 LibVLC/3.0.20'"
                + " --retry 20 --retry-delay 2 --speed-limit 1 --speed-time 30"
                + " | ffmpeg -hide_banner -nostdin -loglevel error -i pipe:0 "
                + codecArgs + " -t " + Math.max(60, Math.floor(durationSec))
                + " -metadata title='" + base.replace(/'/g, "'\\''") + "'"
                + " -metadata artist='" + cleanName.replace(/'/g, "'\\''") + "'"
                + " -n '" + safeOut + "'"
                + " & pid=$!; echo $pid > '" + safePid + "'; "
                + "wait $pid; rc=$?; rm -f '" + safePid + "' '" + safeCfg + "'; "
                // Report the exit code AND the file size — "file is not empty"
                // alone reported half-dead recordings (disk full, stream died) as
                // successes. The QML side combines rc with the elapsed time to tell
                // a requested stop / duration cap from a mid-recording failure.
                + "bytes=$(stat -c %s '" + safeOut + "' 2>/dev/null || echo 0); "
                + "if [ \"$bytes\" -gt 0 ] 2>/dev/null; then echo \"__REC_DONE__ rc=$rc bytes=$bytes\"; "
                + "else rm -f '" + safeOut + "' '" + safeTracks + "'; echo \"__REC_EMPTY__ rc=$rc\"; fi",
            "scheduled": scheduled,
            "station": stationName
        };
        var recCfgLine = 'url = "' + url.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + '"';
        app.exec(": REC_URL; umask 077; printf '%s' "
            + PodcastLogic.shQuote(recCfgLine)
            + " > " + PodcastLogic.shQuote(_recUrlFile)
            + " && echo __REC_URL_OK__ || echo __REC_URL_FAIL__; true # " + app.nextSeq());
    }

    function _loadRecSchedules() {
        // Field-by-field validation lives in AlarmLogic (tested): a config
        // entry with a mangled nextRun or a hand-edited hour used to sit in
        // the list looking armed and never record anything.
        recSchedules = AlarmLogic.sanitizeRecSchedules(cfg.recSchedules);
    }

    function _saveRecSchedules() {
        cfg.recSchedules = JSON.stringify(recSchedules);
    }

    // Next occurrence of hh:mm strictly after fromMs — the wall-clock (DST
    // safe) math lives in AlarmLogic.js, where qmltestrunner covers it.
    function _nextOccurrence(hh, mm, repeat, weekday, fromMs) {
        return AlarmLogic.nextOccurrence(hh, mm, repeat, weekday, fromMs);
    }

    function addRecSchedule(stationName, url, hh, mm, durationMin, repeat, weekday) {
        if (!url || !canRecordUrl(url)) return;
        // One defaulted weekday for BOTH the stored entry and the schedule
        // math — same fix as addAlarm; the raw undefined made a weekly
        // schedule's first nextRun disagree with its stored weekday.
        var wd = weekday === undefined ? new Date().getDay() : weekday;
        var list = recSchedules.slice();
        list.push({
            "station": stationName || url,
            "url": url,
            "hh": hh, "mm": mm,
            "durationMin": Math.max(1, durationMin),
            "repeat": repeat || "once",
            "weekday": wd,
            "nextRun": _nextOccurrence(hh, mm, repeat || "once", wd, Date.now())
        });
        recSchedules = list;
        _saveRecSchedules();
    }

    function removeRecSchedule(index) {
        if (index < 0 || index >= recSchedules.length) return;
        var list = recSchedules.slice();
        list.splice(index, 1);
        recSchedules = list;
        _saveRecSchedules();
    }

    function _recSchedKey(s) {
        return s.url + "@" + s.nextRun;
    }

    function _recSchedNotifyOnce(key, title, text, icon) {
        if (_recSchedNotified[key]) return;
        if (Object.keys(_recSchedNotified).length > 50) _recSchedNotified = {};
        _recSchedNotified[key] = true;
        app.notify(title, text, icon);
    }

    // Advance (or remove, for "once") the schedule entry that just produced a
    // FINISHED recording. Called from the completion handler and from the
    // tick's missed-window path — advancing at start (the old behaviour) threw
    // the rest of the window away whenever a recording died halfway: the entry
    // had already moved to tomorrow, so nothing ever resumed.
    function _recSchedAdvance(key) {
        if (!key) return;
        // The occurrence is over — its failure backoff dies with it (the key
        // embeds nextRun, so the advanced entry gets a clean slate anyway).
        delete _recRetryCount[key];
        delete _recRetryAfter[key];
        var list = recSchedules.slice();
        for (var i = 0; i < list.length; i++) {
            var s = list[i];
            if (_recSchedKey(s) !== key) continue;
            if (s.repeat === "once") {
                list.splice(i, 1);
            } else {
                s.nextRun = _nextOccurrence(s.hh, s.mm, s.repeat, s.weekday, Date.now());
            }
            recSchedules = list;
            _saveRecSchedules();
            return;
        }
    }

    function _recScheduleTick() {
        if (recSchedules.length === 0) return;
        var now = Date.now();
        // Same zone watch the alarm tick runs — a recording schedule used to
        // go an hour wrong at a DST flip while the machine was running,
        // because only alarms watched the offset.
        app._schedApplyTzChange(now);
        // Snapshot: _recSchedAdvance below replaces recSchedules itself.
        var due = recSchedules.slice();
        for (var i = 0; i < due.length; i++) {
            var s = due[i];
            if (now < s.nextRun) continue;
            var key = _recSchedKey(s);
            var endMs = s.nextRun + s.durationMin * 60000;
            // Our own entry, still recording past the nominal window end:
            // ffmpeg's connect/buffer latency pushes its real exit a few
            // seconds past endMs, and the completion handler owns advancing
            // it. This guard MUST precede the missed branch, or a tick in
            // that gap fires a false "missed" toast and advances the entry
            // out from under a recording that is seconds from finishing.
            if (recording && _recActiveSchedKey === key) continue;
            if (now >= endMs) {
                // The window closed without a completed recording (the machine
                // was off, or every attempt failed) — only now is it missed.
                _recSchedNotifyOnce(key, i18n("Scheduled recording missed"),
                                    s.station, "dialog-warning");
                _recSchedAdvance(key);
                continue;
            }
            if (recording) {
                _recSchedNotifyOnce(key, i18n("Scheduled recording skipped"),
                                    i18n("%1 — another recording is already running.", s.station),
                                    "dialog-warning");
                continue; // the entry stays — it can still start if REC ends in time
            }
            // A persistently failing entry (ffmpeg missing, disk full, stream
            // refusing) must not be re-launched on every 30 s tick — that is
            // a notification and process storm for the whole window. Hold off
            // until the backoff deadline this entry earned from its failures.
            if (_recRetryAfter[key] !== undefined && now < _recRetryAfter[key])
                continue;
            var remainSec = Math.round((endMs - now) / 1000);
            if (remainSec >= 60) {
                // Record the remainder of the window. The entry is advanced
                // when the recording FINISHES — if the stream dies mid-way,
                // the next tick lands back here and resumes with what's left.
                _recActiveSchedKey = key;
                _recStart(s.station, s.url, remainSec, true);
            }
            // < 60 s left: not worth an ffmpeg spawn; the entry ages into the
            // missed branch above unless a recording already completed.
        }
    }

    Timer {
        id: recScheduleTimer
        interval: 30000
        repeat: true
        running: recSchedules.length > 0
        onTriggered: _recScheduleTick()
    }

    Timer {
        id: recElapsedTimer
        interval: 1000
        repeat: true
        running: recording
        onTriggered: recElapsedSec += 1
    }

    // The instant-recording tracklist sidecar: one line per title change
    // while THIS stream records. target is _icyStreamTarget(playerSource),
    // computed by the app because it owns the player.
    function noteTrack(target, artist, title) {
        if (recording && !_recScheduled && _recTracksPath !== ""
            && target === _recUrl && title) {
            var recLine = "[" + recElapsedText() + "] "
                          + (artist ? artist + " - " : "") + title;
            app.exec(": REC_TRACK; printf '%s\\n' '" + recLine.replace(/'/g, "'\\''")
                     + "' >> '" + _recTracksPath.replace(/'/g, "'\\''") + "'");
        }
    }

    // Zone-change retime for the recording schedules (the alarm half stays in
    // main's _schedApplyTzChange, which calls this). The active recording's
    // url@nextRun key follows its retimed instant so its guards keep matching.
    function applyTzRetime(now) {
        if (recSchedules.length === 0) return;
        var rl = recSchedules.slice();
        for (var r = 0; r < rl.length; r++) {
            if (!AlarmLogic.shouldRetime(rl[r], now)) continue;
            var wasKey = _recSchedKey(rl[r]);
            rl[r].nextRun = AlarmLogic.retimeForZone(rl[r], now);
            if (recording && _recActiveSchedKey === wasKey)
                _recActiveSchedKey = _recSchedKey(rl[r]);
        }
        recSchedules = rl;
        _saveRecSchedules();
    }

    // Startup: stop an ffmpeg a plasmashell crash may have orphaned (the pid
    // file outlives it), matching our own recording's argv only. Its REC_CLEAN
    // ack releases the first schedule tick.
    function start() {
        var safePid = _recPidFile.replace(/'/g, "'\\''");
        app.exec(": REC_CLEAN; p=$(cat '" + safePid + "' 2>/dev/null);"
            + " if [ -n \"$p\" ] && ps -o cmd= -p \"$p\" 2>/dev/null | grep -q 'ffmpeg.*pipe:0'; then"
            + " kill -INT \"$p\" 2>/dev/null; fi; rm -f '" + safePid + "'; true");
    }

    // The engine's half of the recording exec round-trips.
    function handleExec(cmd, stdout, stderr, exitCode) {
            if (cmd.indexOf(": REC_URL;") === 0) {
            var recJob = _recPending;
            _recPending = null;
            // Called off in the gap (a stop, a station switch): recStop
            // already settled the state, and starting now would record
            // the address of a station the user has left.
            if (!recJob) return true;
            if ((stdout || "").indexOf("__REC_URL_OK__") === -1) {
                app.notify(i18n("Recording failed"), recJob.station, "dialog-error");
                _recFinishAborted(false);
                return true;
            }
            app.exec(recJob.cmd);
            if (recJob.scheduled)
                app.notify(i18n("Scheduled recording started"), recJob.station, "media-record");
            return true;
        }
            if (cmd.indexOf(": REC_CLEAN;") === 0) {
            Qt.callLater(_recScheduleTick);
            return true;
        }
            if (cmd.indexOf(": REC_START;") === 0) {
            var recFile = _recFilePath;
            var recDur = recElapsedText();
            var recElapsed = recElapsedSec;
            var recWanted = _recDurationSec;
            var recWasScheduled = _recScheduled;
            var recSchedKey = _recActiveSchedKey;
            var recWasStopRequested = _recStopRequested;
            recording = false;
            _recScheduled = false;
            _recStopRequested = false;
            _recActiveSchedKey = "";
            _recUrl = "";
            _recFilePath = "";
            _recTracksPath = "";
            var recOut = stdout || "";
            var recName = recFile.substring(recFile.lastIndexOf("/") + 1);
            // Success is judged on evidence, not on "the file is not empty":
            //   • a user stop / the duration cap ending the recording is fine;
            //   • anything that ends the recording early on its own (stream
            //     died, disk full) is an interruption, whatever ffmpeg's rc;
            //   • a file far too small for its duration (< ~10 KB/min — real
            //     audio is at least 60 KB/min) is a broken capture.
            var recDone = recOut.indexOf("__REC_DONE__") !== -1;
            var recBytesM = recOut.match(/__REC_DONE__ rc=(-?\d+) bytes=(\d+)/);
            var recRc = recBytesM ? parseInt(recBytesM[1], 10) : -1;
            var recBytes = recBytesM ? parseInt(recBytesM[2], 10) : 0;
            var recRanFull = recElapsed >= recWanted - 5;
            var recTooSmall = recBytes < Math.max(1, recElapsed / 60) * 10240;
            var recOk = recDone && (recWasStopRequested || (recRanFull && recRc === 0)) && !recTooSmall;
            var recInterrupted = recDone && !recOk;
            var recTitle, recText, recIcon;
            if (recOut.indexOf("__NO_FFMPEG__") !== -1) {
                recTitle = i18n("ffmpeg is not installed");
                recText = i18n("Install ffmpeg to record radio.");
                recIcon = "dialog-warning";
            } else if (recOut.indexOf("__NO_CURL__") !== -1) {
                // curl fetches the stream so the address never rides on a
                // command line — no curl, no recording.
                recTitle = i18n("curl is not installed");
                recText = i18n("Install curl to record radio.");
                recIcon = "dialog-warning";
            } else if (recOut.indexOf("__REC_NOSPACE__") !== -1) {
                recTitle = i18n("Not enough disk space for this recording");
                recText = i18n("Free some space in %1 and try again.", app.downloadDirPath);
                recIcon = "dialog-warning";
            } else if (recOk) {
                recTitle = i18n("Recording saved ✓ (%1)", recDur);
                recText = recName;
                recIcon = "media-record";
            } else if (recInterrupted) {
                recTitle = i18n("Recording interrupted (%1 captured)", recDur);
                recText = recTooSmall
                    ? i18n("%1 — the file is much smaller than expected.", recName)
                    : recName;
                recIcon = "dialog-warning";
            } else {
                recTitle = i18n("Recording failed");
                recText = ((stderr || "").split("\n").filter(function(l){ return l.trim() !== ""; })[0] || i18n("The stream could not be captured.")).substring(0, 120);
                recIcon = "dialog-error";
            }
            // A missing tool is a missing tool — curl counts like ffmpeg:
            // neither will appear inside a recording window.
            var recNoFfmpeg = recOut.indexOf("__NO_FFMPEG__") !== -1
                              || recOut.indexOf("__NO_CURL__") !== -1;
            var recNoSpace = recOut.indexOf("__REC_NOSPACE__") !== -1;
            // A near-instant failure (ffmpeg absent, mkdir/disk failure,
            // stream refused at once) is what storms — a real capture
            // that ran a while and got interrupted is not. Only the
            // former earns backoff; the latter resumes right away.
            var recFailedFast = !recOk && !recWasStopRequested
                                && (recNoFfmpeg || recElapsed < 5 || !recDone);
            app.notify(recTitle, recText, recIcon);
            if (recWasScheduled && recSchedKey) {
                if (recOk || recWasStopRequested) {
                    // The occurrence is done — move the entry forward (or
                    // drop a "once") only NOW, after the actual outcome.
                    delete _recRetryCount[recSchedKey];
                    delete _recRetryAfter[recSchedKey];
                    _recSchedAdvance(recSchedKey);
                } else if (recNoFfmpeg || recNoSpace) {
                    // ffmpeg (or the missing disk space) will not appear
                    // inside this window — retrying is pointless. Give up
                    // on the occurrence with the one toast already shown,
                    // and advance it.
                    delete _recRetryCount[recSchedKey];
                    delete _recRetryAfter[recSchedKey];
                    _recSchedAdvance(recSchedKey);
                } else if (recFailedFast) {
                    // Back off: 30 s, then doubling to 4 min, and after
                    // six straight fast failures let the window age into
                    // "missed" rather than keep pounding a dead stream.
                    var rc = (_recRetryCount[recSchedKey] || 0) + 1;
                    _recRetryCount[recSchedKey] = rc;
                    if (rc >= 6) {
                        _recRetryAfter[recSchedKey] = Date.now() + 3600000;
                    } else {
                        _recRetryAfter[recSchedKey] =
                            Date.now() + Math.min(240000, 30000 * Math.pow(2, rc - 1));
                        Qt.callLater(_recScheduleTick);
                    }
                } else {
                    // A real interruption mid-window (stream died after
                    // recording a while): resume with the remaining time.
                    delete _recRetryCount[recSchedKey];
                    delete _recRetryAfter[recSchedKey];
                    Qt.callLater(_recScheduleTick);
                }
            }
            return true;
        }
        return false;
    }
}
