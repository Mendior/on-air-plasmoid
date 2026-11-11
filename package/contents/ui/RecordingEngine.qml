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
    // Wall-clock seconds since REC was pressed. The completion verdicts
    // (ran full, too small, failed fast) read this one.
    property int recElapsedSec: 0
    // The capture's file exists: ffmpeg has the stream and opened its
    // output. The REC counter waits for it.
    property bool recOnDisk: false
    // Seconds since recOnDisk — what the REC counter, the saved toast and
    // the tracklist show.
    property int recCapturedSec: 0
    // Which recording a disk probe was asked for; an answer for an older
    // one is dropped.
    property int _recGen: 0
    property bool _recProbeInFlight: false
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
    // The stop mark. A stop writes the running recording's token here before
    // it looks for a pid, and the capture shell reads it twice: just before
    // it asks for the stream, and again once the pid is written down.
    // Measured with df held back: at Stop there was no pid file, nothing was
    // signalled, and the shell went on to record what had been called off.
    readonly property string _recStopFile: app._mprisRunDir + "/arp-rec-stop-" + app._mprisId
    // Names one recording, in the mark and in its own capture command, so a
    // mark the recording before left behind stops nothing. The counter
    // starts over with the panel; the start time tells two sessions apart.
    property string _recToken: ""
    property var recSchedules: []

    // Set when the user (or a station switch) asked the recording to stop —
    // ffmpeg then exits via SIGINT with a nonzero code that is NOT an error.
    // Without this flag the completion handler can't tell a requested stop
    // from a stream that died on its own.
    property bool _recStopRequested: false
    // Set when it was the schedule tick that asked, because the capture
    // was still running after its window. The stop is handled like any
    // other; the verdict must not call such a file saved.
    property bool _recOverran: false

    // in the list for its whole window now (see below), so without this the
    // 30 s tick would repeat "skipped"/"failed" notifications until it closes.
    property var _recSchedNotified: ({})

    function _pad2(n) { return ("0" + n).slice(-2); }

    // Both live in RecLogic.js with their tests.
    function _recSanitizeName(name) {
        return RecLogic.sanitizeStationName(name);
    }

    function canRecordUrl(url) {
        return RecLogic.canRecordUrl(url);
    }

    // What the REC button, bar and footer show: "Connecting…" until the
    // file is on disk, then the time since.
    function recCounterText() {
        return recording && !recOnDisk ? i18n("Connecting…")
                                       : RecLogic.elapsedText(recCapturedSec);
    }

    // Asks whether the capture's file exists yet. Existence and not size:
    // ffmpeg opens its output only once the stream has answered, but writes
    // it in 256 KiB blocks. Measured on the bench at 128 kbps, the file sat
    // at 0 bytes for 15 s after it appeared, which at 32 kbps would be a
    // minute of recorded audio the counter never counted.
    function _recProbe() {
        if (_recProbeInFlight || !recording || recOnDisk) return;
        _recProbeInFlight = true;
        app.exec(": REC_PROBE " + _recGen + "; [ -e " + PodcastLogic.shQuote(_recFilePath)
                 + " ] && echo __REC_ON_DISK__; true # " + app.nextSeq());
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
        recOnDisk = false;
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
        // The mark goes down before the pid is looked for. A capture shell
        // still at its mkdir or df has no pid yet, and reads the mark when it
        // gets to the stream; one that is past its last look at the mark has
        // written its pid by then, and is found here.
        //
        // The pid is the pipeline's ffmpeg — SIGINT (not KILL) is what lets it
        // finish the container. Verify it is really ours before signalling: a
        // hard-killed wrapper can leave a stale pid file, and after pid reuse
        // a blind kill would hit an unrelated process.
        //
        // An ffmpeg a few ms old still ignores SIGINT, as every background
        // job of a shell does until it sets its own handlers. Measured: a
        // stop sent as the pid file appeared met SigIgn 0x6 and the capture
        // ran on; 50 ms later the handlers were in. SIGTERM is not ignored
        // there, and ffmpeg with its handlers in closes the file on either.
        app.exec(": REC_STOP; printf '%s' " + PodcastLogic.shQuote(_recToken)
            + " > " + PodcastLogic.shQuote(_recStopFile) + "; p=$(cat '" + safePid + "' 2>/dev/null);"
            + " [ -n \"$p\" ] && ps -o cmd= -p \"$p\" 2>/dev/null | grep -q 'ffmpeg.*pipe:0' && {"
            + " if grep -q '^SigIgn:.*[2367abef]$' \"/proc/$p/status\" 2>/dev/null;"
            + " then kill -TERM \"$p\"; else kill -INT \"$p\"; fi; } 2>/dev/null; true");
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
        recOnDisk = false;
        recCapturedSec = 0;
        _recGen++;
        _recToken = _recGen + "." + d.getTime();
        _recProbeInFlight = false;
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
        var markQ = PodcastLogic.shQuote(_recStopFile);
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
            // must not outlive the recording that never started. The stop
            // mark goes the same way, on every way out.
            "cmd": ": REC_START; cln() { rm -f '" + safeCfg + "' " + markQ + "; }; "
                // Whether this recording has been called off: the mark holds
                // its own token. Another recording's token, or none, is no.
                + "off() { [ \"$(cat " + markQ + " 2>/dev/null)\" = "
                + PodcastLogic.shQuote(_recToken) + " ]; }; "
                + "if ! command -v ffmpeg >/dev/null 2>&1; then cln; echo __NO_FFMPEG__; exit 0; fi; "
                + "if ! command -v curl >/dev/null 2>&1; then cln; echo __NO_CURL__; exit 0; fi; "
                + "mkdir -p '" + safeDir + "' || { cln; echo __REC_EMPTY__; exit 0; }; "
                + "avail=$(df -Pk '" + safeDir + "' 2>/dev/null | awk 'NR==2{print $4}'); "
                + "if [ -n \"$avail\" ] && [ \"$avail\" -lt " + recNeedKiB + " ] 2>/dev/null; then cln; echo __REC_NOSPACE__; exit 0; fi; "
                // The first look at the mark: after the slow steps, so a stop
                // during any of them is seen, and before a byte is asked for.
                + "if off; then cln; echo __REC_OFF__; exit 0; fi; "
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
                // The second look, with the pid already down: a stop that
                // came after the first one either left its mark before this
                // line or finds the pid. ffmpeg is microseconds old here and
                // deaf to SIGINT, so the shell ends it with SIGTERM.
                + "off && kill -TERM $pid 2>/dev/null; "
                + "wait $pid; rc=$?; rm -f '" + safePid + "'; cln; "
                // Report the exit code AND the file size — "file is not empty"
                // alone reported half-dead recordings (disk full, stream died) as
                // successes. The QML side combines rc with the elapsed time to tell
                // a requested stop / duration cap from a mid-recording failure.
                + "bytes=$(stat -c %s '" + safeOut + "' 2>/dev/null || echo 0); "
                // And the length the file itself gives, in whole seconds. It
                // costs one ffprobe at the end, inside this shell: measured
                // 26 ms on a three-hour MP3, since it reads headers and not
                // the audio. Without ffprobe, or for a container that cannot
                // say (a FLAC copied from a pipe answers N/A), secs= stays
                // empty and the verdict falls back on the clock.
                + "if [ \"$bytes\" -gt 0 ] 2>/dev/null; then "
                + "secs=$(timeout 10 ffprobe -v error -show_entries format=duration -of csv=p=0 '"
                + safeOut + "' 2>/dev/null); "
                + "echo \"__REC_DONE__ rc=$rc bytes=$bytes secs=${secs%%.*}\"; "
                + "else rm -f '" + safeOut + "' '" + safeTracks + "'; echo \"__REC_EMPTY__ rc=$rc\"; fi",
            "scheduled": scheduled,
            "station": stationName
        };
        var recCfgLine = 'url = "' + url.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + '"';
        // The write says which recording it is for, as the disk probe does,
        // so its answer can be told from an earlier recording's.
        app.exec(": REC_URL " + _recGen + "; umask 077; printf '%s' "
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

    // A scheduled recording carries its own copy of the address and has no
    // heal road at all: after a station moved, ffmpeg was started on the dead
    // address every day and the programme was never recorded.
    // Contract: every schedule whose url IS oldUrl gets newUrl; true only
    // when something was rewritten. What the engine remembers about a
    // rewritten entry moves with it (_recSchedRefiled).
    function retargetStation(oldUrl, newUrl) {
        if (!oldUrl || !newUrl || oldUrl === newUrl) return false;
        var list = [], changed = false;
        for (var i = 0; i < recSchedules.length; i++) {
            var a = recSchedules[i];
            if ((a.url || "") === oldUrl) {
                var b = {}; for (var k in a) b[k] = a[k];
                b.url = newUrl;
                _recSchedRefiled(_recSchedKey(a), _recSchedKey(b));
                a = b; changed = true;
            }
            list.push(a);
        }
        if (changed) {
            recSchedules = list;
            _saveRecSchedules();
        }
        return changed;
    }

    // An occurrence is filed under address@time, and so is everything kept
    // about it. With the address rewritten and the filing left behind, a
    // running capture was a stranger to its own entry: the tick called it
    // skipped, and when it finished there was no entry to settle.
    // Contract: the running capture and a word already said follow the entry
    // from was to key. The failure backoff does not. It was earned by the
    // address that went away, and the new one gets its first try at once.
    function _recSchedRefiled(was, key) {
        if (_recActiveSchedKey === was) _recActiveSchedKey = key;
        if (_recSchedNotified[was]) {
            delete _recSchedNotified[was];
            _recSchedNotified[key] = true;
        }
        delete _recRetryCount[was];
        delete _recRetryAfter[was];
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
            if (recording && _recActiveSchedKey === key) {
                if (_recStopRequested || !RecLogic.captureOverran(now, endMs)) continue;
                // Five minutes past the end: the machine slept through
                // it, or the stream stalled that long. With the window 150
                // minutes gone the tick used to pass the capture by, and
                // the answer that came later was reported as saved.
                if (_recPending === null) {
                    _recOverran = true;
                    recStop();
                    continue;
                }
                // The capture itself never started, so there is nothing to
                // signal and no file. It is a missed window, said below.
                _recFinishAborted(false);
            }
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

    Timer {
        id: recCapturedTimer
        interval: 1000
        repeat: true
        running: engine.recording && engine.recOnDisk
        onTriggered: engine.recCapturedSec += 1
    }

    // Only while the capture shell runs and its file is not there yet —
    // usually one or two asks. A server that keeps the recorder waiting
    // (141 s on 2026-09-23) is asked every second for the first half
    // minute, then every two. The interval is how late the counter can
    // start: with five here the bench counter read 0:53 over a 58.3 s file.
    Timer {
        id: recDiskProbe
        interval: engine.recElapsedSec < 30 ? 1000 : 2000
        repeat: true
        running: engine.recording && !engine.recOnDisk && engine._recPending === null
        onTriggered: engine._recProbe()
    }

    // The instant-recording tracklist sidecar: one line per title change
    // while THIS stream records. target is _icyStreamTarget(playerSource),
    // computed by the app because it owns the player.
    function noteTrack(target, artist, title) {
        if (recording && !_recScheduled && _recTracksPath !== ""
            && target === _recUrl && title) {
            var recLine = "[" + RecLogic.elapsedText(recCapturedSec) + "] "
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
            + " kill -INT \"$p\" 2>/dev/null; fi; rm -f '" + safePid + "' "
            + PodcastLogic.shQuote(_recStopFile) + "; true");
    }

    // The engine's half of the recording exec round-trips.
    function handleExec(cmd, stdout, stderr, exitCode) {
            if (cmd.indexOf(": REC_URL ") === 0) {
            // An answer for a recording called off since, with another one
            // waiting by now. Taken for that one's, a late yes started its
            // capture before its own address was written and a late no
            // reported it failed. The gap is one shell round trip, about
            // 1 ms measured.
            if (parseInt(cmd.substring(10), 10) !== _recGen) return true;
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
            if (cmd.indexOf(": REC_PROBE ") === 0) {
            var probeGen = parseInt(cmd.substring(12), 10);
            if (probeGen !== _recGen) return true;
            _recProbeInFlight = false;
            if (recording && (stdout || "").indexOf("__REC_ON_DISK__") !== -1) recOnDisk = true;
            return true;
        }
            if (cmd.indexOf(": REC_CLEAN;") === 0) {
            Qt.callLater(_recScheduleTick);
            return true;
        }
            if (cmd.indexOf(": REC_START;") === 0) {
            var recFile = _recFilePath;
            // The time since the file appeared, and whether it was seen to
            // appear at all: a clock that never started is no witness.
            var recClock = recOnDisk ? recCapturedSec : NaN;
            var recElapsed = recElapsedSec;
            var recWanted = _recDurationSec;
            var recWasScheduled = _recScheduled;
            var recSchedKey = _recActiveSchedKey;
            var recWasStopRequested = _recStopRequested;
            var recOverran = _recOverran;
            recording = false;
            recOnDisk = false;
            _recScheduled = false;
            _recStopRequested = false;
            _recOverran = false;
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
            //     audio is at least 60 KB/min) is a broken capture;
            //   • the time running out proves nothing by itself: a capture
            //     that connected late, or stalled, ends on time with a
            //     fraction of the audio, and that is an interruption too.
            var recDone = recOut.indexOf("__REC_DONE__") !== -1;
            // The file's own length when the shell could read it. The toast
            // names what is in the file, so it reads this before the clock.
            var recMedia = RecLogic.mediaSeconds(recOut);
            var recDur = RecLogic.elapsedText(RecLogic.heardSeconds(recMedia, recCapturedSec));
            var recShort = RecLogic.fallsShort(recWanted, recMedia, recClock);
            var recBytesM = recOut.match(/__REC_DONE__ rc=(-?\d+) bytes=(\d+)/);
            var recRc = recBytesM ? parseInt(recBytesM[1], 10) : -1;
            var recBytes = recBytesM ? parseInt(recBytesM[2], 10) : 0;
            var recRanFull = recElapsed >= recWanted - 5;
            var recTooSmall = recBytes < Math.max(1, recElapsed / 60) * 10240;
            // A capture the tick had to stop past its window is a file with
            // a hole in it or with the next programme on its end: interrupted.
            var recOk = recDone && !recOverran
                        && (recWasStopRequested || (recRanFull && recRc === 0 && !recShort))
                        && !recTooSmall;
            var recInterrupted = recDone && !recOk;
            var recTitle = "", recText, recIcon;
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
            } else if (RecLogic.calledOff(recWasStopRequested, recOverran, recDone)) {
                // Stopped before anything was on disk, by the mark or by the
                // signal. That is what was asked for, and there is no word
                // for it: recTitle stays empty.
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
            // A capture that held the connection but wrote nothing is not
            // the latter: measured on a host that answers, keeps the socket
            // open past five seconds and closes clean with an empty file,
            // the resume road erased its own counter and relaunched on the
            // next tick — a toast and a process per tick for the whole
            // window, which is exactly what the backoff exists to stop.
            var recFailedFast = !recOk && !recWasStopRequested
                                && (recNoFfmpeg || recElapsed < 5 || !recDone || recTooSmall);
            if (recTitle !== "") app.notify(recTitle, recText, recIcon);
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
