// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The heal ladder's ranking rules. The directory is publicly writable and
// name-matched entries from it audition in this exact order — the order IS
// the product decision, so it lives under tests.
import QtQuick
import QtTest

import "../../package/contents/ui/HealLogic.js" as HL

TestCase {
    name: "HealLogic"

    function test_norm_name_collapses_noise() {
        compare(HL.normName("  Radio   NOVA  "), "radio nova");
        compare(HL.normName(null), "");
    }

    function test_score_exact_beats_contains_and_home_domain_beats_both() {
        compare(HL.scoreRow("radio nova", "radio nova", false), 2);
        compare(HL.scoreRow("radio nova fm", "radio nova", false), 1);
        compare(HL.scoreRow("radio nova", "radio nova", true), 4);
        compare(HL.scoreRow("something else", "radio nova", false), -1);
        compare(HL.scoreRow("anything", "", false), -1);  // no name, no guesses
    }

    function test_rank_prefers_score_then_bitrate() {
        var out = HL.rank([
            { url: "http://a/128", score: 2, bitrate: 128 },
            { url: "http://b/320", score: 2, bitrate: 320 },
            { url: "http://c/home", score: 4, bitrate: 64 },
        ]);
        compare(out[0], "http://c/home");   // home domain outranks any bitrate
        compare(out[1], "http://b/320");    // then the better stream wins
        compare(out[2], "http://a/128");
    }

    function test_rank_sinks_hls_to_the_bottom_but_keeps_it() {
        var out = HL.rank([
            { url: "http://h/live.m3u8", score: 4, bitrate: 320, hls: true },
            { url: "http://p/plain", score: 1, bitrate: 64 },
        ]);
        compare(out.length, 2);
        compare(out[0], "http://p/plain");      // any real stream first
        compare(out[1], "http://h/live.m3u8");  // HLS is the last door, not no door
    }

    function test_rank_dedupes_keeping_the_best_position() {
        var out = HL.rank([
            { url: "http://same", score: 4, bitrate: 128 },
            { url: "http://other", score: 2, bitrate: 128 },
            { url: "http://same", score: 1, bitrate: 320 },
        ]);
        compare(out, ["http://same", "http://other"]);
    }
}
