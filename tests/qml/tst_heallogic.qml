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
        compare(out[0].url, "http://c/home");   // home domain outranks any bitrate
        compare(out[1].url, "http://b/320");    // then the better stream wins
        compare(out[2].url, "http://a/128");
    }

    function test_rank_sinks_hls_to_the_bottom_but_keeps_it() {
        var out = HL.rank([
            { url: "http://h/live.m3u8", score: 4, bitrate: 320, hls: true },
            { url: "http://p/plain", score: 1, bitrate: 64 },
        ]);
        compare(out.length, 2);
        compare(out[0].url, "http://p/plain");      // any real stream first
        compare(out[1].url, "http://h/live.m3u8");  // HLS is the last door, not no door
    }

    function test_rank_dedupes_keeping_the_best_position() {
        var out = HL.rank([
            { url: "http://same", score: 4, bitrate: 128 },
            { url: "http://other", score: 2, bitrate: 128 },
            { url: "http://same", score: 1, bitrate: 320 },
        ]);
        compare(out.length, 2);
        compare(out[0].url, "http://same");
        compare(out[1].url, "http://other");
    }

    function test_rank_carries_the_exact_name_verdict_through() {
        // The commit gate reads each candidate's exact flag AFTER ranking
        // and dedup — a rank that dropped it would quietly demote every
        // legitimate own-domain repair to a session stopgap.
        var out = HL.rank([
            { url: "http://same", score: 4, bitrate: 128, exact: true },
            { url: "http://same", score: 1, bitrate: 320, exact: false },
        ]);
        compare(out.length, 1);
        compare(out[0].exact, true);   // the best position keeps its verdict
    }

    function test_a_shared_streaming_host_is_a_landlord_not_a_home() {
        verify(HL.sharedBase("zeno.fm"));
        verify(HL.sharedBase("streamtheworld.com"));
        verify(HL.sharedBase("ZENO.FM"));          // case must not matter
        verify(!HL.sharedBase("somafm.com"));      // one broadcaster, one roof
        verify(!HL.sharedBase("err.ee"));
        verify(!HL.sharedBase(""));
        verify(!HL.sharedBase(null));
    }

    function test_the_commit_gate_demands_identity_not_similarity() {
        // The directory's own uuid row IS the station — always permanent.
        compare(HL.commitVerdict(true, "err.ee", "elsewhere.net", false), "permanent");
        // A foreign domain never writes, however good the name looked.
        compare(HL.commitVerdict(false, "err.ee", "elsewhere.net", true), "stopgap");
        // The station's own roof, same exact name: it moved a port/mount.
        compare(HL.commitVerdict(false, "err.ee", "err.ee", true), "permanent");
        // Same roof but only a contains-match: "Smooth Jazz Radio" is not
        // the user's "Jazz" — this exact class once rewrote a saved
        // station into a different tenant for good.
        compare(HL.commitVerdict(false, "err.ee", "err.ee", false), "stopgap");
        // A shared host proves nothing even with the exact name: two
        // tenants of zeno.fm can carry the same generic name.
        compare(HL.commitVerdict(false, "zeno.fm", "zeno.fm", true), "stopgap");
        // No base to compare against — no write.
        compare(HL.commitVerdict(false, "", "", true), "stopgap");
    }
}
