// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The timeshift state machine, driven through its app facade with a mock
// clock. The measured facts these tests encode: Qt freezes a growing
// file's duration at open, EndOfMedia stops the player at that horizon,
// and a reopen+seek is how playback crosses it.
import QtQuick
import QtTest

import "../../package/contents/ui"

Item {
    id: harness

    function i18n(s) {
        var out = s;
        for (var i = 1; i < arguments.length; i++)
            out = out.replace("%" + i, arguments[i]);
        return out;
    }

    Component {
        id: engineComp
        TimeshiftEngine {}
    }

    Component {
        id: mockAppComp
        QtObject {
            property var execLog: []
            property var played: []      // {kind: "buffer"|"live", url, pos}
            property int seqN: 0
            // The real facade REWRITES the command: an LC_ALL export lands
            // after the sentinel, so the ack never string-equals what the
            // engine sent. The mock does the same rewrite — an engine that
            // matches acks by full string fails here instead of only in a
            // live panel (which is exactly how it slipped through once).
            function exec(cmd) {
                var m = /^(:[^;]*;\s*)/.exec(String(cmd));
                var s = String(cmd);
                execLog.push(m ? m[1] + "export LC_ALL=C LANGUAGE=C; " + s.slice(m[1].length)
                               : "export LC_ALL=C LANGUAGE=C; " + s);
            }
            function nextSeq() { return ++seqN; }
            function notify(t, x, i) {}
            function tsBufferDir() { return "/home/egon/.cache/onair/timeshift"; }
            function tsPlayBuffer(url, pos) { played.push({ kind: "buffer", url: url, pos: pos }); }
            function tsPlayLive(url) { played.push({ kind: "live", url: url, pos: -1 }); }
        }
    }

    Component {
        id: mockCfgComp
        QtObject {
            property bool timeshiftEnabled: true
            property int timeshiftWindowMin: 60
        }
    }

    TestCase {
        name: "TimeshiftEngine"

        readonly property string stream: "http://s1.radio.ee/live.mp3"

        function rig(cfgProps) {
            var mock = mockAppComp.createObject(harness);
            var cfg = mockCfgComp.createObject(harness, cfgProps || {});
            var e = engineComp.createObject(harness, { app: mock, cfg: cfg });
            return { e: e, mock: mock, cfg: cfg };
        }

        // Walk a rig to the "writer running" state the honest way.
        function armed(r) {
            verify(r.e.armForStation(stream, "Jazz FM", 1000000));
            r.e.handleExec(r.mock.execLog[0], "__TS_URL_OK__", 1000000);
            compare(r.mock.execLog.length, 2);
            verify(r.e.writerUp);
        }

        function test_arming_writes_the_url_first_and_runs_second() {
            var r = rig();
            verify(r.e.armForStation(stream, "Jazz FM", 1000000));
            compare(r.mock.execLog.length, 1);
            verify(r.mock.execLog[0].indexOf(": TS_URL;") === 0);
            r.e.handleExec(r.mock.execLog[0], "__TS_URL_OK__", 1000500);
            compare(r.mock.execLog.length, 2);
            verify(r.mock.execLog[1].indexOf(": TS_RUN;") === 0);
            verify(r.mock.execLog[1].indexOf(stream) === -1);
            compare(r.e.bufStartMs, 1000500);
        }

        function test_arming_refuses_what_cannot_shift() {
            var r = rig();
            verify(!r.e.armForStation("http://s1.radio.ee/live.m3u8", "HLS", 0));
            verify(!r.e.armForStation("file:///x.mp3", "Local", 0));
            compare(r.mock.execLog.length, 0);
            var off = rig({ timeshiftEnabled: false });
            verify(!off.e.armForStation(stream, "Jazz FM", 0));
            compare(off.mock.execLog.length, 0);
        }

        function test_a_failed_url_write_folds_quietly() {
            var r = rig();
            r.e.armForStation(stream, "Jazz FM", 1000000);
            r.e.handleExec(r.mock.execLog[0], "__TS_URL_FAIL__", 1000500);
            verify(!r.e.active);
            compare(r.mock.execLog.length, 1);   // the writer never launched
        }

        function test_pause_parks_at_the_guarded_edge() {
            var r = rig();
            armed(r);
            // 100 s captured, 3 s guard: the pause parks at 97 s.
            var pos = r.e.pauseGesture(1100000);
            compare(pos, 97000);
            verify(!r.e.shifted);                // parked, not yet playing
            verify(r.e.resumeGesture());
            verify(r.e.shifted);
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].kind, "buffer");
            compare(r.mock.played[0].pos, 97000);
        }

        function test_a_pause_too_young_is_not_owned() {
            var r = rig();
            armed(r);
            compare(r.e.pauseGesture(1002000), -1);   // 2 s of buffer
            var cold = rig();
            compare(cold.e.pauseGesture(1000000), -1); // never armed
        }

        function test_the_horizon_reopen_carries_the_position_over() {
            var r = rig();
            armed(r);
            r.e.pauseGesture(1100000);
            r.e.resumeGesture();
            // The reader hits the frozen 97 s horizon at wall 1200 s: the
            // file has 200 s by now — reopen just behind the old position.
            verify(r.e.playerEndOfMedia(97000, 1200000));
            compare(r.mock.played.length, 2);
            compare(r.mock.played[1].kind, "buffer");
            compare(r.mock.played[1].pos, 96700);
        }

        function test_a_drained_buffer_returns_to_live() {
            var r = rig();
            armed(r);
            r.e.pauseGesture(1100000);
            r.e.resumeGesture();
            // The reader is within the guard of everything captured — a
            // reopen would gain nothing; the shift is over.
            verify(r.e.playerEndOfMedia(99500, 1103000));
            var last = r.mock.played[r.mock.played.length - 1];
            compare(last.kind, "live");
            verify(!r.e.shifted);
        }

        function test_a_reopen_that_gains_nothing_gives_up() {
            var r = rig();
            armed(r);
            r.e.pauseGesture(1100000);
            r.e.resumeGesture();
            verify(r.e.playerEndOfMedia(97000, 1200000));   // reopen at 96700
            // EndOfMedia lands again at the same spot: the file never grew.
            verify(r.e.playerEndOfMedia(96900, 1300000));
            var last = r.mock.played[r.mock.played.length - 1];
            compare(last.kind, "live");
        }

        function test_the_window_cap_freezes_the_buffer_not_the_listener() {
            var r = rig();
            armed(r);
            r.e.pauseGesture(1100000);
            r.e.resumeGesture();
            // The writer exits at wall 1200 s: 200 s are frozen on disk.
            r.e.handleExec(r.mock.execLog[1], "__TS_EXIT__ rc=0 bytes=3200000", 1200000);
            verify(r.e.windowFull);
            verify(r.e.shifted);                 // playback untouched
            compare(r.e.frozenCapturedMs, 200000);
            // The frozen file still serves a reopen up to ITS end, not the
            // wall clock's: at 150 s in, 200 s frozen — reopen works.
            verify(r.e.playerEndOfMedia(150000, 1500000));
            var last = r.mock.played[r.mock.played.length - 1];
            compare(last.kind, "buffer");
            compare(last.pos, 149700);
        }

        function test_a_writer_dying_live_folds_the_arm_quietly() {
            var r = rig();
            armed(r);
            r.e.handleExec(r.mock.execLog[1], "__TS_NOSPACE__", 1050000);
            verify(!r.e.active);
            verify(!r.e.writerUp);
            compare(r.mock.played.length, 0);    // playback never touched
        }

        function test_disarm_stops_the_writer_and_removes_the_buffer() {
            var r = rig();
            armed(r);
            r.e.disarm();
            var last = r.mock.execLog[r.mock.execLog.length - 1];
            verify(last.indexOf(": TS_STOP;") === 0);
            verify(last.indexOf("kill -INT") !== -1);
            verify(!r.e.active);
            compare(r.e.shiftPosMs, -1);
        }

        function test_a_previous_writers_exit_cannot_touch_the_new_arm() {
            // The re-arm kills the old writer, whose __TS_EXIT__ lands a
            // moment AFTER the new arm is up. Matched by prefix alone it
            // froze the new arm (windowFull, active=false) and killed the
            // pause icon for the rest of the session.
            var r = rig();
            armed(r);
            var oldRun = r.mock.execLog[1];
            r.e.armForStation("http://s2.radio.ee/other.mp3", "Rock FM", 2000000);
            r.e.handleExec(r.mock.execLog[3], "__TS_URL_OK__", 2000500);
            verify(r.e.writerUp);
            r.e.handleExec(oldRun, "__TS_EXIT__ rc=0 bytes=100", 2001000);
            verify(r.e.writerUp);
            verify(!r.e.windowFull);
            verify(r.e.active);
        }

        function test_each_arm_names_its_own_files() {
            // Shared fixed names let the outgoing arm's delayed cleanup
            // delete the incoming arm's fresh buffer.
            var r = rig();
            armed(r);
            var first = r.e.bufPath;
            r.e.armForStation("http://s2.radio.ee/other.mp3", "Rock FM", 2000000);
            verify(r.e.bufPath !== first);
        }

        function test_a_same_station_replay_ends_the_shift_not_the_buffer() {
            var r = rig();
            armed(r);
            r.e.pauseGesture(1100000);
            r.e.resumeGesture();
            verify(r.e.shifted);
            r.e.noteLivePlayback();
            verify(!r.e.shifted);
            compare(r.e.shiftPosMs, -1);
            verify(r.e.active);          // the caught minutes stay
            verify(r.e.writerUp);
        }

        function test_rearming_stops_the_previous_writer_first() {
            // A station switch with only a state reset would orphan the old
            // ffmpeg, copying a stream nobody plays until its wall cap.
            var r = rig();
            armed(r);
            verify(r.e.armForStation("http://s2.radio.ee/other.mp3", "Rock FM", 2000000));
            var stop = r.mock.execLog[2];
            verify(stop.indexOf(": TS_STOP;") === 0);
            verify(r.mock.execLog[3].indexOf(": TS_URL;") === 0);
            compare(r.e.stationName, "Rock FM");
        }

        function test_a_relay_arms_and_plays_with_the_feature_off() {
            // Issue #3: live Ogg-family streams wedge the backend on the
            // socket. The relay is playability, not a feature — it must
            // arm with the timeshift checkbox unticked and start playing
            // from the file on its own.
            var r = rig({ timeshiftEnabled: false });
            verify(r.e.armRelay("http://s1.radio.ee/gold.flac", "Gold", 1000000));
            verify(r.e.relay);
            r.e.handleExec(r.mock.execLog[0], "__TS_URL_OK__", 1000000);
            verify(r.e.writerUp);
            compare(r.mock.played.length, 0);        // not yet — file too young
            wait(3300);
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].kind, "buffer");
            compare(r.mock.played[0].pos, 0);
            verify(r.e.shifted);
        }

        function test_a_relay_catch_up_rearms_instead_of_going_live() {
            var r = rig({ timeshiftEnabled: false });
            r.e.armRelay("http://s1.radio.ee/gold.flac", "Gold", 1000000);
            r.e.handleExec(r.mock.execLog[0], "__TS_URL_OK__", 1000000);
            wait(3300);
            var n = r.mock.execLog.length;
            r.e.backToLive();
            // No live handover — the direct stream is the thing that
            // wedges. A fresh capture takes its place.
            for (var i = 0; i < r.mock.played.length; i++)
                verify(r.mock.played[i].kind !== "live");
            verify(r.mock.execLog.length > n);
            verify(r.mock.execLog[n].indexOf(": TS_STOP;") === 0);
            verify(r.e.relay);
        }

        function test_a_drained_relay_buffer_starts_over() {
            var r = rig({ timeshiftEnabled: false });
            r.e.armRelay("http://s1.radio.ee/gold.flac", "Gold", 1000000);
            r.e.handleExec(r.mock.execLog[0], "__TS_URL_OK__", 1000000);
            wait(3300);
            var n = r.mock.execLog.length;
            // The reader caught the writer for real (stall): re-arm, not live.
            verify(r.e.playerEndOfMedia(2500, 1003000));
            verify(r.mock.execLog.length > n);
            for (var i = 0; i < r.mock.played.length; i++)
                verify(r.mock.played[i].kind !== "live");
            verify(r.e.relay);
            verify(r.e.active);
        }

        function test_back_to_live_keeps_a_running_writer() {
            var r = rig();
            armed(r);
            r.e.pauseGesture(1100000);
            r.e.resumeGesture();
            r.e.backToLive();
            compare(r.mock.played[r.mock.played.length - 1].kind, "live");
            verify(r.e.active);                  // the buffer keeps growing
            verify(r.e.writerUp);
        }
    }
}
