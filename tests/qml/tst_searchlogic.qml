// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The search's matching rules. The directory only does substring matches
// and only ranks by fame — these functions decide what the user MEANT, so
// the decisions live under tests.
import QtQuick
import QtTest

import "../../package/contents/ui/SearchLogic.js" as SL

TestCase {
    name: "SearchLogic"

    function test_fold_is_case_and_accent_blind() {
        compare(SL.fold("Järviradio"), "jarviradio");
        compare(SL.fold("  Radio   NOVA  "), "radio nova");
        compare(SL.fold("Šveits Türgi"), "sveits turgi");
        compare(SL.fold(null), "");
    }

    function test_words_splits_the_folded_query() {
        compare(SL.words("Radio  Nova"), ["radio", "nova"]);
        compare(SL.words("   "), []);
    }

    function test_longest_word_stays_unfolded_for_the_server() {
        // The directory compares accents literally — the word it is asked
        // for must be the one the user typed. Ties keep the first word.
        compare(SL.longestWord("Järvi radio"), "Järvi");
        compare(SL.longestWord("fm Järviradio"), "Järviradio");
        compare(SL.longestWord(""), "");
    }

    function test_matches_all_words_any_order_fold_blind() {
        verify(SL.matchesAllWords("Radio Nova", SL.words("nova radio")));
        verify(SL.matchesAllWords("Järviradio", SL.words("jarvi")));
        verify(!SL.matchesAllWords("Radio Nova", SL.words("nova jazz")));
        verify(!SL.matchesAllWords("anything", []));
    }

    function test_relevance_exact_then_prefix_then_rest() {
        compare(SL.relevance("NRJ Suomi", "nrj suomi"), 0);   // the name IS the query
        compare(SL.relevance("NRJ Suomi Hits", "nrj suomi"), 1);
        compare(SL.relevance("Radio NRJ Suomi", "nrj suomi"), 2);
        compare(SL.relevance("anything", ""), 2);             // empty query boosts nothing
    }

    function test_stems_shave_the_inflected_tail() {
        compare(SL.stems("elmari"), ["elmar", "elma"]);   // genitive → nominative
        compare(SL.stems("elmar"), ["elma"]);             // never below four left
        compare(SL.stems("nova"), []);                    // short queries stay whole
        compare(SL.stems("  "), []);
    }

    function test_probe_verdict_reads_the_status_line() {
        compare(SL.probeVerdict(200), 1);    // a live mount
        compare(SL.probeVerdict(206), 1);
        compare(SL.probeVerdict(404), 0);    // a dead mount, definitively
        compare(SL.probeVerdict(403), 0);    // geo-blocks read as forbidden
        compare(SL.probeVerdict(410), 0);
        compare(SL.probeVerdict(429), -1);   // a throttle is not a death certificate
        compare(SL.probeVerdict(460), -1);   // CDN rate limiter, measured live
        compare(SL.probeVerdict(503), -1);   // a server hiccup is not a dead station
        compare(SL.probeVerdict(0), -1);     // transport error: unknown, not dead
    }
}
