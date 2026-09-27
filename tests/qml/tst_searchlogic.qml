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

    function test_the_word_pass_asks_for_the_listeners_own_word() {
        // "radio" is the directory's 50 most voted names holding "radio", and
        // one of them held "nova"; asked for "nova", twenty-one did. Unfolded,
        // and the first word on a tie, like longestWord.
        compare(SL.askWord("nova radio"), "nova");
        compare(SL.askWord("Rádio Nova"), "Nova");        // folds to the station word
        compare(SL.askWord("the rock station"), "rock");
        compare(SL.askWord("radio 101"), "101");
        compare(SL.askWord("bbc radio 1"), "bbc");
        compare(SL.askWord("Järvi radio"), "Järvi");
        compare(SL.askWord("fm Järviradio"), "Järviradio");
    }

    function test_with_no_word_of_its_own_the_longest_is_asked_as_before() {
        compare(SL.askWord("radio fm"), "radio");
        compare(SL.askWord("fm 4"), "fm");                // under three letters culls nothing
        compare(SL.askWord("r1 radio"), "radio");
        compare(SL.askWord("raadio elmar"), "raadio");    // no station word typed: the longest
        compare(SL.askWord(""), "");
        compare(SL.askWord(null), "");
    }

    function test_an_http_and_an_https_twin_are_one_address() {
        // Rows 6 and 47 of name=rock by votes, measured 2026-09-21.
        compare(SL.urlKey("http://mp3channels.webradio.rockantenne.de/heavy-metal"),
                SL.urlKey("https://mp3channels.webradio.rockantenne.de/heavy-metal"));
        compare(SL.urlKey("http://Host.FM:80/live/"), "host.fm/live");
        compare(SL.urlKey("https://host.fm:443/live"), "host.fm/live");
        compare(SL.urlKey("https://icast.connectmedia.hu/5301/live.mp3/"),
                SL.urlKey("https://icast.connectmedia.hu/5301/live.mp3"));
        compare(SL.urlKey("http://ec4.yesstreaming.net:3770/"), "ec4.yesstreaming.net:3770");
        compare(SL.urlKey("HTTP://host.fm/play/?id=7#now"), "host.fm/play?id=7#now");
    }

    function test_what_names_another_stream_is_another_key() {
        verify(SL.urlKey("http://host.fm/Live") !== SL.urlKey("http://host.fm/live"));   // a mount's case counts
        verify(SL.urlKey("http://host.fm/play?id=1") !== SL.urlKey("http://host.fm/play?id=2"));
        verify(SL.urlKey("http://host.fm:8000/live") !== SL.urlKey("http://host.fm:8080/live"));
        verify(SL.urlKey("http://host.fm:443/live") !== SL.urlKey("https://host.fm/live"));
        // A relay of the same station on another host is a stream of its own.
        verify(SL.urlKey("http://stream.gal.io/arrow") !== SL.urlKey("http://stream.player.arrow.nl/arrowcr"));
        compare(SL.urlKey("  rtmp://host.fm/x "), "rtmp://host.fm/x");
        compare(SL.urlKey(null), "");
        compare(SL.urlKey(undefined), "");
    }

    function test_a_hidden_rail_never_fences_a_later_search() {
        // The chip and its ✕ live on the rail. With the rail switched off,
        // "jazz in uk" pinned GB and "raadio elmar" then ran inside Britain.
        compare(SL.scopeFor({ released: false, textCc: "", countryRole: false,
                              pinnedCc: "GB", railShown: false }), "");
        // The country the text names is the listener's word, rail or no rail.
        compare(SL.scopeFor({ released: false, textCc: "GB", countryRole: false,
                              pinnedCc: "", railShown: false }), "GB");
    }

    function test_a_visible_chip_fences_as_before() {
        compare(SL.scopeFor({ released: false, textCc: "", countryRole: false,
                              pinnedCc: "GB", railShown: true }), "GB");
        compare(SL.scopeFor({ released: false, textCc: "FI", countryRole: false,
                              pinnedCc: "GB", railShown: true }), "FI");
        compare(SL.scopeFor({ released: true, textCc: "FI", countryRole: false,
                              pinnedCc: "GB", railShown: true }), "");
        compare(SL.scopeFor({ released: false, textCc: "", countryRole: true,
                              pinnedCc: "GB", railShown: true }), "");
        compare(SL.scopeFor({ pinnedCc: "GB" }), "GB");   // no word about the rail: it is there
        compare(SL.scopeFor({}), "");
        compare(SL.scopeFor(null), "");
    }

    function test_a_bitrate_in_bps_reads_as_kbps() {
        compare(SL.kbps(128), 128);
        compare(SL.kbps("320"), 320);
        compare(SL.kbps(128000), 128);
        compare(SL.kbps(1411), 1411);     // lossless, and in kbps already
        compare(SL.kbps(7999), 7999);
        compare(SL.kbps(8000), 8);
        compare(SL.kbps(null), 0);
        compare(SL.kbps("x"), 0);
    }

    readonly property string byBitrate:
        "/json/stations/search?name=rock&hidebroken=true&order=bitrate&reverse=true&limit=50"

    function rateRow(name, bitrate, votes, codec) {
        return { "name": name, "bitrate": bitrate, "votes": votes, "codec": codec };
    }

    function rowNames(rows) {
        return rows.map(function(r) { return r.name; });
    }

    function test_the_bitrate_page_is_ordered_by_the_honest_number() {
        // The head of name=rock by bitrate as the directory gave it on
        // 2026-09-21, plus a television row and a 320 filed in bps.
        var page = [rateRow("Mellow Rock", 64000, 56, "MP4"),
                    rateRow("radio club 80 rock", 3072, 105, "OGG"),
                    rateRow("Paradise FLAC http", 1441, 24, "OGG"),
                    rateRow("Paradise FLAC https", 1441, 2860, "OGG"),
                    rateRow("Rock", 320, 7, "AAC+"),
                    rateRow("Paradise 320k", 320, 15205, "AAC"),
                    rateRow("24h Television", 3012, 3295, "AAC,H.264"),
                    rateRow("Filed in bps", 320000, 100, "MP3")];
        var got = SL.pageOrder(page, byBitrate, 30);
        compare(got.length, 8);
        compare(rowNames(got), ["radio club 80 rock", "Paradise FLAC https", "Paradise FLAC http",
                                "Paradise 320k", "Filed in bps", "Rock", "Mellow Rock",
                                "24h Television"]);
    }

    function test_only_the_rows_the_page_will_show_change_places() {
        // "Show more" asks from the position the walk reached, so the rows
        // shown have to be the first rows of the directory's own order.
        var page = [rateRow("a", 64000, 1, "MP3"), rateRow("b", 320, 5, "MP3"),
                    rateRow("c", 320, 9, "MP3"), rateRow("d", 1411, 2, "FLAC")];
        var got = SL.pageOrder(page, byBitrate, 3);
        compare(got.length, 4);
        compare(rowNames(got), ["c", "b", "a", "d"]);
        var none = SL.pageOrder(page, byBitrate, 0);
        compare(none.length, 4);
        compare(rowNames(none), ["a", "b", "c", "d"]);
    }

    function test_any_other_order_is_the_directorys_own() {
        var page = [rateRow("a", 64, 1, "MP3"), rateRow("b", 320, 5, "MP3")];
        var got = SL.pageOrder(page, byBitrate.replace("order=bitrate", "order=votes"), 30);
        compare(got.length, 2);
        compare(rowNames(got), ["a", "b"]);
        verify(SL.asksBitrate(byBitrate));
        verify(!SL.asksBitrate("/json/stations/search?name=order%3Dbitrate&order=votes&reverse=true"));
        verify(!SL.asksBitrate(null));
        // What is no list goes back untouched: the caller's own guard reads it.
        compare(SL.pageOrder(null, byBitrate, 30), null);
        var slush = { "ok": false };
        verify(SL.pageOrder(slush, byBitrate, 30) === slush);
    }

    // "nova radio" under the Bitrate chip, 2026-09-23: the name pass and the
    // word pass each came back in bitrate order and were shown one after the
    // other, so a 320 from Croatia sat under a 64 from London.
    function novaPasses() {
        return [{ "name": "Nova Radio Lloret", "rate": 320, "votes": 2, "alive": -1 },
                { "name": "Kazanova Radio", "rate": 192, "votes": 31, "alive": -1 },
                { "name": "DeepNova Radio - DanceNova", "rate": 160, "votes": 11, "alive": -1 },
                { "name": "DeepNova Radio", "rate": 128, "votes": 12, "alive": -1 },
                { "name": "Terranova Radio", "rate": 128, "votes": 1, "alive": -1 },
                { "name": "24/7 Bossa Nova Radio", "rate": 64, "votes": 69, "alive": -1 },
                { "name": "Radio Nova Gradiška", "rate": 320, "votes": 83, "alive": -1 },
                { "name": "Radio Nova (NO)", "rate": 256, "votes": 138, "alive": -1 },
                { "name": "Radio Nova22", "rate": 224, "votes": 183, "alive": -1 },
                { "name": "Radio Nova (BE)", "rate": 192, "votes": 22, "alive": -1 },
                { "name": "Radio Nova (FR)", "rate": 128, "votes": 29, "alive": -1 }];
    }

    readonly property var novaInOneOrder:
        ["Radio Nova Gradiška", "Nova Radio Lloret", "Radio Nova (NO)", "Radio Nova22",
         "Kazanova Radio", "Radio Nova (BE)", "DeepNova Radio - DanceNova", "Radio Nova (FR)",
         "DeepNova Radio", "Terranova Radio", "24/7 Bossa Nova Radio"]

    function test_every_pass_of_a_bitrate_search_is_one_order() {
        var rows = novaPasses();
        var got = SL.rateOrder(rows).map(function(i) { return rows[i].name; });
        compare(got, novaInOneOrder);
    }

    function test_a_dead_row_stays_under_the_living_in_its_own_order() {
        // The probe's verdict outranks the number, and the dead keep the
        // order _webSinkDead gave them, so a re-sort never shuffles them.
        var rows = [{ "rate": 64, "votes": 1, "alive": 0 },
                    { "rate": 128, "votes": 5, "alive": -1 },
                    { "rate": 256, "votes": 5, "alive": 1 },
                    { "rate": 320, "votes": 9, "alive": 0 }];
        compare(SL.rateOrder(rows), [2, 1, 0, 3]);
    }

    function test_rows_that_tie_keep_their_places() {
        var same = [{ "rate": 128, "votes": 5 }, { "rate": 128, "votes": 5 }, { "rate": 128, "votes": 5 }];
        compare(SL.rateOrder(same), [0, 1, 2]);
        compare(SL.rateOrder([{ "rate": 128, "votes": 5 }, { "rate": 320, "votes": 1 },
                              { "rate": 128, "votes": 5 }]), [1, 0, 2]);
        // What says nothing about its sound sorts as nothing, and never throws.
        compare(SL.rateOrder([null, { "rate": 64 }, {}]), [1, 0, 2]);
        compare(SL.rateOrder(null), []);
        compare(SL.rateOrder({ "length": 2 }), []);
    }

    ListModel { id: orderModel }

    function fillOrderModel(rows) {
        orderModel.clear();
        for (var i = 0; i < rows.length; i++) orderModel.append(rows[i]);
    }

    function orderNames() {
        var out = [];
        for (var i = 0; i < orderModel.count; i++) out.push(orderModel.get(i).name);
        return out;
    }

    function test_an_order_lands_on_a_real_list_model() {
        fillOrderModel(["a", "b", "c", "d", "e"].map(function(n) { return { "name": n }; }));
        verify(SL.applyOrder(orderModel, [2, 0, 4, 1, 3]));
        compare(orderNames(), ["c", "a", "e", "b", "d"]);
        verify(SL.applyOrder(orderModel, [0, 1, 2, 3, 4]));
        compare(orderNames(), ["c", "a", "e", "b", "d"]);
        verify(SL.applyOrder(orderModel, [4, 3, 2, 1, 0]));
        compare(orderNames(), ["d", "b", "e", "a", "c"]);
    }

    function test_an_order_that_is_no_permutation_moves_nothing() {
        fillOrderModel(["a", "b", "c"].map(function(n) { return { "name": n }; }));
        verify(!SL.applyOrder(orderModel, [0, 1]));
        verify(!SL.applyOrder(orderModel, [0, 0, 1]));
        verify(!SL.applyOrder(orderModel, [0, 1, 3]));
        verify(!SL.applyOrder(orderModel, [2, 1, "0"]));
        verify(!SL.applyOrder(orderModel, null));
        verify(!SL.applyOrder(null, [0]));
        compare(orderNames(), ["a", "b", "c"]);
    }

    function test_the_results_model_is_sorted_in_place() {
        fillOrderModel(novaPasses());
        SL.rateSort(orderModel);
        compare(orderNames(), novaInOneOrder);
        SL.rateSort(null);   // no model, no throw
    }

    function test_a_rotten_row_sorts_as_one_that_says_nothing() {
        // The mirrors are only semi-trusted: a null among the rows must not
        // throw here, it is skipped by the walk like before.
        var holed = SL.pageOrder([null, rateRow("b", 320, 5, "MP3")], byBitrate, 30);
        compare(holed.length, 2);
        compare(holed[1], null);
        compare(holed[0].name, "b");
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


    // ── a wish typed as facets: "rock 80 uk" ────────────────────────────
    // The resolver the facet tests use: the hand aliases first, like the
    // widget does, then the small stand-in map above.
    function _ccAll(name) {
        var k = SL.fold(name)
        var a = SL.countryAliases()
        if (Object.prototype.hasOwnProperty.call(a, k)) return a[k]
        return _cc(name)
    }

    function test_a_decade_is_one_tag_however_it_is_spelled() {
        var same = ["80", "80s", "80's", "80’s", "1980s", "1980", "80er", "80ies", "eighties", "80S"]
        for (var i = 0; i < same.length; i++)
            compare(SL.decadeTag(same[i]), "80", same[i])
        compare(SL.decadeTag("60s"), "60")
        compare(SL.decadeTag("nineties"), "90")
        // The 2000s keep their "s": a bare "00" is every "top 100".
        compare(SL.decadeTag("2000s"), "00s")
        compare(SL.decadeTag("00s"), "00s")
        compare(SL.decadeTag("2010s"), "10s")
    }

    function test_numbers_that_are_no_decade_stay_words() {
        var not = ["10", "00", "2000", "85", "104", "1080", "180s", "8", "rock", "", "40", "2030s"]
        for (var i = 0; i < not.length; i++)
            compare(SL.decadeTag(not[i]), "", not[i])
        compare(SL.decadeTag(null), "")
    }

    function test_genre_decade_country_without_the_word_in() {
        // The listener's own example. Before this the directory was asked
        // for a station NAMED "rock 80 uk", found none, and the stem retry
        // answered with French and German "rock 80" stations.
        var r = SL.facetQuery("rock 80 uk", _ccAll)
        verify(r !== null)
        compare(r.tags, ["rock", "80"])
        compare(r.cc, "GB")
        compare(r.country, "uk")
        compare(r.text, "rock 80")
        // Any order, any case.
        r = SL.facetQuery("UK 80s Rock", _ccAll)
        compare(r.tags, ["80", "rock"]); compare(r.cc, "GB"); compare(r.text, "80s Rock")
    }

    function test_facets_without_a_country_are_still_facets() {
        var r = SL.facetQuery("rock 80", _ccAll)
        compare(r.tags, ["rock", "80"]); compare(r.cc, ""); compare(r.country, "")
        compare(r.text, "rock 80")
        // Multiword genres are one tag, and win over their own words.
        r = SL.facetQuery("classic rock 70s", _ccAll)
        compare(r.tags, ["classic rock", "70"])
        r = SL.facetQuery("hip hop 90s france", _ccAll)
        compare(r.tags, ["hip hop", "90"]); compare(r.cc, "FR")
    }

    function test_multiword_countries_and_everyday_names_resolve() {
        var r = SL.facetQuery("jazz new zealand", _ccAll)
        compare(r.tags, ["jazz"]); compare(r.cc, "NZ"); compare(r.country, "new zealand")
        // The directory files these under names nobody types.
        r = SL.facetQuery("country united states", _ccAll)
        compare(r.tags, ["country"]); compare(r.cc, "US")
        r = SL.facetQuery("punk england", _ccAll)
        compare(r.cc, "GB")
        r = SL.facetQuery("news united kingdom", _ccAll)
        compare(r.cc, "GB"); compare(r.text, "news")
    }

    function test_an_unknown_word_is_a_tag_only_beside_an_anchor() {
        // "synthwave" is in nobody's vocabulary, the country makes it a wish.
        var r = SL.facetQuery("synthwave uk", _ccAll)
        compare(r.tags, ["synthwave"]); compare(r.cc, "GB")
        r = SL.facetQuery("bossa nova 60s", _ccAll)
        compare(r.tags, ["bossa nova", "60"])
        // No anchor, no guessing: two unknown words are a station name.
        compare(SL.facetQuery("deep purple", _ccAll), null)
        compare(SL.facetQuery("nova synthwave", _ccAll), null)
        // Three unknown words are a name even beside a country.
        compare(SL.facetQuery("sounds of silence uk", _ccAll), null)
    }

    function test_station_names_are_left_to_the_name_roads() {
        // The pinned promise from the scoped parser holds here too.
        compare(SL.facetQuery("radio france", _ccAll), null)
        compare(SL.facetQuery("virgin radio uk", _ccAll), null)
        compare(SL.facetQuery("classic fm uk", _ccAll), null)
        compare(SL.facetQuery("rock 104 uk", _ccAll), null)     // a frequency, not a decade
        compare(SL.facetQuery("radio 80", _ccAll), null)
        // One facet is what the tag pass already does.
        compare(SL.facetQuery("jazz", _ccAll), null)
        compare(SL.facetQuery("uk", _ccAll), null)
        compare(SL.facetQuery("finland france", _ccAll), null)  // two countries, no wish
        compare(SL.facetQuery("rock uk france", _ccAll), null)
        compare(SL.facetQuery("", _ccAll), null)
        compare(SL.facetQuery(null, _ccAll), null)
        // Seven words are a sentence.
        compare(SL.facetQuery("rock pop jazz soul funk disco uk", _ccAll), null)
    }

    function test_a_lone_decade_is_the_one_single_facet() {
        // "80s" alone used to ask for the tag "80s" and miss every "80's".
        var r = SL.facetQuery("80s", _ccAll)
        compare(r.tags, ["80"]); compare(r.cc, ""); compare(r.text, "80s")
    }

    // ── a genre word alone: "rock" is the genre ─────────────────────────
    function test_a_genre_word_alone_is_a_wish_for_the_genre() {
        var yes = ["rock", "Rock ", "JAZZ", "smooth jazz", "hip-hop", "drum and bass", "80s", "80",
                   "80's", "1980s", "eighties", "00s", "country"]
        for (var i = 0; i < yes.length; i++) verify(SL.isGenreWord(yes[i]), yes[i])
        var no = ["rock fm", "radio rock", "rock antenne", "jazz fm", "rock 80", "rock uk", "uk", "10",
                  "deep purple", "constructor", "toString", "", null, undefined]
        for (var j = 0; j < no.length; j++) verify(!SL.isGenreWord(no[j]), String(no[j]))
    }

    function test_a_station_named_after_the_word_leads() {
        var yes = [["Rock", "rock"], ["ROCK FM", "rock"], ["Rock FM 104.6", "rock"], ["Radio 1 Rock", "rock"],
                   ["Radio ROCK", "rock"], ["Rock-FM!", "rock"], ["Jazz FM", "jazz"], ["Jazz Radio", "jazz"],
                   ["J\u00e1zz FM", "jazz"], ["Hip-Hop FM", "hip hop"], ["K-Pop Radio", "k-pop"],
                   ["Radio 80", "80s"], [".977 80s", "80"], ["The 80's Station", "eighties"],
                   ["Smooth Jazz Radio", "smooth jazz"]]
        for (var i = 0; i < yes.length; i++) verify(SL.namedAfter(yes[i][0], yes[i][1]), yes[i][0])
        // A name of its own is no namesake: those stand in the genre's list on their votes.
        var no = [["Rock Antenne", "rock"], ["Rockabilly-radio.net", "rock"], ["RockFM 101.7", "rock"],
                  ["Skyrock", "rock"], ["Jazz Radio Blues", "jazz"], ["80s80s", "80s"], ["80s 90s Radio", "80s"],
                  ["\u0420\u043e\u043a FM", "rock"], ["Radio", "rock"], ["104.6", "rock"], ["", "rock"],
                  [null, "rock"], [undefined, "rock"], [12345, "rock"], ["Rock", ""], ["Rock", null]]
        for (var j = 0; j < no.length; j++) verify(!SL.namedAfter(no[j][0], no[j][1]), String(no[j][0]))
    }

    function test_a_frequency_is_no_decade_and_a_foreign_word_is_a_word() {
        // Measured on name=90: three of the four leads were a Greek news
        // station on 90.1, a Thai one on 90.5 and "Radio 9090 90.9". A cut at
        // everything that is not a-z or 0-9 made "90.1" two bare numbers and
        // made a Greek or Cyrillic word vanish without a trace.
        var no = [["\u03a0\u03b1\u03c1\u03b1\u03c0\u03bf\u03bb\u03b9\u03c4\u03b9\u03ba\u03ac FM 90.1", "90"],
                  ["\u0e21\u0e34\u0e15\u0e34\u0e02\u0e48\u0e32\u0e27 90.5", "90"], ["Radio 9090 90.9", "90"],
                  ["90.5 FM", "90"], ["Radio 90,1", "90s"],
                  ["\u041d\u0430\u0448\u0435 Rock", "rock"]]
        for (var i = 0; i < no.length; i++) verify(!SL.namedAfter(no[i][0], no[i][1]), no[i][0])
        var yes = [["90s FM", "90"], ["Radio 90", "90s"], ["Rock FM \u2013 104.6", "rock"],
                   ["\u00abRock\u00bb FM", "rock"], ["Rock \u00b7 FM", "rock"]]
        for (var j = 0; j < yes.length; j++) verify(SL.namedAfter(yes[j][0], yes[j][1]), yes[j][0])
    }

    function test_the_biggest_name_always_leads_and_a_twin_leads_once() {
        // Measured on "world": BBC World Service, 163 397 votes, tagged news
        // and talk, is the first row of the name answer and is in no tag
        // answer's first page. The name answer's first row leads whatever
        // it is called; it is the directory's own idea of the biggest.
        var k = SL.leadRows("world")
        verify(k({ name: "BBC World Service", countrycode: "GB" }))
        verify(!k({ name: "BBC World Service Relay", countrycode: "US" }))
        verify(k({ name: "World Radio", countrycode: "CH" }))
        // The directory lists many stations twice. A twin takes no second
        // lead; a namesake from another country is another station.
        var p = SL.leadRows("pop")
        verify(p({ name: "Pop Radio 101.5", countrycode: "AR" }))
        verify(!p({ name: "POP Radio 101.5", countrycode: "ar" }))
        verify(p({ name: "Pop Radio 101.5", countrycode: "MX" }))
    }

    function test_the_leads_are_few_and_a_name_query_gets_no_filter() {
        compare(SL.leadRows("rock antenne"), null)
        compare(SL.leadRows("deep purple"), null)
        compare(SL.leadRows("rock 80 uk"), null)
        compare(SL.leadRows(""), null)
        var keep = SL.leadRows("rock")
        compare(typeof keep, "function")
        verify(keep({ name: "Rock FM" }))
        verify(!keep({ name: "Rock Antenne" }))
        verify(!keep({}))
        verify(!keep(null))
        // Eight at most: the genre keeps 22 of the page's 30 rows.
        var fresh = SL.leadRows("rock"), kept = 0, lands = "ABCDEFGHIJKL"
        for (var i = 0; i < 12; i++) if (fresh({ name: "Rock FM", countrycode: "X" + lands[i] })) kept++
        compare(kept, 8)
        // The count belongs to one answer, not to the word.
        verify(SL.leadRows("rock")({ name: "Rock FM" }))
    }

    function test_the_alias_table_is_folded_and_two_letter_coded() {
        var a = SL.countryAliases()
        var n = 0
        for (var k in a) {
            n++
            compare(SL.fold(k), k, k)
            verify(/^[A-Z]{2}$/.test(a[k]), k)
        }
        verify(n >= 60)
        compare(a["uk"], "GB"); compare(a["usa"], "US"); compare(a["america"], "US")
        compare(a["south korea"], "KR"); compare(a["soome"], "FI"); compare(a["turgi"], "TR")
        // Null-prototype, like the API map: "constructor" is no country.
        compare(a["constructor"], undefined)
    }

    function test_a_row_shows_the_short_country_name() {
        var longGb = "The United Kingdom Of Great Britain And Northern Ireland"
        compare(SL.countryLabel("GB", longGb, "en_US"), "United Kingdom")
        compare(SL.countryLabel("gb", longGb, "et_EE"), "United Kingdom")
        compare(SL.countryLabel("US", "The United States Of America", "en_GB"), "United States")
        // No code, or a code Qt has no name for: the directory's own word,
        // minus the article it files half its countries under.
        compare(SL.countryLabel("", "Somewhere", "en_US"), "Somewhere")
        compare(SL.countryLabel("ZZ", "The Land Of Nowhere", "en_US"), "Land Of Nowhere")
        compare(SL.countryLabel("ZZ", "", "en_US"), "")
        compare(SL.countryLabel(null, null, null), "")
    }

    function _empty(over) {
        var s = { count: 0, gotAnswer: true, mode: "all", inheritedScope: false,
                  countryQuery: false, stemCount: 2 }
        for (var k in over) s[k] = over[k]
        return SL.emptyNext(s)
    }

    function test_an_inherited_country_chip_steps_aside_for_an_empty_answer() {
        compare(_empty({ inheritedScope: true }), "unscope")
        // In every mode: the chip scopes the genre and language roads too.
        compare(_empty({ inheritedScope: true, mode: "genre", stemCount: 0 }), "unscope")
        compare(_empty({ inheritedScope: true, mode: "language" }), "unscope")
    }

    function test_an_empty_answer_without_a_chip_goes_to_the_stems() {
        compare(_empty({}), "stems")
        compare(_empty({ stemCount: 0 }), "done")
        compare(_empty({ mode: "genre" }), "done")
        compare(_empty({ countryQuery: true }), "done")
    }

    function test_rows_or_a_dead_network_end_the_search() {
        compare(_empty({ count: 3, inheritedScope: true }), "done")
        compare(_empty({ count: 3 }), "done")
        // Dead mirrors are a network answer, not "nothing in this country".
        compare(_empty({ gotAnswer: false, inheritedScope: true }), "done")
        compare(_empty({ gotAnswer: false }), "done")
        compare(SL.emptyNext(null), "done")
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

    function test_country_queries_go_out_capitalized() {
        // The directory's country filter is a case-sensitive substring —
        // measured live, country=mexico answers nothing, country=Mexico
        // plenty. Every word gets its capital, hyphens included.
        compare(SL.countryQueryForm("mexico"), "Mexico")
        compare(SL.countryQueryForm("south korea"), "South Korea")
        compare(SL.countryQueryForm("guinea-bissau"), "Guinea-Bissau")
        compare(SL.countryQueryForm("  new zealand "), "New Zealand")
        compare(SL.countryQueryForm("Mexico"), "Mexico")
        compare(SL.countryQueryForm(""), "")
    }

    function test_the_directorys_country_list_becomes_a_folded_map() {
        var m = SL.countryMapFromApi([
            { name: "Mexico", iso_3166_1: "MX" },
            { name: "The United Arab Emirates", iso_3166_1: "AE" },
            { name: "Curaçao", iso_3166_1: "CW" },
            // Catalogue slush must not enter: a three-letter "code", an
            // empty name, a row with nothing at all.
            { name: "Nowhere", iso_3166_1: "XXX" },
            { name: "", iso_3166_1: "DE" },
            {}
        ])
        compare(m["mexico"], "MX")
        // Keyed both with and without the leading article — the searcher
        // types "united arab emirates", the directory files "The ...".
        compare(m["the united arab emirates"], "AE")
        compare(m["united arab emirates"], "AE")
        // Folded like every other name comparison: accents are optional.
        compare(m["curacao"], "CW")
        compare(m["nowhere"], undefined)
        // Null-prototype: a country named "constructor" must answer as a
        // country or not at all, never as Object.prototype furniture.
        compare(m["toString"], undefined)
    }

    function test_uri_part_drops_a_lone_surrogate_and_keeps_whole_pairs() {
        // A name cut mid-emoji ends in a lone high surrogate, on which
        // encodeURIComponent throws. The half is dropped, a whole pair
        // survives, and plain text encodes exactly as it always did.
        var loneHigh = "Radio " + String.fromCharCode(0xD83D);
        compare(SL.uriPart(loneHigh), "Radio%20");
        var loneLow = String.fromCharCode(0xDE00) + "FM";
        compare(SL.uriPart(loneLow), "FM");
        var pair = "Jazz " + String.fromCharCode(0xD83C, 0xDFB7);
        compare(SL.uriPart(pair), encodeURIComponent(pair));
        compare(SL.uriPart("Raadio Elmar & Sky+"), encodeURIComponent("Raadio Elmar & Sky+"));
        compare(SL.uriPart(null), "");
        compare(SL.uriPart(undefined), "");
    }

    function test_mirror_rungs_lead_with_the_answer_keep_the_seeds_and_close_on_all() {
        var rows = [
            { name: "de1.api.radio-browser.info" },
            { name: "fi1.api.radio-browser.info" },
            { name: "all.api.radio-browser.info" },
            { name: "de1.api.radio-browser.info" },
            { name: "evil.example/../api.radio-browser.info" },
            { name: "UPPER.api.radio-browser.info" },
            { },
            null
        ];
        var r = SL.mirrorRungs(rows, ["de2", "de1", "all"]);
        compare(r.names, ["de1", "fi1", "de2", "all"]);
        compare(r.discovered, 2);
    }

    function test_mirror_rungs_with_nothing_discovered_keep_the_seeds_untouched() {
        // An empty or broken answer must not cost the walk its known-good
        // rungs — that is the whole reason the seeds are merged, not replaced.
        var r = SL.mirrorRungs([], ["de2", "de1", "all"]);
        compare(r.names, ["de2", "de1", "all"]);
        compare(r.discovered, 0);
        var g = SL.mirrorRungs("garbage", null);
        compare(g.names, ["all"]);
        compare(g.discovered, 0);
    }

    // ── the settings page's list ────────────────────────────────────────
    function test_the_settings_list_is_asked_by_votes_a_page_at_a_time() {
        var b = SL.directoryBase("de2", "bytag", "rock")
        compare(b, "https://de2.api.radio-browser.info/json/stations/bytag/rock")
        compare(SL.directoryPage(b, 100, 0),
                b + "?hidebroken=true&order=votes&reverse=true&limit=100&offset=0")
        // The next page is the same question further down, never a second spelling.
        compare(SL.directoryPage(b, 100, 200),
                b + "?hidebroken=true&order=votes&reverse=true&limit=100&offset=200")
        // A base that still carries a query loses it: one "?" per URL.
        compare(SL.directoryPage(b + "?limit=500&offset=0", 100, 100),
                b + "?hidebroken=true&order=votes&reverse=true&limit=100&offset=100")
        compare(SL.directoryPage(b, "x", -5),
                b + "?hidebroken=true&order=votes&reverse=true&limit=100&offset=0")
    }

    function test_a_later_page_that_failed_is_asked_again_by_itself() {
        // Measured on the bench: page two of "rock" failed once at the end of
        // the list and nothing asked for it again, because the only trigger
        // was the list moving and a list at its end does not move.
        compare(SL.pageRetryDelay(1), 2000)
        compare(SL.pageRetryDelay(2), 4000)
        compare(SL.pageRetryDelay(3), 8000)
        // Three waits and the page stops asking by itself; scrolling still asks.
        compare(SL.pageRetryDelay(4), -1)
        compare(SL.pageRetryDelay(40), -1)
        // Nothing failed, nothing to wait for; garbage never means "at once".
        compare(SL.pageRetryDelay(0), -1)
        compare(SL.pageRetryDelay(undefined), -1)
        compare(SL.pageRetryDelay("x"), -1)
        // The directory asks for no more than one request a second or two;
        // even the first retry keeps two seconds between the questions.
        verify(SL.pageRetryDelay(1) >= 2000)
    }

    function test_a_retried_page_goes_to_the_next_mirror() {
        var b = SL.directoryBase("de1", "bytag", "rock")
        compare(SL.rehost(b, "de2"), "https://de2.api.radio-browser.info/json/stations/bytag/rock")
        compare(SL.rehost(SL.directoryBase("de1", null, ""), "all"),
                "https://all.api.radio-browser.info/json/stations")
        // The same guard directoryBase has: no label, no host.
        compare(SL.rehost(b, "evil.example/x?"), "https://all.api.radio-browser.info/json/stations/bytag/rock")
        // Only the directory's own addresses are moved, anything else stays put.
        compare(SL.rehost("https://example.org/json/stations", "de2"), "https://example.org/json/stations")
        compare(SL.rehost("", "de2"), "")
        // The page asked is the same page, only the door is different.
        compare(SL.directoryPage(SL.rehost(b, "de2"), 100, 100),
                "https://de2.api.radio-browser.info/json/stations/bytag/rock"
                + "?hidebroken=true&order=votes&reverse=true&limit=100&offset=100")
    }

    function test_the_settings_list_url_is_built_from_safe_parts_only() {
        var bare = "https://de2.api.radio-browser.info/json/stations"
        compare(SL.directoryBase("de2", null, "rock"), bare)
        compare(SL.directoryBase("de2", "bytag", "   "), bare)
        // A slash in the word is part of the word (measured: byname/AC%2FDC answers).
        compare(SL.directoryBase("de2", "byname", " AC/DC "), bare + "/byname/AC%2FDC")
        // A road the combo box never offered is no path segment.
        compare(SL.directoryBase("de2", "../../admin", "x"), bare + "/byname/x")
        compare(SL.directoryBase("de2", "constructor", "x"), bare + "/byname/x")
        // A mirror name that is no hostname label never becomes a host.
        compare(SL.directoryBase("evil.example/x?", "bytag", "rock"),
                "https://all.api.radio-browser.info/json/stations/bytag/rock")
        compare(SL.directoryBase("", "bytag", "rock"),
                "https://all.api.radio-browser.info/json/stations/bytag/rock")
        // A lone surrogate in the word is dropped, not thrown on.
        compare(SL.directoryBase("de2", "byname", "jazz\uD83D"), bare + "/byname/jazz")
    }

    function test_a_station_is_listed_once_however_the_pages_shift() {
        var seen = ({})
        verify(SL.firstSight(seen, "u-1"))
        verify(SL.firstSight(seen, "u-2"))
        verify(!SL.firstSight(seen, "u-1"))
        // No uuid, no way to tell two rows apart: both are shown.
        verify(SL.firstSight(seen, ""))
        verify(SL.firstSight(seen, undefined))
        verify(SL.firstSight(seen, null))
        // A uuid that is a property name is only a key.
        verify(SL.firstSight(seen, "constructor"))
        verify(!SL.firstSight(seen, "constructor"))
        verify(SL.firstSight(seen, "__proto__"))
        verify(!SL.firstSight(seen, "__proto__"))
    }

    function test_a_directory_name_becomes_one_clean_line() {
        compare(SL.rowName("\t  Radio\r\n  Nova \t"), "Radio Nova")
        compare(SL.rowName("Rock & Pop <live>"), "Rock & Pop <live>")
        compare(SL.rowName(null), "")
        compare(SL.rowName(undefined), "")
        var many = ""
        for (var i = 0; i < 400; i++) many += "a"
        compare(SL.rowName(many).length, 300)
        // The cap never cuts an emoji in half.
        var edge = many.substring(0, 299) + "\uD83D\uDE00"
        compare(SL.rowName(edge).length, 299)
        // A cut that lands just after a space must not leave the space behind.
        var spaced = many.substring(0, 299) + " tail"
        compare(SL.rowName(spaced), many.substring(0, 299))
    }
}
