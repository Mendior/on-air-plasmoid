// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// StandWatch against stand-ins for the widget, the timeshift engine and the
// player: when its timer runs, what a standing position is handed to, and
// what is asked first. The rule itself is tst_standlogic's.
import QtQuick
import QtMultimedia
import QtTest

import "../../package/contents/ui" as Ui

TestCase {
    id: tc
    name: "StandWatch"

    Component { id: watchComp; Ui.StandWatch {} }

    Component {
        id: appComp
        QtObject {
            property bool playing: false
            function isPlaying() { return playing; }
            property bool _tsPaused: false
            property bool _casting: false
            property string _podPlayingKey: ""
            property string _previewUrl: ""
            // main.qml's asks the alarm engine; here an alarm rings up to this moment.
            property double ringsUntil: 0
            function _alarmRings(nowMs) { return nowMs <= ringsUntil; }
            property bool lapsed: false
            property var said: []
            function _orderLapsed() { said.push("asked"); return lapsed; }
            // main.qml's stops the player, and that ends the watch.
            function _streamDied() { said.push("died"); playing = false; }
        }
    }

    Component {
        id: engineComp
        QtObject {
            property bool relay: false
            property string relayUrl: ""
            property bool shifted: false
            property var app: null
            function disarm() { app.said.push("disarmed"); }
        }
    }

    Component {
        id: playerComp
        QtObject {
            property url source
            property real position: 0
            property int mediaStatus: MediaPlayer.BufferingMedia
            signal errorOccurred()
        }
    }

    function rig() {
        var app = appComp.createObject(tc), engine = engineComp.createObject(tc, { app: app }), player = playerComp.createObject(tc);
        return { w: watchComp.createObject(tc, { app: app, engine: engine, player: player }), app: app, engine: engine, player: player };
    }

    // A saved station starts to play; the clock the looks are given starts here.
    function plays(r) {
        r.player.position = 0;
        r.player.source = "http://s1.radio.ee/live.mp3";
        r.app.playing = true;
        return Date.now();
    }

    // The stream plays to stopMs at the clock's pace and stands from there;
    // one look every five seconds up to untilMs. Returns the second the
    // watch handed the stream over at, -1 when it did not.
    function run(r, t0, stopMs, untilMs, fromMs) {
        for (var t = fromMs || 5000; t <= untilMs; t += 5000) {
            r.player.position = Math.min(t, stopMs);
            if (r.w._look(t0 + t)) return t / 1000;
        }
        return -1;
    }

    function test_nothing_ticks_until_a_live_stream_plays() {
        var r = rig();
        verify(!r.w.watching)
        verify(!r.w.ticking)
        plays(r);
        verify(r.w.watching)
        verify(r.w.ticking)
        r.app.playing = false;
        verify(!r.w.ticking)
    }

    function test_what_is_not_the_broadcast_stops_the_timer_data() {
        return [
            { tag: "a parked station", on: function(r) { r.app._tsPaused = true; }, off: function(r) { r.app._tsPaused = false; } },
            { tag: "a listener in the buffer", on: function(r) { r.engine.shifted = true; }, off: function(r) { r.engine.shifted = false; } },
            { tag: "a relayed station", on: function(r) { r.engine.relay = true; }, off: function(r) { r.engine.relay = false; } },
            { tag: "a cast", on: function(r) { r.app._casting = true; }, off: function(r) { r.app._casting = false; } },
            { tag: "a podcast episode", on: function(r) { r.app._podPlayingKey = "feed|guid"; }, off: function(r) { r.app._podPlayingKey = ""; } },
            { tag: "an audition", on: function(r) { r.app._previewUrl = "http://s1.radio.ee/live.mp3"; }, off: function(r) { r.app._previewUrl = ""; } },
            { tag: "a file", on: function(r) { r.player.source = "file:///home/egon/Music/song.mp3"; }, off: function(r) { r.player.source = "http://s1.radio.ee/live.mp3"; } },
            { tag: "the buffer's file", on: function(r) { r.player.source = "file:///home/egon/.cache/x/buffer-7.mka"; }, off: function(r) { r.player.source = "http://s1.radio.ee/live.mp3"; } },
            { tag: "the tap", on: function(r) { r.engine.relayUrl = "http://127.0.0.1:34567/"; r.player.source = "http://127.0.0.1:34567/"; },
              off: function(r) { r.player.source = "http://s1.radio.ee/live.mp3"; } },
            { tag: "no source", on: function(r) { r.player.source = ""; }, off: function(r) { r.player.source = "http://s1.radio.ee/live.mp3"; } }
        ];
    }

    function test_what_is_not_the_broadcast_stops_the_timer(data) {
        var r = rig();
        plays(r);
        verify(r.w.ticking)
        data.on(r);
        verify(!r.w.watching, data.tag)
        verify(!r.w.ticking, data.tag)
        data.off(r);
        verify(r.w.ticking, data.tag + ", over")
    }

    function test_a_watch_without_its_three_does_not_tick_or_fail() {
        var w = watchComp.createObject(tc);
        verify(!w.watching)
        verify(!w.ticking)
        verify(!w._look(Date.now()))
    }

    function test_the_timer_is_one_look_every_five_seconds() {
        var r = rig(), found = null;
        for (var i = 0; i < r.w.resources.length; i++)
            if (r.w.resources[i].hasOwnProperty("interval")) found = r.w.resources[i];
        verify(found !== null)
        compare(found.interval, 5000)
        compare(found.repeat, true)
    }

    function test_a_position_that_stands_hands_the_stream_over_once() {
        var r = rig(), t0 = plays(r);
        // The measured stall: sound to 29976 ms, standing from the look at 30 s.
        compare(run(r, t0, 29976, 45000), -1)
        compare(r.app.said.length, 0)
        compare(run(r, t0, 29976, 600000, 50000), 50)
        // The buffer's writer drinks from the same station. It goes before
        // the stream is handed over, so the start that follows arms a new
        // one: on the bench the old writer ended while that start was still
        // waiting for the station, and the station played on with no buffer.
        compare(r.app.said, ["asked", "disarmed", "died"])
        // The player was stopped: the watch is over and nothing ticks.
        verify(!r.w.ticking)
        verify(!r.w._look(t0 + 55000))
        compare(r.app.said.length, 3)
    }

    function test_a_stream_that_plays_is_left_alone() {
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 3600000, 3600000), -1)
        compare(r.app.said.length, 0)
        verify(r.w.ticking)
    }

    function test_a_position_that_never_moved_is_left_to_the_relays_rescue() {
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 278, 3600000), -1)
        compare(r.app.said.length, 0)
    }

    function test_the_watch_begins_where_the_player_stands_when_it_begins() {
        // A station that has played a while when the watch starts looking
        // (a cast ended): what it played before vouches for nothing.
        var r = rig();
        r.player.source = "http://s1.radio.ee/live.mp3";
        r.player.position = 480000;
        r.app._casting = true;
        r.app.playing = true;
        verify(!r.w.ticking)
        r.app._casting = false;
        var t0 = Date.now();
        r.player.position = 482999;
        for (var t = 5000; t <= 600000; t += 5000) verify(!r.w._look(t0 + t));
        compare(r.app.said.length, 0)
        r.player.position = 483000;
        verify(!r.w._look(t0 + 605000))
        for (t = 610000; t < 625000; t += 5000) verify(!r.w._look(t0 + t));
        verify(r.w._look(t0 + 625000))
    }

    function test_an_order_that_lapsed_is_asked_first_and_nothing_is_handed_over() {
        var r = rig(), t0 = plays(r);
        r.app.lapsed = true;
        compare(run(r, t0, 29976, 50000), -1)
        compare(r.app.said, ["asked"])
    }

    function test_a_status_that_says_starving_is_not_this_watchs() {
        var r = rig(), t0 = plays(r);
        r.player.mediaStatus = MediaPlayer.StalledMedia;
        compare(run(r, t0, 29976, 120000), -1)
        compare(r.app.said.length, 0)
        var other = [MediaPlayer.NoMedia, MediaPlayer.LoadingMedia, MediaPlayer.LoadedMedia, MediaPlayer.EndOfMedia, MediaPlayer.InvalidMedia];
        for (var i = 0; i < other.length; i++) {
            r.player.mediaStatus = other[i];
            verify(!r.w._look(t0 + 125000 + i * 5000), String(other[i]))
        }
        r.player.mediaStatus = MediaPlayer.BufferedMedia;
        verify(r.w._look(t0 + 150000))
        // Buffering is the status a live stream wears while it plays.
        var again = rig(), t1 = plays(again);
        again.player.mediaStatus = MediaPlayer.BufferingMedia;
        compare(run(again, t1, 29976, 600000), 50)
    }

    function test_the_players_error_ends_the_wait_at_five_seconds() {
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 3600000, 30000), -1)
        // The measured close: the error comes, the last sound a second later.
        r.w._erred(t0 + 30100);
        r.player.position = 31000;
        verify(!r.w._look(t0 + 35000))
        verify(r.w._look(t0 + 40000))
        compare(r.app.said, ["asked", "disarmed", "died"])
        // Without the error the same stream is given its twenty seconds.
        var calm = rig(), t1 = plays(calm);
        compare(run(calm, t1, 3600000, 30000), -1)
        compare(run(calm, t1, 31000, 600000, 35000), 55)
    }

    function test_the_players_own_error_signal_is_the_one_heard() {
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 3600000, 30000), -1)
        r.player.errorOccurred();
        // Standing since the look at 30 s: five seconds, with an error.
        verify(r.w._look(t0 + 35000))
        var calm = rig(), t1 = plays(calm);
        compare(run(calm, t1, 3600000, 30000), -1)
        verify(!calm.w._look(t1 + 35000))
    }

    function test_an_error_before_the_watch_began_is_not_this_streams() {
        var r = rig();
        r.player.errorOccurred();
        var t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 50)
    }

    function test_every_verdict_doubles_the_wait_and_ten_minutes_of_sound_forgive() {
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 50)
        // The station is on again, plays half a minute and stands again.
        t0 = plays(r);
        compare(run(r, t0, 29976, 65000), -1)
        compare(run(r, t0, 29976, 600000, 70000), 70)
        t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 110)
        // Ten minutes of sound, and a stream that then dies has twenty seconds again.
        t0 = plays(r);
        compare(run(r, t0, 600000, 600000), -1)
        compare(run(r, t0, 600000, 3600000, 605000), 620)
        compare(r.app.said.length, 12)
    }

    function test_while_an_alarm_rings_every_silence_is_known_as_fast_as_the_first() {
        // The bench alarm of 2026-11-12: every connection sounds to 7968 ms and holds its peace.
        var r = rig();
        r.app.ringsUntil = Date.now() + 1800000;
        var t0 = plays(r);
        // Seen moving for the last time at 10 s, handed over at 30 s.
        compare(run(r, t0, 7968, 600000), 30)
        // The knock brings eight seconds more; the second silence and the third take no longer.
        t0 = plays(r);
        compare(run(r, t0, 7968, 600000), 30)
        t0 = plays(r);
        compare(run(r, t0, 7968, 600000), 30)
        compare(r.app.said.length, 9)
    }

    function test_what_an_alarm_went_through_is_not_held_against_the_listening_after_it() {
        var r = rig();
        r.app.ringsUntil = Date.now() + 1800000;
        var t0 = plays(r);
        compare(run(r, t0, 7968, 600000), 30)
        t0 = plays(r);
        compare(run(r, t0, 7968, 600000), 30)
        compare(r.w._strikes, 0)
        // "I'm up". The next station's first silence has its twenty seconds, the second its forty.
        r.app.ringsUntil = 0;
        t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 50)
        t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 70)
    }

    function test_a_verdict_from_before_the_alarm_neither_slows_it_nor_is_forgotten_by_it() {
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 50)
        r.app.ringsUntil = Date.now() + 1800000;
        t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 50)
        compare(r.w._strikes, 1)
        r.app.ringsUntil = 0;
        t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 70)
    }

    function test_the_watch_asks_whether_the_alarm_rings_at_every_look_with_that_looks_clock() {
        // One verdict stands against the station. The alarm's half hour ends
        // 12 s into the next stream: the looks up to 10 s are the alarm's,
        // the ones after it a radio's, and the silence has its forty seconds
        // from where it was last seen moving.
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 29976, 600000), 50)
        t0 = plays(r);
        r.app.ringsUntil = t0 + 12000;
        compare(run(r, t0, 7968, 600000), 50)
        compare(r.w._strikes, 2)
    }

    function test_a_look_after_a_night_gives_the_stream_its_seconds_again() {
        var r = rig(), t0 = plays(r);
        compare(run(r, t0, 29976, 45000), -1)
        // Eight hours on, the position where it was.
        verify(!r.w._look(t0 + 28845000))
        for (var t = 28850000; t < 28865000; t += 5000) verify(!r.w._look(t0 + t));
        verify(r.w._look(t0 + 28865000))
    }
}
