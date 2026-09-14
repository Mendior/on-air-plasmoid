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

TestCase {
    id: tc
    name: "RecordingEngine"

    property var execLog: []
    property var notified: []
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

    function test_staging_writes_the_url_owner_only_then_the_capture_reads_it() {
        var e = makeEngine();
        e._recStart("Test Radio", "https://s.example/stream?token=SECRET", 3600, false);
        verify(e.recording);
        // Stage one: the URL goes to an owner-only file, not onto any argv.
        compare(tc.execLog.length, 1);
        verify(_lastExec().indexOf(": REC_URL;") === 0);
        verify(_lastExec().indexOf("umask 077") !== -1);
        // The pending capture command is armed but not yet run.
        verify(e._recPending !== null);
        verify(e._recPending.cmd.indexOf(": REC_START;") === 0);
        // Stage two: the config lands, the capture starts — curl reads the URL
        // via -K, ffmpeg never learns the address.
        verify(e.handleExec(": REC_URL;", "__REC_URL_OK__", "", 0));
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
        verify(_lastExec().indexOf(": REC_URL;") === 0);
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
        verify(e.handleExec(": REC_URL;", "__REC_URL_FAIL__", "", 0));
        compare(e.recording, false);
        e.destroy();
    }

    function test_a_clean_full_capture_reports_saved() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 60, false);
        e.recElapsedSec = 60;                       // ran to the end
        e.handleExec(": REC_URL;", "__REC_URL_OK__", "", 0);
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
        e.handleExec(": REC_URL;", "__REC_URL_OK__", "", 0);
        tc.notified = [];
        verify(e.handleExec(": REC_START;", "__NO_FFMPEG__", "", 0));
        compare(tc.notified.length, 1);
        verify(tc.notified[0].indexOf("ffmpeg") !== -1);
        e.destroy();
    }

    function test_stop_sends_a_targeted_sigint() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        e.handleExec(": REC_URL;", "__REC_URL_OK__", "", 0);
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

    function test_notetrack_writes_only_for_the_matching_instant_recording() {
        var e = makeEngine();
        e._recStart("Radio", "https://s.example/stream", 3600, false);
        e.handleExec(": REC_URL;", "__REC_URL_OK__", "", 0);
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
        verify(tc.execLog[0].indexOf(": REC_URL;") === 0);
        verify(e.recording);
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
