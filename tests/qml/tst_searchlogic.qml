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

    function test_probe_safe_host_blocks_literal_private_addresses() {
        // The catalogue is publicly writable — a crafted entry must not
        // aim the probe's GET at the user's own machine or network.
        verify(!SL.isProbeSafeHost("http://localhost:8000/stream"));
        verify(!SL.isProbeSafeHost("http://127.0.0.1/stream"));
        verify(!SL.isProbeSafeHost("http://127.8.9.10/stream"));      // whole /8
        verify(!SL.isProbeSafeHost("http://10.0.0.5:8080/live"));
        verify(!SL.isProbeSafeHost("http://172.16.0.1/x"));
        verify(!SL.isProbeSafeHost("http://172.31.255.254/x"));
        verify(!SL.isProbeSafeHost("http://192.168.1.1/x"));
        verify(!SL.isProbeSafeHost("http://169.254.1.1/x"));
        verify(!SL.isProbeSafeHost("http://user:pass@127.0.0.1/x"));  // userinfo hides nothing
        verify(!SL.isProbeSafeHost("http://[::1]:8000/x"));
        verify(!SL.isProbeSafeHost("http://[fc00::1]/x"));
        verify(!SL.isProbeSafeHost("http://[fd12:3456::1]/x"));
        verify(!SL.isProbeSafeHost("http://[fe80::1%25eth0]/x"));     // zone id included
        verify(!SL.isProbeSafeHost(""));
    }

    function test_probe_safe_host_passes_public_and_dns_hosts() {
        // Literal-only by design: QML has no resolver, so a DNS name that
        // resolves privately (rebinding) cannot be caught here.
        verify(SL.isProbeSafeHost("http://stream.example.com/live"));
        verify(SL.isProbeSafeHost("https://user:pass@radio.example.org:8000/x"));
        verify(SL.isProbeSafeHost("http://93.184.216.34/stream"));
        verify(SL.isProbeSafeHost("http://172.15.0.1/x"));            // outside the /12
        verify(SL.isProbeSafeHost("http://172.32.0.1/x"));
        verify(SL.isProbeSafeHost("http://192.169.0.1/x"));
        verify(SL.isProbeSafeHost("http://[2001:db8::1]/x"));
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
