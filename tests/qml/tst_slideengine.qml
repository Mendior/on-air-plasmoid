// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The timeshift engine on its sliding buffer, driven through the same app
// facade as the single file's tests, with a clock the test owns. What the
// player does with a list was measured on Qt 6.12 with FFmpeg 9 and is
// written down in SlideLogic.js; here the engine is held to it.
import QtQuick
import QtTest

import "../../package/contents/ui"
import "../../package/contents/ui/SlideLogic.js" as SL
import "../../package/contents/ui/TimeshiftLogic.js" as TL

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
            // The real facade rewrites the command: an LC_ALL export lands
            // after the sentinel, so an ack never string-equals what was sent.
            function exec(cmd) {
                var m = /^(:[^;]*;\s*)/.exec(String(cmd));
                var s = String(cmd);
                execLog.push(m ? m[1] + "export LC_ALL=C LANGUAGE=C; " + s.slice(m[1].length)
                               : "export LC_ALL=C LANGUAGE=C; " + s);
            }
            function nextSeq() { return ++seqN; }
            property var notes: []
            function notify(t, x, i) { notes.push({ title: t, text: x }); }
            property string bufDir: "/home/egon/.cache/onair/onair-timeshift-48"
            function tsBufferDir() { return bufDir; }
            function tsServeScriptPath() { return "/opt/onair/relayserve.py"; }
            property bool playingNow: true
            function isPlaying() { return playingNow; }
            property bool _tsPaused: false
            property bool _wantsPlaying: true
            property string metadata: ""
            function tsPlayBuffer(url, pos) { _tsPaused = false; played.push({ kind: "buffer", url: url, pos: pos }); }
            // The engine under test, for a tsPlayLive that goes on as the
            // widget's does: startWithFade asks an engine that holds this
            // station to note the live playback, and arms one that does not.
            property var engine: null
            function tsPlayLive(url) {
                _tsPaused = false;
                played.push({ kind: "live", url: url, pos: -1 });
                if (!engine) return;
                if (engine.active && engine.streamUrl === url) engine.noteLivePlayback(1);
                else engine.armForStation(url, "Jazz FM", 1);
            }
            function tsPlayRelay(url) { played.push({ kind: "relay", url: url, pos: -1 }); }
            property bool lapsed: false
            function _orderLapsed() { return lapsed; }
            // What StreamKind remembers of an address; "" when nothing.
            property var kinds: ({})
            function tsKnownKind(url) { return kinds[url] || ""; }
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
        name: "SlideEngine"

        readonly property string stream: "http://s1.radio.ee/live"
        readonly property double t0: 1000000

        function rig(cfgProps) {
            var mock = mockAppComp.createObject(harness);
            var cfg = mockCfgComp.createObject(harness, cfgProps || {});
            var e = engineComp.createObject(harness, { app: mock, cfg: cfg });
            return { e: e, mock: mock, cfg: cfg };
        }

        function last(r, tag) {
            for (var i = r.mock.execLog.length - 1; i >= 0; i--)
                if (r.mock.execLog[i].indexOf(": " + tag + ";") === 0) return r.mock.execLog[i];
            return "";
        }

        function count(r, tag) {
            var n = 0;
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": " + tag + ";") === 0) n++;
            return n;
        }

        // An arm whose writer answered that it cuts segments.
        function sliding(r, url) {
            verify(r.e.armForStation(url || stream, "Jazz FM", t0));
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            // Answered in the same instant: the clock starts with this word.
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ slide mp3\n", t0);
            verify(r.e.slide);
        }

        // The position of a player whose sound is level with the writer's
        // clock, so that a park lands on the clock's round numbers.
        function level(r) { return r.e.runMs + SL.PARK_LAG_MS; }

        // The writer's clock, a second at a time.
        function run(r, fromMs, secs) {
            for (var i = 1; i <= secs; i++) r.e._beat(fromMs + i * 1000);
            return fromMs + secs * 1000;
        }

        // The same with a folder that keeps up: every question about more
        // segments is answered with all it asked for.
        function listen(r, fromMs, secs) {
            var seen = "";
            for (var i = 1; i <= secs; i++) {
                r.e._beat(fromMs + i * 1000);
                var g = last(r, "TS_GROW");
                if (g === "" || g === seen) continue;
                seen = g;
                var m = /grow '[^']*' '[^']*' (\d+) (\d+)/.exec(g);
                r.e.handleExec(g, "__TS_LIST__ last=" + m[2] + " newest=" + m[2] + "\n", fromMs + i * 1000);
            }
            return fromMs + secs * 1000;
        }

        // A listener parked at 100 s who has pressed Play, with segments
        // first..lastSeg on disk: through the folder and the list to the open.
        function opened(r, first, lastSeg) {
            sliding(r);
            var now = run(r, t0, 100);
            compare(r.e.pauseGesture(now, level(r)), 100000);
            r.mock._tsPaused = true;
            verify(r.e.resumeGesture());
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=" + first + " last=" + lastSeg + "\n", now);
            var upto = SL.parseList("__TS_LIST__ last=" + /write '[^']*' '[^']*' (\d+)/.exec(last(r, "TS_LIST"))[1] + "\n").last;
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=" + upto + " newest=" + lastSeg + "\n", now);
            return now;
        }

        // ── arming ──────────────────────────────────────────────────────

        function test_a_plain_arm_gets_the_writer_that_looks_first() {
            var r = rig();
            verify(r.e.armForStation(stream, "Jazz FM", t0));
            compare(r.mock.execLog.length, 1);
            verify(r.mock.execLog[0].indexOf(": TS_URL;") === 0);
            r.e.handleExec(r.mock.execLog[0], "__TS_URL_OK__", t0 + 100);
            compare(r.mock.execLog.length, 3);
            var w = r.mock.execLog[1];
            verify(w.indexOf(": TS_RUN;") === 0);
            verify(w.indexOf("--codec") !== -1);
            verify(w.indexOf("-f hls -hls_time " + SL.SEG_SEC + " -hls_list_size 1800 ") !== -1);
            verify(w.indexOf("/onair-timeshift-48/buffer-1.hls/seg-%d.ts") !== -1);
            verify(w.indexOf("/onair-timeshift-48/buffer-1.mka") !== -1);
            verify(w.indexOf(stream) === -1);
            verify(r.mock.execLog[2].indexOf(": TS_KIND;") === 0);
            verify(r.e.cut);
            verify(r.e.writerUp);
            // Until the writer says what it cuts there is nothing to park in.
            verify(!r.e.slide);
            compare(r.e.bufPath, "");
            compare(r.e.pauseGesture(t0 + 60000), -1);
        }

        function test_the_window_setting_is_the_writers_list_size() {
            var r = rig({ timeshiftWindowMin: 5 });
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            verify(last(r, "TS_RUN").indexOf("-hls_list_size 150 ") !== -1);
            r = rig({ timeshiftWindowMin: 100000 });
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            verify(last(r, "TS_RUN").indexOf("-hls_list_size 7200 ") !== -1);
        }

        function test_what_cannot_be_mp3_or_aac_keeps_the_writer_it_had() {
            // An ending that names another codec.
            var r = rig();
            verify(r.e.armForStation("http://s1.radio.ee/live.flac", "Lossless", t0));
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            compare(r.mock.execLog.length, 2);
            verify(!r.e.cut);
            var old = TL.buildBufferCommands({
                url: "http://s1.radio.ee/live.flac", cfgPath: r.mock.bufDir + "/url-1.cfg",
                outPath: r.mock.bufDir + "/buffer-1.flac", pidPath: r.mock.bufDir + "/writer-1.pid",
                dirPath: r.mock.bufDir, windowSec: 3600, guardPath: r.e.guardScriptPath,
                needKiB: TL.bufferNeedKiB(60, false), seq: 1 }).run;
            compare(r.mock.execLog[1].replace("export LC_ALL=C LANGUAGE=C; ", ""), old);
            // A kind already learnt for a bare address.
            r = rig();
            r.mock.kinds[stream] = "flac";
            r.e.armForStation(stream, "Lossless", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            verify(!r.e.cut);
            verify(last(r, "TS_RUN").indexOf("--codec") === -1);
            compare(count(r, "TS_KIND"), 0);
            // The relay's writer.
            r = rig();
            verify(r.e.armRelay(stream, "Ogg FM", t0, true));
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            verify(!r.e.cut);
            verify(last(r, "TS_RUN").indexOf("--codec") === -1);
            verify(last(r, "TS_RUN").indexOf("buffer-1.ogg") !== -1);
        }

        function test_a_writer_that_answers_single_file_is_the_old_road() {
            var r = rig();
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ file\n", t0 + 400);
            verify(!r.e.slide);
            compare(r.e.bufPath, r.mock.bufDir + "/buffer-1.mka");
            // Pause and play as the single file always did them.
            compare(r.e.pauseGesture(t0 + 100000), 97000);
            verify(r.e.resumeGesture());
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].url, "file://" + r.mock.bufDir + "/buffer-1.mka");
            compare(r.mock.played[0].pos, 97000);
            verify(!r.e.parkInPlace());
            verify(!r.e.stepGesture(-SL.STEP_MS, t0 + 101000));
            verify(r.e.sourceLoaded(false, 0));
            verify(!r.e.listPlaybackFell(t0 + 101000));
            compare(count(r, "TS_HAVE"), 0);
        }

        function test_a_wait_without_a_decision_asks_again_and_then_gives_up() {
            var r = rig();
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            compare(count(r, "TS_KIND"), 1);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ none\n", t0 + 20000);
            compare(count(r, "TS_KIND"), 2);
            r.e.handleExec(last(r, "TS_KIND"), "garbage\n", t0 + 40000);
            compare(count(r, "TS_KIND"), 3);
            r.e.handleExec(last(r, "TS_KIND"), "", t0 + 60000);
            compare(count(r, "TS_KIND"), 3);
            verify(!r.e.slide);
            run(r, t0 + 60000, 30);
            verify(!r.e.parkable);
            compare(r.e.pauseGesture(t0 + 90000), -1);
            // The writer itself is left running: a late decision has no
            // listener, and the stop takes its files whatever it cut.
            verify(r.e.active);
        }

        function test_a_decision_for_another_arm_changes_nothing() {
            var r = rig();
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            var stale = last(r, "TS_KIND");
            r.e.armForStation("http://other.example/live", "Other", t0 + 5000);
            r.e.handleExec(stale, "__TS_KIND__ slide mp3\n", t0 + 5100);
            verify(!r.e.slide);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0 + 5200);
            r.e.handleExec(stale, "__TS_KIND__ slide mp3\n", t0 + 5300);
            verify(!r.e.slide);
        }

        // ── the clock and the park ──────────────────────────────────────

        function test_the_clock_starts_when_the_writer_has_its_stream() {
            // A writer armed while the station is silent waits for its first
            // bytes, and so does the player. Counted from the command, the
            // clock was ahead of the segments by that wait for as long as
            // the buffer lived.
            var r = rig();
            verify(r.e.armForStation(stream, "Jazz FM", t0));
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            run(r, t0, 8);
            // The widget started the station again meanwhile, as its
            // recovery does: a date on a clock that has not begun.
            r.e.noteLivePlayback(t0 + 5000);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ slide mp3\n", t0 + 8300);
            verify(r.e.slide);
            compare(r.e.runMs, 0);
            compare(r.e.liveBaseMs, 0);
            verify(!r.e.parkable);
            var now = run(r, t0 + 8300, 30);
            compare(r.e.runMs, 30000);
            compare(r.e.pauseGesture(now, 29000), 29000 - SL.PARK_LAG_MS);
            // A note nobody dated stays undated.
            r = rig();
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            r.e.noteLivePlayback();
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ slide mp3\n", t0 + 2000);
            compare(r.e.liveBaseMs, -1);
        }

        function test_a_pause_parks_where_the_writers_clock_stands() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 30);
            compare(r.e.runMs, 30000);
            compare(r.e.pauseGesture(now, level(r)), 30000);
            compare(r.e.shiftPosMs, 30000);
            // Parking asks nothing of the folder and plays nothing.
            compare(count(r, "TS_HAVE"), 0);
            compare(r.mock.played.length, 0);
        }

        function test_a_pause_parks_where_the_player_is_on_the_broadcast() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 45);
            // The player made its first sound 3.2 s after the writer began.
            compare(r.e.pauseGesture(now, 41800), 41800 - SL.PARK_LAG_MS);
            compare(r.e.liveLagMs, 45000 - 40800);
            // Parked this instant, it is not behind; a minute on, a minute.
            compare(r.e.behindText(0, now), "0:00");
            now = run(r, now, 60);
            compare(r.e.behindText(0, now), "1:00");
            // A step forward cannot park ahead of where the broadcast is.
            r.e.stepGesture(SL.STEP_MS * 5, now);
            compare(r.e.shiftPosMs, 105000 - 4200);
            compare(r.e.behindText(0, now), "0:00");
            // A player that says nothing: three seconds before the clock.
            r = rig();
            sliding(r);
            now = run(r, t0, 45);
            compare(r.e.pauseGesture(now), 45000 - SL.PARK_GUESS_MS);
            compare(r.e.pauseGesture(now, 0), 45000 - SL.PARK_GUESS_MS);
            compare(r.e.liveLagMs, SL.PARK_GUESS_MS);
        }

        function test_a_pause_after_a_return_to_live_counts_the_player_from_the_return() {
            // Found on the bench: back on the broadcast the player has joined
            // the station anew and its position starts at nought, while the
            // writer has run on. A pause twelve seconds after the return was
            // parked twelve seconds into the buffer, 118 s before the word
            // it was pressed on.
            var r = rig();
            var now = opened(r, 0, 49);
            now = listen(r, now, 60);
            compare(r.e.runMs, 160000);
            r.e.backToLive(now);
            compare(r.e.liveBaseMs, 160000);
            now = run(r, now, 20);
            compare(r.e.pauseGesture(now, 19500), 160000 + 19500 - SL.PARK_LAG_MS);
            compare(r.e.behindText(0, now), "0:00");
            // The same after a start of the same station that kept its buffer
            // (a stall retry): the player is new, the writer is not.
            r = rig();
            sliding(r);
            now = run(r, t0, 100);
            r.e.noteLivePlayback(now + 400);
            compare(r.e.liveBaseMs, 100400);
            now = run(r, now, 30);
            compare(r.e.pauseGesture(now, 29000), 100400 + 29000 - SL.PARK_LAG_MS);
            // A return nobody dated leaves the position unreadable: the guess.
            r = rig();
            sliding(r);
            now = run(r, t0, 100);
            r.e.noteLivePlayback();
            now = run(r, now, 30);
            compare(r.e.pauseGesture(now, 29000), 130000 - SL.PARK_GUESS_MS);
        }

        function test_a_pause_between_two_beats_reads_the_clock_to_the_millisecond() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 45);
            // 700 ms after the last beat the player is 300 ms past the
            // beat's round number; the park is where the player is.
            compare(r.e.pauseGesture(now + 700, 45300), 45300 - SL.PARK_LAG_MS);
            compare(r.e.liveLagMs, 45700 - 44300);
        }

        function test_the_lag_of_one_station_is_not_carried_to_the_next() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 45);
            r.e.pauseGesture(now, 41800);
            r.e.disarm();
            compare(r.e.liveLagMs, 0);
        }

        function test_the_clock_does_not_follow_a_night_asleep_or_a_clock_set_back() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 30);
            r.e._beat(now + 9 * 3600 * 1000);
            compare(r.e.runMs, 31000);
            r.e._beat(now + 9 * 3600 * 1000 - 3600 * 1000);
            compare(r.e.runMs, 32000);
            r.e._beat(now + 8 * 3600 * 1000 + 1200);
            compare(r.e.runMs, 33200);
        }

        function test_nothing_parks_in_a_buffer_five_seconds_young() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 4);
            verify(!r.e.parkable);
            compare(r.e.pauseGesture(now, level(r)), -1);
            now = run(r, now, 1);
            verify(r.e.parkable);
            compare(r.e.pauseGesture(now, level(r)), 5000);
        }

        function test_the_steps_are_offered_once_the_folder_can_take_an_open() {
            // A step pressed on a buffer a few seconds old finds a folder
            // too small to open anything, and its answer is the broadcast
            // again, with a gap for nothing.
            var r = rig();
            sliding(r);
            verify(!r.e.steppable);
            var now = run(r, t0, SL.STEP_READY_MS / 1000 - 1);
            verify(r.e.parkable);
            verify(!r.e.steppable);
            now = run(r, now, 1);
            verify(r.e.steppable);
            // It stays while a listener is in the buffer, also behind a
            // writer that has ended, and goes with the arm.
            r.e.pauseGesture(now, level(r));
            r.mock._tsPaused = true;
            r.mock.playingNow = false;
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            verify(r.e.slideFrozen);
            verify(r.e.steppable);
            r.e.disarm();
            verify(!r.e.steppable);
            // The single file has no steps.
            r = rig();
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ file\n", t0 + 400);
            run(r, t0, 60);
            verify(!r.e.steppable);
        }

        function test_a_writer_that_is_gone_offers_no_park() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 30);
            r.mock.playingNow = false;
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            verify(!r.e.parkable);
            compare(r.e.pauseGesture(now, level(r)), -1);
        }

        // ── a long pause ────────────────────────────────────────────────

        // A window of five minutes and a pause at 100 s.
        function longPause(r) {
            sliding(r);
            compare(r.e.keepMs, 300000);
            var now = run(r, t0, 100);
            compare(r.e.pauseGesture(now, level(r)), 100000);
            r.mock._tsPaused = true;
            r.mock.playingNow = false;
            return now;
        }

        function test_a_pause_that_reaches_the_windows_edge_ends_the_capture_and_keeps_what_was_cut() {
            var r = rig({ timeshiftWindowMin: 5 });
            var now = longPause(r);
            // Thirty seconds short of the window the buffer still slides.
            now = run(r, now, 269);
            compare(count(r, "TS_END"), 0);
            verify(r.e.writerUp);
            // The next beat is the one: the writer is signalled and nothing
            // is taken away.
            now = run(r, now, 1);
            compare(count(r, "TS_END"), 1);
            verify(last(r, "TS_END").indexOf("writer-1.pid") !== -1 && last(r, "TS_END").indexOf("kill -INT") !== -1);
            verify(!r.e.writerUp);
            verify(r.e.slideFrozen);
            verify(r.e.active && r.e.slide && r.e.steppable);
            compare(count(r, "TS_STOP"), 0);
            // Once, however long the pause goes on.
            now = run(r, now, 600);
            compare(count(r, "TS_END"), 1);
            // The writer's own word that it has ended changes nothing more,
            // and it worked for minutes: the station may slide again.
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            r.e.handleExec(last(r, "TS_END"), "", now);
            verify(r.e.slideFrozen && r.e.active);
            compare(count(r, "TS_STOP"), 0);
            compare(count(r, "TS_URL"), 1);
            // Play comes back to the pause, in what was kept.
            verify(r.e.resumeGesture());
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=37 last=186\n", now);
            verify(last(r, "TS_LIST").indexOf("#EXT-X-MEDIA-SEQUENCE:50\n") !== -1);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=64 newest=186\n", now);
            compare(r.mock.played[0].kind, "buffer");
            compare(r.e.placeMs, 100000);
            compare(r.mock.notes.length, 0);
            // A stop takes the folder as any stop does.
            r.e.disarm();
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            compare(r.e.keepMs, 0);
            compare(r.e.goneMs, 0);
        }

        function test_only_a_park_in_a_running_sliding_buffer_ends_a_capture() {
            // A listener inside the buffer moves with the window.
            var r = rig({ timeshiftWindowMin: 5 });
            var now = opened(r, 0, 49);
            now = listen(r, now, 900);
            compare(count(r, "TS_END"), 0);
            // On the broadcast with nothing parked, however long.
            r = rig({ timeshiftWindowMin: 5 });
            sliding(r);
            run(r, t0, 900);
            compare(count(r, "TS_END"), 0);
            // While Play is on its way to the folder the writer is left be.
            r = rig({ timeshiftWindowMin: 5 });
            now = longPause(r);
            now = run(r, now, 268);
            r.e.resumeGesture();
            now = run(r, now, 2);
            compare(count(r, "TS_END"), 0);
            // The single file has a cap of its own and is not asked about.
            r = rig({ timeshiftWindowMin: 5 });
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ file\n", t0);
            r.e.pauseGesture(t0 + 100000);
            run(r, t0 + 100000, 900);
            compare(count(r, "TS_END"), 0);
        }

        function test_a_pause_made_at_the_edge_of_the_window_ends_the_capture_at_once() {
            // Inside the buffer and nearly five minutes behind: the place is
            // about to be pushed out, and a pause there stops the pushing.
            var r = rig({ timeshiftWindowMin: 5 });
            var now = opened(r, 0, 49);
            now = listen(r, now, 300);
            for (var i = 0; i < 9; i++) r.e.stepGesture(-SL.STEP_MS, now);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=50 last=199\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=71 newest=199\n", now);
            compare(r.e.placeMs, 118000);
            verify(r.e.parkInPlace());
            r.mock._tsPaused = true;
            r.mock.playingNow = false;
            compare(count(r, "TS_END"), 0);
            run(r, now, 1);
            compare(count(r, "TS_END"), 1);
            verify(r.e.slideFrozen);
        }

        function test_the_pill_of_a_capture_that_ended_reads_the_distance_to_live() {
            var r = rig({ timeshiftWindowMin: 5 });
            var now = longPause(r);
            now = run(r, now, 270);
            verify(r.e.slideFrozen);
            // Parked a second behind the writer, 270 s ago.
            compare(r.e.behindText(0, now), "4:30");
            // The broadcast goes on without the writer, and so does the pill.
            now = run(r, now, 600);
            compare(r.e.behindText(0, now), "14:30");
            compare(r.e.runMs, 370000);
            // Inside what was kept the listener keeps that distance.
            r.e.resumeGesture();
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=37 last=186\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=64 newest=186\n", now);
            r.mock.playingNow = true;
            now = listen(r, now, 20);
            compare(r.e.placeMs, 120000);
            compare(r.e.behindText(0, now), "14:30");
        }

        function test_a_step_while_parked_in_a_capture_that_ended_stays_inside_what_was_cut() {
            var r = rig({ timeshiftWindowMin: 5 });
            var now = longPause(r);
            now = run(r, now, 870);
            verify(r.e.slideFrozen);
            verify(r.e.stepGesture(-SL.STEP_MS, now));
            compare(r.e.shiftPosMs, 70000);
            // Forward as far as the writer got, and not as far as the pause
            // has lasted.
            for (var i = 0; i < 40; i++) r.e.stepGesture(SL.STEP_MS, now);
            compare(r.e.shiftPosMs, 370000);
            compare(count(r, "TS_HAVE"), 0);
            compare(r.mock.played.length, 0);
        }

        function test_after_a_capture_that_ended_the_broadcast_has_a_new_buffer_behind_it() {
            // The listener hears out what was kept or taps the pill: the
            // widget's start of the station finds the engine holding it,
            // and the engine arms a new buffer there and then, so the next
            // pause has one without the station being started again.
            var r = rig({ timeshiftWindowMin: 5 });
            r.mock.engine = r.e;
            var now = longPause(r);
            now = run(r, now, 400);
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            r.e.resumeGesture();
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=37 last=186\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=64 newest=186\n", now);
            r.mock.playingNow = true;
            r.e.backToLive(now + 5000);
            compare(r.mock.played[r.mock.played.length - 1].kind, "live");
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            compare(count(r, "TS_URL"), 2);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 5100);
            verify(r.e.cut && r.e.active && r.e.writerUp && !r.e.slideFrozen);
            verify(last(r, "TS_RUN").indexOf("--codec") !== -1);
            compare(r.e.goneMs, 0);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ slide mp3\n", now + 5400);
            now = run(r, now + 5400, 30);
            verify(r.e.parkable && r.e.steppable);
            compare(r.e.pauseGesture(now, 30500), 29500);
        }

        // ── play ────────────────────────────────────────────────────────

        function test_play_asks_the_folder_writes_a_list_and_opens_it_at_the_place() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            compare(r.e.pauseGesture(now, level(r)), 100000);
            r.mock._tsPaused = true;
            now = run(r, now, 60);
            verify(r.e.resumeGesture());
            compare(r.mock.played.length, 0);
            var have = last(r, "TS_HAVE");
            verify(have.indexOf("tsslide.sh' have '" + r.mock.bufDir + "/buffer-1.hls'") !== -1);
            // 160 s of writer: segments 0..79 are finished.
            r.e.handleExec(have, "__TS_HAVE__ first=0 last=79\n", now + 20);
            compare(r.mock.played.length, 0);
            var wr = last(r, "TS_LIST");
            verify(wr.indexOf("#EXT-X-MEDIA-SEQUENCE:50\n") !== -1);
            verify(wr.indexOf("seg-50.ts\n") !== -1);
            // The list reaches thirty seconds past the place, not to the edge.
            verify(wr.indexOf("seg-64.ts\n") !== -1);
            verify(wr.indexOf("seg-65.ts") === -1);
            verify(wr.indexOf("write '" + r.mock.bufDir + "/buffer-1.hls' 'play-1.m3u8' 64 ") !== -1);
            r.e.handleExec(wr, "__TS_LIST__ last=64 newest=79\n", now + 40);
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].kind, "buffer");
            compare(r.mock.played[0].url, "file://" + r.mock.bufDir + "/buffer-1.hls/play-1.m3u8");
            compare(r.mock.played[0].pos, 0);
            verify(r.e.shifted);
            compare(r.e.placeMs, 100000);
            compare(r.e.listLast, 64);
            // The path the player is on is the buffer's path for everyone
            // who asks whether a file is the buffer.
            compare(r.e.bufPath, r.mock.bufDir + "/buffer-1.hls/play-1.m3u8");
            compare(r.mock.notes.length, 0);
        }

        function test_a_place_inside_a_segment_is_sought_inside_it() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            r.e._beat(now + 700);
            compare(r.e.pauseGesture(now + 700, level(r)), 100700);
            r.mock._tsPaused = true;
            now = run(r, now + 700, 60);
            r.e.resumeGesture();
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=79\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=65 newest=79\n", now);
            compare(r.mock.played[0].pos, 700);
            compare(r.e.placeMs, 100700);
        }

        function test_play_right_after_a_pause_lands_short_of_the_edge() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            r.e.pauseGesture(now, level(r));
            r.mock._tsPaused = true;
            r.e.resumeGesture();
            // 100 s of writer: segments 0..49, the edge at 100 s.
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=49\n", now);
            var wr = last(r, "TS_LIST");
            verify(wr.indexOf("#EXT-X-MEDIA-SEQUENCE:44\n") !== -1);
            r.e.handleExec(wr, "__TS_LIST__ last=49 newest=49\n", now);
            compare(r.e.placeMs, 100000 - SL.OPEN_GAP_MS);
            compare(r.mock.played[0].pos, 0);
            compare(r.mock.notes.length, 0);
        }

        function test_a_park_stepped_back_past_what_is_kept_plays_the_oldest_and_says_so_once() {
            // A pause no longer leaves the window by waiting: the capture
            // ends before it would. A park can still be put where nothing
            // is kept, by stepping it back, and Play there is owed a word.
            var r = rig({ timeshiftWindowMin: 5 });
            sliding(r);
            var now = run(r, t0, 1000);
            r.e.pauseGesture(now, level(r));
            r.mock._tsPaused = true;
            r.mock.playingNow = false;
            for (var i = 0; i < 40; i++) r.e.stepGesture(-SL.STEP_MS, now);
            compare(r.e.shiftPosMs, 0);
            r.e.resumeGesture();
            // Five minutes are kept of a thousand seconds: segments 350..499.
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=350 last=499\n", now);
            verify(last(r, "TS_LIST").indexOf("#EXT-X-MEDIA-SEQUENCE:352\n") !== -1);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=367 newest=499\n", now);
            compare(r.e.placeMs, 350 * SL.SEG_MS + SL.KEEP_MS);
            compare(r.mock.notes.length, 1);
            compare(r.mock.notes[0].text, "Jazz FM");
            // A step back from there meets the same edge without a second word.
            r.e.stepGesture(-SL.STEP_MS, now + 1000);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=350 last=499\n", now + 1000);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=367 newest=499\n", now + 1000);
            compare(r.mock.played.length, 2);
            compare(r.mock.notes.length, 1);
        }

        function test_a_folder_that_holds_too_little_goes_to_the_broadcast() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 8);
            verify(r.e.pauseGesture(now, level(r)) > 0);
            r.mock._tsPaused = true;
            r.e.resumeGesture();
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=2\n", now);
            compare(count(r, "TS_LIST"), 0);
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].kind, "live");
            compare(r.mock.played[0].url, stream);
            verify(!r.e.shifted);
            compare(r.e.shiftPosMs, -1);
            // The buffer itself is not at fault and goes on sliding.
            verify(r.e.slide);
            verify(!r.e.slideOff);
            r = rig();
            sliding(r);
            now = run(r, t0, 8);
            r.e.pauseGesture(now, level(r));
            r.e.resumeGesture();
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=-1 last=-1\n", now);
            compare(r.mock.played[0].kind, "live");
        }

        function test_a_folder_that_never_answers_ends_on_the_single_file() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            r.e.pauseGesture(now, level(r));
            r.mock._tsPaused = true;
            r.e.resumeGesture();
            r.e._wishLate();
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].kind, "live");
            verify(r.e.slideOff);
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            // A late answer opens nothing.
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=49\n", now + 4000);
            compare(count(r, "TS_LIST"), 0);
            compare(r.mock.played.length, 1);
            // The next arm of any station is the single file's writer.
            r.e.armForStation(stream, "Jazz FM", now + 5000);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 5000);
            verify(!r.e.cut);
            verify(last(r, "TS_RUN").indexOf("--codec") === -1);
        }

        function test_a_list_that_cannot_be_written_ends_on_the_single_file() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            r.e.pauseGesture(now, level(r));
            r.mock._tsPaused = true;
            r.e.resumeGesture();
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=49\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST_FAIL__\n", now);
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].kind, "live");
            verify(r.e.slideOff);
            verify(!r.e.shifted);
        }

        function test_a_resume_with_nothing_parked_is_refused() {
            var r = rig();
            sliding(r);
            run(r, t0, 100);
            verify(!r.e.resumeGesture());
            compare(count(r, "TS_HAVE"), 0);
        }

        // ── a step ──────────────────────────────────────────────────────

        function test_a_step_back_opens_a_new_list_thirty_seconds_earlier() {
            var r = rig();
            var now = opened(r, 0, 49);
            compare(r.e.placeMs, 88000);
            now = listen(r, now, 10);
            compare(r.e.placeMs, 98000);
            verify(r.e.stepGesture(-SL.STEP_MS, now));
            compare(count(r, "TS_HAVE"), 2);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=54\n", now);
            verify(last(r, "TS_LIST").indexOf("#EXT-X-MEDIA-SEQUENCE:34\n") !== -1);
            verify(last(r, "TS_LIST").indexOf("'play-2.m3u8'") !== -1);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=49 newest=54\n", now);
            compare(r.mock.played.length, 2);
            compare(r.mock.played[1].url, "file://" + r.mock.bufDir + "/buffer-1.hls/play-2.m3u8");
            compare(r.e.placeMs, 68000);
            verify(r.e.shifted);
        }

        function test_a_step_forward_inside_the_buffer_opens_and_near_the_edge_goes_live() {
            var r = rig();
            var now = opened(r, 0, 49);
            now = listen(r, now, 100);
            // The writer has run 200 s and the place is 188 s: back three
            // steps first, to 98 s.
            compare(r.e.placeMs, 188000);
            r.e.stepGesture(-SL.STEP_MS * 3, now);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=63 newest=99\n", now);
            compare(r.e.placeMs, 98000);
            var opens = r.mock.played.length;
            verify(r.e.stepGesture(SL.STEP_MS, now));
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=78 newest=99\n", now);
            compare(r.mock.played.length, opens + 1);
            compare(r.mock.played[opens].kind, "buffer");
            compare(r.e.placeMs, 128000);
            r.e.stepGesture(SL.STEP_MS, now);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=93 newest=99\n", now);
            compare(r.e.placeMs, 158000);
            // The next step would land 12 s short of an edge at 200 s, which
            // is the nearest an open may be, and is taken.
            r.e.stepGesture(SL.STEP_MS, now);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=99 newest=99\n", now);
            compare(r.e.placeMs, 188000);
            compare(r.mock.played[r.mock.played.length - 1].kind, "buffer");
            // One more lands past the edge: the broadcast.
            r.e.stepGesture(SL.STEP_MS, now);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now);
            compare(r.mock.played[r.mock.played.length - 1].kind, "live");
            compare(r.mock.played[r.mock.played.length - 1].url, stream);
            verify(!r.e.shifted);
            compare(r.e.shiftPosMs, -1);
        }

        function test_ten_presses_move_the_wish_and_open_once() {
            var r = rig();
            var now = opened(r, 0, 49);
            now = listen(r, now, 500);
            var haves = count(r, "TS_HAVE"), opens = r.mock.played.length, place = r.e.placeMs;
            for (var i = 0; i < 10; i++) verify(r.e.stepGesture(-SL.STEP_MS, now + i * 100));
            compare(count(r, "TS_HAVE"), haves + 1);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=299\n", now + 1000);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=100 newest=299\n", now + 1000);
            compare(r.mock.played.length, opens + 1);
            compare(r.e.placeMs, place - 10 * SL.STEP_MS);
        }

        function test_four_hundred_presses_stop_at_the_oldest_segment() {
            var r = rig();
            var now = opened(r, 0, 49);
            now = listen(r, now, 500);
            var haves = count(r, "TS_HAVE"), opens = r.mock.played.length;
            for (var i = 0; i < 400; i++) r.e.stepGesture(-SL.STEP_MS, now);
            compare(count(r, "TS_HAVE"), haves + 1);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=299\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=16 newest=299\n", now);
            compare(r.mock.played.length, opens + 1);
            compare(r.e.placeMs, SL.KEEP_MS);
            compare(r.mock.notes.length, 0);
        }

        function test_a_press_while_the_list_is_written_starts_over() {
            var r = rig();
            var now = opened(r, 0, 49);
            now = listen(r, now, 100);
            var opens = r.mock.played.length;
            r.e.stepGesture(-SL.STEP_MS, now);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now);
            var firstList = last(r, "TS_LIST");
            // The second press comes before that list is down.
            r.e.stepGesture(-SL.STEP_MS, now + 30);
            r.e.handleExec(firstList, "__TS_LIST__ last=93 newest=99\n", now + 40);
            compare(r.mock.played.length, opens);
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now + 50);
            verify(last(r, "TS_LIST") !== firstList);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=78 newest=99\n", now + 60);
            compare(r.mock.played.length, opens + 1);
            compare(r.e.placeMs, 188000 - 2 * SL.STEP_MS);
        }

        function test_a_step_while_parked_moves_the_park_in_silence() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            r.e.pauseGesture(now, level(r));
            r.mock._tsPaused = true;
            verify(r.e.stepGesture(-SL.STEP_MS, now));
            compare(r.e.shiftPosMs, 70000);
            verify(r.e.stepGesture(SL.STEP_MS, now));
            verify(r.e.stepGesture(SL.STEP_MS, now));
            // Not past where the writer is.
            compare(r.e.shiftPosMs, 100000);
            for (var i = 0; i < 9; i++) r.e.stepGesture(-SL.STEP_MS, now);
            compare(r.e.shiftPosMs, 0);
            compare(count(r, "TS_HAVE"), 0);
            compare(r.mock.played.length, 0);
            verify(!r.e.shifted);
        }

        function test_a_step_without_a_sliding_buffer_is_not_taken() {
            var r = rig();
            verify(!r.e.stepGesture(-SL.STEP_MS, t0));
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            verify(!r.e.stepGesture(-SL.STEP_MS, t0 + 9000));
            sliding(r);
            run(r, t0, 100);
            // Live, with nothing parked: the caller parks first.
            verify(!r.e.stepGesture(-SL.STEP_MS, t0 + 100000));
            var junk = [null, undefined, NaN, "x", 0];
            r.e.pauseGesture(t0 + 100000);
            for (var i = 0; i < junk.length; i++) verify(!r.e.stepGesture(junk[i], t0 + 100000), String(junk[i]));
            compare(r.e.shiftPosMs, 100000 - SL.PARK_GUESS_MS);
        }

        // ── while the listener is in the buffer ─────────────────────────

        function test_the_list_is_kept_ahead_of_the_listener() {
            var r = rig();
            var now = opened(r, 0, 49);
            compare(r.e.listLast, 49);
            compare(count(r, "TS_GROW"), 0);
            r.e._beat(now + 1000);
            var g = last(r, "TS_GROW");
            verify(g.indexOf("grow '" + r.mock.bufDir + "/buffer-1.hls' 'play-1.m3u8' 50 ") !== -1);
            verify(g.indexOf("seg-50.ts\n") !== -1);
            // One question at a time.
            r.e._beat(now + 2000);
            compare(count(r, "TS_GROW"), 1);
            r.e.handleExec(g, "__TS_LIST__ last=50 newest=50\n", now + 2100);
            compare(r.e.listLast, 50);
            r.e._beat(now + 3000);
            compare(count(r, "TS_GROW"), 2);
            // An answer that never comes is asked for again five beats on.
            run(r, now + 3000, 4);
            compare(count(r, "TS_GROW"), 2);
            r.e._beat(now + 8000);
            compare(count(r, "TS_GROW"), 3);
        }

        function test_the_place_moves_only_while_the_player_sounds() {
            var r = rig();
            var now = opened(r, 0, 79);
            var place = r.e.placeMs;
            r.mock.playingNow = false;
            now = run(r, now, 3);
            compare(r.e.placeMs, place);
            r.mock.playingNow = true;
            now = run(r, now, 3);
            compare(r.e.placeMs, place + 3000);
        }

        function test_a_list_that_stops_growing_is_left_before_it_runs_out() {
            var r = rig();
            var now = opened(r, 0, 49);
            compare(r.e.placeMs, 88000);
            // The list ends at 100 s and nothing more is cut.
            now = run(r, now, 5);
            compare(r.mock.played.length, 1);
            verify(r.e.shifted);
            r.e._beat(now + 1000);
            compare(r.mock.played.length, 2);
            compare(r.mock.played[1].kind, "live");
            compare(r.mock.played[1].url, stream);
            verify(!r.e.shifted);
            // The player was taken off with seven seconds of list ahead of it.
            verify(100000 - 94000 < SL.LEAVE_GAP_MS);
            verify(100000 - 93000 >= SL.LEAVE_GAP_MS);
        }

        function test_behind_live_is_read_off_the_engines_clock() {
            var r = rig();
            var now = opened(r, 0, 49);
            // Place 88 s, the writer's clock at 100 s.
            compare(r.e.behindText(999999, now), "0:12");
            now = run(r, now, 2);
            r.e.handleExec(last(r, "TS_GROW"), "__TS_LIST__ last=50 newest=50\n", now);
            compare(r.e.behindText(0, now), "0:12");
            // Parked, the place stands and the broadcast runs on.
            verify(r.e.parkInPlace());
            now = run(r, now, 60);
            compare(r.e.behindText(0, now), "1:12");
        }

        function test_behind_live_on_the_single_file_is_the_old_sum() {
            var r = rig();
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ file\n", t0 + 400);
            compare(r.e.behindText(40000, t0 + 100000), "1:00");
            compare(r.e.behindText(-1, t0 + 100000), "0:00");
            var none = rig();
            compare(none.e.behindText(40000, t0), "0:00");
        }

        function test_a_pause_inside_the_buffer_parks_the_place() {
            var r = rig();
            var now = opened(r, 0, 49);
            now = run(r, now, 4);
            verify(r.e.parkInPlace());
            verify(!r.e.shifted);
            compare(r.e.shiftPosMs, 92000);
            // Play comes back to it through a new list.
            r.mock._tsPaused = true;
            now = run(r, now, 30);
            verify(r.e.resumeGesture());
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=66\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=60 newest=66\n", now);
            compare(r.mock.played.length, 2);
            compare(r.e.placeMs, 92000);
            verify(r.mock.played[1].url.indexOf("play-2.m3u8") !== -1);
        }

        function test_a_pause_while_a_step_is_on_its_way_parks_where_the_step_was_going() {
            var r = rig();
            var now = opened(r, 0, 49);
            now = listen(r, now, 100);
            compare(r.e.placeMs, 188000);
            // The press has asked the folder and nothing has answered yet.
            verify(r.e.stepGesture(-SL.STEP_MS, now));
            verify(r.e.parkInPlace());
            compare(r.e.shiftPosMs, 188000 - SL.STEP_MS);
            verify(!r.e.shifted);
            // The step's own answers come to a wish that is over.
            var opens = r.mock.played.length;
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=99\n", now + 30);
            compare(r.mock.played.length, opens);
        }

        // ── the player ──────────────────────────────────────────────────

        function test_a_player_that_cannot_search_a_list_is_found_out_once() {
            var r = rig();
            var now = opened(r, 0, 49);
            verify(!r.e.sourceLoaded(false, 0));
            compare(r.mock.played.length, 2);
            compare(r.mock.played[1].kind, "live");
            verify(r.e.slideOff);
            verify(!r.e.shifted);
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            r.e.armForStation("http://other.example/live", "Other", now + 5000);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 5000);
            verify(!r.e.cut);
        }

        function test_a_list_without_a_length_cannot_be_searched_either() {
            var r = rig();
            opened(r, 0, 49);
            verify(!r.e.sourceLoaded(true, 0));
            verify(r.e.slideOff);
        }

        function test_a_player_that_searched_one_list_is_not_asked_again() {
            var r = rig();
            opened(r, 0, 49);
            verify(r.e.sourceLoaded(true, 12000));
            verify(r.e.slideProven);
            verify(!r.e.slideOff);
            // What a later list reports while it loads is its own business.
            verify(r.e.sourceLoaded(false, 0));
            verify(!r.e.slideOff);
            compare(r.mock.played.length, 1);
        }

        function test_a_list_that_does_not_sound_falls_back() {
            var r = rig();
            opened(r, 0, 49);
            r.mock.playingNow = false;
            r.e._openLate();
            compare(r.mock.played.length, 2);
            compare(r.mock.played[1].kind, "live");
            verify(r.e.slideOff);
            // One that sounds is left alone.
            r = rig();
            opened(r, 0, 49);
            r.e._openLate();
            compare(r.mock.played.length, 1);
            verify(!r.e.slideOff);
        }

        function test_a_player_error_on_a_list_falls_back() {
            var r = rig();
            var now = opened(r, 0, 49);
            verify(r.e.listPlaybackFell(now + 500));
            compare(r.mock.played[1].kind, "live");
            verify(r.e.slideOff);
            // Nothing of it is taken while the listener is on the broadcast.
            r = rig();
            sliding(r);
            verify(!r.e.listPlaybackFell(t0 + 9000));
            compare(r.mock.played.length, 0);
        }

        function test_a_fallback_does_not_play_over_a_lapsed_order() {
            var r = rig();
            var now = opened(r, 0, 49);
            r.mock.lapsed = true;
            verify(r.e.listPlaybackFell(now + 500));
            compare(r.mock.played.length, 1);
            verify(!r.e.active);
        }

        function test_a_list_has_no_horizon_to_watch() {
            // On a list the position stops at the length the list had when
            // it was opened while the sound goes on. The single file's
            // watchdog would reopen it every three seconds.
            var r = rig();
            var now = opened(r, 0, 49);
            for (var s = 1; s <= 10; s++) verify(!r.e._horizonTick(true, 12000, now + s * 1000));
            compare(r.mock.played.length, 1);
            verify(r.e.shifted);
        }

        function test_the_end_of_a_list_is_the_end_of_the_buffer() {
            var r = rig();
            var now = opened(r, 0, 49);
            r.mock.playingNow = false;
            verify(r.e.playerEndOfMedia(12000, now + 3000));
            compare(r.mock.played.length, 2);
            compare(r.mock.played[1].kind, "live");
            verify(!r.e.shifted);
            verify(r.e.slide);
        }

        // ── the writer ends ─────────────────────────────────────────────

        function test_a_cutting_writer_that_ends_after_a_minute_is_replaced_by_one_that_slides_again() {
            // What ends a writer that has worked is the station or the line:
            // a stream that stood still for half a minute, a connection that
            // was closed. Its clock ends with it. The next buffer is a new
            // folder with a clock of its own, and it may slide.
            var r = rig();
            sliding(r);
            var now = run(r, t0, 300);
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=28 bytes=0\n", now);
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            compare(count(r, "TS_URL"), 2);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 100);
            verify(r.e.cut && r.e.active && r.e.writerUp);
            verify(!r.e.slide);
            verify(last(r, "TS_RUN").indexOf("--codec") !== -1);
            verify(last(r, "TS_RUN").indexOf("/buffer-1.hls") === -1);
            compare(r.mock.played.length, 0);
            // Its clock is its own: nothing of the three hundred seconds.
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ slide mp3\n", now + 600);
            verify(r.e.slide);
            now = run(r, now + 600, 10);
            compare(r.e.runMs, 10000);
            // The player has played on all the while: its position is no
            // place in the new buffer, and the park is the guess.
            compare(r.e.pauseGesture(now, 310500), 10000 - SL.PARK_GUESS_MS);
        }

        function test_a_cutting_writer_that_ends_in_its_first_minute_gives_the_station_to_the_single_file() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 59);
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            // The folder goes and a new arm writes its address down.
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            compare(count(r, "TS_URL"), 2);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 100);
            verify(!r.e.cut);
            verify(last(r, "TS_RUN").indexOf("--codec") === -1);
            verify(r.e.active);
            compare(r.mock.played.length, 0);
            // And so is every later arm of that station, but not of another.
            r.e.armForStation(stream, "Jazz FM", now + 9000);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 9000);
            verify(!r.e.cut);
            r.e.armForStation("http://other.example/live", "Other", now + 9500);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 9500);
            verify(r.e.cut);
        }

        function test_a_cutting_writer_that_ends_in_silence_is_not_replaced() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 300);
            r.mock.playingNow = false;
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            compare(count(r, "TS_URL"), 1);
            verify(!r.e.active);
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            // The station's next start gets a buffer that slides again.
            r.e.armForStation(stream, "Jazz FM", now + 40000);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 40000);
            verify(r.e.cut);
            // Nor over a park the engine has not been told of yet.
            r = rig();
            sliding(r);
            now = run(r, t0, 300);
            r.mock._tsPaused = true;
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            compare(count(r, "TS_URL"), 1);
            compare(r.mock.played.length, 0);
        }

        function test_a_cutting_writer_that_ends_under_a_park_keeps_what_it_caught() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            r.e.pauseGesture(now, level(r));
            r.mock._tsPaused = true;
            r.mock.playingNow = false;
            now = run(r, now, 60);
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now);
            verify(r.e.slideFrozen);
            verify(r.e.active);
            compare(count(r, "TS_STOP"), 0);
            compare(count(r, "TS_URL"), 1);
            // Nothing more can be parked behind a writer that has ended, and
            // asking does not move the park that stands.
            compare(r.e.pauseGesture(now + 500, 150000), -1);
            compare(r.e.shiftPosMs, 100000);
            // The writer's clock stands with it.
            var ran = r.e.runMs;
            now = run(r, now, 30);
            compare(r.e.runMs, ran);
            // Play still finds the place.
            verify(r.e.resumeGesture());
            r.e.handleExec(last(r, "TS_HAVE"), "__TS_HAVE__ first=0 last=79\n", now);
            r.e.handleExec(last(r, "TS_LIST"), "__TS_LIST__ last=65 newest=79\n", now);
            compare(r.mock.played.length, 1);
            compare(r.mock.played[0].kind, "buffer");
            compare(r.e.placeMs, 100000);
            // At the end of what was caught the broadcast takes over, with
            // a new buffer behind it; the writer had run 160 s, so it slides.
            r.mock.playingNow = true;
            r.e.backToLive(now + 1000);
            compare(r.mock.played[1].kind, "live");
            verify(last(r, "TS_STOP").indexOf("buffer-1.hls") !== -1);
            compare(count(r, "TS_URL"), 2);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 1100);
            verify(r.e.cut);
            verify(last(r, "TS_RUN").indexOf("--codec") !== -1);
        }

        function test_the_broadcast_after_a_frozen_buffer_has_a_buffer_behind_it() {
            // Found on the bench with a writer killed under a listener 30 s
            // behind: the buffer was heard out, the broadcast came back, and
            // it played on with no buffer at all. The widget's start of a
            // station the engine holds asks it to note the live playback,
            // and that note retired the arm the engine had made a moment
            // before, whose address write had not answered yet.
            var r = rig();
            r.mock.engine = r.e;
            var now = opened(r, 0, 49);
            now = run(r, now, 3);
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=137 bytes=0\n", now);
            verify(r.e.slideFrozen);
            r.e.backToLive(now + 1000);
            compare(r.mock.played[r.mock.played.length - 1].kind, "live");
            compare(count(r, "TS_URL"), 2);
            verify(r.e.active);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", now + 1100);
            verify(r.e.active && r.e.writerUp);
            compare(count(r, "TS_RUN"), 2);
            // The writer had run 103 s: the new buffer slides, in a folder
            // of its own, and can be parked in by the player that joined
            // the broadcast with it.
            verify(r.e.cut);
            verify(last(r, "TS_RUN").indexOf("--codec") !== -1 && last(r, "TS_RUN").indexOf("/buffer-1.hls") === -1);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ slide mp3\n", now + 1400);
            now = run(r, now + 1400, 100);
            compare(r.e.pauseGesture(now, 100500), 100500 - SL.PARK_LAG_MS);
        }

        // ── the stop ────────────────────────────────────────────────────

        function test_disarm_takes_the_folder_and_every_file_of_the_arm() {
            var r = rig();
            var now = opened(r, 0, 49);
            r.e.disarm();
            var st = last(r, "TS_STOP");
            var lists = st.indexOf("/buffer-1.hls'/play-*.m3u8"), dir = st.indexOf("rm -rf '" + r.mock.bufDir + "/buffer-1.hls'");
            verify(lists > 0 && dir > lists);
            verify(st.indexOf("writer-1.pid") !== -1);
            verify(st.indexOf("url-1.cfg") !== -1);
            verify(st.indexOf("head-1.bin") !== -1);
            verify(st.indexOf("kind-1.txt") !== -1);
            verify(st.indexOf("buffer-1.mka") !== -1);
            verify(!r.e.active && !r.e.slide && !r.e.cut && !r.e.shifted);
            compare(r.e.bufPath, "");
            compare(r.e.placeMs, -1);
            compare(r.e.runMs, 0);
            // Nothing starts afterwards: a beat, a late answer, a late end.
            var execs = r.mock.execLog.length;
            run(r, now, 5);
            r.e.handleExec(last(r, "TS_RUN"), "__TS_EXIT__ rc=255 bytes=0\n", now + 6000);
            compare(r.mock.execLog.length, execs);
            compare(r.mock.played.length, 1);
        }

        function test_a_stop_ends_a_wish_on_its_way() {
            var r = rig();
            sliding(r);
            var now = run(r, t0, 100);
            r.e.pauseGesture(now, level(r));
            r.e.resumeGesture();
            var have = last(r, "TS_HAVE");
            r.e.disarm();
            r.e.handleExec(have, "__TS_HAVE__ first=0 last=49\n", now + 50);
            compare(count(r, "TS_LIST"), 0);
            compare(r.mock.played.length, 0);
            r.e._wishLate();
            compare(r.mock.played.length, 0);
            verify(!r.e.slideOff);
        }

        function test_an_answer_for_an_older_wish_opens_nothing() {
            var r = rig();
            var now = opened(r, 0, 49);
            now = listen(r, now, 100);
            r.e.stepGesture(-SL.STEP_MS, now);
            var have = last(r, "TS_HAVE");
            r.e.handleExec(have, "__TS_HAVE__ first=0 last=99\n", now);
            var list1 = last(r, "TS_LIST");
            r.e.handleExec(list1, "__TS_LIST__ last=93 newest=99\n", now);
            compare(r.mock.played.length, 2);
            // The same two answers again, late.
            r.e.handleExec(have, "__TS_HAVE__ first=0 last=99\n", now + 100);
            r.e.handleExec(list1, "__TS_LIST__ last=93 newest=99\n", now + 100);
            compare(r.mock.played.length, 2);
            compare(count(r, "TS_LIST"), 2);
        }

        function test_a_single_file_arm_of_the_looking_writer_is_stopped_whole_too() {
            var r = rig();
            r.e.armForStation(stream, "Jazz FM", t0);
            r.e.handleExec(last(r, "TS_URL"), "__TS_URL_OK__", t0);
            r.e.handleExec(last(r, "TS_KIND"), "__TS_KIND__ file\n", t0 + 400);
            r.e.disarm();
            var st = last(r, "TS_STOP");
            verify(st.indexOf("buffer-1.mka") !== -1);
            verify(st.indexOf("head-1.bin") !== -1);
            verify(st.indexOf("kind-1.txt") !== -1);
        }
    }
}
