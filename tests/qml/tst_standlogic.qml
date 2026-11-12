// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// When a standing position means a dead stream. The numbers are the ones
// measured on 2026-11-12: a station that stopped sending left the player
// playing at 29976 ms for as long as it was watched, an Ogg FLAC stream off
// the socket stands at 278 ms from its first second, and an output that
// stopped taking sound held the position the same way with no error.
import QtQuick
import QtTest

import "../../package/contents/ui/StandLogic.js" as SL

TestCase {
    name: "StandLogic"

    function live() {
        return { playing: true, source: "http://s1.radio.ee/live.mp3", relayUrl: "", relay: false, shifted: false,
                 parked: false, casting: false, episode: false, audition: false };
    }

    // Looks every five seconds from fromMs to toMs at the positions pos(t)
    // gives; the first verdict ends the walk.
    // Returns { mem, at, stoodMs, forgivenAt }: at is -1 when none came.
    function walk(mem, fromMs, toMs, pos, full, strikes, waking) {
        var out = { mem: mem, at: -1, stoodMs: 0, forgivenAt: -1 };
        for (var t = fromMs; t <= toMs; t += SL.TICK_MS) {
            var seen = SL.look(out.mem, pos(t), t, full === undefined ? true : full, strikes || 0, waking);
            out.mem = seen.mem;
            if (seen.forgiven && out.forgivenAt < 0) out.forgivenAt = t;
            if (seen.stoodMs > 0) { out.at = t; out.stoodMs = seen.stoodMs; return out; }
        }
        return out;
    }

    // A stream that plays from 0 at the clock's own pace and stops at stopMs.
    function dies(stopMs) { return function(t) { return Math.min(t, stopMs); }; }

    function test_the_numbers_the_watch_is_built_on() {
        compare(SL.TICK_MS, 5000)
        compare(SL.ARM_MS, 3000)
        compare(SL.STAND_MS, 20000)
        compare(SL.ERRED_STAND_MS, 5000)
        compare(SL.STAND_CAP_MS, 300000)
        compare(SL.HEALTHY_MS, 600000)
    }

    function test_a_live_stream_that_plays_is_watched() {
        verify(SL.watched(live()))
        var f = live();
        f.source = "HTTPS://Stream.Example.org/rock";
        verify(SL.watched(f))
        // The tap's address is known and this is not it.
        f = live();
        f.relayUrl = "http://127.0.0.1:34567/";
        verify(SL.watched(f))
    }

    function test_what_is_not_the_broadcast_is_not_watched_data() {
        return [
            { tag: "a player that does not play", key: "playing", value: false },
            { tag: "a relayed station", key: "relay", value: true },
            { tag: "a listener in the buffer", key: "shifted", value: true },
            { tag: "a parked station", key: "parked", value: true },
            { tag: "a cast", key: "casting", value: true },
            { tag: "a podcast episode", key: "episode", value: true },
            { tag: "an audition", key: "audition", value: true },
            { tag: "a file", key: "source", value: "file:///home/egon/Music/song.mp3" },
            { tag: "a buffer's list", key: "source", value: "file:///home/egon/.cache/x/buffer-7.hls/play-1.m3u8" },
            { tag: "nothing", key: "source", value: "" },
            { tag: "a bare scheme", key: "source", value: "http://" },
            { tag: "another scheme", key: "source", value: "rtsp://cam.example/live" }
        ];
    }

    function test_what_is_not_the_broadcast_is_not_watched(data) {
        var f = live();
        f[data.key] = data.value;
        verify(!SL.watched(f), data.tag)
    }

    function test_the_tap_is_not_watched_whatever_the_engine_says() {
        var f = live();
        f.source = "http://127.0.0.1:34567/";
        f.relayUrl = "http://127.0.0.1:34567/";
        verify(!SL.watched(f))
    }

    function test_a_fact_that_is_missing_or_no_fact_is_not_watched() {
        var keys = ["playing", "relay", "shifted", "parked", "casting", "episode", "audition", "source", "relayUrl"];
        var junk = [undefined, null, 1, 0, "true", "false", "", {}, []];
        for (var k = 0; k < keys.length; k++) {
            for (var j = 0; j < junk.length; j++) {
                var f = live();
                f[keys[k]] = junk[j];
                // Any text is an address the tap could have; "" is no tap.
                if (keys[k] === "relayUrl" && typeof junk[j] === "string") continue;
                verify(!SL.watched(f), keys[k] + " = " + String(junk[j]))
            }
            var gone = live();
            delete gone[keys[k]];
            verify(!SL.watched(gone), keys[k] + " left out")
        }
        verify(!SL.watched())
        verify(!SL.watched(null))
        verify(!SL.watched("http://s1.radio.ee/live.mp3"))
        verify(!SL.watched({}))
    }

    function test_a_watch_begins_where_the_player_stands() {
        var m = SL.begin(0, 1000);
        compare(m.low, 0)
        compare(m.pos, 0)
        compare(m.since, 1000)
        compare(m.tickAt, 1000)
        compare(m.bornAt, 1000)
        compare(m.armed, false)
        compare(m.erredAt, 0)
        m = SL.begin(48000, 2000);
        compare(m.low, 48000)
        compare(m.pos, 48000)
        var junk = [undefined, null, NaN, -1, "9000", {}, Infinity];
        for (var i = 0; i < junk.length; i++) {
            compare(SL.begin(junk[i], 1000).low, 0, String(junk[i]))
            compare(SL.begin(junk[i], 1000).pos, 0, String(junk[i]))
        }
    }

    function test_the_wait_doubles_with_every_strike_up_to_five_minutes() {
        compare(SL.limitMs(0, false), 20000)
        compare(SL.limitMs(1, false), 40000)
        compare(SL.limitMs(2, false), 80000)
        compare(SL.limitMs(3, false), 160000)
        compare(SL.limitMs(4, false), 300000)
        compare(SL.limitMs(5, false), 300000)
        compare(SL.limitMs(1000000, false), 300000)
        // An error the player reported is a witness of its own.
        compare(SL.limitMs(0, true), 5000)
        compare(SL.limitMs(1, true), 10000)
        compare(SL.limitMs(3, true), 40000)
        compare(SL.limitMs(6, true), 300000)
        compare(SL.limitMs(1000000, true), 300000)
        // Only a plain true is that witness, and only a count counts.
        var notTrue = [undefined, null, 1, "true", {}];
        for (var i = 0; i < notTrue.length; i++) compare(SL.limitMs(0, notTrue[i]), 20000, String(notTrue[i]))
        var noCount = [undefined, null, NaN, -1, 1.5, "2", {}, Infinity];
        for (i = 0; i < noCount.length; i++) compare(SL.limitMs(noCount[i], false), 20000, String(noCount[i]))
        compare(SL.limitMs(), 20000)
    }

    function test_a_stream_that_plays_is_never_taken_for_dead() {
        var w = walk(SL.begin(0, 0), 5000, 3600000, function(t) { return t; });
        compare(w.at, -1)
        // Ten minutes of sound forgive whatever came before.
        compare(w.forgivenAt, 600000)
        verify(w.mem.armed)
    }

    function test_a_position_that_stands_twenty_seconds_is_a_dead_stream() {
        // The measured stall: sound to 29976 ms, then nothing.
        var w = walk(SL.begin(0, 0), 5000, 600000, dies(29976));
        // Seen moving for the last time at 30 s, standing since: 50 s.
        compare(w.at, 50000)
        compare(w.stoodMs, 20000)
        // One look earlier it is not yet a verdict.
        w = walk(SL.begin(0, 0), 5000, 45000, dies(29976));
        compare(w.at, -1)
    }

    function test_a_position_never_seen_to_move_is_no_witness() {
        // Ogg FLAC off the socket: 278 ms from the first second, for an hour.
        var w = walk(SL.begin(0, 0), 5000, 3600000, function(t) { return 278; });
        compare(w.at, -1)
        verify(!w.mem.armed)
        // Nor one that never left where the watch found it.
        w = walk(SL.begin(48000, 0), 5000, 3600000, function(t) { return 48000; });
        compare(w.at, -1)
    }

    function test_three_seconds_of_movement_arm_the_watch_and_less_does_not() {
        var w = walk(SL.begin(0, 0), 5000, 3600000, function(t) { return 2999; });
        compare(w.at, -1)
        verify(!w.mem.armed)
        w = walk(SL.begin(0, 0), 5000, 3600000, function(t) { return 3000; });
        compare(w.at, 25000)
        // Counted from where the watch began, not from nought.
        w = walk(SL.begin(50000, 0), 5000, 3600000, function(t) { return 52999; });
        compare(w.at, -1)
        w = walk(SL.begin(50000, 0), 5000, 3600000, function(t) { return 53000; });
        compare(w.at, 25000)
        // In two steps as well as in one.
        w = walk(SL.begin(0, 0), 5000, 3600000, function(t) { return t <= 5000 ? 1500 : 3000; });
        compare(w.at, 30000)
    }

    function test_a_player_that_says_it_starves_is_the_stall_timers() {
        // Twenty seconds standing, and the status is neither Buffered nor Buffering.
        var w = walk(SL.begin(0, 0), 5000, 120000, dies(29976), false);
        compare(w.at, -1)
        // The status comes back and the position still stands: the next look ends it.
        var seen = SL.look(w.mem, 29976, 125000, true, 0);
        compare(seen.stoodMs, 95000)
        // Only a plain true is that status.
        var notTrue = [undefined, null, 1, "true"];
        for (var i = 0; i < notTrue.length; i++) compare(SL.look(w.mem, 29976, 125000, notTrue[i], 0).stoodMs, 0, String(notTrue[i]))
    }

    function test_a_position_that_went_back_begins_the_watch_again() {
        // Thirty seconds of sound, then the same address is opened anew.
        var w = walk(SL.begin(0, 0), 5000, 30000, function(t) { return t; });
        verify(w.mem.armed)
        var again = SL.look(w.mem, 400, 35000, true, 0);
        compare(again.stoodMs, 0)
        compare(again.mem.armed, false)
        compare(again.mem.low, 400)
        compare(again.mem.bornAt, 35000)
        // It stands there: the first open's movement does not vouch for this one.
        w = walk(again.mem, 40000, 3600000, function(t) { return 400; });
        compare(w.at, -1)
    }

    function test_an_error_the_player_reported_ends_the_wait_at_five_seconds() {
        // The measured close: the error at 30.0 s, the last sound at 31 s.
        var w = walk(SL.begin(0, 0), 5000, 30000, function(t) { return t; });
        var m = SL.erred(w.mem, 30100);
        compare(m.erredAt, 30100)
        compare(w.mem.erredAt, 0)
        w = walk(m, 35000, 600000, dies(31000));
        // Seen at 31000 for the first time at 35 s, standing five seconds at 40 s.
        compare(w.at, 40000)
        compare(w.stoodMs, 5000)
        // An error on a watch that is not armed changes nothing.
        w = walk(SL.erred(SL.begin(0, 0), 100), 5000, 3600000, function(t) { return 278; });
        compare(w.at, -1)
        compare(SL.erred(null, 5), null)
    }

    function test_an_error_the_stream_outlived_is_forgotten() {
        var w = walk(SL.begin(0, 0), 5000, 30000, function(t) { return t; });
        var m = SL.erred(w.mem, 30100);
        // Ten seconds on it is still remembered, a look later it is not.
        w = walk(m, 35000, 40000, function(t) { return t; });
        compare(w.mem.erredAt, 30100)
        w = walk(w.mem, 45000, 45000, function(t) { return t; });
        compare(w.mem.erredAt, 0)
        // And the stream dying later gets the whole twenty seconds.
        w = walk(w.mem, 50000, 600000, dies(52000));
        compare(w.at, 75000)
        compare(w.stoodMs, 20000)
    }

    function test_a_look_that_comes_late_starts_the_standing_anew() {
        var w = walk(SL.begin(0, 0), 5000, 45000, dies(29976));
        compare(w.at, -1)
        // The machine slept eight hours on a position that already stood 15 s.
        var late = SL.look(SL.erred(w.mem, 44000), 29976, 28845000, true, 0);
        compare(late.stoodMs, 0)
        compare(late.mem.since, 28845000)
        compare(late.mem.erredAt, 0)
        w = walk(late.mem, 28850000, 28900000, function(t) { return 29976; });
        compare(w.at, 28865000)
        compare(w.stoodMs, 20000)
        // Two ticks apart is on time, a millisecond more is late.
        var m = SL.begin(0, 0);
        m = SL.look(m, 5000, 5000, true, 0).mem;
        m = SL.look(m, 5000, 15000, true, 0).mem;
        compare(m.since, 5000)
        m = SL.look(m, 5000, 25001, true, 0).mem;
        compare(m.since, 25001)
        // A clock that went back is no clock to count on either.
        m = SL.look(m, 5000, 20000, true, 0).mem;
        compare(m.since, 20000)
    }

    function test_a_look_that_comes_a_moment_early_still_counts() {
        // The timer's five seconds are sometimes 4999 ms.
        var m = SL.begin(0, 0);
        m = SL.look(m, 29976, 30000, true, 0).mem;
        m = SL.look(m, 29976, 34999, true, 0).mem;
        m = SL.look(m, 29976, 39998, true, 0).mem;
        m = SL.look(m, 29976, 44997, true, 0).mem;
        var seen = SL.look(m, 29976, 49996, true, 0);
        compare(seen.stoodMs, 19996)
        // Half a second is all the grace there is.
        compare(SL.look(m, 29976, 49500, true, 0).stoodMs, 19500)
        compare(SL.look(m, 29976, 49499, true, 0).stoodMs, 0)
        compare(SL.EARLY_MS, 500)
        // With an error: 4.5 s.
        var e = SL.erred(SL.look(SL.begin(0, 0), 29976, 30000, true, 0).mem, 30100);
        compare(SL.look(e, 29976, 34499, true, 0).stoodMs, 0)
        compare(SL.look(e, 29976, 34500, true, 0).stoodMs, 4500)
    }

    function test_every_strike_doubles_the_wait() {
        var w = walk(SL.begin(0, 0), 5000, 600000, dies(29976), true, 1);
        compare(w.at, 70000)
        compare(w.stoodMs, 40000)
        w = walk(SL.begin(0, 0), 5000, 600000, dies(29976), true, 2);
        compare(w.at, 110000)
        w = walk(SL.begin(0, 0), 5000, 3600000, dies(29976), true, 9);
        compare(w.at, 330000)
    }

    function test_while_an_alarm_rings_no_verdict_lengthens_the_wait() {
        compare(SL.limitMs(0, false, true), 20000)
        compare(SL.limitMs(1, false, true), 20000)
        compare(SL.limitMs(3, false, true), 20000)
        compare(SL.limitMs(1000000, false, true), 20000)
        compare(SL.limitMs(undefined, undefined, true), 20000)
        // The player's own error is the witness it always is.
        compare(SL.limitMs(0, true, true), 5000)
        compare(SL.limitMs(4, true, true), 5000)
        // Only a plain true is an alarm that rings.
        var notTrue = [undefined, null, false, 1, "true", {}];
        for (var i = 0; i < notTrue.length; i++) {
            compare(SL.limitMs(0, false, notTrue[i]), 20000, String(notTrue[i]))
            compare(SL.limitMs(2, false, notTrue[i]), 80000, String(notTrue[i]))
            compare(SL.limitMs(1, true, notTrue[i]), 10000, String(notTrue[i]))
        }
    }

    function test_the_third_silence_of_an_alarm_is_known_as_fast_as_the_first() {
        // The bench alarm of 2026-11-12: sound to 7968 ms, then a connection held open with nothing in it.
        var w = walk(SL.begin(0, 0), 5000, 600000, dies(7968), true, 0, true);
        // Seen moving for the last time at 10 s, standing since: 30 s.
        compare(w.at, 30000)
        compare(w.stoodMs, 20000)
        w = walk(SL.begin(0, 0), 5000, 600000, dies(7968), true, 3, true);
        compare(w.at, 30000)
        // With nobody to wake, three verdicts make it 160 s.
        w = walk(SL.begin(0, 0), 5000, 600000, dies(7968), true, 3, false);
        compare(w.at, 170000)
        w = walk(SL.begin(0, 0), 5000, 600000, dies(7968), true, 3);
        compare(w.at, 170000)
    }

    function test_an_alarm_does_not_make_a_witness_of_what_is_none() {
        // A position never seen to move, a player that says it starves and a stream that plays stay what they were.
        var w = walk(SL.begin(278, 0), 5000, 600000, function(t) { return 278; }, true, 0, true);
        compare(w.at, -1)
        w = walk(SL.begin(0, 0), 5000, 600000, dies(7968), false, 0, true);
        compare(w.at, -1)
        w = walk(SL.begin(0, 0), 5000, 600000, function(t) { return t; }, true, 0, true);
        compare(w.at, -1)
    }

    function test_forgiveness_takes_ten_minutes_of_a_watch_that_was_armed() {
        var w = walk(SL.begin(0, 0), 5000, 595000, function(t) { return t; });
        compare(w.forgivenAt, -1)
        w = walk(w.mem, 600000, 600000, function(t) { return t; });
        compare(w.forgivenAt, 600000)
        // Ten minutes of standing are not ten minutes of sound.
        w = walk(SL.begin(0, 0), 5000, 3600000, function(t) { return 278; });
        compare(w.forgivenAt, -1)
        // Nor is an hour of a position that creeps and never gets three seconds on.
        w = walk(SL.begin(0, 0), 5000, 3600000, function(t) { return 278 + t / 10000; });
        compare(w.at, -1)
        verify(!w.mem.armed)
        compare(w.forgivenAt, -1)
    }

    function test_a_look_changes_nothing_it_was_handed() {
        var m = SL.begin(0, 0);
        var kept = JSON.stringify(m);
        var seen = SL.look(m, 5000, 5000, true, 0);
        compare(JSON.stringify(m), kept)
        verify(seen.mem !== m)
        compare(seen.mem.pos, 5000)
        var e = SL.erred(seen.mem, 6000);
        verify(e !== seen.mem)
        compare(seen.mem.erredAt, 0)
    }

    function test_a_look_with_nothing_to_go_on_begins_a_watch() {
        var seen = SL.look(null, 7000, 1000, true, 0);
        compare(seen.stoodMs, 0)
        compare(seen.forgiven, false)
        compare(seen.mem.low, 7000)
        compare(seen.mem.since, 1000)
        seen = SL.look(undefined, 7000, 1000, true, 0);
        compare(seen.mem.low, 7000)
        var armed = walk(SL.begin(0, 0), 5000, 45000, dies(29976)).mem;
        var junk = [undefined, null, NaN, -1, "29976", {}, Infinity];
        for (var i = 0; i < junk.length; i++) {
            seen = SL.look(armed, junk[i], 50000, true, 0);
            compare(seen.stoodMs, 0, "position " + String(junk[i]))
            compare(seen.mem.armed, false, "position " + String(junk[i]))
            seen = SL.look(armed, 29976, junk[i], true, 0);
            compare(seen.stoodMs, 0, "clock " + String(junk[i]))
            // A clock that is no number dates nothing, and what was remembered stays
            // as it was. -1 is a number: a clock that went back, which is a late look.
            if (junk[i] !== -1) compare(JSON.stringify(seen.mem), JSON.stringify(armed), "clock " + String(junk[i]))
        }
        seen = SL.look();
        compare(seen.stoodMs, 0)
        compare(seen.forgiven, false)
        compare(seen.mem, undefined)
    }
}
