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

    function test_probe_safe_host_blocks_every_alternate_spelling() {
        // An address has more spellings than a dotted quad. Qt's URL layer
        // resolves inet_aton's dialects (verified live: 2130706433,
        // 0177.0.0.1 and 127.1 all connect to 127.0.0.1), glibc resolves a
        // trailing root dot, and IPv6 embeds IPv4 two ways — the guard
        // (HostGuard.js, shared with the settings pages) must read them all.
        verify(!SL.isProbeSafeHost("http://[::ffff:127.0.0.1]/x"));   // mapped, dotted
        verify(!SL.isProbeSafeHost("http://[::ffff:7f00:1]/x"));      // mapped, hex
        verify(!SL.isProbeSafeHost("http://[::ffff:192.168.1.1]/x"));
        verify(!SL.isProbeSafeHost("http://[0:0:0:0:0:0:0:1]/x"));    // loopback, longhand
        verify(!SL.isProbeSafeHost("http://[::0:1]/x"));              // loopback, partial run
        verify(!SL.isProbeSafeHost("http://[::]/x"));                 // unspecified
        verify(!SL.isProbeSafeHost("http://2130706433/x"));           // decimal 127.0.0.1
        verify(!SL.isProbeSafeHost("http://127.1/x"));                // shortened
        verify(!SL.isProbeSafeHost("http://0177.0.0.1/x"));           // octal
        verify(!SL.isProbeSafeHost("http://0x7f.0.0.1/x"));           // hex
        verify(!SL.isProbeSafeHost("http://0.0.0.0/x"));              // routes to loopback
        verify(!SL.isProbeSafeHost("http://localhost./x"));           // DNS root dot
        verify(!SL.isProbeSafeHost("http://sub.localhost/x"));        // RFC 6761 subdomains
        verify(!SL.isProbeSafeHost("http://a@b@127.0.0.1/x"));        // the LAST @ ends userinfo
        // Qt DECODES before it dials: a percent-encoded or unicode host
        // reads as gibberish here and as 127.0.0.1 on the wire. Anything
        // the parser cannot take literally is refused.
        verify(!SL.isProbeSafeHost("http://%31%32%37.0.0.1/x"));      // decodes to 127.0.0.1
        verify(!SL.isProbeSafeHost("http://127.0.0.%31/x"));
        verify(!SL.isProbeSafeHost("http://ⓛocalhost/x"));            // IDN-normalizes
        verify(!SL.isProbeSafeHost("http://𝟏𝟐𝟕.0.0.1/x"));            // mathematical digits
        // Carrier-grade NAT — and every Tailscale node's address.
        verify(!SL.isProbeSafeHost("http://100.64.0.1/x"));
        verify(!SL.isProbeSafeHost("http://100.127.255.254/x"));
        // ...and the spellings must not swallow the public internet.
        verify(SL.isProbeSafeHost("http://0x08.0x08.0x08.0x08/x"));   // 8.8.8.8
        verify(SL.isProbeSafeHost("http://[::ffff:8.8.8.8]/x"));      // mapped public
        verify(SL.isProbeSafeHost("http://10.or.at/x"));              // hostname, not a quad
        verify(SL.isProbeSafeHost("http://999.1.2.3/x"));             // not inet_aton-valid
        verify(SL.isProbeSafeHost("http://fcstation.example/x"));     // fc-prefixed NAME
        verify(SL.isProbeSafeHost("http://100.63.255.254/x"));        // below the CGNAT range
        verify(SL.isProbeSafeHost("http://100.128.0.1/x"));           // above it
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

    // The country map the resolver callback stands in for in these tests.
    function _cc(name) {
        var map = { "uk": "GB", "finland": "FI", "new zealand": "NZ",
                    "france": "FR" }
        var k = (name || "").toLowerCase()
        return map[k] !== undefined ? map[k] : ""
    }

    function test_scoped_query_splits_genre_in_country() {
        var r = SL.scopedQuery("70s in UK", _cc)
        compare(r.text, "70s"); compare(r.cc, "GB"); compare(r.country, "UK")
        r = SL.scopedQuery("jazz from France", _cc)
        compare(r.text, "jazz"); compare(r.cc, "FR")
        // Multiword country and multiword genre both survive.
        r = SL.scopedQuery("classic rock in new zealand", _cc)
        compare(r.text, "classic rock"); compare(r.cc, "NZ")
    }

    function test_scoped_query_leaves_band_names_alone() {
        // "chains" is no country — the resolver said no, one query stays one.
        compare(SL.scopedQuery("alice in chains", _cc), null)
        compare(SL.scopedQuery("in flames", _cc), null)      // no text before
        compare(SL.scopedQuery("radio france", _cc), null)   // no separator
        compare(SL.scopedQuery("", _cc), null)
        // A later separator wins when the first tail is not a country.
        var r = SL.scopedQuery("stuck in the middle from uk", _cc)
        compare(r.text, "stuck in the middle"); compare(r.cc, "GB")
    }


    function test_a_short_artist_name_still_finds_its_record() {
        // The old rule let a name under four characters match only by being
        // identical, so a station line with the guests in it found nothing:
        // measured, all three of these returned no cover at all.
        verify(SL.nameAkin("nas & damian marley", "nas"))
        verify(SL.nameAkin("sia", "sia feat. sean paul"))
        verify(SL.nameAkin("eve", "eve feat. gwen stefani"))
        // ...and the case the rule was written against still holds: a short
        // name may not match its way through the middle of another name.
        verify(!SL.nameAkin("ac", "dc and ac company"))
        verify(!SL.nameAkin("ab", "abba"))          // no word boundary
        verify(!SL.nameAkin("u", "u2"))             // one character names nobody
        verify(SL.nameAkin("u2", "u2 & the edge"))
        verify(!SL.nameAkin("u2", "u2 live"))     // not a collaboration line
    }

    function test_country_flag_from_iso_code() {
        compare(SL.countryFlag("GB"), "🇬🇧")
        compare(SL.countryFlag("fi"), "🇫🇮")   // case-blind
        compare(SL.countryFlag(""), "")
        compare(SL.countryFlag("G"), "")
        compare(SL.countryFlag("GBR"), "")
        compare(SL.countryFlag("1!"), "")
    }

    function test_download_pick_treats_numbers_as_identity() {
        // The measured case: the stream said episode 659, the search's #1
        // was the more famous 600 Special. 659 in the query must appear in
        // the title as its own number — 600 is not "close".
        var found = ["Ori Uplift - Uplifting Only 600 Special [No Talking] (Aug 8, 2024)",
                     "He Only Goes Outside for the Ice Cream Man | My 600-lb Life",
                     "Ori Uplift - Uplifting Only Episode 659 (full set)"]
        compare(SL.downloadPick("Ori Uplift - Uplifting Only Episode 659 Replay", found), 2)
        // With the right episode absent, refusing beats the wrong one.
        compare(SL.downloadPick("Ori Uplift - Uplifting Only Episode 659 Replay",
                                [found[0], found[1]]), -1)
        // No numbers in the query: words decide, search order breaks ties.
        compare(SL.downloadPick("Armin van Buuren - Great Spirit",
                                ["Armin van Buuren feat. Vini Vici - Great Spirit (Extended)",
                                 "Something Else Entirely"]), 0)
        // A candidate sharing no words at all never qualifies.
        compare(SL.downloadPick("Great Spirit", ["Something Else Entirely"]), -1)
        compare(SL.downloadPick("anything", []), -1)
    }

    function test_country_display_name_only_trusts_an_exact_locale() {
        compare(SL.countryDisplayName("FI", "en_US"), "Finland")
        compare(SL.countryDisplayName("DE", "en_US"), "Germany")
        // The listener's own language when the CLDR really carries the pair…
        compare(SL.countryDisplayName("EE", "et_EE"), "Eesti")
        // …but Qt's silent fallback must not smuggle the wrong country in:
        // measured, Qt.locale("et_FI") answers as et_EE ("Eesti") and
        // Qt.locale("en_ZZ") as en_US ("United States"). The name check
        // rejects both — et_FI falls through to English, ZZ to the bare code.
        compare(SL.countryDisplayName("FI", "et_FI"), "Finland")
        compare(SL.countryDisplayName("ZZ", "en_US"), "ZZ")
        compare(SL.countryDisplayName("", "en_US"), "")
        compare(SL.countryDisplayName("usa", "en_US"), "")
    }

    function test_stems_never_split_a_surrogate_pair() {
        // A name ending in an emoji: the shave must drop the whole code
        // point, or encodeURIComponent throws on the lone surrogate later.
        var out = SL.stems("abcd🎶")
        // Both cuts land on the emoji, the whole pair goes, dupes collapse.
        compare(out.length, 1)
        compare(out[0], "abcd")
        for (var i = 0; i < out.length; i++)
            encodeURIComponent(out[i])   // throws on a broken pair
        compare(SL.stems("ab🎶").length, 0)
        // The plain path is untouched: one letter, then two.
        var el = SL.stems("Elmari")
        compare(el.length, 2)
        compare(el[0], "Elmar"); compare(el[1], "Elma")
    }

    function test_clean_label_strips_markup_and_caps_length() {
        compare(SL.cleanLabel("  Radio   <b>X</b> & Co  "), "Radio b X /b Co")
        compare(SL.cleanLabel("plain"), "plain")
        compare(SL.cleanLabel(null), "")
        compare(SL.cleanLabel("x".repeat(500), 60).length, 60)
        compare(SL.cleanLabel("abcdef", 3), "abc")
    }

    function test_format_votes_reads_as_a_badge() {
        compare(SL.formatVotes(0), "")
        compare(SL.formatVotes(-5), "")
        compare(SL.formatVotes(999), "999")
        compare(SL.formatVotes(1250), "1.3k")
        compare(SL.formatVotes("12304"), "12k")
        compare(SL.formatVotes("junk"), "")
        // The rounding must move up a unit instead of lying: 999500 used to
        // render as "1000k".
        compare(SL.formatVotes(999499), "999k")
        compare(SL.formatVotes(999500), "1M")
        compare(SL.formatVotes(2400000), "2.4M")
        compare(SL.formatVotes(15000000), "15M")
    }

    function test_a_shaved_stem_never_ends_in_a_space() {
        // "Elmar 😀" cut back to "Elmar " asked the directory for a name
        // with a trailing blank, which matches nothing it holds.
        var out = SL.stems("Elmar \u{1F600}")
        for (var i = 0; i < out.length; i++) {
            compare(out[i], out[i].replace(/\s+$/, ""))
            verify(out[i].length >= 4)
        }
    }

    function test_art_pick_refuses_somebody_elses_record() {
        // The measured case: an Estonian dance remix called "Veel veel veel"
        // was illustrated with a Tamil devotional album of the same name,
        // because the lookup took the search engine's first hit on faith.
        var cands = [{ artist: "Veeramanidaasan", title: "Veel veel veel" },
                     { artist: "Anaconda", title: "Veel veel veel (Remix 2025)" }]
        compare(SL.artPick("Anaconda", "Veel veel veel", cands), 1)
        // Nobody by that name among the answers: no cover beats a wrong one.
        compare(SL.artPick("Anaconda", "Veel veel veel",
                           [{ artist: "Veeramanidaasan", title: "Veel veel veel" }]), -1)
        // "feat." spellings are the same act.
        compare(SL.artPick("Anaconda", "X",
                           [{ artist: "Anaconda feat. Someone", title: "X" }]), 0)
        // Accent- and case-blind, like every other comparison here.
        compare(SL.artPick("Jarviradio", "X", [{ artist: "Järviradio", title: "X" }]), 0)
        // No artist in the stream's metadata: the title has to carry it.
        compare(SL.artPick("", "Dancing Queen", [{ artist: "ABBA", title: "Dancing Queen" }]), 0)
        compare(SL.artPick("", "Dancing Queen", [{ artist: "X", title: "Something Else" }]), -1)
        // The right artist AND the right song beats the right artist alone.
        compare(SL.artPick("Curly Strings", "Kuu",
                           [{ artist: "Curly Strings", title: "Kuule, mees!" },
                            { artist: "Curly Strings", title: "Kuu" }]), 1)
        // But one of their own records still beats a stranger's when no
        // title lines up.
        compare(SL.artPick("Curly Strings", "Kuu",
                           [{ artist: "Curly Strings", title: "Kuule, mees!" }]), 0)
        // The exact song must beat one that merely CONTAINS its name, even
        // when the containing record is listed first. The "Kuu" case above
        // passes for the wrong reason — three letters are below nameAkin's
        // length guard, so containment never even applies there. At four
        // letters it does, and both candidates used to score the same 2;
        // the strict > then handed it to whoever the service listed first,
        // and a played "Kiss" wore the sleeve of "Kiss the Sky".
        compare(SL.artPick("Prince", "Kiss",
                           [{ artist: "Prince", title: "Kiss the Sky" },
                            { artist: "Prince", title: "Kiss" }]), 1)
        compare(SL.artPick("The Beatles", "Hello",
                           [{ artist: "The Beatles", title: "Hello Goodbye" },
                            { artist: "The Beatles", title: "Hello" }]), 1)
        // Same rule where the stream names no artist and the title decides
        // alone — exact still outranks containment.
        compare(SL.artPick("", "Yellow",
                           [{ artist: "A", title: "Yellow Submarine" },
                            { artist: "B", title: "Yellow" }]), 1)
        // Containment is load-bearing and must survive the tie-break: a
        // remaster carries the original artwork and is the right answer
        // when no exact title is on offer.
        compare(SL.artPick("Queen", "Radio Ga Ga",
                           [{ artist: "Queen", title: "Radio Ga Ga - Remastered 2011" }]), 0)
        // And an exact title under the WRONG artist still loses to the
        // right artist — the artist keeps the final say.
        compare(SL.artPick("Prince", "Kiss",
                           [{ artist: "Somebody Else", title: "Kiss" },
                            { artist: "Prince", title: "Kiss the Sky" }]), 1)
        // Nothing to go on at all.
        compare(SL.artPick("", "", [{ artist: "A", title: "B" }]), -1)
        compare(SL.artPick("A", "B", []), -1)
    }

    function test_name_akin_needs_more_than_a_letter() {
        verify(SL.nameAkin("anaconda", "anaconda"))
        verify(SL.nameAkin("anaconda", "anaconda feat. x"))
        verify(!SL.nameAkin("ac", "ac/dc"))      // too short to mean anything
        verify(!SL.nameAkin("abba", "queen"))
        verify(!SL.nameAkin("", "abba"))
    }

    function test_art_pick_drops_karaoke_and_knows_initials() {
        // Measured on the panel: free text for "Bodies Without Organs —
        // Sunshine In The Rain" returns three karaoke labels and nothing
        // else. A karaoke sleeve is not this record's cover.
        var junk = [{ artist: "Zoom Karaoke", title: "Sunshine In The Rain (In The Style Of 'Bodies Without Organs BWO')" },
                    { artist: "Party Tyme Karaoke", title: "Sunshine in the Rain (Made Popular By Bodies Without Organs) [Karaoke Version]" }]
        compare(SL.artPick("Bodies Without Organs", "Sunshine In The Rain", junk), -1)
        // The catalogue files that band as "BWO" — neither name contains
        // the other, so containment alone lost the record.
        var real = [{ artist: "Shania Yan", title: "Sunshine in the Rain" },
                    { artist: "BWO", title: "Sunshine in the Rain (Radio Edit)" }]
        compare(SL.artPick("Bodies Without Organs", "Sunshine In The Rain (Radio Edit)", real), 1)
        // The bracketed tail must not decide a match either way.
        compare(SL.artCoreTitle("Enter Sandman (Remastered 2021)"), "enter sandman")
        compare(SL.artInitials("Bodies Without Organs"), "bwo")
        // A stranger with the right title is still refused — the Tamil case.
        compare(SL.artPick("Anaconda", "Veel veel veel",
                           [{ artist: "Veeramanidaasan", title: "Veel veel veel" }]), -1)
    }
}
