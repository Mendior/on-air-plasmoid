// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// How much quieter a saved station plays, whom the cut is for, when a
// station is listened to, and how the readings are kept. The numbers the
// rules rest on are in LoudLogic.js; what is asked here is what a listener
// would notice: a station at -8 LUFS comes down ten decibels, an audition
// and an alarm do not come down at all, and no station is connected to a
// second time for nothing.
import QtQuick
import QtTest

import "../../package/contents/ui/LoudLogic.js" as LL

TestCase {
    name: "LoudLogic"

    readonly property string pop: "https://stream.example.org/pop"
    readonly property string jazz: "https://cdn.example.net/jazz?token=abc123&sid=7"
    readonly property double now: 1794400000
    readonly property int day: 86400

    function rows(hosts) {
        return JSON.stringify(hosts.map(function(h) { return { "name": "N", "hostname": h, "favicon": "", "active": true }; }));
    }
    function close(a, b) { return Math.abs(a - b) < 0.0005; }

    // ── how far down ────────────────────────────────────────────────────

    function test_a_station_louder_than_the_target_comes_down_by_the_difference() {
        compare(LL.TARGET_LUFS, -18)
        compare(LL.cutDb(-8), -10)
        verify(close(LL.cutDb(-12.3), -5.7))
        verify(close(LL.cutDb(-17.9), -0.1))
        // The survey's loudest and its median.
        verify(close(LL.cutDb(-7.8), -10.2))
        verify(close(LL.cutDb(-12.25), -5.75))
    }

    function test_a_station_at_or_under_the_target_is_never_turned_up() {
        compare(LL.cutDb(-18), 0)
        compare(LL.cutDb(-18.1), 0)
        compare(LL.cutDb(-21.1), 0)
        compare(LL.cutDb(-40), 0)
        compare(LL.cutDb(-70), 0)
    }

    function test_no_reading_turns_a_station_down_more_than_fifteen() {
        compare(LL.MAX_CUT_DB, 15)
        verify(close(LL.cutDb(-3.1), -14.9))
        compare(LL.cutDb(-3), -15)
        compare(LL.cutDb(-2.9), -15)
        compare(LL.cutDb(0), -15)
        compare(LL.cutDb(6), -15)
        compare(LL.cutDb(1e9), -15)
    }

    function test_what_is_no_reading_cuts_nothing() {
        var junk = [null, undefined, "", "-8", NaN, Infinity, -Infinity, {}, [], [-8], true];
        for (var i = 0; i < junk.length; i++) compare(LL.cutDb(junk[i]), 0, String(junk[i]))
    }

    // ── the factor ──────────────────────────────────────────────────────

    // The cut for a saved station at -8 LUFS that plays here alone, with the option on; `over` changes the facts.
    function cut(over) {
        var f = { on: true, subject: pop, alarmPct: -1, casting: false, local: false, lufs: -8 };
        for (var k in over) f[k] = over[k];
        return LL.cut(f);
    }

    function test_the_cut_is_the_stations_own_with_the_option_on() {
        compare(cut({}), -10)
        compare(cut({ lufs: -12 }), -6)
        compare(cut({ lufs: -3 }), -15)
        compare(cut({ lufs: 5 }), -15)
        compare(cut({ lufs: -18 }), 0)
        compare(cut({ lufs: -40 }), 0)
    }

    function test_the_factor_is_the_cut_as_an_amplitude() {
        compare(LL.factor(0), 1)
        verify(close(LL.factor(-10), Math.pow(10, -10 / 20)))
        verify(close(LL.factor(-10), 0.3162))
        verify(close(LL.factor(-6), 0.5012))
        // Six decibels is half, as near as the number goes.
        verify(close(LL.factor(-6.02), 0.4999))
        verify(close(LL.factor(-15), 0.1778))
        verify(close(LL.factor(-7.5), 0.4217))
    }

    function test_the_factor_never_leaves_its_range() {
        // Nothing turns a station up and nothing turns it down by more than the ceiling, whatever is handed in.
        var out = [-15.0001, -16, -100, -1e9, -Infinity];
        for (var i = 0; i < out.length; i++) verify(close(LL.factor(out[i]), 0.1778), String(out[i]))
        var none = [0.0001, 1, 15, 1e9, Infinity, NaN, null, undefined, "", "-10", {}, [], [-10], true];
        for (i = 0; i < none.length; i++) compare(LL.factor(none[i]), 1, String(none[i]))
        var readings = [-1e9, -70, -50, -18.0001, -18, -17.9999, -10, -3, 0, 6, 100, 1e9];
        for (i = 0; i < readings.length; i++) {
            var g = LL.factor(cut({ lufs: readings[i] }));
            verify(g <= 1 && g >= Math.pow(10, -15 / 20) - 1e-9, readings[i] + " -> " + g)
        }
    }

    function test_nothing_is_cut_with_the_option_off() {
        compare(cut({ on: false }), 0)
        var notYes = [undefined, null, 0, 1, "true", "", {}, []];
        for (var i = 0; i < notYes.length; i++) compare(cut({ on: notYes[i] }), 0, String(notYes[i]))
    }

    function test_nothing_is_cut_of_what_is_no_saved_stations_stream() {
        compare(cut({ subject: "" }), 0)
        var none = [null, undefined, 0, 7, true, {}, [], [pop]];
        for (var i = 0; i < none.length; i++) compare(cut({ subject: none[i] }), 0, String(none[i]))
    }

    function test_nothing_is_cut_while_an_alarms_level_stands() {
        // An alarm at 40 %, at its lowest 15 %, and at 0, which is still a level.
        compare(cut({ alarmPct: 40 }), 0)
        compare(cut({ alarmPct: 15 }), 0)
        compare(cut({ alarmPct: 0 }), 0)
        compare(cut({ alarmPct: 100 }), 0)
        compare(cut({ alarmPct: -1 }), -10)
        compare(cut({ alarmPct: -0.5 }), -10)
        // A level nobody can read is taken for one that stands: louder is the safe side of a morning.
        var unread = [undefined, null, NaN, "", "-1", {}, []];
        for (var i = 0; i < unread.length; i++) compare(cut({ alarmPct: unread[i] }), 0, String(unread[i]))
    }

    function test_nothing_is_cut_while_a_device_plays_along() {
        // The device takes the stream itself and nobody turns it down. With
        // this computer cut beside it, the balance between the two would
        // move with every station.
        compare(cut({ casting: true, local: true }), 0)
        // A device alone: nothing sounds here, and nothing is in the way of the rule.
        compare(cut({ casting: true, local: false }), -10)
        // No device: whether this computer would play along is no matter.
        compare(cut({ casting: false, local: true }), -10)
        compare(cut({ casting: false, local: false }), -10)
        // Facts nobody can read are taken for a device that plays along, which is how it sounded before the option.
        var unread = [undefined, null, 0, 1, "false", "", {}, []];
        for (var i = 0; i < unread.length; i++) {
            compare(cut({ casting: unread[i], local: true }), 0, "casting " + unread[i])
            compare(cut({ casting: true, local: unread[i] }), 0, "local " + unread[i])
            compare(cut({ casting: unread[i], local: unread[i] }), 0, "both " + unread[i])
        }
    }

    function test_nothing_is_cut_where_nothing_is_known() {
        var none = [null, undefined, NaN, "", "-8", Infinity, {}, [], [-8]];
        for (var i = 0; i < none.length; i++) compare(cut({ lufs: none[i] }), 0, String(none[i]))
        compare(LL.cut(null), 0)
        compare(LL.cut(undefined), 0)
        compare(LL.cut({}), 0)
        compare(LL.cut("x"), 0)
        compare(LL.cut(7), 0)
    }

    // ── whom it is for ──────────────────────────────────────────────────

    function facts(over) {
        var f = { station: pop, source: pop, preview: "", episode: false, buffer: "", saved: rows([pop, jazz]) };
        for (var k in over) f[k] = over[k];
        return f;
    }

    function test_a_saved_station_on_the_player_is_the_subject() {
        compare(LL.subject(facts({})), pop)
        compare(LL.subject(facts({ station: jazz, source: jazz })), jazz)
        // The list as rows is the list too.
        compare(LL.subject(facts({ saved: JSON.parse(rows([pop])) })), pop)
    }

    function test_the_subject_is_the_row_and_not_the_address_that_plays() {
        // A playlist unwrapped, a better bitrate picked, the relay's tap: the
        // row's address is what the reading is kept for.
        compare(LL.subject(facts({ source: "https://edge7.example.org/pop-320" })), pop)
        compare(LL.subject(facts({ source: "http://127.0.0.1:34567/" })), pop)
        compare(LL.subject(facts({ source: "HTTP://EDGE.example.org/x" })), pop)
    }

    function test_a_listener_inside_the_pause_buffer_is_still_on_the_station() {
        compare(LL.subject(facts({ source: "file:///run/user/1000/onair-timeshift-7/buf-41", buffer: "/run/user/1000/onair-timeshift-7/buf-41" })), pop)
        // Another file is not the buffer, nor is the buffer of no path.
        compare(LL.subject(facts({ source: "file:///home/me/Music/a.mp3", buffer: "/run/user/1000/onair-timeshift-7/buf-41" })), "")
        compare(LL.subject(facts({ source: "file://", buffer: "" })), "")
    }

    function test_an_audition_an_episode_and_a_file_are_nobodys_subject() {
        compare(LL.subject(facts({ preview: pop })), "")
        compare(LL.subject(facts({ preview: "https://other.example/x" })), "")
        compare(LL.subject(facts({ episode: true })), "")
        compare(LL.subject(facts({ source: "file:///home/me/Music/a.flac" })), "")
        compare(LL.subject(facts({ source: "file:///usr/share/on-air/sounds/alarm-fallback.ogg" })), "")
        compare(LL.subject(facts({ source: "" })), "")
    }

    function test_an_address_the_list_does_not_hold_is_nobodys_subject() {
        compare(LL.subject(facts({ station: "https://gone.example/x" })), "")
        compare(LL.subject(facts({ station: "" })), "")
        compare(LL.subject(facts({ saved: "[]" })), "")
        compare(LL.subject(facts({ saved: "" })), "")
        compare(LL.subject(facts({ saved: "not json" })), "")
        compare(LL.subject(facts({ saved: null })), "")
        // A row has to hold exactly the address.
        compare(LL.subject(facts({ station: pop + "/" })), "")
        compare(LL.subject(facts({ station: pop.toUpperCase() })), "")
        // A file in the list is no station to listen to.
        compare(LL.subject(facts({ station: "file:///x.mp3", saved: rows(["file:///x.mp3"]) })), "")
    }

    function test_facts_nobody_can_read_name_no_subject() {
        compare(LL.subject(null), "")
        compare(LL.subject(undefined), "")
        compare(LL.subject({}), "")
        compare(LL.subject(7), "")
        compare(LL.subject("x"), "")
        var bad = [null, undefined, 7, true, {}, []];
        for (var i = 0; i < bad.length; i++) {
            compare(LL.subject(facts({ station: bad[i] })), "", "station " + bad[i])
            compare(LL.subject(facts({ source: bad[i] })), "", "source " + bad[i])
            compare(LL.subject(facts({ preview: bad[i] })), "", "preview " + bad[i])
            compare(LL.subject(facts({ saved: bad[i] })), "", "saved " + bad[i])
        }
        var notNo = [null, undefined, 0, "", "false", {}];
        for (i = 0; i < notNo.length; i++) compare(LL.subject(facts({ episode: notNo[i] })), "", "episode " + notNo[i])
        // The buffer may be missing: then no file is the buffer.
        compare(LL.subject(facts({ buffer: undefined })), pop)
        compare(LL.subject(facts({ buffer: null, source: "file:///x" })), "")
    }

    function test_a_list_of_five_hundred_names_its_subject() {
        var hosts = [];
        for (var i = 0; i < 500; i++) hosts.push("https://s" + i + ".example.org/live");
        var saved = rows(hosts);
        compare(LL.subject(facts({ station: hosts[499], source: hosts[499], saved: saved })), hosts[499])
        compare(LL.subject(facts({ station: "https://s500.example.org/live", saved: saved })), "")
        var longOne = "https://x.example/" + new Array(3000).join("a");
        compare(LL.subject(facts({ station: longOne, source: longOne, saved: rows([longOne]) })), "")
    }

    function test_an_address_is_saved_when_a_row_holds_exactly_it() {
        verify(LL.isSaved(rows([pop, jazz]), jazz))
        verify(LL.isSaved(JSON.parse(rows([pop])), pop))
        verify(!LL.isSaved(rows([pop]), jazz))
        verify(!LL.isSaved(rows([pop]), ""))
        verify(!LL.isSaved(rows([pop]), pop + "?x"))
        verify(!LL.isSaved("", pop))
        verify(!LL.isSaved("{", pop))
        verify(!LL.isSaved(null, pop))
        verify(!LL.isSaved(rows([pop]), null))
        verify(!LL.isSaved(JSON.stringify([null, 7, "x", { "hostname": 7 }]), pop))
        verify(LL.isSaved(JSON.stringify([null, 7, { "hostname": pop }]), pop))
    }

    // ── when a station is listened to ───────────────────────────────────

    function may(over) {
        var f = { on: true, subject: pop, playing: true, wanted: true, paused: false, healing: false, alarmPct: -1, recording: false, at: pop };
        for (var k in over) f[k] = over[k];
        return LL.asks(f);
    }

    function test_a_saved_station_that_plays_may_be_listened_to() {
        verify(may({}))
        // On the address that plays, which need not be the row's own.
        verify(may({ at: "https://edge7.example.org/pop-320?sid=1" }))
        verify(may({ at: "http://x.example/a" }))
    }

    function test_nobody_is_listened_to_with_the_option_off_or_nothing_playing() {
        verify(!may({ on: false }))
        verify(!may({ playing: false }))
        verify(!may({ subject: "" }))
        verify(!may({ paused: true }))
        // Stop takes the order down and the sound fades for a moment more:
        // a station that was just stopped is not connected to again.
        verify(!may({ wanted: false }))
    }

    function test_a_stream_from_another_address_an_alarm_and_a_recording_wait() {
        verify(!may({ healing: true }))
        verify(!may({ alarmPct: 40 }))
        verify(!may({ alarmPct: 0 }))
        verify(!may({ recording: true }))
    }

    function test_only_a_web_address_is_listened_to() {
        var no = ["", "file:///run/user/1000/onair-timeshift-7/buf", "ftp://x.example/a", "x.example/a", "http://", "https://",
                  " http://x.example/a", "data:audio/mpeg;base64,AAAA"];
        for (var i = 0; i < no.length; i++) verify(!may({ at: no[i] }), no[i])
        verify(may({ at: "https://x.example/" + new Array(2000).join("a") }))
        verify(!may({ at: "https://x.example/" + new Array(2100).join("a") }))
    }

    function test_facts_nobody_can_read_let_nobody_be_listened_to() {
        verify(!LL.asks(null))
        verify(!LL.asks(undefined))
        verify(!LL.asks({}))
        verify(!LL.asks("x"))
        var bad = [null, undefined, 0, 1, "true", "", {}, []];
        for (var i = 0; i < bad.length; i++) {
            verify(!may({ on: bad[i] }), "on " + bad[i])
            verify(!may({ playing: bad[i] }), "playing " + bad[i])
            verify(!may({ wanted: bad[i] }), "wanted " + bad[i])
            verify(!may({ paused: bad[i] }), "paused " + bad[i])
            verify(!may({ healing: bad[i] }), "healing " + bad[i])
            verify(!may({ recording: bad[i] }), "recording " + bad[i])
        }
        var unread = [null, undefined, NaN, "", "-1", {}, []];
        for (i = 0; i < unread.length; i++) verify(!may({ alarmPct: unread[i] }), "alarm " + unread[i])
        var none = [null, undefined, 7, true, {}, []];
        for (i = 0; i < none.length; i++) {
            verify(!may({ subject: none[i] }), "subject " + none[i])
            verify(!may({ at: none[i] }), "at " + none[i])
        }
    }

    // ── the helper's answer ─────────────────────────────────────────────

    function test_the_answer_is_one_number() {
        compare(LL.answerOf("-9.6\n"), -9.6)
        compare(LL.answerOf("-21.1"), -21.1)
        compare(LL.answerOf("  -12.2 \n"), -12.2)
        compare(LL.answerOf("-18\n"), -18)
        compare(LL.answerOf("0.4\n"), 0.4)
        compare(LL.answerOf("3\n"), 3)
    }

    function test_silence_and_what_no_decoder_puts_out_are_no_answer() {
        compare(LL.SILENT_LUFS, -50)
        compare(LL.answerOf("-70.0\n"), null)
        compare(LL.answerOf("-50.0\n"), null)
        compare(LL.answerOf("-49.9\n"), -49.9)
        compare(LL.answerOf("6.0\n"), 6)
        compare(LL.answerOf("6.1\n"), null)
        compare(LL.answerOf("99\n"), null)
        compare(LL.answerOf("-120.5\n"), null)
    }

    function test_what_is_not_one_number_is_no_answer() {
        var no = ["", " ", "\n", "nan", "-inf", "inf", "-", ".", "-.5", "9.", "-9,6", "-9.6 LUFS", "I: -9.6", "-9.6\n-9.7\n", "-9.6 -9.7",
                  "1e1", "0x10", "--9", "+9", "-9.6.1", "ogg-flac", "-9.123456789012",
                  "-12.25", "-49.96"];
        for (var i = 0; i < no.length; i++) compare(LL.answerOf(no[i]), null, JSON.stringify(no[i]))
        var junk = [null, undefined, -9.6, 0, true, {}, [], ["-9.6"]];
        for (i = 0; i < junk.length; i++) compare(LL.answerOf(junk[i]), null, String(junk[i]))
        compare(LL.answerOf(new Array(100000).join("-9.6\n")), null)
        compare(LL.answerOf("-9.6" + new Array(5000).join(" ")), -9.6)
    }

    // ── the readings ────────────────────────────────────────────────────

    // A map holding these readings of one address, a day apart, the last of them taken at `at`.
    function read(url, readings, at) {
        var m = "{}";
        for (var i = 0; i < readings.length; i++) m = LL.withAnswer(m, url, readings[i], at - (readings.length - 1 - i) * day);
        return m;
    }

    function test_a_reading_is_kept_for_its_address() {
        var m = LL.withAnswer("{}", pop, -9.6, now);
        compare(LL.lufsAt(m, rows([pop]), pop), -9.6)
        compare(LL.lufsAt(m, rows([pop, jazz]), jazz), null)
        m = LL.withAnswer(m, jazz, -21.14, now + 5);
        compare(LL.lufsAt(m, rows([pop, jazz]), jazz), -21.1)
        compare(LL.lufsAt(m, rows([pop, jazz]), pop), -9.6)
        // An entry is the second its newest reading was taken, the second of
        // a later attempt that gave nothing, and the readings, oldest first.
        compare(JSON.parse(m)[pop], [now, 0, -9.6])
        compare(JSON.parse(m)[jazz], [now + 5, 0, -21.1])
        compare(LL.readingsAt(m, pop), [-9.6])
        compare(LL.readingsAt(m, "https://nobody.example/x"), [])
        compare(Object.keys(JSON.parse(m)).length, 2)
    }

    function test_the_number_is_the_median_of_the_readings() {
        compare(LL.median([-9]), -9)
        compare(LL.median([-8, -14, -9]), -9)
        compare(LL.median([-14, -8, -9]), -9)
        compare(LL.median([-8, -8, -14, -20, -9]), -9)
        compare(LL.median([-9, -9, -9]), -9)
        // An even count has two in the middle, and the quieter one serves. A
        // reading that is too loud turns the station down too far, and
        // nothing on the screen says why; one that is too quiet leaves it
        // where it would have played without the option.
        compare(LL.median([-8, -14]), -14)
        compare(LL.median([-14, -8]), -14)
        compare(LL.median([-8, -9, -14, -20]), -14)
        compare(LL.median([-20, -14, -9, -8]), -14)
        compare(LL.median([-9, -9]), -9)
        // The list handed in is left in the order it had.
        var mine = [-8, -14, -9];
        LL.median(mine);
        compare(mine, [-8, -14, -9])
    }

    function test_what_is_no_reading_is_not_counted() {
        compare(LL.median([]), null)
        var junk = [null, undefined, "", "-9", -9, 0, true, {}, { "0": -9, "length": 1 }];
        for (var i = 0; i < junk.length; i++) compare(LL.median(junk[i]), null, String(junk[i]))
        compare(LL.median([null, "x", NaN, -70, 99, undefined]), null)
        compare(LL.median([-8, null, "x", NaN, -14, -70]), -14)
        var many = [];
        for (i = 0; i < 1001; i++) many.push(-10 - (i % 7));
        compare(LL.median(many), -13)
    }

    function test_one_loud_reading_does_not_decide_once_there_are_more() {
        // A station at -14 whose first twenty seconds were an advert at -8.
        var m = LL.withAnswer("{}", pop, -8, now);
        compare(LL.lufsAt(m, null, pop), -8)
        m = LL.withAnswer(m, pop, -14, now + day);
        compare(LL.lufsAt(m, null, pop), -14)
        // The advert again on the third day: two of the three are the advert, and it decides again.
        m = LL.withAnswer(m, pop, -8, now + 2 * day);
        compare(LL.lufsAt(m, null, pop), -8)
        m = LL.withAnswer(m, pop, -14, now + 3 * day);
        compare(LL.lufsAt(m, null, pop), -14)
        m = LL.withAnswer(m, pop, -14, now + 4 * day);
        compare(LL.lufsAt(m, null, pop), -14)
        compare(LL.readingsAt(m, pop), [-8, -14, -8, -14, -14])
    }

    function test_five_readings_are_kept_and_a_sixth_takes_the_oldest_ones_place() {
        compare(LL.KEEP, 5)
        var m = read(pop, [-8, -9, -10, -11, -12], now);
        compare(LL.readingsAt(m, pop), [-8, -9, -10, -11, -12])
        compare(LL.lufsAt(m, null, pop), -10)
        m = LL.withAnswer(m, pop, -13, now + 31 * day);
        compare(LL.readingsAt(m, pop), [-9, -10, -11, -12, -13])
        compare(LL.lufsAt(m, null, pop), -11)
        compare(JSON.parse(m)[pop], [now + 31 * day, 0, -9, -10, -11, -12, -13])
        for (var i = 0; i < 40; i++) m = LL.withAnswer(m, pop, -20 - (i % 3), now + (32 + i) * day);
        compare(LL.readingsAt(m, pop), [-22, -20, -21, -22, -20])
        compare(Object.keys(JSON.parse(m)).length, 1)
    }

    function test_a_reading_is_read_whatever_the_list_looks_like() {
        var m = LL.withAnswer("{}", pop, -9.6, now);
        compare(LL.lufsAt(m, "", pop), -9.6)
        compare(LL.lufsAt(m, null, pop), -9.6)
        compare(LL.lufsAt(m, "not json", pop), -9.6)
        compare(LL.lufsAt(m, rows([jazz]), pop), -9.6)
    }

    function test_a_station_that_moved_keeps_its_reading_until_it_has_a_new_one() {
        var there = "https://new.example.org/pop";
        var moved = JSON.stringify([{ "name": "Pop", "hostname": there, "prev": pop }]);
        var m = LL.withAnswer("{}", pop, -9.6, now);
        compare(LL.lufsAt(m, moved, there), -9.6)
        // What the old address lends is what it played at: its median.
        compare(LL.lufsAt(read(pop, [-8, -14, -9], now), moved, there), -9)
        // Its own reading wins once it is there, and a miss alone is none.
        compare(LL.lufsAt(LL.withMiss(m, there, now + 5), moved, there), -9.6)
        compare(LL.lufsAt(LL.withAnswer(m, there, -14, now + 5), moved, there), -14)
        // Only the row that holds the address lends its past, and only its own.
        compare(LL.lufsAt(m, JSON.stringify([{ "hostname": jazz, "prev": pop }]), there), null)
        compare(LL.lufsAt(m, JSON.stringify([{ "hostname": there, "prev": jazz }]), there), null)
        compare(LL.lufsAt(m, JSON.stringify([{ "hostname": there, "prev": 7 }]), there), null)
        compare(LL.lufsAt(m, JSON.stringify([{ "hostname": there }]), there), null)
    }

    function test_a_map_that_is_not_one_reads_as_empty() {
        var bad = ["", " ", "null", "7", "\"x\"", "[]", "[1,2]", "{", "not json", null, undefined, 7, {}, [], true];
        for (var i = 0; i < bad.length; i++) {
            compare(LL.lufsAt(bad[i], rows([pop]), pop), null, String(bad[i]))
            compare(LL.readingsAt(bad[i], pop), [], String(bad[i]))
            verify(LL.due(bad[i], pop, now), String(bad[i]))
            compare(LL.withAnswer(bad[i], "nope", -9, now), "{}", String(bad[i]))
            compare(LL.kept(bad[i], rows([pop])), "{}", String(bad[i]))
        }
    }

    function test_an_entry_that_is_not_one_is_not_read() {
        var o = {};
        o[pop] = [now, 0, -9.6];
        o["https://a.example/miss"] = [0, now];
        o["ftp://x.example/a"] = [now, 0, -9.6];
        o["https://a.example/1"] = -9.6;
        o["https://a.example/2"] = [now];
        o["https://a.example/3"] = [now, 0];
        o["https://a.example/4"] = [now, 0, "-9.6"];
        o["https://a.example/5"] = [now, 0, -70];
        o["https://a.example/6"] = [-1, 0, -9.6];
        o["https://a.example/7"] = [now, "0", -9.6];
        o["https://a.example/8"] = [0, 0, -9.6];
        o["https://a.example/9"] = { "0": now, "1": 0, "2": -9.6 };
        o["https://a.example/10"] = [now + 0.5, 0, -9.6];
        o["https://a.example/11"] = [now, 0, -9, -9, -9, -9, -9, -9];
        o["https://a.example/12"] = [now, 0, -9, null];
        o["https://a.example/13"] = [0, 0];
        o["https://a.example/14"] = [now, now + 5];
        // What this branch kept before there were several readings: one
        // reading first, then its time. Nothing shipped in that shape, and
        // none of it is taken for a time and a reading the other way round.
        o["https://a.example/15"] = [-9.6, now, 0];
        o["https://a.example/16"] = [null, 0, now];
        o["https://a.example/17"] = [3, now, 0];
        o["https://a.example/18"] = [0, now, 0];
        // A second of the year 1970 is a clock that was never set.
        o["https://a.example/19"] = [5000, 0, -9.6];
        o["https://a.example/" + new Array(2100).join("a")] = [now, 0, -9.6];
        var tidy = JSON.parse(LL.withAnswer(JSON.stringify(o), "nope", -9, now));
        compare(Object.keys(tidy), [pop, "https://a.example/miss"])
        compare(tidy[pop], [now, 0, -9.6])
        compare(tidy["https://a.example/miss"], [0, now])
    }

    function test_nothing_is_written_that_would_not_be_read() {
        var m = LL.withAnswer("{}", pop, -9.6, now);
        var bad = [[jazz, -70], [jazz, -50], [jazz, -49.96], [jazz, 6.5], [jazz, 6.06], [jazz, null], [jazz, "-9"], [jazz, NaN],
                   ["ftp://x/a", -9], ["", -9], [null, -9], ["https://x.example/" + new Array(2100).join("a"), -9]];
        for (var i = 0; i < bad.length; i++) compare(LL.withAnswer(m, bad[i][0], bad[i][1], now), m, String(bad[i]))
        var clocks = [0, -5, 5000, NaN, null, undefined, "1794400000", Infinity];
        for (i = 0; i < clocks.length; i++) {
            compare(LL.withAnswer(m, jazz, -9, clocks[i]), m, "answer at " + clocks[i])
            compare(LL.withMiss(m, jazz, clocks[i]), m, "miss at " + clocks[i])
        }
        compare(LL.withMiss(m, "ftp://x/a", now), m)
        // A clock with a fraction is written as its whole second, a reading to one decimal.
        compare(JSON.parse(LL.withAnswer("{}", pop, -9.649, now + 0.9))[pop], [now, 0, -9.6])
        compare(JSON.parse(LL.withAnswer("{}", pop, -49.94, now))[pop], [now, 0, -49.9])
    }

    function test_the_map_stops_at_its_cap_and_lets_the_oldest_go() {
        var m = "{}", i;
        for (i = 0; i < 5; i++) m = LL.withAnswer(m, "https://s" + i + ".example.org/live", -9 - i, now + i, 3);
        compare(Object.keys(JSON.parse(m)), ["https://s2.example.org/live", "https://s3.example.org/live", "https://s4.example.org/live"])
        // Written again, an address is the newest.
        m = LL.withAnswer(m, "https://s2.example.org/live", -9, now + 9, 3);
        m = LL.withMiss(m, "https://s9.example.org/live", now + 10, 3);
        compare(Object.keys(JSON.parse(m)), ["https://s4.example.org/live", "https://s2.example.org/live", "https://s9.example.org/live"])
        // A cap that is none is the cap there is.
        var caps = [0, -1, 1.5, null, undefined, "3", NaN];
        for (i = 0; i < caps.length; i++) compare(Object.keys(JSON.parse(LL.withAnswer(m, pop, -9, now, caps[i]))).length, 4, String(caps[i]))
        compare(LL.CAP, 512)
        var big = "{}";
        for (i = 0; i < 600; i++) big = LL.withAnswer(big, "https://s" + i + ".example.org/live", -9, now + i);
        var keys = Object.keys(JSON.parse(big));
        compare(keys.length, 512)
        compare(keys[0], "https://s88.example.org/live")
        compare(keys[511], "https://s599.example.org/live")
    }

    function test_a_second_reading_at_a_full_map_lets_nobody_go() {
        var m = "{}", i, hosts = [];
        for (i = 0; i < 3; i++) { hosts.push("https://s" + i + ".example.org/live"); m = LL.withAnswer(m, hosts[i], -9 - i, now + i, 3); }
        // The station in the middle is read a second time: its own entry is
        // rewritten, as the newest, and the two others stay.
        m = LL.withAnswer(m, hosts[1], -12, now + day, 3);
        compare(Object.keys(JSON.parse(m)), [hosts[0], hosts[2], hosts[1]])
        compare(LL.readingsAt(m, hosts[1]), [-10, -12])
        compare(LL.lufsAt(m, null, hosts[0]), -9)
        // So does a miss.
        m = LL.withMiss(m, hosts[0], now + day, 3);
        compare(Object.keys(JSON.parse(m)), [hosts[2], hosts[1], hosts[0]])
        compare(LL.lufsAt(m, null, hosts[0]), -9)
        // At the real cap, with 512 stations each read five times.
        var big = "{}";
        for (i = 0; i < 512; i++) big = LL.withAnswer(big, "https://s" + i + ".example.org/live", -9, now + i);
        big = LL.withAnswer(big, "https://s0.example.org/live", -12, now + day);
        var keys = Object.keys(JSON.parse(big));
        compare(keys.length, 512)
        compare(keys[0], "https://s1.example.org/live")
        compare(keys[511], "https://s0.example.org/live")
    }

    function test_five_hundred_stations_all_keep_their_readings() {
        var hosts = [], m = "{}", i, k;
        for (i = 0; i < 500; i++) {
            hosts.push("https://s" + i + ".example.org/live");
            for (k = 0; k < 5; k++) m = LL.withAnswer(m, hosts[i], -6 - i / 50 - k / 10, now + i + k * day);
        }
        var saved = rows(hosts);
        compare(Object.keys(JSON.parse(LL.kept(m, saved))).length, 500)
        compare(LL.lufsAt(m, saved, hosts[0]), -6.2)
        compare(LL.lufsAt(m, saved, hosts[499]), -16.2)
        verify(m.length < 45000, "500 stations with five readings each take " + m.length + " characters")
    }

    function test_a_miss_keeps_the_readings_there_were() {
        var m = LL.withMiss("{}", pop, now);
        compare(JSON.parse(m)[pop], [0, now])
        compare(LL.lufsAt(m, rows([pop]), pop), null)
        compare(LL.readingsAt(m, pop), [])
        m = LL.withMiss(read(pop, [-9.6, -10], now), pop, now + 40 * day);
        compare(JSON.parse(m)[pop], [now, now + 40 * day, -9.6, -10])
        compare(LL.lufsAt(m, rows([pop]), pop), -10)
        // And a reading after a miss clears the miss.
        compare(JSON.parse(LL.withAnswer(m, pop, -11, now + 41 * day))[pop], [now + 41 * day, 0, -9.6, -10, -11])
    }

    function test_only_addresses_still_saved_stay_in_the_map() {
        var m = LL.withAnswer(LL.withAnswer(LL.withMiss("{}", "https://gone.example/x", now), pop, -9.6, now), jazz, -20, now);
        compare(Object.keys(JSON.parse(LL.kept(m, rows([jazz, pop])))), [pop, jazz])
        compare(Object.keys(JSON.parse(LL.kept(m, rows([jazz])))), [jazz])
        compare(LL.kept(m, "[]"), "{}")
        compare(LL.kept(m, ""), "{}")
        compare(LL.kept(m, null), "{}")
        compare(LL.kept(m, "not json"), "{}")
        // The address a row moved from stays while the row remembers it.
        var moved = JSON.stringify([{ "hostname": "https://new.example.org/pop", "prev": pop }, null, 7]);
        compare(Object.keys(JSON.parse(LL.kept(m, moved))), [pop])
    }

    // ── when a reading is taken ─────────────────────────────────────────

    function test_an_address_nothing_is_kept_of_is_due() {
        verify(LL.due("{}", pop, now))
        verify(LL.due(LL.withAnswer("{}", jazz, -9, now), pop, now))
    }

    function test_one_more_reading_a_day_until_there_are_five() {
        var m = "{}", i;
        for (i = 0; i < 5; i++) {
            verify(LL.due(m, pop, now + i * day), "day " + i)
            m = LL.withAnswer(m, pop, -9 - i, now + i * day);
            // However often the station is played that day, it is not read again.
            verify(!LL.due(m, pop, now + i * day), "at once on day " + i)
            verify(!LL.due(m, pop, now + i * day + 3600), "an hour on, day " + i)
            verify(!LL.due(m, pop, now + (i + 1) * day - 1), "a second short of a day, day " + i)
        }
        compare(LL.readingsAt(m, pop).length, 5)
        // Five are enough: not the next day, nor the next week.
        verify(!LL.due(m, pop, now + 5 * day))
        verify(!LL.due(m, pop, now + 12 * day))
        // Days on which the station is not played change nothing: the next play reads it.
        var two = read(pop, [-9, -10], now);
        verify(LL.due(two, pop, now + 9 * day))
        verify(LL.due(two, pop, now + 300 * day))
    }

    function test_five_readings_serve_until_the_newest_is_thirty_days_old() {
        var m = read(pop, [-8, -9, -10, -11, -12], now);
        verify(!LL.due(m, pop, now + 1))
        verify(!LL.due(m, pop, now + 29 * day))
        verify(!LL.due(m, pop, now + 30 * day))
        verify(LL.due(m, pop, now + 30 * day + 1))
        verify(LL.due(m, pop, now + 400 * day))
        // The sixth takes the oldest one's place, and then it is a month again.
        m = LL.withAnswer(m, pop, -13, now + 31 * day);
        verify(!LL.due(m, pop, now + 32 * day))
        verify(!LL.due(m, pop, now + 61 * day))
        verify(LL.due(m, pop, now + 61 * day + 1))
    }

    function test_an_attempt_without_a_number_is_not_repeated_before_a_day_has_passed() {
        var m = LL.withMiss("{}", pop, now);
        verify(!LL.due(m, pop, now))
        verify(!LL.due(m, pop, now + 3600))
        verify(!LL.due(m, pop, now + day - 1))
        verify(LL.due(m, pop, now + day))
        // A station that is silent on its second day keeps its first
        // reading, and is asked again on the third.
        m = LL.withMiss(LL.withAnswer("{}", pop, -9.6, now), pop, now + day);
        compare(LL.lufsAt(m, null, pop), -9.6)
        compare(LL.readingsAt(m, pop), [-9.6])
        verify(!LL.due(m, pop, now + day + 10))
        verify(!LL.due(m, pop, now + 2 * day - 1))
        verify(LL.due(m, pop, now + 2 * day))
        // Five readings whose monthly look failed serve on, and are asked for again tomorrow.
        m = LL.withMiss(read(pop, [-8, -9, -10, -11, -12], now), pop, now + 31 * day);
        verify(!LL.due(m, pop, now + 31 * day + 10))
        verify(!LL.due(m, pop, now + 32 * day - 1))
        verify(LL.due(m, pop, now + 32 * day))
        compare(LL.lufsAt(m, null, pop), -10)
    }

    function test_a_clock_that_stepped_back_a_day_asks_nobody_twice() {
        // The reading was taken "tomorrow" by the clock that stands now.
        var m = LL.withAnswer("{}", pop, -9.6, now + day);
        verify(!LL.due(m, pop, now))
        verify(!LL.due(m, pop, now + day))
        verify(!LL.due(m, pop, now + 2 * day - 1))
        verify(LL.due(m, pop, now + 2 * day))
        compare(LL.lufsAt(m, null, pop), -9.6)
        verify(!LL.due(LL.withMiss("{}", pop, now + 30), pop, now))
    }

    function test_a_stamp_from_a_clock_that_was_wrong_does_not_stand_for_years() {
        verify(LL.due(read(pop, [-8, -9, -10, -11, -12], now + 400 * day), pop, now))
        verify(LL.due(LL.withMiss("{}", pop, now + 400 * day), pop, now))
        // More than a day ahead is such a clock. The reading taken now is the newest, and the day counts from it.
        var m = LL.withAnswer("{}", pop, -9.6, now + day + 1);
        verify(LL.due(m, pop, now))
        m = LL.withAnswer(m, pop, -12, now);
        compare(JSON.parse(m)[pop], [now, 0, -9.6, -12])
        verify(!LL.due(m, pop, now + 30))
        verify(LL.due(m, pop, now + day))
    }

    function test_nothing_is_due_without_an_address_or_a_clock() {
        var none = ["", "ftp://x/a", null, undefined, 7, {}, "https://x.example/" + new Array(2100).join("a")];
        for (var i = 0; i < none.length; i++) verify(!LL.due("{}", none[i], now), String(none[i]))
        var clocks = [0, -1, 5000, NaN, null, undefined, "1794400000", Infinity];
        for (i = 0; i < clocks.length; i++) verify(!LL.due("{}", pop, clocks[i]), String(clocks[i]))
    }

    // ── the commands ────────────────────────────────────────────────────

    function ask(over) {
        var o = { url: jazz, urlPath: "/run/user/1000/arp-icy-src-7.loud41", scriptPath: "/usr/share/on air/loudness.py", seq: 41 };
        for (var k in over) o[k] = over[k];
        return LL.buildAsk(o);
    }

    function test_the_address_goes_into_a_file_and_never_to_the_helper() {
        var c = ask({});
        compare(c.write, ": LD_URL; umask 077; printf '%s' '" + jazz + "' > '/run/user/1000/arp-icy-src-7.loud41'"
                         + " && echo __LD_URL_OK__ || echo __LD_URL_FAIL__; true # 41")
        compare(c.run, ": LD_RUN; timeout 45 python3 -B '/usr/share/on air/loudness.py' '/run/user/1000/arp-icy-src-7.loud41' 20"
                       + " 2>/dev/null; rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 41")
        verify(c.run.indexOf("example") === -1 && c.run.indexOf("token") === -1)
        compare(LL.LISTEN_S, 20)
        // The shell's limit stands above the helper's own.
        compare(LL.HELPER_LIMIT_S, 40)
    }

    function test_a_hostile_address_or_path_stays_quoted() {
        var evil = "https://x.example/a'; touch /tmp/pwned; echo ' b?t=$(id)&u=`id`";
        var c = ask({ url: evil, urlPath: "/run/a b/it's.loud7", scriptPath: "/opt/it's/loudness.py", seq: 7 });
        verify(c.write.indexOf("printf '%s' 'https://x.example/a'\\''; touch /tmp/pwned; echo '\\'' b?t=$(id)&u=`id`'"
                               + " > '/run/a b/it'\\''s.loud7'") !== -1, c.write)
        verify(c.run.indexOf("python3 -B '/opt/it'\\''s/loudness.py' '/run/a b/it'\\''s.loud7' 20") !== -1, c.run)
        compare(LL.buildEnd("/run/a b/it's.loud7", 7), ": LD_END; rm -f '/run/a b/it'\\''s.loud7'; true # 7")
    }

    function test_no_command_is_made_of_half_a_question() {
        var none = { write: "", run: "" };
        compare(LL.buildAsk(null), none)
        compare(LL.buildAsk(undefined), none)
        compare(LL.buildAsk({}), none)
        compare(ask({ url: "" }), none)
        compare(ask({ url: "file:///etc/passwd" }), none)
        compare(ask({ url: "ftp://x.example/a" }), none)
        compare(ask({ url: null }), none)
        compare(ask({ url: "https://x.example/" + new Array(2100).join("a") }), none)
        compare(ask({ urlPath: "" }), none)
        compare(ask({ urlPath: null }), none)
        compare(ask({ scriptPath: "" }), none)
        compare(ask({ scriptPath: 7 }), none)
        compare(ask({ seq: -1 }), none)
        compare(ask({ seq: undefined }), none)
        compare(ask({ seq: "41" }), none)
        verify(ask({ seq: 0 }).write !== "")
    }

    function test_an_end_removes_one_file_and_names_its_question() {
        compare(LL.buildEnd("/run/user/1000/arp-icy-src-7.loud41", 41), ": LD_END; rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 41")
        compare(LL.buildEnd("/run/user/1000/arp-icy-src-7.loud41", 0), ": LD_END; rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 0")
        compare(LL.buildEnd("", 41), "")
        compare(LL.buildEnd(null, 41), "")
        compare(LL.buildEnd(undefined, 41), "")
        compare(LL.buildEnd(7, 41), "")
        compare(LL.buildEnd("/x", -1), "")
        compare(LL.buildEnd("/x", "41"), "")
        compare(LL.buildEnd("/x", undefined), "")
        compare(LL.buildEnd("/x", NaN), "")
    }
}
