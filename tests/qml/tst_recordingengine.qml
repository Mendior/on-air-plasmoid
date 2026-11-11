// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The recording engine, driven through a mock app. The two-stage capture is
// asserted on the exact command strings it emits — the URL reaches disk in an
// owner-only config the transfer reads with -K, never on ffmpeg's argv, which
// is the whole point of the staging. The completion handler's verdicts (saved,
// interrupted, tool missing) and the schedule round-trip are exercised too.
import QtQuick
import QtTest
import "../../package/contents/ui"
import "../../package/contents/ui/RecLogic.js" as RecLogic

TestCase {
    id: tc
    name: "RecordingEngine"

    property var execLog: []
    property var notified: []
    property string stagedWrite: ""
    property int seq: 0

    function i18n(s) {
        var out = s;
        for (var i = 1; i < arguments.length; i++) out = out.replace("%" + i, arguments[i]);
        return out;
    }

    Component { id: engineComp; RecordingEngine {} }

    function makeEngine(cfgOverrides, appOverrides) {
        tc.execLog = []; tc.notified = []; tc.seq = 0;
        var cfg = { recSchedules: "[]", recordFormat: "original", recordMaxMinutes: 120,
                    schedTzOffset: 0 };
        for (var k in (cfgOverrides || {})) cfg[k] = cfgOverrides[k];
        var app = {
            exec: function(c) { tc.execLog.push(c); },
            nextSeq: function() { return ++tc.seq; },
            notify: function(t, x, i) { tc.notified.push(t); },
            downloadDirPath: "/home/x/Music/OnAir",
            _mprisRunDir: "/run/user/1000",
            _mprisId: "42",
            isPlaying: function() { return true; },
            playerSourceString: function() { return "https://s.example/stream"; },
            upstreamSourceString: function() { return "https://s.example/stream"; },
            currentStation: "Test Radio",
            fadeStopInProgress: false
        };
        for (var a in (appOverrides || {})) app[a] = appOverrides[a];
        return engineComp.createObject(tc, { app: app, cfg: cfg });
    }

    function _lastExec() { return tc.execLog[tc.execLog.length - 1]; }
    // The answer to the address write the engine sent last, as the shell
    // hands it back: the command itself and what it printed. The write
    // names its recording, so a bare ": REC_URL;" is nobody's answer.
    function _urlAck(e, out) {
        var w = _urlWrites();
        return w.length > 0 && e.handleExec(w[w.length - 1], out, "", 0);
    }

    function test_staging_writes_the_url_owner_only_then_the_capture_reads_it() {
        var e = makeEngine();
        e._recStart("Test Radio", "https://s.example/stream?token=SECRET", 3600, false);
        verify(e.recording);
        // Stage one: the URL goes to an owner-only file, not onto any argv.
        compare(tc.execLog.length, 1);
        verify(_lastExec().indexOf(": REC_URL ") === 0);
        verify(_lastExec().indexOf("umask 077") !== -1);
        // The pending capture command is armed but not yet run.
        verify(e._recPending !== null);
        verify(e._recPending.cmd.indexOf(": REC_START;") === 0);
        // Stage two: the config lands, the capture starts — curl reads the URL
        // via -K, ffmpeg never learns the address.
        verify(_urlAck(e, "__REC_URL_OK__"));
        verify(_lastExec().indexOf(": REC_START;") === 0);
        verify(_lastExec().indexOf("curl") !== -1);
        verify(_lastExec().indexOf("-K ") !== -1);
        verify(_lastExec().indexOf("ffmpeg") !== -1);
        // The secret token rides only inside the quoted config write, never bare.
        verify(_lastExec().indexOf("SECRET") === -1);
        e.destroy();
    }

    function test_the_rec_button_records_the_station_not_the_timeshift_tap() {
        // While the timeshift tap feeds the player, the player's source reads
        // 127.0.0.1 — a port with exactly one seat, already taken. Pressing
        // REC there used to curl that closed port for twenty retries and hand
        // back __REC_EMPTY__ (traced 2026-09-03 on a FLAC station). The
        // recorder has to ask for the station's own address instead.
        var e = makeEngine({}, {
            playerSourceString: function() { return "http://127.0.0.1:41234/"; },
            upstreamSourceString: function() { return "https://s.example/live.flac"; }
        });
        e.recStartCurrent();
        verify(e.recording);
        compare(tc.execLog.length, 1);
        verify(_lastExec().indexOf(": REC_URL ") === 0);
        verify(_lastExec().indexOf("s.example/live.flac") !== -1);
        verify(_lastExec().indexOf("127.0.0.1") === -1);
        e.destroy();
    }

    function test_a_control_char_in_the_url_is_refused_before_any_exec() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/\nstream", 3600, false);
        // No REC_URL emitted; the recording aborts and frees itself.
        compare(e.recording, false);
        compare(tc.notified.length, 1);
        e.destroy();
    }

    function test_a_failed_url_stage_aborts_and_frees_the_slot() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        verify(_urlAck(e, "__REC_URL_FAIL__"));
        compare(e.recording, false);
        e.destroy();
    }

    function test_a_clean_full_capture_reports_saved() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 60, false);
        e.recElapsedSec = 60;                       // ran to the end
        _urlAck(e, "__REC_URL_OK__");
        tc.notified = [];
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=9999999", "", 0));
        compare(e.recording, false);
        compare(tc.notified.length, 1);
        verify(tc.notified[0].indexOf("saved") !== -1);
        e.destroy();
    }

    function test_a_missing_ffmpeg_is_named_not_blamed_on_the_stream() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 60, false);
        _urlAck(e, "__REC_URL_OK__");
        tc.notified = [];
        verify(e.handleExec(": REC_START;", "__NO_FFMPEG__", "", 0));
        compare(tc.notified.length, 1);
        verify(tc.notified[0].indexOf("ffmpeg") !== -1);
        e.destroy();
    }

    function test_stop_sends_a_targeted_sigint() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        _urlAck(e, "__REC_URL_OK__");
        tc.execLog = [];
        e.recStop();
        verify(e._recStopRequested);
        verify(_lastExec().indexOf(": REC_STOP") === 0 || _lastExec().indexOf("kill -INT") !== -1);
        e.destroy();
    }

    function test_schedule_add_remove_roundtrips_through_config() {
        var e = makeEngine();
        // addRecSchedule returns nothing (matches the original) — assert on
        // the state it built, not on a return value.
        e.addRecSchedule("Radio", "https://s.example/stream", 7, 30, 60, "daily", 0);
        compare(e.recSchedules.length, 1);
        var e2 = makeEngine({ recSchedules: e.cfg.recSchedules });
        e2._loadRecSchedules();
        compare(e2.recSchedules.length, 1);
        e2.removeRecSchedule(0);
        compare(e2.recSchedules.length, 0);
        e.destroy(); e2.destroy();
    }

    function test_a_healed_station_moves_its_scheduled_recordings() {
        // A schedule has no heal road of its own: on the dead address ffmpeg
        // simply fails, every day, and the programme is never recorded.
        var e = makeEngine();
        e.addRecSchedule("Rock FM", "https://old.example/live", 20, 0, 60, "weekly", 5);
        e.addRecSchedule("Other", "https://other.example/live", 7, 30, 30, "daily", 0);
        var nextRun = e.recSchedules[0].nextRun;
        verify(e.retargetStation("https://old.example/live", "https://new.example/live"));
        compare(e.recSchedules[0].url, "https://new.example/live");
        compare(e.recSchedules[0].station, "Rock FM");
        compare(e.recSchedules[0].nextRun, nextRun);
        compare(e.recSchedules[1].url, "https://other.example/live");
        compare(JSON.parse(e.cfg.recSchedules)[0].url, "https://new.example/live");
        verify(!e.retargetStation("https://nobody.example/x", "https://new.example/live"));
        verify(!e.retargetStation("", "https://new.example/live"));
        verify(!e.retargetStation("https://new.example/live", ""));
        e.destroy();
    }

    // ── A station that moves while its programme is being recorded ────────

    // An entry due now on the old address, its capture started and running.
    function _capturingOnTheOldAddress(repeat) {
        var e = makeEngine();
        e.app._schedApplyTzChange = function(now) {};   // shared, lives in main
        e.addRecSchedule("Rock FM", "https://old.example/live", 7, 30, 60, repeat, 0);
        var rl = e.recSchedules.slice();
        rl[0].nextRun = Date.now() - 1000;
        e.recSchedules = rl;
        e._recScheduleTick();
        _urlAck(e, "__REC_URL_OK__");
        verify(e.recording);
        return e;
    }

    function test_a_station_moved_mid_capture_is_still_the_captures_own_data() {
        return [
            { tag: "once", repeat: "once", left: 0 },
            { tag: "daily", repeat: "daily", left: 1 }
        ];
    }

    function test_a_station_moved_mid_capture_is_still_the_captures_own(data) {
        // An entry is filed under address@time. The move rewrote the address
        // and the running capture kept the old filing, so the next tick took
        // its own recording for somebody else's and said "skipped", and the
        // finished capture found no entry to settle: a "once" stayed in the
        // list and was called missed when its window closed.
        var e = _capturingOnTheOldAddress(data.repeat);
        verify(e.retargetStation("https://old.example/live", "https://new.example/live"));
        tc.notified = [];
        e._recScheduleTick();
        compare(tc.notified.length, 0);
        e.recElapsedSec = 3600;
        e.recCapturedSec = 3600;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=99999999", "", 0));
        compare(tc.notified.length, 1);
        verify(tc.notified[0].indexOf("Recording saved") === 0);
        compare(e.recSchedules.length, data.left);
        if (data.left === 1) verify(e.recSchedules[0].nextRun > Date.now());
        // Nothing is left for a later tick to call missed.
        e._recScheduleTick();
        compare(tc.notified.length, 1);
        e.destroy();
    }

    function test_a_capture_stopped_by_hand_after_the_move_spends_its_entry() {
        var e = _capturingOnTheOldAddress("once");
        e.retargetStation("https://old.example/live", "https://new.example/live");
        e.recStop();
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=255 bytes=99999999", "", 0));
        compare(e.recSchedules.length, 0);
        e.destroy();
    }

    function test_a_capture_that_fails_after_the_move_backs_off_under_the_new_address() {
        // The capture was still on the address that died. It ends at once,
        // and the entry it retries under is the one the list holds now.
        var e = _capturingOnTheOldAddress("once");
        e.retargetStation("https://old.example/live", "https://new.example/live");
        e.recElapsedSec = 1;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=1 bytes=0", "", 0));
        var key = e._recSchedKey(e.recSchedules[0]);
        compare(e._recRetryCount[key], 1);
        // Inside the backoff the tick leaves it alone.
        tc.execLog = [];
        e._recScheduleTick();
        compare(_urlWrites().length, 0);
        e.destroy();
    }

    function test_a_move_lets_a_failing_entry_try_the_new_address_at_once() {
        // The backoff was earned by the address that went away. Carried
        // over, it kept the programme waiting on an address that answers.
        var e = _capturingOnTheOldAddress("once");
        e.recElapsedSec = 1;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=1 bytes=0", "", 0));
        verify(!e.recording);
        var was = e._recSchedKey(e.recSchedules[0]);
        verify(e._recRetryAfter[was] > Date.now());
        e.retargetStation("https://old.example/live", "https://new.example/live");
        compare(e._recRetryCount[was], undefined);
        compare(e._recRetryAfter[was], undefined);
        tc.execLog = [];
        e._recScheduleTick();
        compare(_urlWrites().length, 1);
        verify(e.recording);
        e.destroy();
    }

    function test_a_skipped_word_is_not_said_again_after_the_move() {
        // Another recording holds the recorder, the due entry was called
        // skipped once, and its address then changes under it.
        var e = makeEngine();
        e.app._schedApplyTzChange = function(now) {};
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        e.addRecSchedule("Rock FM", "https://old.example/live", 7, 30, 60, "once", 0);
        var rl = e.recSchedules.slice();
        rl[0].nextRun = Date.now() - 1000;
        e.recSchedules = rl;
        e._recScheduleTick();
        compare(tc.notified.length, 1);
        compare(tc.notified[0], "Scheduled recording skipped");
        e.retargetStation("https://old.example/live", "https://new.example/live");
        e._recScheduleTick();
        compare(tc.notified.length, 1);
        e.destroy();
    }

    function test_notetrack_writes_only_for_the_matching_instant_recording() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        _urlAck(e, "__REC_URL_OK__");
        tc.execLog = [];
        // Wrong stream target: nothing written.
        e.noteTrack("https://OTHER.example/x", "Artist", "Song");
        compare(tc.execLog.length, 0);
        // The recording's own stream: one REC_TRACK append.
        e.noteTrack(e._recUrl, "Artist", "Song");
        compare(tc.execLog.length, 1);
        verify(_lastExec().indexOf(": REC_TRACK;") === 0);
        verify(_lastExec().indexOf("Song") !== -1);
        e.destroy();
    }

    // ── The REC counter and the file on disk. Measured 2026-09-23: the file
    // of a Dance Wave! recording was born 141 s after the click, and the
    // counter read 11:50 over 592.6 s of audio. On the bench, a server that
    // held the recorder's connection for 25 s gave REC 0:24 with no file.

    function _captureRunning(e) {
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        _urlAck(e, "__REC_URL_OK__");
        tc.execLog = [];
    }

    function _probeCmd() {
        for (var i = tc.execLog.length - 1; i >= 0; i--)
            if (tc.execLog[i].indexOf(": REC_PROBE ") === 0) return tc.execLog[i];
        return "";
    }

    function test_the_counter_says_connecting_until_the_file_exists() {
        var e = makeEngine();
        _captureRunning(e);
        compare(e.recCounterText(), "Connecting…");
        wait(1300);
        // The wall clock runs for the verdicts; the counter does not.
        verify(e.recElapsedSec >= 1);
        compare(e.recCapturedSec, 0);
        compare(e.recCounterText(), "Connecting…");
        e._recProbe();
        var probe = _probeCmd();
        verify(probe !== "");
        verify(e.handleExec(probe, "", "", 1));          // not there yet
        verify(!e.recOnDisk);
        e._recProbe();
        verify(e.handleExec(_probeCmd(), "__REC_ON_DISK__\n", "", 0));
        verify(e.recOnDisk);
        compare(e.recCounterText(), "0:00");
        wait(1300);
        verify(e.recCapturedSec >= 1);
        compare(e.recCounterText(), RecLogic.elapsedText(e.recCapturedSec));
        e.destroy();
    }

    function test_the_probe_asks_about_this_recordings_own_file() {
        var e = makeEngine();
        _captureRunning(e);
        e._recProbe();
        var probe = _probeCmd();
        verify(probe.indexOf("[ -e '" + e._recFilePath.replace(/'/g, "'\\''") + "' ]") !== -1);
        // One question at a time: a second tick while the first is out asks nothing.
        tc.execLog = [];
        e._recProbe();
        compare(_probeCmd(), "");
        e.destroy();
    }

    function test_an_answer_about_the_previous_recording_is_dropped() {
        var e = makeEngine();
        _captureRunning(e);
        e._recProbe();
        var old = _probeCmd();
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=9999999", "", 0));
        _captureRunning(e);
        verify(e.handleExec(old, "__REC_ON_DISK__\n", "", 0));
        verify(!e.recOnDisk);
        compare(e.recCounterText(), "Connecting…");
        e.destroy();
    }

    function test_the_toast_and_the_tracklist_read_the_captured_time() {
        var e = makeEngine();
        _captureRunning(e);
        e._recProbe();
        e.handleExec(_probeCmd(), "__REC_ON_DISK__\n", "", 0);
        e.recElapsedSec = 200;          // pressed 3:20 ago…
        e.recCapturedSec = 65;          // …the file began 1:05 ago
        tc.execLog = [];
        e.noteTrack(e._recUrl, "Artist", "Song");
        verify(_lastExec().indexOf("[1:05] Artist - Song") !== -1);
        tc.notified = [];
        e.recStop();
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=255 bytes=9999999", "", 0));
        compare(tc.notified[0], "Recording saved ✓ (1:05)");
        verify(!e.recOnDisk);
        e.destroy();
    }

    function test_a_stop_before_the_file_leaves_the_next_recording_waiting() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        compare(e.recCounterText(), "Connecting…");
        e.recStop();                    // called off before the capture ran
        verify(!e.recording);
        _captureRunning(e);
        verify(!e.recOnDisk);
        compare(e.recCapturedSec, 0);
        e.destroy();
    }

    // ── an answer belongs to the recording that asked ────────────────────
    // The address is written by its own short command and the capture
    // waits for that command's answer. The answer said nothing about which
    // recording it was for, so one arriving late was taken by whichever
    // recording was waiting then.

    // The address writes the engine has sent, oldest first, as it sent them.
    function _urlWrites() {
        return tc.execLog.filter(function(c) { return c.indexOf(": REC_URL") === 0 && c.indexOf(": REC_URLCLEAN") !== 0; });
    }
    function _captures() {
        return tc.execLog.filter(function(c) { return c.indexOf(": REC_START;") === 0; });
    }
    // Recording A is asked for and called off, recording B is asked for,
    // and A's answer is still on its way: [A's write, B's write].
    function _twoStartsOneCalledOff(e) {
        e._recStart("Alpha FM", "https://a.example/stream", 3600, false);
        e.recStop();
        e._recStart("Beta FM", "https://b.example/stream", 3600, false);
        var w = _urlWrites();
        compare(w.length, 2, "each recording writes its own address");
        verify(w[0] !== w[1], "the two writes cannot be told apart");
        verify(e.recording && e._recPending !== null, "the second recording is not waiting for its answer");
        return w;
    }

    function test_a_late_yes_for_a_recording_called_off_does_not_start_the_next() {
        // Seen with the real engine: the first recording's late "written"
        // started the second one's capture before its own address was on
        // disk, and when the second write then failed nobody heard of it:
        // the answer found no one waiting and the recording stayed "on".
        var told = [];
        var e = makeEngine({}, { notify: function(t, x, i) { told.push(t + "|" + x); } });
        var w = _twoStartsOneCalledOff(e);
        verify(e.handleExec(w[0], "__REC_URL_OK__", "", 0), "a late answer is still the engine's to take");
        compare(_captures().length, 0, "a capture was started on another recording's answer");
        verify(e._recPending !== null, "the waiting recording lost its place to a late answer");
        // Its own answer is the one that counts, and this time it is a no.
        verify(e.handleExec(w[1], "__REC_URL_FAIL__", "", 0));
        compare(e.recording, false, "a failed write left the recording standing");
        compare(told.join(" / "), "Recording failed|Beta FM");
        compare(_captures().length, 0);
        e.destroy();
    }

    function test_a_late_no_for_a_recording_called_off_is_not_the_next_ones() {
        // The other way round: the first recording's late "could not write"
        // reported the second as failed and took it down.
        var told = [];
        var e = makeEngine({}, { notify: function(t, x, i) { told.push(t + "|" + x); } });
        var w = _twoStartsOneCalledOff(e);
        verify(e.handleExec(w[0], "__REC_URL_FAIL__", "", 0));
        compare(told.join(" / "), "", "a recording was reported failed on another one's answer");
        verify(e.recording, "a late answer stopped the recording that was waiting");
        verify(e._recPending !== null);
        // Its own yes starts it, once.
        verify(e.handleExec(w[1], "__REC_URL_OK__", "", 0));
        compare(_captures().length, 1);
        verify(e.recording);
        compare(told.join(" / "), "");
        // The same answer a second time finds nobody waiting and changes nothing.
        verify(e.handleExec(w[1], "__REC_URL_OK__", "", 0));
        compare(_captures().length, 1, "one answer started the capture twice");
        e.destroy();
    }

    function test_two_recordings_in_a_row_each_take_their_own_answer() {
        var e = makeEngine();
        e._recStart("Alpha FM", "https://a.example/stream", 60, false);
        verify(e.handleExec(_urlWrites()[0], "__REC_URL_OK__", "", 0));
        compare(_captures().length, 1);
        e.recElapsedSec = 60;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=9999999", "", 0));
        verify(!e.recording);
        e._recStart("Beta FM", "https://b.example/stream", 60, false);
        compare(_urlWrites().length, 2);
        verify(e.handleExec(_urlWrites()[1], "__REC_URL_OK__", "", 0));
        compare(_captures().length, 2, "the second recording's own answer was not taken");
        e.destroy();
    }

    function test_an_answer_that_names_no_recording_starts_nothing() {
        var e = makeEngine();
        e._recStart("Alpha FM", "https://a.example/stream", 3600, false);
        var own = _urlWrites()[0];
        var after = own.substring(own.indexOf(";"));        // "; umask 077; printf ..."
        var nobodys = [": REC_URL " + after, ": REC_URL x" + after, ": REC_URL -1" + after,
                       ": REC_URL 99999999999999999999" + after, ": REC_URL 0" + after, ": REC_URL "];
        for (var i = 0; i < nobodys.length; i++) {
            verify(e.handleExec(nobodys[i], "__REC_URL_OK__", "", 0), "case " + i + " was not taken as the engine's");
            compare(_captures().length, 0, "case " + i + " started a capture");
            verify(e._recPending !== null, "case " + i + " took the waiting recording's place");
        }
        // And the real one still works after all of them.
        verify(e.handleExec(own, "__REC_URL_OK__", "", 0));
        compare(_captures().length, 1);
        e.destroy();
    }

    // ── A stop while the capture is still getting ready ───────────────────
    // Measured with the real command and df held back: at Stop there was no
    // pid file, nothing was signalled, and the shell went on to ask for the
    // stream and wrote 159819 bytes. A stop sent the moment the pid file
    // appeared was lost as well: ffmpeg was 0 ms old, still ignored SIGINT
    // (SigIgn 0x6, nothing caught yet) and recorded on.

    // A recording whose capture shell has been sent off, the log kept.
    function _captureSent(e, name) {
        e._recStart(name || "Radio", "https://s.example/stream", 3600, false);
        verify(_urlAck(e, "__REC_URL_OK__"));
        return _captures()[_captures().length - 1];
    }
    // The mark as a stop writes it and as the capture shell asks for it.
    function _markWrite(e) {
        return "printf '%s' '" + e._recToken + "' > '" + e._recStopFile + "'";
    }
    function _markAsk(e) {
        return "[ \"$(cat '" + e._recStopFile + "' 2>/dev/null)\" = '" + e._recToken + "' ]";
    }

    function test_a_stop_leaves_its_mark_before_it_looks_for_a_pid() {
        var e = makeEngine();
        _captureSent(e);
        compare(e._recStopFile, "/run/user/1000/arp-rec-stop-42");
        verify(/^\d+\.\d+$/.test(e._recToken), "no token for this recording: '" + e._recToken + "'");
        e.recStop();
        compare(_stops().length, 1);
        var s = _stops()[0];
        var mark = s.indexOf(_markWrite(e) + "; ");
        var pid = s.indexOf("p=$(cat '/run/user/1000/arp-rec-42.pid'");
        verify(mark !== -1, "the stop left no mark: " + s);
        verify(pid !== -1 && mark < pid, "the pid is read before the mark is down");
        e.destroy();
    }

    function test_the_capture_reads_the_mark_before_the_stream_and_after_the_pid() {
        var e = makeEngine();
        var c = _captureSent(e);
        verify(c.indexOf("off() { " + _markAsk(e) + "; }; ") !== -1, "the capture cannot read its mark: " + c);
        var first = c.indexOf("if off; then cln; echo __REC_OFF__; exit 0; fi; ");
        var stream = c.indexOf(" timeout --signal=INT");
        var pid = c.indexOf("echo $pid > '/run/user/1000/arp-rec-42.pid'; ");
        var second = c.indexOf("off && kill -TERM $pid 2>/dev/null; ");
        var waits = c.indexOf("wait $pid; ");
        verify(first !== -1, "nothing asks for the mark before the stream");
        verify(second !== -1, "nothing asks for the mark once the pid is down");
        // After the slow steps, so a stop during any of them is seen, and
        // before a single byte is asked for.
        verify(c.indexOf("df -Pk") < first && first < stream);
        // The pid first: a stop that finds no mark reader left finds the pid.
        verify(stream < pid && pid < second && second < waits);
        e.destroy();
    }

    function test_a_mark_is_one_recordings_own() {
        // Stop pressed as the capture ends by itself: the mark lands after
        // its shell has left, and the next recording must not die of it.
        var e = makeEngine();
        _captureSent(e, "Alpha FM");
        var alpha = e._recToken;
        e.recStop();
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=255 bytes=9999999", "", 0));
        var c = _captureSent(e, "Beta FM");
        verify(e._recToken !== alpha, "two recordings share one token");
        verify(c.indexOf(_markAsk(e)) !== -1);
        verify(c.indexOf("'" + alpha + "'") === -1, "the next capture answers to the last one's mark");
        e.recStop();
        verify(_stops()[1].indexOf(_markWrite(e) + "; ") !== -1);
        verify(_stops()[1].indexOf("'" + alpha + "'") === -1);
        e.destroy();
    }

    function test_a_second_press_writes_the_same_mark_again() {
        var e = makeEngine();
        _captureSent(e);
        e.recStop();
        e.recStop();
        compare(_stops().length, 2);
        verify(_stops()[0].indexOf(_markWrite(e) + "; ") !== -1);
        compare(_stops()[0], _stops()[1]);
        e.destroy();
    }

    function test_a_stop_before_the_capture_was_sent_needs_no_mark() {
        // The address is still being written: the capture command is simply
        // never sent, and there is no shell to tell.
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        var own = _urlWrites()[0];
        e.recStop();
        compare(_stops().length, 0);
        verify(!e.recording);
        verify(e.handleExec(own, "__REC_URL_OK__", "", 0));
        compare(_captures().length, 0);
        // With nothing recording there is nothing to mark either.
        e.recStop();
        compare(_stops().length, 0);
        e.destroy();
    }

    function test_a_stop_sends_the_signal_the_process_can_hear() {
        // A process still ignoring SIGINT has not got to ffmpeg's own
        // handlers yet. SIGTERM ends it there, and once the handlers are in
        // ffmpeg closes the file on either.
        var e = makeEngine();
        _captureSent(e);
        e.recStop();
        verify(_stops()[0].indexOf("if grep -q '^SigIgn:.*[2367abef]$' \"/proc/$p/status\" 2>/dev/null;"
                                   + " then kill -TERM \"$p\"; else kill -INT \"$p\"; fi") !== -1, _stops()[0]);
        // Still only for a process that is this recorder's own.
        verify(_stops()[0].indexOf("grep -q 'ffmpeg.*pipe:0' && {") !== -1);
        e.destroy();
    }

    function test_every_way_out_takes_the_mark_along() {
        var e = makeEngine();
        var c = _captureSent(e);
        var both = "rm -f '/run/user/1000/arp-rec-url-42' '/run/user/1000/arp-rec-stop-42'";
        verify(c.indexOf("cln() { " + both + "; }; ") !== -1, c);
        verify(c.indexOf("wait $pid; rc=$?; rm -f '/run/user/1000/arp-rec-42.pid'; cln; ") !== -1);
        // And the one a crashed panel left goes at the next start.
        tc.execLog = [];
        e.start();
        verify(_lastExec().indexOf("rm -f '/run/user/1000/arp-rec-42.pid' '/run/user/1000/arp-rec-stop-42'; true") !== -1,
               _lastExec());
        e.destroy();
    }

    function test_a_quote_in_the_run_dir_stays_inside_the_marks_path() {
        var e = makeEngine({}, { _mprisRunDir: "/run/o'neil" });
        var c = _captureSent(e);
        var path = "'/run/o'\\''neil/arp-rec-stop-42'";
        verify(c.indexOf("off() { [ \"$(cat " + path + " 2>/dev/null)\" = '" + e._recToken + "' ]; }; ") !== -1, c);
        e.recStop();
        verify(_stops()[0].indexOf("printf '%s' '" + e._recToken + "' > " + path + "; ") !== -1, _stops()[0]);
        e.destroy();
    }

    function test_a_capture_called_off_says_nothing_data() {
        return [
            // The shell met the mark before it asked for the stream.
            { tag: "before it began", answer: "__REC_OFF__" },
            // It met the mark, or the signal, with ffmpeg a few ms old.
            { tag: "ffmpeg ended at once", answer: "__REC_EMPTY__ rc=143" },
            // Stopped while still connecting: ffmpeg leaves without a file.
            { tag: "no file yet", answer: "__REC_EMPTY__ rc=255" }
        ];
    }

    function test_a_capture_called_off_says_nothing(data) {
        // The listener asked for the stop and there is nothing on disk: that
        // is what was asked for. It used to read "Recording failed".
        var e = makeEngine();
        _captureSent(e);
        e.recStop();
        tc.notified = [];
        verify(e.handleExec(": REC_START;", data.answer, "", 0));
        compare(tc.notified, []);
        verify(!e.recording);
        verify(!e._recStopRequested);
        e.destroy();
    }

    function test_a_scheduled_capture_called_off_spends_its_entry() {
        var e = _capturingOnTheOldAddress("once");
        e.recStop();
        tc.notified = [];
        verify(e.handleExec(": REC_START;", "__REC_OFF__", "", 0));
        compare(tc.notified, []);
        compare(e.recSchedules.length, 0);
        e.destroy();
    }

    function test_nothing_on_disk_that_nobody_asked_for_is_still_a_failure_data() {
        return [
            { tag: "the stream gave nothing", answer: "__REC_EMPTY__ rc=1" },
            // A capture that says it was called off when no stop was sent.
            { tag: "called off unasked", answer: "__REC_OFF__" },
            { tag: "no answer at all", answer: "" }
        ];
    }

    function test_nothing_on_disk_that_nobody_asked_for_is_still_a_failure(data) {
        var e = makeEngine();
        _captureSent(e);
        tc.notified = [];
        verify(e.handleExec(": REC_START;", data.answer, "", 0));
        compare(tc.notified, ["Recording failed"]);
        e.destroy();
    }

    function test_a_capture_stopped_past_its_window_with_nothing_on_disk_is_said() {
        // The tick's own stop is not the listener's. A programme that left
        // nothing behind has to be heard of.
        var e = _scheduledCaptureRunning(150 * 60000);
        e._recScheduleTick();
        compare(_stops().length, 1);
        verify(e.handleExec(": REC_START;", "__REC_EMPTY__ rc=143", "", 0));
        compare(tc.notified, ["Recording failed"]);
        compare(e.recSchedules.length, 0);
        e.destroy();
    }

    function test_a_missing_tool_is_named_even_when_the_stop_came_first() {
        var e = makeEngine();
        _captureSent(e);
        e.recStop();
        tc.notified = [];
        verify(e.handleExec(": REC_START;", "__NO_FFMPEG__", "", 0));
        compare(tc.notified, ["ffmpeg is not installed"]);
        e.destroy();
    }

    function test_commands_that_are_not_ours_are_declined() {
        var e = makeEngine();
        compare(e.handleExec(": PW_PROBE;", "x", "", 0), false);
        e.destroy();
    }

    // ── The schedule tick and the DST retime — the two paths the first
    // eleven tests never walked, where the facade rewrite hid a bare
    // _schedApplyTzChange (ReferenceError, scheduled recording 100% dead)
    // and a dropped applyTzRetime call (schedules an hour off after DST).

    function test_the_schedule_tick_runs_and_launches_a_due_recording() {
        var e = makeEngine();
        var tzCalls = 0;
        e.app._schedApplyTzChange = function(now) { tzCalls++; };  // shared, in main
        e.addRecSchedule("Radio", "https://s.example/stream", 7, 30, 60, "once", 0);
        // Force the single entry due now.
        var rl = e.recSchedules.slice();
        rl[0].nextRun = Date.now() - 1000;
        e.recSchedules = rl;
        e._recScheduleTick();                 // must not throw on app._schedApplyTzChange
        compare(tzCalls, 1);
        // A due entry started staging its capture.
        verify(tc.execLog.length >= 1);
        verify(tc.execLog[0].indexOf(": REC_URL ") === 0);
        verify(e.recording);
        e.destroy();
    }

    function test_a_scheduled_capture_that_wrote_nothing_keeps_its_backoff() {
        // A host that answers, holds the socket past five seconds and closes
        // clean with an empty file is not "interrupted mid-window" — but the
        // resume road used to read it that way, erase its own retry counter
        // and relaunch on the next tick, a toast and a process each time for
        // the whole window. An empty capture earns the backoff like any other
        // failure that never produced audio.
        var e = makeEngine();
        e.app._schedApplyTzChange = function(now) {};   // shared, lives in main
        e.addRecSchedule("Radio", "https://s.example/stream", 7, 30, 60, "once", 0);
        var rl = e.recSchedules.slice();
        rl[0].nextRun = Date.now() - 1000;
        e.recSchedules = rl;
        e._recScheduleTick();
        var key = e._recActiveSchedKey;
        verify(key !== "");
        _urlAck(e, "__REC_URL_OK__");
        e.recElapsedSec = 60;                      // ran the whole window...
        tc.notified = [];
        // ...and produced 100 bytes, which is nothing for sixty seconds.
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=100", "", 0));
        compare(e._recRetryCount[key], 1);
        verify(e._recRetryAfter[key] > Date.now());
        e.destroy();
    }

    // ── A capture the machine slept through ───────────────────────────────

    // A scheduled hour-long capture that is running, with the wall clock
    // moved to pastEndMs after the end of its window. The clock cannot be
    // moved from here, so the window is: the entry and the active key go
    // back together, which is what a night's sleep leaves behind.
    function _scheduledCaptureRunning(pastEndMs, staged) {
        var e = makeEngine();
        e.app._schedApplyTzChange = function(now) {};   // shared, lives in main
        e.addRecSchedule("Radio", "https://s.example/stream", 7, 30, 60, "once", 0);
        var rl = e.recSchedules.slice();
        rl[0].nextRun = Date.now() - 1000;
        e.recSchedules = rl;
        e._recScheduleTick();
        // The address write the engine sent, kept for a test that answers it
        // late: an answer names its recording, and a bare one is nobody's.
        tc.stagedWrite = _urlWrites().pop();
        if (!staged) _urlAck(e, "__REC_URL_OK__");
        rl = e.recSchedules.slice();
        rl[0].nextRun = Date.now() - 60 * 60000 - pastEndMs;
        e.recSchedules = rl;
        e._recActiveSchedKey = e._recSchedKey(rl[0]);
        tc.execLog = []; tc.notified = [];
        return e;
    }

    function _stops() {
        return tc.execLog.filter(function(c) { return c.indexOf(": REC_STOP;") === 0; });
    }

    function test_a_capture_past_its_window_is_stopped_by_the_tick() {
        // The window ended 150 minutes ago and the capture is still going.
        // The tick used to pass it by: no command, no word.
        var e = _scheduledCaptureRunning(150 * 60000);
        e._recScheduleTick();
        compare(_stops().length, 1);
        verify(_stops()[0].indexOf("kill -INT") !== -1);
        // It is still the completion's to settle: nothing is called missed
        // and the entry stays until the capture has answered.
        compare(tc.notified.length, 0);
        compare(e.recSchedules.length, 1);
        verify(e.recording);
        e.destroy();
    }

    function test_a_capture_stopped_past_its_window_is_not_called_saved_data() {
        return [
            { tag: "ended by the stop", answer: "__REC_DONE__ rc=255 bytes=99999999" },
            // ffmpeg reaching its own end in the same second changes nothing.
            { tag: "ended on its own", answer: "__REC_DONE__ rc=0 bytes=99999999" }
        ];
    }

    function test_a_capture_stopped_past_its_window_is_not_called_saved(data) {
        var e = _scheduledCaptureRunning(150 * 60000);
        e.recElapsedSec = 3600;         // the tick counter says a full hour
        e.recCapturedSec = 3590;
        e._recScheduleTick();
        verify(e.handleExec(": REC_START;", data.answer, "", 0));
        compare(tc.notified.length, 1);
        compare(tc.notified[0], "Recording interrupted (59:50 captured)");
        // The occurrence is over. A "once" entry leaves, and the next tick
        // has nothing left to call missed.
        compare(e.recSchedules.length, 0);
        verify(!e.recording);
        e._recScheduleTick();
        compare(tc.notified.length, 1);
        e.destroy();
    }

    function test_the_overrun_stop_is_sent_once() {
        var e = _scheduledCaptureRunning(150 * 60000);
        e._recScheduleTick();
        e._recScheduleTick();           // the capture has not answered yet
        compare(_stops().length, 1);
        e.destroy();
    }

    function test_a_capture_seconds_past_its_window_is_left_to_finish() {
        // ffmpeg's own exit lands a few seconds after the end. Stopping it
        // there would turn every good recording into an interrupted one.
        var e = _scheduledCaptureRunning(20000);
        e._recScheduleTick();
        compare(_stops().length, 0);
        compare(tc.notified.length, 0);
        e.recElapsedSec = 3600;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=99999999", "", 0));
        verify(tc.notified[0].indexOf("Recording saved") === 0);
        e.destroy();
    }

    function test_a_capture_that_connected_late_is_left_to_run_its_length() {
        // 141 s to connect was measured on a slow station. Such a capture is
        // whole, it only ends that much after the window, and it is saved.
        var e = _scheduledCaptureRunning(141000);
        e._recScheduleTick();
        compare(_stops().length, 0);
        compare(tc.notified.length, 0);
        e.recElapsedSec = 3600;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=99999999", "", 0));
        verify(tc.notified[0].indexOf("Recording saved") === 0);
        e.destroy();
    }

    function test_a_stop_the_listener_asked_for_keeps_its_verdict() {
        // Stopped by hand, and the window happens to be over as well: the
        // tick has nothing to add, and a hand stop is a saved file.
        var e = _scheduledCaptureRunning(150 * 60000);
        e.recStop();
        e._recScheduleTick();
        compare(_stops().length, 1);
        e.recElapsedSec = 1200;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=255 bytes=99999999", "", 0));
        verify(tc.notified[0].indexOf("Recording saved") === 0);
        e.destroy();
    }

    function test_a_capture_that_never_started_before_its_window_closed_is_missed() {
        // Asleep between the address being written and the capture starting.
        // There is no process to signal and no file; the honest word is
        // "missed", once, and a late acknowledgement starts nothing.
        var e = _scheduledCaptureRunning(150 * 60000, true);
        verify(e._recPending !== null);
        e._recScheduleTick();
        compare(_stops().length, 0);
        compare(tc.notified, ["Scheduled recording missed"]);
        compare(e.recSchedules.length, 0);
        verify(!e.recording);
        tc.execLog = [];
        verify(e.handleExec(tc.stagedWrite, "__REC_URL_OK__", "", 0));
        compare(tc.execLog.length, 0);
        e.destroy();
    }

    function test_the_next_capture_after_an_overrun_is_judged_on_its_own() {
        var e = _scheduledCaptureRunning(150 * 60000);
        e._recScheduleTick();
        e.handleExec(": REC_START;", "__REC_DONE__ rc=255 bytes=99999999", "", 0);
        e._recStart("Radio", "https://s.example/stream", 60, false);
        e.recElapsedSec = 60;
        _urlAck(e, "__REC_URL_OK__");
        tc.notified = [];
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=9999999", "", 0));
        verify(tc.notified[0].indexOf("Recording saved") === 0);
        e.destroy();
    }

    // ── The time ran out and the audio is not there ───────────────────────
    // The verdict asked the wall clock, the exit code and a floor of 10 KB
    // a minute. Reported: asked 300 s, 302 s gone, the file 7 s old, rc=0,
    // 112000 bytes, and the notice read "Recording saved ✓ (0:07)".
    // Measured on the bench: a station that sent ten seconds and then held
    // the socket silent kept a one-minute capture going for its whole
    // six-minute cap, and the shell answered rc=0 with ten seconds on disk.

    // A capture asked to run wantedSec that has just ended on its own.
    // clockSec is how long ago its file was seen to appear, null for never.
    function _ranOut(wantedSec, elapsedSec, clockSec) {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", wantedSec, false);
        _urlAck(e, "__REC_URL_OK__");
        e.recElapsedSec = elapsedSec;
        if (clockSec !== null) {
            e._recProbe();
            verify(e.handleExec(_probeCmd(), "__REC_ON_DISK__\n", "", 0));
            e.recCapturedSec = clockSec;
        }
        tc.notified = [];
        return e;
    }

    function test_a_capture_far_short_of_its_length_is_not_called_saved_data() {
        return [
            { tag: "connected late, ended at once", wanted: 300, elapsed: 302, clock: 7,
              answer: "__REC_DONE__ rc=0 bytes=112000", said: "Recording interrupted (0:07 captured)" },
            { tag: "the same, the file asked", wanted: 300, elapsed: 302, clock: 7,
              answer: "__REC_DONE__ rc=0 bytes=112000 secs=7", said: "Recording interrupted (0:07 captured)" },
            // The clock counted the silence; the notice names the audio.
            { tag: "stalled after ten seconds", wanted: 300, elapsed: 600, clock: 598,
              answer: "__REC_DONE__ rc=0 bytes=160172 secs=10", said: "Recording interrupted (0:10 captured)" },
            { tag: "over before the file was seen", wanted: 300, elapsed: 300, clock: null,
              answer: "__REC_DONE__ rc=0 bytes=160172 secs=1", said: "Recording interrupted (0:01 captured)" },
            { tag: "one second under the file's slack", wanted: 300, elapsed: 300, clock: 296,
              answer: "__REC_DONE__ rc=0 bytes=9999999 secs=269", said: "Recording interrupted (4:29 captured)" },
            { tag: "one second under the clock's slack", wanted: 300, elapsed: 300, clock: 239,
              answer: "__REC_DONE__ rc=0 bytes=9999999 secs=N/A", said: "Recording interrupted (3:59 captured)" }
        ];
    }

    function test_a_capture_far_short_of_its_length_is_not_called_saved(data) {
        var e = _ranOut(data.wanted, data.elapsed, data.clock);
        verify(e.handleExec(": REC_START;", data.answer, "", 0));
        compare(tc.notified, [data.said]);
        e.destroy();
    }

    function test_a_whole_capture_is_saved_under_its_own_length_data() {
        return [
            { tag: "the file asked", wanted: 300, elapsed: 303, clock: 296,
              answer: "__REC_DONE__ rc=0 bytes=9999999 secs=300", said: "Recording saved ✓ (5:00)" },
            // 141 s to connect was measured. The capture runs its length
            // and is whole, however long the wall clock took over it.
            { tag: "connected late", wanted: 600, elapsed: 741, clock: 590,
              answer: "__REC_DONE__ rc=0 bytes=9999999 secs=600", said: "Recording saved ✓ (10:00)" },
            { tag: "at the file's slack", wanted: 300, elapsed: 300, clock: 296,
              answer: "__REC_DONE__ rc=0 bytes=9999999 secs=270", said: "Recording saved ✓ (4:30)" },
            // No ffprobe, and a container that cannot say: the clock.
            { tag: "no ffprobe", wanted: 300, elapsed: 303, clock: 296,
              answer: "__REC_DONE__ rc=0 bytes=9999999 secs=", said: "Recording saved ✓ (4:56)" },
            { tag: "length unknown", wanted: 300, elapsed: 303, clock: 240,
              answer: "__REC_DONE__ rc=0 bytes=9999999 secs=N/A", said: "Recording saved ✓ (4:00)" },
            // Neither witness: judged as it always was.
            { tag: "never seen, never asked", wanted: 300, elapsed: 300, clock: null,
              answer: "__REC_DONE__ rc=0 bytes=9999999", said: "Recording saved ✓ (0:00)" }
        ];
    }

    function test_a_whole_capture_is_saved_under_its_own_length(data) {
        var e = _ranOut(data.wanted, data.elapsed, data.clock);
        verify(e.handleExec(": REC_START;", data.answer, "", 0));
        compare(tc.notified, [data.said]);
        e.destroy();
    }

    function test_a_stop_by_hand_is_saved_however_short() {
        // Asked for up to two hours, stopped after a minute: that is the
        // listener's own length, and the notice names what the file holds.
        var e = _ranOut(7200, 70, 65);
        e.recStop();
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=255 bytes=1072000 secs=67", "", 0));
        compare(tc.notified, ["Recording saved ✓ (1:07)"]);
        e.destroy();
    }

    function test_a_broken_file_keeps_its_own_words() {
        // Too few bytes for its minutes is said as before, and a length the
        // file could not give does not make it whole.
        var told = [];
        var e = makeEngine({}, { notify: function(t, x, i) { told.push(t + "|" + x.replace(/^REC .*\.mp3/, "FILE")); } });
        e._recStart("Radio", "https://s.example/stream.mp3", 300, false);
        _urlAck(e, "__REC_URL_OK__");
        e.recElapsedSec = 300;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=5000 secs=", "", 0));
        compare(told, ["Recording interrupted (0:00 captured)|FILE — the file is much smaller than expected."]);
        e.destroy();
    }

    function test_a_stream_that_died_early_is_still_interrupted() {
        // What the wall clock always caught: the capture ended long before
        // its time. The length in the file changes nothing about that.
        var e = _ranOut(300, 120, 118);
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=1920000 secs=120", "", 0));
        compare(tc.notified, ["Recording interrupted (2:00 captured)"]);
        e.destroy();
    }

    function test_a_short_scheduled_capture_leaves_its_window_to_the_tick() {
        // An hour's programme of which ten minutes came: 9.6 MB, well over
        // the byte floor, which an hour puts at 615 KB. The capture is not
        // the occurrence done: the entry stays for the tick, and with the
        // window over the tick says what a window without a whole recording
        // has always been called.
        var e = _scheduledCaptureRunning(20000);
        e.recElapsedSec = 3605;
        e.recOnDisk = true;
        e.recCapturedSec = 3590;
        verify(e.handleExec(": REC_START;", "__REC_DONE__ rc=0 bytes=9600000 secs=600", "", 0));
        compare(tc.notified, ["Recording interrupted (10:00 captured)"]);
        compare(e.recSchedules.length, 1);
        e._recScheduleTick();
        compare(tc.notified, ["Recording interrupted (10:00 captured)", "Scheduled recording missed"]);
        compare(e.recSchedules.length, 0);
        e.destroy();
    }

    function test_the_capture_asks_the_file_for_its_length() {
        var e = makeEngine();
        var c = _captureSent(e);
        var out = "'" + e._recFilePath + "'";
        // Bounded, quiet, and only for a file that is there.
        var ask = "secs=$(timeout 10 ffprobe -v error -show_entries format=duration -of csv=p=0 "
                  + out + " 2>/dev/null); ";
        var has = c.indexOf("if [ \"$bytes\" -gt 0 ] 2>/dev/null; then " + ask
                            + "echo \"__REC_DONE__ rc=$rc bytes=$bytes secs=${secs%%.*}\"; ");
        verify(has !== -1, c);
        e.destroy();
    }

    function test_applytzretime_retimes_and_the_active_key_follows() {
        // The real path the first version of this test skipped by passing
        // empty schedules: a zone change retimes an entry, and the ACTIVE
        // recording's url@nextRun key must follow its new instant or the
        // tick reads its own recording as a stranger's and the completion
        // path loses the entry it should advance.
        var e = makeEngine();
        e.addRecSchedule("Radio", "https://s.example/stream", 7, 30, 60, "daily", 0);
        // Corrupt the stored instant to something recent-but-wrong, so
        // shouldRetime fires and retimeForZone lands on a different value.
        var rl = e.recSchedules.slice();
        rl[0].nextRun = Date.now() + 1000;
        e.recSchedules = rl;
        var oldKey = e._recSchedKey(e.recSchedules[0]);
        e.recording = true;
        e._recActiveSchedKey = oldKey;
        e.applyTzRetime(Date.now());
        var newKey = e._recSchedKey(e.recSchedules[0]);
        verify(newKey !== oldKey);               // the entry was retimed
        compare(e._recActiveSchedKey, newKey);   // the active key followed
        e.recording = false;
        e.destroy();
    }

    function test_applytzretime_is_callable_on_empty_schedules() {
        // It was dead code (zero callers) until main was fixed to call it;
        // the empty-schedule early return must stay harmless.
        var e = makeEngine();
        e.applyTzRetime(Date.now());
        compare(e.recSchedules.length, 0);
        e.destroy();
    }
}
