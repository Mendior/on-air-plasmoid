// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The sliding buffer's arithmetic: which segment holds a moment, where an
// open may land, what a step does, what the list says and when the player
// has to be taken off it. The measurements behind the numbers are in
// SlideLogic.js.
import QtQuick
import QtTest

import "../../package/contents/ui/SlideLogic.js" as SL

TestCase {
    name: "SlideLogic"

    readonly property var junk: [null, undefined, NaN, "12", "", {}, [], true, Infinity, -Infinity]

    function test_segments_are_whole_seconds_and_the_gaps_are_ordered() {
        // The list is written in whole seconds; a fraction is read as its
        // whole part under a comma-decimal locale.
        compare(SL.SEG_SEC, Math.floor(SL.SEG_SEC))
        verify(SL.SEG_SEC >= 1)
        compare(SL.SEG_MS, SL.SEG_SEC * 1000)
        // The reader runs 4.5 s ahead of the sound; the sound is taken off
        // the list before that, and an open leaves a segment and a late
        // look at the folder on top.
        verify(SL.LEAVE_GAP_MS >= 6000)
        verify(SL.OPEN_GAP_MS >= SL.LEAVE_GAP_MS + SL.SEG_MS + SL.TICK_MS)
        verify(SL.AHEAD_MS > SL.OPEN_GAP_MS)
        verify(SL.AHEAD_MS - SL.GROW_SLACK_MS > SL.OPEN_GAP_MS)
        compare(SL.KEEP_MS, 2 * SL.SEG_MS)
        compare(SL.STEP_MS, 30000)
        verify(SL.STEP_READY_MS >= SL.OPEN_GAP_MS + SL.KEEP_MS + SL.SEG_MS)
    }

    function test_a_pause_parks_where_the_player_is_and_not_where_the_writer_is() {
        // The writer has run 45.0 s, the player has played 40.8 s of it.
        compare(SL.parkAt(45000, 40800), 40800 - SL.PARK_LAG_MS)
        compare(SL.parkAt(600000, 598500), 598500 - SL.PARK_LAG_MS)
        // A player level with the writer, and one up to two seconds past it
        // (the clock lost a beat): the park is never ahead of the writer.
        compare(SL.parkAt(45000, 45000), 45000 - SL.PARK_LAG_MS)
        compare(SL.parkAt(45000, 45000 + SL.PARK_LAG_MS), 45000)
        compare(SL.parkAt(45000, 47000), 45000)
        // Further past it is no position on this stream: the old guess.
        compare(SL.parkAt(45000, 47001), 45000 - SL.PARK_GUESS_MS)
        compare(SL.parkAt(45000, 3600000), 45000 - SL.PARK_GUESS_MS)
        // A player that has just begun, on a writer as young.
        compare(SL.parkAt(1500, SL.PARK_LAG_MS), 0)
        compare(SL.parkAt(1500, 1), 0)
        // A player further behind the writer than a start can put it is one
        // whose position is not a place in this buffer: the old guess. The
        // last place that is still believed, and one millisecond before it.
        compare(SL.parkAt(45000, 45000 - SL.PARK_TRUST_MS), 45000 - SL.PARK_TRUST_MS - SL.PARK_LAG_MS)
        compare(SL.parkAt(45000, 45000 - SL.PARK_TRUST_MS - 1), 45000 - SL.PARK_GUESS_MS)
        compare(SL.parkAt(190000, 12400), 190000 - SL.PARK_GUESS_MS)
        // A player that says nothing, or nonsense.
        compare(SL.parkAt(45000, 0), 45000 - SL.PARK_GUESS_MS)
        // Also on a writer so young that nought lies inside what is believed.
        compare(SL.parkAt(10000, 0), 10000 - SL.PARK_GUESS_MS)
        compare(SL.parkAt(45000, -200), 45000 - SL.PARK_GUESS_MS)
        compare(SL.parkAt(45000), 45000 - SL.PARK_GUESS_MS)
        for (var i = 0; i < junk.length; i++) {
            compare(SL.parkAt(45000, junk[i]), 45000 - SL.PARK_GUESS_MS, "pos " + String(junk[i]))
            compare(SL.parkAt(junk[i], 40800), 0, "run " + String(junk[i]))
        }
        compare(SL.parkAt(), 0)
        compare(SL.parkAt(-5, 40800), 0)
        // A writer two seconds old with nothing to guess back into.
        compare(SL.parkAt(2000, 0), 0)
        compare(SL.parkAt(0, 0), 0)
        compare(SL.parkAt(1e12, 1e12 - 5000), 1e12 - 5000 - SL.PARK_LAG_MS)
    }

    function test_a_place_is_in_the_segment_that_holds_it() {
        compare(SL.segOf(5000), 2)
        compare(SL.segOf(4321), 2)
        // The boundary belongs to the segment it opens.
        compare(SL.segOf(0), 0)
        compare(SL.segOf(1999), 0)
        compare(SL.segOf(2000), 1)
        compare(SL.segOf(3999.9), 1)
        compare(SL.segOf(-1), 0)
        compare(SL.segOf(-50000), 0)
        for (var i = 0; i < junk.length; i++) compare(SL.segOf(junk[i]), 0, String(junk[i]))
        compare(SL.segOf(), 0)
        // Four hours in, and a year in.
        compare(SL.segOf(4 * 3600 * 1000), 7200)
        compare(SL.segOf(365 * 86400 * 1000), 15768000)
    }

    function test_the_window_is_counted_in_segments() {
        compare(SL.listSize(60), 1800)
        compare(SL.listSize(5), 150)
        compare(SL.listSize(2), 60)
        // Held to 1..240 minutes, like the setting.
        compare(SL.listSize(1), 30)
        compare(SL.listSize(0), 30)
        compare(SL.listSize(-7), 30)
        compare(SL.listSize(240), 7200)
        compare(SL.listSize(241), 7200)
        compare(SL.listSize(100000), 7200)
        compare(SL.listSize(7.9), 210)
        var none = [null, undefined, NaN, "x", {}, []];
        for (var i = 0; i < none.length; i++) compare(SL.listSize(none[i]), 1800, String(none[i]))
        compare(SL.listSize(), 1800)
    }

    function test_a_beat_adds_what_passed_unless_the_clock_jumped() {
        compare(SL.beat(1000000, 1001000), 1000)
        compare(SL.beat(1000000, 1001370), 1370)
        // Up to the sane gap is taken at its word, and nothing passing is 0.
        compare(SL.beat(1000000, 1000000), 0)
        compare(SL.beat(1000000, 1000000 + SL.TICK_SANE_MS), SL.TICK_SANE_MS)
        // A night asleep, and a clock set back an hour: one beat each.
        compare(SL.beat(1000000, 1000000 + SL.TICK_SANE_MS + 1), SL.TICK_MS)
        // Ten seconds between two beats is a shell that stood or a lid
        // that closed, and counts as the one beat it was.
        compare(SL.beat(1000000, 1010000), 1000)
        compare(SL.beat(1000000, 1000000 + 9 * 3600 * 1000), SL.TICK_MS)
        compare(SL.beat(1000000, 1000000 - 1), SL.TICK_MS)
        compare(SL.beat(1000000, 1000000 - 3600 * 1000), SL.TICK_MS)
        // The first beat has nothing to measure from.
        compare(SL.beat(0, 1000000), 0)
        compare(SL.beat(-5, 1000000), 0)
        for (var i = 0; i < junk.length; i++) {
            compare(SL.beat(junk[i], 1000000), 0, "last " + String(junk[i]))
            compare(SL.beat(1000000, junk[i]), 0, "now " + String(junk[i]))
        }
        compare(SL.beat(), 0)
    }

    function test_a_writer_that_ended_in_its_first_minute_could_not_cut_the_station() {
        compare(SL.TRIED_MS, 60000)
        verify(SL.endedYoung(10000))
        verify(SL.endedYoung(SL.TRIED_MS - 1))
        // From a minute on the writer worked, and what ended it was the
        // station or the line: the next buffer may slide again.
        verify(!SL.endedYoung(SL.TRIED_MS))
        verify(!SL.endedYoung(300000))
        verify(!SL.endedYoung(1e12))
        // A writer that never ran, and a time nobody can read.
        verify(SL.endedYoung(0))
        verify(SL.endedYoung(-5))
        for (var i = 0; i < junk.length; i++) verify(SL.endedYoung(junk[i]), String(junk[i]))
        verify(SL.endedYoung())
    }

    function test_only_an_address_that_may_be_mp3_or_aac_is_cut() {
        var yes = ["http://s.example/live", "https://s.example/live.mp3", "http://s.example/a.aac?sid=1",
                   "http://s.example:8000/;", "http://s.example/stream?token=a b'c\"d"];
        for (var i = 0; i < yes.length; i++) verify(SL.mayCut(yes[i], ""), yes[i])
        verify(SL.mayCut("http://s.example/live", "other"))
        verify(SL.mayCut("http://s.example/live", undefined))
        // An ending or a learnt kind that names another codec rules it out.
        var no = ["http://s.example/live.flac", "http://s.example/live.ogg", "http://s.example/live.opus",
                  "http://s.example/live.m3u8", "http://s.example/list.pls", "http://s.example/list.m3u"];
        for (i = 0; i < no.length; i++) verify(!SL.mayCut(no[i], ""), no[i])
        var kinds = ["flac", "ogg", "ogg-flac"];
        for (i = 0; i < kinds.length; i++) verify(!SL.mayCut("http://s.example/live", kinds[i]), kinds[i])
        var notWeb = ["", "file:///home/x/a.mp3", "ftp://s.example/a.mp3", "s.example/live", "http:", "http://", "https://",
                      null, undefined, 7, {}, []];
        for (i = 0; i < notWeb.length; i++) verify(!SL.mayCut(notWeb[i], ""), String(notWeb[i]))
        verify(SL.mayCut("http://s.example/" + new Array(3000).join("a"), ""))
    }

    function test_an_open_lands_on_the_wish_inside_what_is_kept() {
        // Segments 100..160 are on disk: 200 s to 322 s.
        var p = SL.openPlan(250500, 100, 160);
        verify(p.ok)
        compare(p.startMs, 250500)
        compare(p.firstSeg, 125)
        compare(p.seekMs, 500)
        compare(p.clamped, "")
        // On a segment's first millisecond the seek is 0.
        p = SL.openPlan(250000, 100, 160);
        compare(p.firstSeg, 125)
        compare(p.seekMs, 0)
    }

    function test_an_open_keeps_clear_of_both_ends() {
        var endMs = 161 * SL.SEG_MS, oldest = 100 * SL.SEG_MS + SL.KEEP_MS;
        // The last place that is not too near the end, and one past it.
        var p = SL.openPlan(endMs - SL.OPEN_GAP_MS, 100, 160);
        compare(p.startMs, endMs - SL.OPEN_GAP_MS)
        compare(p.clamped, "")
        p = SL.openPlan(endMs - SL.OPEN_GAP_MS + 1, 100, 160);
        compare(p.startMs, endMs - SL.OPEN_GAP_MS)
        compare(p.clamped, "edge")
        p = SL.openPlan(endMs + 99999, 100, 160);
        compare(p.startMs, endMs - SL.OPEN_GAP_MS)
        compare(p.clamped, "edge")
        // The oldest place an open may take, and one before it.
        p = SL.openPlan(oldest, 100, 160);
        compare(p.startMs, oldest)
        compare(p.clamped, "")
        p = SL.openPlan(oldest - 1, 100, 160);
        compare(p.startMs, oldest)
        compare(p.clamped, "old")
        compare(p.firstSeg, 102)
        compare(p.seekMs, 0)
        // A park an hour older than the window, and a wish before the start.
        p = SL.openPlan(200000 - 3600000, 100, 160);
        compare(p.clamped, "old")
        compare(p.startMs, oldest)
        p = SL.openPlan(-1, 0, 60);
        compare(p.clamped, "old")
        compare(p.startMs, SL.KEEP_MS)
    }

    function test_an_open_refuses_a_folder_that_holds_too_little() {
        var need = Math.ceil((SL.OPEN_GAP_MS + SL.KEEP_MS) / SL.SEG_MS);
        // Exactly enough: one place, both clamps meeting on it.
        var p = SL.openPlan(0, 10, 10 + need - 1);
        verify(p.ok)
        compare(p.startMs, 10 * SL.SEG_MS + SL.KEEP_MS)
        // One segment short of that.
        p = SL.openPlan(0, 10, 10 + need - 2);
        verify(!p.ok)
        compare(p.startMs, 0)
        compare(p.firstSeg, 0)
        compare(p.seekMs, 0)
        compare(p.clamped, "")
        verify(!SL.openPlan(5000, 3, 3).ok)
        // An empty folder says -1 -1; a folder read backwards is no folder.
        verify(!SL.openPlan(5000, -1, -1).ok)
        verify(!SL.openPlan(5000, 60, 10).ok)
        verify(!SL.openPlan(5000, -3, 60).ok)
        verify(!SL.openPlan(5000, 1.5, 60).ok)
        for (var i = 0; i < junk.length; i++) {
            verify(!SL.openPlan(junk[i], 0, 60).ok, "want " + String(junk[i]))
            verify(!SL.openPlan(5000, junk[i], 60).ok, "first " + String(junk[i]))
            verify(!SL.openPlan(5000, 0, junk[i]).ok, "last " + String(junk[i]))
        }
        verify(!SL.openPlan().ok)
        // A year of segments is still a folder.
        p = SL.openPlan(15768000 * SL.SEG_MS - 60000, 15768000 - 1800, 15768000);
        verify(p.ok)
        compare(p.clamped, "")
        compare(p.seekMs, 0)
    }

    function test_a_step_back_opens_and_a_step_to_the_edge_goes_live() {
        // Sixty seconds behind an edge at 600 s.
        compare(SL.stepWhat(540000, -SL.STEP_MS, 600000), "open")
        compare(SL.stepWhat(540000, SL.STEP_MS, 600000), "open")
        // Forward to exactly the nearest place an open may take, and 1 ms on.
        compare(SL.stepWhat(600000 - SL.OPEN_GAP_MS - SL.STEP_MS, SL.STEP_MS, 600000), "open")
        compare(SL.stepWhat(600000 - SL.OPEN_GAP_MS - SL.STEP_MS + 1, SL.STEP_MS, 600000), "live")
        compare(SL.stepWhat(595000, SL.STEP_MS, 600000), "live")
        compare(SL.stepWhat(900000, SL.STEP_MS, 600000), "live")
        // Back never goes live, however near the edge or far before the start.
        compare(SL.stepWhat(599000, -SL.STEP_MS, 600000), "open")
        compare(SL.stepWhat(1000, -SL.STEP_MS, 600000), "open")
        compare(SL.stepWhat(599000, -1, 600000), "open")
        // No step at all stays where it is.
        compare(SL.stepWhat(540000, 0, 600000), "open")
        for (var i = 0; i < junk.length; i++) {
            compare(SL.stepWhat(junk[i], SL.STEP_MS, 600000), "live", "from " + String(junk[i]))
            compare(SL.stepWhat(540000, junk[i], 600000), "live", "delta " + String(junk[i]))
            compare(SL.stepWhat(540000, SL.STEP_MS, junk[i]), "live", "edge " + String(junk[i]))
        }
        compare(SL.stepWhat(), "live")
        compare(SL.stepWhat(1e12, -SL.STEP_MS, 1e12 + 5000), "open")
    }

    function test_the_list_names_its_segments_in_whole_seconds_and_has_no_end() {
        var t = SL.listText(125, 127);
        compare(t, "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:" + SL.SEG_SEC
                   + "\n#EXT-X-MEDIA-SEQUENCE:125\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
                   + "#EXTINF:" + SL.SEG_SEC + ",\nseg-125.ts\n"
                   + "#EXTINF:" + SL.SEG_SEC + ",\nseg-126.ts\n"
                   + "#EXTINF:" + SL.SEG_SEC + ",\nseg-127.ts\n")
        // No fraction anywhere and no end mark: a dot would be cut off under
        // a comma-decimal locale, and an ended list never grows.
        verify(t.indexOf(".") === t.indexOf(".ts"))
        verify(!/EXTINF:[0-9]*[.,][0-9]/.test(t))
        verify(t.indexOf("ENDLIST") === -1)
        // One segment is a list.
        compare(SL.listText(0, 0).split("\n").length, 8)
        compare(SL.listText(7, 7).indexOf("seg-7.ts") !== -1, true)
        compare(SL.listText(8, 7), "")
        compare(SL.listText(-1, 3), "")
        compare(SL.listText(1.5, 3), "")
        compare(SL.listText(1, 3.5), "")
        for (var i = 0; i < junk.length; i++) {
            compare(SL.listText(junk[i], 5), "", "first " + String(junk[i]))
            compare(SL.listText(1, junk[i]), "", "upto " + String(junk[i]))
        }
        compare(SL.listText(), "")
        // A whole four-hour window.
        var big = SL.listText(1000, 8199);
        compare(big.split("\n").length, 5 + 2 * 7200 + 1)
        verify(big.indexOf("seg-8199.ts\n") === big.length - "seg-8199.ts\n".length)
    }

    function test_growing_a_list_adds_the_same_two_lines_a_segment() {
        compare(SL.entriesText(128, 129), "#EXTINF:" + SL.SEG_SEC + ",\nseg-128.ts\n#EXTINF:" + SL.SEG_SEC + ",\nseg-129.ts\n")
        // What listText ends in is what entriesText gives.
        var whole = SL.listText(125, 129), head = SL.listText(125, 127);
        compare(head + SL.entriesText(128, 129), whole)
        compare(SL.entriesText(5, 5), "#EXTINF:" + SL.SEG_SEC + ",\nseg-5.ts\n")
        compare(SL.entriesText(6, 5), "")
        compare(SL.entriesText(-2, 5), "")
        compare(SL.entriesText(2.5, 5), "")
        for (var i = 0; i < junk.length; i++) {
            compare(SL.entriesText(junk[i], 5), "", "from " + String(junk[i]))
            compare(SL.entriesText(1, junk[i]), "", "upto " + String(junk[i]))
        }
        compare(SL.entriesText(), "")
        compare(SL.entriesText(0, 9999).split("\n").length, 20001)
    }

    function test_a_list_is_kept_filled_well_ahead_of_the_listener() {
        // The list ends with segment 130 (262 s); the listener is at 250 s
        // and wants it to reach 280 s: segments 131..139.
        var g = SL.growBy(130, 250000);
        compare(g.from, 131)
        compare(g.upto, SL.segOf(250000 + SL.AHEAD_MS - 1))
        // A list that reaches the full thirty seconds is left alone until
        // ten of them are used up: a question to the folder costs 8 ms of
        // processor (measured), and one a second would be most of what the
        // shifted listener costs. Exactly at that mark, and 1 ms past it.
        compare(SL.growBy(130, 131 * SL.SEG_MS - SL.AHEAD_MS), null)
        compare(SL.growBy(130, 131 * SL.SEG_MS - SL.AHEAD_MS + SL.GROW_SLACK_MS), null)
        g = SL.growBy(130, 131 * SL.SEG_MS - SL.AHEAD_MS + SL.GROW_SLACK_MS + 1);
        compare(g.from, 131)
        compare(g.upto, 136)
        // A list far ahead of a listener who stepped back asks for nothing.
        compare(SL.growBy(500, 250000), null)
        // A list far behind is filled a bounded piece at a time.
        g = SL.growBy(10, 3600000);
        compare(g.from, 11)
        compare(g.upto, 42)
        compare(SL.growBy(-1, 0).from, 0)
        for (var i = 0; i < junk.length; i++) {
            compare(SL.growBy(junk[i], 250000), null, "last " + String(junk[i]))
            compare(SL.growBy(130, junk[i]), null, "place " + String(junk[i]))
        }
        compare(SL.growBy(), null)
        compare(SL.growBy(1.5, 250000), null)
        compare(SL.growBy(-2, 250000), null)
    }

    function test_the_player_leaves_a_list_that_runs_short() {
        verify(!SL.mustLeave(300000, 250000))
        // Exactly the gap is still safe; a millisecond less is not.
        verify(!SL.mustLeave(300000, 300000 - SL.LEAVE_GAP_MS))
        verify(SL.mustLeave(300000, 300000 - SL.LEAVE_GAP_MS + 1))
        verify(SL.mustLeave(300000, 300000))
        verify(SL.mustLeave(300000, 400000))
        // What cannot be read is left: staying is what freezes the shell.
        for (var i = 0; i < junk.length; i++) {
            verify(SL.mustLeave(junk[i], 250000), "end " + String(junk[i]))
            verify(SL.mustLeave(300000, junk[i]), "place " + String(junk[i]))
        }
        verify(SL.mustLeave())
        verify(!SL.mustLeave(1e12, 1e12 - 3600000))
    }

    function test_behind_live_is_the_writers_clock_less_the_place() {
        // The writer has run 600 s, the listener is at 540 s.
        compare(SL.behindMs(600000, 540000), 60000)
        // A beat later both have moved a second and the number stands.
        compare(SL.behindMs(601000, 541000), 60000)
        // A park made this instant is not behind, and a place past the
        // clock (the clock lost a beat) is not ahead of the broadcast.
        compare(SL.behindMs(600000, 600000), 0)
        compare(SL.behindMs(600000, 600001), 0)
        compare(SL.behindMs(600000, 700000), 0)
        compare(SL.behindMs(600000, 0), 600000)
        // No place at all.
        compare(SL.behindMs(600000, -1), 0)
        for (var i = 0; i < junk.length; i++) {
            compare(SL.behindMs(junk[i], 540000), 0, "run " + String(junk[i]))
            compare(SL.behindMs(600000, junk[i]), 0, "place " + String(junk[i]))
        }
        compare(SL.behindMs(), 0)
        compare(SL.behindMs(1e12, 1e12 - 14400000), 14400000)
    }

    function test_the_pill_reads_minutes_and_seconds() {
        compare(SL.clockText(60000), "1:00")
        compare(SL.clockText(61000), "1:01")
        compare(SL.clockText(9000), "0:09")
        compare(SL.clockText(0), "0:00")
        compare(SL.clockText(499), "0:00")
        compare(SL.clockText(500), "0:01")
        compare(SL.clockText(59499), "0:59")
        compare(SL.clockText(59500), "1:00")
        compare(SL.clockText(-3000), "0:00")
        for (var i = 0; i < junk.length; i++) compare(SL.clockText(junk[i]), "0:00", String(junk[i]))
        compare(SL.clockText(), "0:00")
        // Four hours are 240 minutes, not 4:00:00.
        compare(SL.clockText(14400000), "240:00")
    }

    function test_the_folders_answer_is_read_strictly() {
        var h = SL.parseHave("__TS_HAVE__ first=100 last=160\n");
        compare(h.first, 100)
        compare(h.last, 160)
        h = SL.parseHave("noise\n__TS_HAVE__ first=0 last=0\n");
        compare(h.first, 0)
        compare(h.last, 0)
        compare(SL.parseHave("__TS_HAVE__ first=-1 last=-1\n"), null)
        compare(SL.parseHave("__TS_HAVE__ first=160 last=100\n"), null)
        compare(SL.parseHave("__TS_HAVE__ first=1 last=\n"), null)
        compare(SL.parseHave("__TS_HAVE__ first=a last=b\n"), null)
        compare(SL.parseHave("first=1 last=2\n"), null)
        compare(SL.parseHave(""), null)
        var none = [null, undefined, 7, {}, []];
        for (var i = 0; i < none.length; i++) compare(SL.parseHave(none[i]), null, String(none[i]))
        compare(SL.parseHave(), null)
        h = SL.parseHave(new Array(20000).join("x") + "\n__TS_HAVE__ first=15766200 last=15768000\n");
        compare(h.last, 15768000)
    }

    function test_a_written_list_answers_with_its_last_segment_and_the_newest() {
        var a = SL.parseList("__TS_LIST__ last=139 newest=151\n");
        compare(a.last, 139)
        compare(a.newest, 151)
        a = SL.parseList("x\n__TS_LIST__ last=7 newest=7\ny\n");
        compare(a.last, 7)
        // A list of one segment, and a folder the helper could not read.
        a = SL.parseList("__TS_LIST__ last=0 newest=-1\n");
        compare(a.last, 0)
        compare(a.newest, -1)
        compare(SL.parseList("__TS_LIST__ last=5\n").newest, -1)
        compare(SL.parseList("__TS_LIST__ last=-1 newest=4\n"), null)
        compare(SL.parseList("__TS_LIST_FAIL__\n"), null)
        compare(SL.parseList("__TS_LIST__ last= newest=3\n"), null)
        compare(SL.parseList("__TS_LIST__ last=x newest=3\n"), null)
        compare(SL.parseList("__TS_LIST__ last=3 newest=x\n"), null)
        compare(SL.parseList(""), null)
        var none = [null, undefined, 7, {}, []];
        for (var i = 0; i < none.length; i++) compare(SL.parseList(none[i]), null, String(none[i]))
        compare(SL.parseList(), null)
        compare(SL.parseList(new Array(20000).join("x") + "\n__TS_LIST__ last=15768000 newest=15768009\n").last, 15768000)
    }

    function test_the_writers_decision_is_one_of_three_words() {
        compare(SL.parseKind("__TS_KIND__ slide mp3\n"), "mp3")
        compare(SL.parseKind("__TS_KIND__ slide aac\n"), "aac")
        compare(SL.parseKind("__TS_KIND__ file\n"), "file")
        compare(SL.parseKind("warning\n__TS_KIND__ slide mp3\n"), "mp3")
        // A codec the segments cannot hold, and a word too many.
        compare(SL.parseKind("__TS_KIND__ slide flac\n"), "")
        compare(SL.parseKind("__TS_KIND__ slide mp3 aac\n"), "")
        compare(SL.parseKind("__TS_KIND__ slide\n"), "")
        compare(SL.parseKind("__TS_KIND__ none\n"), "")
        compare(SL.parseKind("__TS_KIND__ \n"), "")
        compare(SL.parseKind("slide mp3\n"), "")
        compare(SL.parseKind(""), "")
        var none = [null, undefined, 7, {}, []];
        for (var i = 0; i < none.length; i++) compare(SL.parseKind(none[i]), "", String(none[i]))
        compare(SL.parseKind(), "")
        compare(SL.parseKind(new Array(20000).join("x") + "\n__TS_KIND__ file\n"), "file")
    }

    // ── the commands ────────────────────────────────────────────────────

    readonly property var w: ({
        cfgPath: "/c/onair-timeshift-48/url-7.cfg", dirPath: "/c/onair-timeshift-48",
        slidePath: "/c/onair-timeshift-48/buffer-7.hls", outPath: "/c/onair-timeshift-48/buffer-7.mka",
        pidPath: "/c/onair-timeshift-48/writer-7.pid", headPath: "/c/onair-timeshift-48/head-7.bin",
        kindPath: "/c/onair-timeshift-48/kind-7.txt", probePath: "/p/ui/streamkind.py",
        guardPath: "/p/ui/tsguard.sh", windowMin: 60, needKiB: 122880, seq: 7
    })

    function _with(over) {
        var o = {}, k;
        for (k in w) o[k] = w[k];
        for (k in over) o[k] = over[k];
        return o;
    }

    function test_the_writer_looks_before_it_cuts_and_never_names_the_address() {
        var c = SL.buildWriter(w);
        verify(c.indexOf(": TS_RUN;") === 0)
        verify(/ # 7$/.test(c))
        // One connection, curl's, with the address in its config file.
        compare(c.split("curl -sS").length, 2)
        verify(c.indexOf("-K '/c/onair-timeshift-48/url-7.cfg'") !== -1)
        verify(c.indexOf("://") === -1)
        // curl hands the stream on as it comes. Left to fill its 4 KiB
        // first, it is how a stop travels that slows down: ffmpeg, cat and
        // curl each learn of it with the next block. Measured on a 2 kB/s
        // station: the three were gone 3, 5 and 7 s after the stop.
        verify(c.indexOf("curl -sS -N -L ") !== -1)
        // A stream that stops for half a minute ends the writer, and the
        // writer does not join the station again: the segments would go on
        // with a hole in them that the engine's clock knows nothing of.
        verify(c.indexOf(" --speed-limit 1 --speed-time 30 | ") !== -1)
        verify(c.indexOf("--retry") === -1)
        // The first bytes go to a file, the helper names the codec, and
        // ffmpeg is given those bytes back before the rest.
        verify(c.indexOf("head -c " + SL.HEAD_BYTES + " <&3 > '/c/onair-timeshift-48/head-7.bin'") !== -1)
        verify(c.indexOf("'/p/ui/streamkind.py' --codec '/c/onair-timeshift-48/head-7.bin'") !== -1)
        compare(c.split("cat '/c/onair-timeshift-48/head-7.bin'").length, 3)
        // MP3 and AAC are cut; whole seconds, the window as the list size.
        verify(c.indexOf("mp3|aac)") !== -1)
        verify(c.indexOf("-f hls -hls_time " + SL.SEG_SEC + " -hls_list_size 1800 ") !== -1)
        verify(c.indexOf("-hls_segment_type mpegts") !== -1)
        verify(c.indexOf("delete_segments+temp_file") !== -1)
        verify(c.indexOf("-hls_segment_filename '/c/onair-timeshift-48/buffer-7.hls/seg-%d.ts'") !== -1)
        // Anything else is today's single file, with today's cap.
        verify(c.indexOf("-c copy -flush_packets 1 -t 3600 -y '/c/onair-timeshift-48/buffer-7.mka'") !== -1)
        verify(c.indexOf("timeout --signal=INT --kill-after=30 3960 cat <&3") !== -1)
        // The decision is written down for the wait, the writer's pid with
        // its owner for the guard and the sweep, and the exit is told.
        verify(c.indexOf("> '/c/onair-timeshift-48/kind-7.txt'") !== -1)
        verify(c.indexOf("echo \"$fp $$ $PPID\" > '/c/onair-timeshift-48/writer-7.pid'") !== -1)
        verify(c.indexOf("bash '/p/ui/tsguard.sh' watch \"$$\" \"$PPID\" \"$fp\"") !== -1)
        // The guard is born inside the pipe that carries the stream. Left with
        // that pipe as its input it kept curl from noticing the writer was
        // gone: measured, curl and the run's shell outlived a stop until the
        // guard's next look, up to five seconds on.
        verify(c.indexOf("watch \"$$\" \"$PPID\" \"$fp\" </dev/null >/dev/null 2>&1 3<&- & ") !== -1)
        verify(c.indexOf("__TS_EXIT__ rc=$rc") !== -1)
        verify(c.indexOf("__TS_NOSPACE__") !== -1)
        verify(c.indexOf("-lt 122880 ]") !== -1)
    }

    function test_a_writer_that_was_stopped_while_it_looked_starts_nothing() {
        // A stop that comes before the pid is written down has nobody to
        // signal. It takes the address file, and the writer asks for that
        // file twice: before it starts ffmpeg, and once the pid is down.
        var c = SL.buildWriter(w);
        var look = c.indexOf("--codec"), ask1 = c.indexOf("[ -e '/c/onair-timeshift-48/url-7.cfg' ] || exit 0; "),
            cut = c.indexOf("-f hls"), pid = c.indexOf("> '/c/onair-timeshift-48/writer-7.pid'"),
            ask2 = c.indexOf("[ -e '/c/onair-timeshift-48/url-7.cfg' ] || kill -INT \"$fp\" 2>/dev/null; "),
            wait = c.indexOf("wait $fp");
        verify(look > 0 && look < ask1 && ask1 < cut && cut < pid && pid < ask2 && ask2 < wait)
        // Before the folder is made, so a stopped arm leaves none behind.
        verify(ask1 < c.indexOf("mkdir -p '/c/onair-timeshift-48/buffer-7.hls'"))
    }

    function test_the_writer_follows_the_window_and_quotes_every_path() {
        verify(SL.buildWriter(_with({ windowMin: 5 })).indexOf("-hls_list_size 150 ") !== -1)
        verify(SL.buildWriter(_with({ windowMin: 5 })).indexOf(" -t 300 -y ") !== -1)
        verify(SL.buildWriter(_with({ windowMin: 240 })).indexOf("-hls_list_size 7200 ") !== -1)
        verify(SL.buildWriter(_with({ windowMin: 9999 })).indexOf("-hls_list_size 7200 ") !== -1)
        verify(SL.buildWriter(_with({ windowMin: "x" })).indexOf("-hls_list_size 1800 ") !== -1)
        // A cache folder with a quote and a space in its name.
        var odd = "/home/o'brien/my cache/onair-timeshift-48";
        var c = SL.buildWriter(_with({ dirPath: odd, slidePath: odd + "/buffer-7.hls", cfgPath: odd + "/url-7.cfg",
                                       outPath: odd + "/buffer-7.mka", pidPath: odd + "/writer-7.pid",
                                       headPath: odd + "/head-7.bin", kindPath: odd + "/kind-7.txt" }));
        verify(c.indexOf("'/home/o'\\''brien/my cache/onair-timeshift-48/buffer-7.hls/seg-%d.ts'") !== -1)
        verify(c.indexOf("o'brien") === -1)
        // Without a guard script the writer still runs; without a place to
        // write it does not.
        verify(SL.buildWriter(_with({ guardPath: "" })).indexOf("tsguard") === -1)
        verify(SL.buildWriter(_with({ guardPath: "" })).indexOf(": TS_RUN;") === 0)
        var need = ["cfgPath", "dirPath", "slidePath", "outPath", "pidPath", "headPath", "kindPath", "probePath"];
        for (var i = 0; i < need.length; i++) {
            var gone = {};
            gone[need[i]] = "";
            compare(SL.buildWriter(_with(gone)), "", need[i])
        }
        compare(SL.buildWriter(_with({ seq: undefined })), "")
        compare(SL.buildWriter(_with({ seq: -1 })), "")
        compare(SL.buildWriter(_with({ slidePath: "/c/onair-timeshift-48/buffer-7" })), "")
        compare(SL.buildWriter(null), "")
        compare(SL.buildWriter(), "")
    }

    function test_the_wait_answers_with_the_writers_decision() {
        var c = SL.buildKindWait({ kindPath: "/c/d/kind-7.txt", seq: 9 });
        verify(c.indexOf(": TS_KIND;") === 0)
        verify(/ # 9$/.test(c))
        verify(c.indexOf("[ -s '/c/d/kind-7.txt' ]") !== -1)
        verify(c.indexOf("__TS_KIND__ $(cat '/c/d/kind-7.txt')") !== -1)
        verify(c.indexOf("__TS_KIND__ none") !== -1)
        // Twenty seconds: eighty looks, a quarter of a second apart. The
        // engine asks three times, so a station has a minute to send 4 KiB.
        verify(c.indexOf("while [ $i -lt 80 ]; do") !== -1 && c.indexOf("sleep 0.25; done") !== -1)
        compare(SL.buildKindWait({ kindPath: "", seq: 9 }), "")
        compare(SL.buildKindWait({ kindPath: "/c/d/kind-7.txt" }), "")
        compare(SL.buildKindWait(null), "")
        compare(SL.buildKindWait(), "")
        verify(SL.buildKindWait({ kindPath: "/it's/kind.txt", seq: 0 }).indexOf("'/it'\\''s/kind.txt'") !== -1)
    }

    function test_the_folder_commands_hand_the_helper_paths_and_text() {
        var base = { scriptPath: "/p/ui/tsslide.sh", slidePath: "/c/d/buffer-7.hls", seq: 11 };
        var h = SL.buildHave(base);
        compare(h, ": TS_HAVE; bash '/p/ui/tsslide.sh' have '/c/d/buffer-7.hls' 2>/dev/null; true # 11")
        var wr = SL.buildWrite({ scriptPath: base.scriptPath, slidePath: base.slidePath, seq: 12,
                                 listName: "play-3.m3u8", text: SL.listText(125, 127), upto: 127 });
        verify(wr.indexOf(": TS_LIST; printf '%s' '#EXTM3U\n") === 0)
        verify(wr.indexOf("seg-127.ts\n' | bash '/p/ui/tsslide.sh' write '/c/d/buffer-7.hls' 'play-3.m3u8' 127 2>/dev/null; true # 12") !== -1)
        var g = SL.buildGrow({ scriptPath: base.scriptPath, slidePath: base.slidePath, seq: 13,
                               listName: "play-3.m3u8", text: SL.entriesText(128, 130), from: 128, upto: 130 });
        verify(g.indexOf(": TS_GROW; printf '%s' '#EXTINF:") === 0)
        verify(g.indexOf("| bash '/p/ui/tsslide.sh' grow '/c/d/buffer-7.hls' 'play-3.m3u8' 128 130 2>/dev/null; true # 13") !== -1)
        // A list's name is a bare file name of this widget's making.
        compare(SL.buildWrite({ scriptPath: base.scriptPath, slidePath: base.slidePath, seq: 1,
                                listName: "../x.m3u8", text: "x", upto: 1 }), "")
        compare(SL.buildWrite({ scriptPath: base.scriptPath, slidePath: base.slidePath, seq: 1,
                                listName: "play-3.m3u8", text: "", upto: 1 }), "")
        compare(SL.buildGrow({ scriptPath: base.scriptPath, slidePath: base.slidePath, seq: 1,
                               listName: "play-3.m3u8", text: "x", from: 5, upto: 4 }), "")
        compare(SL.buildHave({ scriptPath: "", slidePath: base.slidePath, seq: 1 }), "")
        compare(SL.buildHave({ scriptPath: base.scriptPath, slidePath: "", seq: 1 }), "")
        compare(SL.buildHave({ scriptPath: base.scriptPath, slidePath: base.slidePath }), "")
        compare(SL.buildHave(null), "")
        compare(SL.buildWrite(), "")
        compare(SL.buildGrow(), "")
        verify(SL.buildHave({ scriptPath: "/it's/tsslide.sh", slidePath: "/a b/buffer-1.hls", seq: 2 })
               .indexOf("bash '/it'\\''s/tsslide.sh' have '/a b/buffer-1.hls'") !== -1)
    }

    function test_a_park_that_reaches_the_edge_of_what_is_kept_ends_the_capture() {
        var keep = 300000;   // a window of five minutes
        compare(SL.PARK_END_MS, 30000)
        // A pause a minute old: the buffer slides on.
        verify(!SL.parkEndsCapture(100000, 160000, keep))
        // Thirty seconds before the pause would leave the window, to the
        // millisecond, and whenever after.
        verify(!SL.parkEndsCapture(100000, 100000 + keep - SL.PARK_END_MS - 1, keep))
        verify(SL.parkEndsCapture(100000, 100000 + keep - SL.PARK_END_MS, keep))
        verify(SL.parkEndsCapture(100000, 100000 + keep + 5000, keep))
        // A park at the buffer's start, as one stepped all the way back is.
        verify(!SL.parkEndsCapture(0, 1000, keep))
        verify(SL.parkEndsCapture(0, keep, keep))
        // No park, and a park ahead of the clock.
        verify(!SL.parkEndsCapture(-1, 1e9, keep))
        verify(!SL.parkEndsCapture(200000, 100000, keep))
        // A window nobody set: nothing is ended on its account.
        verify(!SL.parkEndsCapture(100000, 500000, 0))
        verify(!SL.parkEndsCapture(100000, 500000, SL.PARK_END_MS))
        for (var i = 0; i < junk.length; i++) {
            verify(!SL.parkEndsCapture(junk[i], 500000, keep), "park " + String(junk[i]))
            verify(!SL.parkEndsCapture(100000, junk[i], keep), "run " + String(junk[i]))
            verify(!SL.parkEndsCapture(100000, 500000, junk[i]), "keep " + String(junk[i]))
        }
        verify(!SL.parkEndsCapture())
        // Four hours of window, a week of pause.
        verify(SL.parkEndsCapture(1e9, 1e9 + 7 * 86400000, 14400000))
    }

    function test_the_end_of_a_capture_signals_the_writer_and_removes_nothing() {
        var c = SL.buildEnd({ pidPath: "/c/d/writer-7.pid", seq: 12 });
        verify(c.indexOf(": TS_END;") === 0)
        verify(/ # 12$/.test(c))
        verify(c.indexOf("[ -f '/c/d/writer-7.pid' ] && read -r p _ < '/c/d/writer-7.pid' && kill -INT \"$p\" 2>/dev/null") !== -1)
        // What was cut stays where it is: that is the difference to a stop.
        verify(c.indexOf("rm ") === -1)
        verify(SL.buildEnd({ pidPath: "/it's/writer-1.pid", seq: 0 }).indexOf("'/it'\\''s/writer-1.pid'") !== -1)
        compare(SL.buildEnd({ pidPath: "", seq: 12 }), "")
        compare(SL.buildEnd({ pidPath: "/c/d/writer-7.pid" }), "")
        compare(SL.buildEnd({ pidPath: "/c/d/writer-7.pid", seq: "x" }), "")
        compare(SL.buildEnd(null), "")
        compare(SL.buildEnd(), "")
    }

    function test_the_stop_frees_the_player_first_and_takes_only_its_own_folder() {
        var c = SL.buildStop({ pidPath: "/c/d/writer-7.pid", slidePath: "/c/d/buffer-7.hls", cfgPath: "/c/d/url-7.cfg",
                               headPath: "/c/d/head-7.bin", kindPath: "/c/d/kind-7.txt", outPath: "/c/d/buffer-7.mka", seq: 21 });
        verify(c.indexOf(": TS_STOP;") === 0)
        verify(/ # 21$/.test(c))
        // The lists go before anything else: a reader waiting on one is let
        // go by its going, and the sleep below would hold it a second more.
        // The address file goes before the signal: it is the only word a
        // writer that has no pid down yet will ever get.
        var lists = c.indexOf("rm -f '/c/d/buffer-7.hls'/play-*.m3u8"), cfg = c.indexOf("rm -f '/c/d/url-7.cfg'; "),
            kill = c.indexOf("kill -INT"), nap = c.indexOf("sleep 1"), dir = c.indexOf("rm -rf '/c/d/buffer-7.hls'");
        verify(lists > 0 && lists < cfg && cfg < kill && kill < nap && nap < dir)
        verify(c.indexOf("read -r p _ < '/c/d/writer-7.pid'") !== -1)
        verify(c.indexOf("'/c/d/buffer-7.mka'") !== -1)
        verify(c.indexOf("'/c/d/head-7.bin'") !== -1)
        verify(c.indexOf("'/c/d/kind-7.txt'") !== -1)
        // Only a folder of this widget's own naming is removed whole.
        var bad = ["", "/", "/c/d", "/c/d/buffer-7", "/c/d/buffer-7.hls/", "/c/d/buffer-7.hls/..", ".hls", null, undefined, 7];
        for (var i = 0; i < bad.length; i++)
            compare(SL.buildStop({ pidPath: "/c/d/writer-7.pid", slidePath: bad[i], cfgPath: "/c/d/url-7.cfg",
                                   headPath: "/c/d/h", kindPath: "/c/d/k", outPath: "/c/d/o", seq: 1 }), "", String(bad[i]))
        compare(SL.buildStop({ pidPath: "", slidePath: "/c/d/buffer-7.hls", cfgPath: "/c/d/url-7.cfg",
                               headPath: "/c/d/h", kindPath: "/c/d/k", outPath: "/c/d/o", seq: 1 }), "")
        compare(SL.buildStop(null), "")
        compare(SL.buildStop(), "")
        verify(SL.buildStop({ pidPath: "/a b/writer-7.pid", slidePath: "/a b/it's/buffer-7.hls", cfgPath: "/a b/url-7.cfg",
                              headPath: "/a b/h", kindPath: "/a b/k", outPath: "/a b/o", seq: 1 })
               .indexOf("rm -rf '/a b/it'\\''s/buffer-7.hls'") !== -1)
    }
}
