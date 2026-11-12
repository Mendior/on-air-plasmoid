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

    // ── the liveness probe's pass over the rows ─────────────────────────
    function _probeUrl(n) { return "https://" + n.toLowerCase() + ".example/live" }

    function fillProbeModel(names) {
        fillOrderModel(names.map(function(n) { return { "name": n, "url": _probeUrl(n), "alive": -1 } }))
    }

    function probeRows() {
        var out = []
        for (var i = 0; i < orderModel.count; i++) out.push(orderModel.get(i))
        return out
    }

    function probeState(over) {
        var s = { spent: {}, verdicts: {}, inFlight: {}, active: 0, now: 1000000, ttl: 900000, slots: 6 }
        for (var k in over) s[k] = over[k]
        return s
    }

    function aliveByName() {
        var out = []
        for (var i = 0; i < orderModel.count; i++) out.push(orderModel.get(i).name + ":" + orderModel.get(i).alive)
        return out
    }

    function test_remembered_dead_rows_are_all_marked_in_one_pass_in_their_order() {
        // The list and the cache of a query typed again within fifteen minutes.
        var names = ["a", "b", "DEAD1", "DEAD2", "c", "DEAD3", "DEAD4", "DEAD5", "d"]
        fillProbeModel(names)
        var verdicts = {}
        for (var i = 0; i < names.length; i++)
            verdicts[_probeUrl(names[i])] = { v: names[i].indexOf("DEAD") === 0 ? 0 : 1, t: 999000 }
        var pass = SL.probePass(probeRows(), probeState({ verdicts: verdicts }))
        compare(pass.known.length, 9)
        compare(pass.knock, [])
        SL.markAlive(orderModel, pass.known)
        compare(aliveByName(), ["a:1", "b:1", "c:1", "d:1",
                                "DEAD1:0", "DEAD2:0", "DEAD3:0", "DEAD4:0", "DEAD5:0"])
        // The next pass finds nothing left to do and moves nothing.
        var again = SL.probePass(probeRows(), probeState({ verdicts: verdicts }))
        compare(again.known, []); compare(again.spent, []); compare(again.knock, [])
        SL.markAlive(orderModel, again.known)
        compare(orderNames(), ["a", "b", "c", "d", "DEAD1", "DEAD2", "DEAD3", "DEAD4", "DEAD5"])
    }

    function test_a_pass_remembers_spends_and_knocks() {
        fillProbeModel(["fresh", "alive", "dead", "shrug", "stale", "flying", "judged", "done"])
        orderModel.setProperty(6, "alive", 1)
        var verdicts = {}, spent = {}, inFlight = {}
        verdicts[_probeUrl("alive")] = { v: 1, t: 999999 }
        verdicts[_probeUrl("dead")] = { v: 0, t: 100001 }       // one tick inside its lifetime
        verdicts[_probeUrl("shrug")] = { v: -1, t: 999999 }     // an unknown is remembered too
        verdicts[_probeUrl("stale")] = { v: 0, t: 100000 }      // exactly its lifetime old
        verdicts[_probeUrl("judged")] = { v: 0, t: 999999 }
        inFlight[_probeUrl("flying")] = true
        spent[_probeUrl("done")] = true
        var pass = SL.probePass(probeRows(), probeState({ verdicts: verdicts, spent: spent, inFlight: inFlight }))
        compare(pass.known.map(function(k) { return k.url + " " + k.v }),
                [_probeUrl("alive") + " 1", _probeUrl("dead") + " 0"])
        compare(pass.knock, [_probeUrl("fresh"), _probeUrl("stale")])
        compare(pass.spent, [_probeUrl("fresh"), _probeUrl("alive"), _probeUrl("dead"),
                             _probeUrl("shrug"), _probeUrl("stale")])
        // The caller's books are read and never written.
        compare(Object.keys(spent).length, 1); compare(Object.keys(inFlight).length, 1)
    }

    function test_a_pass_knocks_only_while_a_slot_is_free() {
        var names = []
        for (var i = 0; i < 40; i++) names.push("s" + i)
        fillProbeModel(names)
        var pass = SL.probePass(probeRows(), probeState({ active: 4 }))
        compare(pass.knock, [_probeUrl("s0"), _probeUrl("s1")])
        compare(pass.spent, pass.knock)      // the others wait unspent for the next pass
        compare(SL.probePass(probeRows(), probeState({ active: 6 })).knock, [])
        compare(SL.probePass(probeRows(), probeState({ active: 9 })).spent, [])
        compare(SL.probePass(probeRows(), probeState({})).knock.length, 6)
        // Slots that are no number open no door.
        compare(SL.probePass(probeRows(), probeState({ slots: "many" })).knock, [])
    }

    function test_a_private_host_is_spent_and_never_knocked_on() {
        var rows = [{ url: "http://192.168.1.10:8000/stream", alive: -1 },
                    { url: "http://localhost/radio", alive: -1 },
                    { url: "https://public.example/live", alive: -1 }]
        var verdicts = { "http://192.168.1.10:8000/stream": { v: 1, t: 999999 } }
        var pass = SL.probePass(rows, probeState({ verdicts: verdicts }))
        compare(pass.knock, ["https://public.example/live"])
        compare(pass.known, [])              // not even a remembered verdict marks it
        compare(pass.spent, ["http://192.168.1.10:8000/stream", "http://localhost/radio",
                             "https://public.example/live"])
    }

    function test_a_pass_over_nothing_or_over_rubbish_is_empty() {
        var empty = [SL.probePass([], probeState({})), SL.probePass(null, probeState({})),
                     SL.probePass([{ url: "https://a.example/x", alive: -1 }], null),
                     SL.probePass("rows", "state"), SL.probePass(undefined, undefined)]
        for (var i = 0; i < empty.length; i++) {
            compare(empty[i].spent, [], i); compare(empty[i].known, [], i); compare(empty[i].knock, [], i)
        }
        // Rows that are no rows are stepped over; a row seen twice is dealt with once.
        var rows = [null, 7, {}, { url: 5, alive: -1 }, { url: "https://a.example/x" },
                    { url: "https://a.example/x", alive: -1 }, { url: "https://a.example/x", alive: -1 }]
        var pass = SL.probePass(rows, probeState({}))
        compare(pass.knock, ["https://a.example/x"]); compare(pass.spent, ["https://a.example/x"])
        // A verdict without a time is no verdict, and the books may be anything.
        var odd = { "https://a.example/x": "dead", "https://b.example/y": { v: 0 },
                    "https://c.example/z": { v: 7, t: 999999 } }
        pass = SL.probePass([{ url: "https://a.example/x", alive: -1 }, { url: "https://b.example/y", alive: -1 },
                             { url: "https://c.example/z", alive: -1 }],
                            probeState({ verdicts: odd, spent: null, inFlight: 5 }))
        compare(pass.knock, ["https://a.example/x", "https://b.example/y"])
        // A fresh one that says neither alive nor dead is a remembered shrug.
        compare(pass.known, [])
        compare(pass.spent.length, 3)
    }

    function test_marking_lands_by_address_and_sinks_once() {
        fillProbeModel(["a", "b", "c", "d"])
        // One verdict, as a finished probe brings it.
        SL.markAlive(orderModel, [{ url: _probeUrl("b"), v: 0 }])
        compare(aliveByName(), ["a:-1", "c:-1", "d:-1", "b:0"])
        SL.markAlive(orderModel, [{ url: _probeUrl("c"), v: 1 }])
        compare(aliveByName(), ["a:-1", "c:1", "d:-1", "b:0"])
        // A row the list no longer shows, and marks that are no marks.
        SL.markAlive(orderModel, [{ url: "https://gone.example/live", v: 0 }, null, {}, { url: _probeUrl("a") },
                                  { url: _probeUrl("d"), v: "0" }])
        compare(aliveByName(), ["a:-1", "c:1", "d:-1", "b:0"])
        SL.markAlive(orderModel, null); SL.markAlive(null, [{ url: _probeUrl("a"), v: 0 }])
        SL.markAlive(orderModel, []); SL.markAlive({}, [{ url: _probeUrl("a"), v: 0 }])
        compare(aliveByName(), ["a:-1", "c:1", "d:-1", "b:0"])
        // Of two rows at one address the first takes the mark, as it always did.
        orderModel.append({ "name": "twin", "url": _probeUrl("a"), "alive": -1 })
        SL.markAlive(orderModel, [{ url: _probeUrl("a"), v: 1 }])
        compare(aliveByName(), ["a:1", "c:1", "d:-1", "b:0", "twin:-1"])
        orderModel.remove(4)
        // Sinking again changes nothing, on a full list and on an empty one.
        SL.sinkDead(orderModel); SL.sinkDead(orderModel)
        compare(orderNames(), ["a", "c", "d", "b"])
        orderModel.clear(); SL.sinkDead(orderModel); SL.sinkDead(null); SL.sinkDead({})
        compare(orderModel.count, 0)
    }

    function test_a_long_list_of_the_dead_keeps_its_order() {
        var names = [], want = [], dead = []
        for (var i = 0; i < 300; i++) names.push((i % 3 === 0 ? "DEAD" : "live") + i)
        fillProbeModel(names)
        var known = []
        for (var j = 0; j < names.length; j++) {
            var isDead = names[j].indexOf("DEAD") === 0
            known.push({ url: _probeUrl(names[j]), v: isDead ? 0 : 1 })
            if (isDead) dead.push(names[j]); else want.push(names[j])
        }
        SL.markAlive(orderModel, known)
        compare(orderNames(), want.concat(dead))
    }

    function test_matches_all_words_any_order_fold_blind() {
        verify(SL.matchesAllWords("Radio Nova", SL.words("nova radio")));
        verify(SL.matchesAllWords("Järviradio", SL.words("jarvi")));
        verify(!SL.matchesAllWords("Radio Nova", SL.words("nova jazz")));
        verify(!SL.matchesAllWords("anything", []));
    }

    function test_a_number_in_the_word_pass_is_a_whole_number() {
        // Measured 2026-11-02: "Raadio 2" kept Vikerraadio and Raadio 4 on the
        // 2 in "128 kbps", and "BBC Radio 1" kept ten 128k streams of other stations.
        verify(!SL.matchesAllWords("BBC Radio 4 (128k)", SL.words("BBC Radio 1")));
        verify(!SL.matchesAllWords("Vikerraadio (128 kbps Ogg Opus) | Eesti Rahvusringhääling",
                                   SL.words("Raadio 2")));
        verify(!SL.matchesAllWords("RTL 102.5", SL.words("rtl 10")));
        verify(!SL.matchesAllWords(null, SL.words("radio 2")));
        verify(SL.matchesAllWords("Raadio 2 HQ", SL.words("Raadio 2")));
        verify(SL.matchesAllWords("BBC Radio 1Xtra (128k)", SL.words("bbc radio 1")));
        verify(SL.matchesAllWords("Yle Radio1HIFI", SL.words("yle radio 1")));
        verify(SL.matchesAllWords("RTL 102.5", SL.words("rtl 102")));
        // A frequency with its point is no whole number: it stays a substring.
        verify(SL.matchesAllWords("104.6 RTL Berlin", SL.words("rtl 104.6")));
        // Only digits are held whole. Short letters stay a substring, or "big fm"
        // loses every bigFM station and "z 100" loses Z100.
        verify(SL.matchesAllWords("bigFM Deutschland", SL.words("big fm")));
        verify(SL.matchesAllWords("Z100 - New York's #1 Hit Music Station WHTZ", SL.words("z 100")));
        verify(SL.matchesAllWords("北京音乐广播", SL.words("北京 音乐")));
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

    function test_a_number_glued_to_a_word_is_spelled_apart() {
        // Measured 2026-11-02: "raadio2" found nothing, and its stem "raadio"
        // put Raadio 2 HQ third among thirty; "raadio 2" is the three Raadio 2 streams.
        compare(SL.spellings("raadio2"), ["raadio 2"]);
        compare(SL.spellings(" Raadio2 "), ["Raadio 2"]);      // the listener's own case
        compare(SL.spellings("BAYERN3"), ["BAYERN 3"]);        // a capital is a letter too
        compare(SL.spellings("1live"), ["1 live"]);            // five units, the floor
        compare(SL.spellings("hot97"), ["hot 97"]);
        compare(SL.spellings("rtl102.5"), ["rtl 102.5"]);      // a point is no letter
        compare(SL.spellings("104.6rtl"), ["104.6 rtl"]);
        compare(SL.spellings("bbc radio1"), ["bbc radio 1"]);
        compare(SL.spellings("mp3stream"), ["mp 3 stream"]);   // every seam
        compare(SL.spellings("Rádio2"), ["Rádio 2"]);          // accents stay as typed
        compare(SL.spellings("Радио2"), ["Радио 2"]);
        compare(SL.spellings("北京音乐2"), ["北京音乐 2"]);
        // An accent typed as its own mark belongs to the letter before it,
        // the way fold() reads it.
        compare(SL.spellings("Rade\u03012"), ["Rade\u0301 2"]);
    }

    function test_only_a_seam_long_enough_is_spelled_apart() {
        compare(SL.spellings("nrj2"), []);                     // four units
        compare(SL.spellings("  yle1  "), []);
        compare(SL.spellings("1fm"), []);
        compare(SL.spellings("jazz"), []);
        compare(SL.spellings("radio 2"), []);                  // already apart
        compare(SL.spellings("102.5"), []);                    // no letter
        compare(SL.spellings("radio-2"), []);                  // a dash is no letter
        compare(SL.spellings(""), []);
        compare(SL.spellings(null), []);
        compare(SL.spellings(undefined), []);
        // The space never lands inside a surrogate pair: half an emoji makes
        // encodeURIComponent throw, and the stems learned that the hard way.
        var e = SL.spellings("abc\u{1F600}1");
        compare(e, ["abc\u{1F600} 1"]);
        compare(encodeURIComponent(e[0]), "abc%F0%9F%98%80%201");
        // A long paste is read whole, every seam in it.
        var many = "";
        for (var i = 0; i < 200; i++) many += "a1";
        var out = SL.spellings(many);
        compare(out.length, 1);
        compare(out[0].length, 799);
        compare(out[0].substring(0, 9), "a 1 a 1 a");
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


    function test_a_country_after_in_may_wear_its_article() {
        // Measured 2026-11-10: "rock in the uk" was no fence at all, because
        // the tail went to the country map as "the uk".
        var r = SL.scopedQuery("rock in the uk", _cc)
        verify(r !== null)
        compare(r.text, "rock"); compare(r.cc, "GB"); compare(r.country, "uk")
        r = SL.scopedQuery("Jazz from The  France", _cc)
        verify(r !== null)
        compare(r.text, "Jazz"); compare(r.cc, "FR"); compare(r.country, "France")
        r = SL.scopedQuery("classic rock in the new zealand", _cc)
        verify(r !== null)
        compare(r.text, "classic rock"); compare(r.cc, "NZ"); compare(r.country, "new zealand")
        // A name the map files with its article is found as it stands.
        var gambia = function(n) { return n.toLowerCase() === "the gambia" ? "GM" : "" }
        r = SL.scopedQuery("reggae in the gambia", gambia)
        verify(r !== null)
        compare(r.cc, "GM"); compare(r.country, "the gambia")
    }

    function test_an_article_alone_names_no_country() {
        compare(SL.scopedQuery("alice in chains", _cc), null)
        compare(SL.scopedQuery("alice in the chains", _cc), null)
        // One article is taken off, not two, and "the" by itself is no tail.
        compare(SL.scopedQuery("rock in the the uk", _cc), null)
        compare(SL.scopedQuery("rock in the", _cc), null)
        compare(SL.scopedQuery("rock in the ", _cc), null)
        compare(SL.scopedQuery("the the", _cc), null)
        compare(SL.scopedQuery("the the in the the", _cc), null)
        compare(SL.scopedQuery("in the uk", _cc), null)        // no text before
        // "theuk" and "then uk" are words of their own.
        compare(SL.scopedQuery("rock in theuk", _cc), null)
        compare(SL.scopedQuery("rock in then uk", _cc), null)
        compare(SL.scopedQuery(null, _cc), null)
        // The band keeps its name when the country comes after it.
        var r = SL.scopedQuery("the the in the uk", _cc)
        verify(r !== null)
        compare(r.text, "the the"); compare(r.cc, "GB")
        // A tail past any honest length is asked once each way and let go.
        var far = "the "
        for (var i = 0; i < 4000; i++) far += "x"
        compare(SL.scopedQuery("rock in " + far, _cc), null)
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
        // The reading says how many of its words it had to guess.
        compare(r.loose, 1)
        compare(SL.facetQuery("bossa nova uk", _ccAll).loose, 2)
        compare(SL.facetQuery("rock 80 uk", _ccAll).loose, 0)
        compare(SL.facetQuery("new wave uk", _ccAll).loose, 0)   // a genre of two words
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

    // ── a genre and a place: "techno berlin" ────────────────────────────
    function test_a_genre_beside_a_place_is_asked_inside_that_place() {
        // Measured 2026-11-02: "techno berlin" found nothing in five requests,
        // and the techno tag inside the state "berlin" is seventeen stations.
        var r = SL.genrePlace("techno berlin")
        verify(r !== null)
        compare(r.tag, "techno"); compare(r.state, "berlin")
        r = SL.genrePlace("  Berlin   Techno ")                 // any order, the place as typed
        verify(r !== null)
        compare(r.tag, "techno"); compare(r.state, "Berlin")
        r = SL.genrePlace("Jazz Wien")                          // four letters are enough
        compare(r.tag, "jazz"); compare(r.state, "Wien")
        r = SL.genrePlace("hip-hop Köln")                       // accents go out as typed
        compare(r.tag, "hip-hop"); compare(r.state, "Köln")
        r = SL.genrePlace("r&b paris")
        compare(r.tag, "r&b"); compare(r.state, "paris")
        // GENRES knows only "classic rock", so the misspelt pair reads as rock
        // in a place of that misspelled name. Harmless today: the word pass finds rows
        // for it first, and this question is only asked of an empty list.
        r = SL.genrePlace("clasic rock")  // codespell:ignore clasic
        compare(r.tag, "rock"); compare(r.state, "clasic")  // codespell:ignore clasic
        // Two genres: the first one typed is the genre. The tag pass has asked
        // for both together long before an empty list gets here.
        r = SL.genrePlace("jazz rock")
        compare(r.tag, "jazz"); compare(r.state, "rock")
        var far = "rock "
        for (var i = 0; i < 300; i++) far += "a"
        compare(SL.genrePlace(far).state.length, 300)
    }

    function test_no_place_without_a_genre_and_a_real_place_word() {
        var no = ["techno", "berlin techno mitte", "nova radio", "deep purple",
                  "smooth jazz", "classic rock",                // the pair is the genre
                  "rock 1live", "pop 90s",                      // a digit is no place
                  "rock radio", "rock online", "jazz fm",       // station words
                  "pop rio", "jazz l.a.",                       // under four letters
                  "", "   ", null, undefined]
        for (var i = 0; i < no.length; i++)
            compare(SL.genrePlace(no[i]), null, String(no[i]))
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

    function test_what_the_neighbours_call_a_country_is_that_country() {
        // A Finn types "Viro", a German "Estland" or "Finnland", an Estonian
        // "Kreeka", "Mehhiko" or "Tšehhi". Measured 2026-11-02: as a name, a
        // tag and two stems each found nothing in four requests, and "Viro"
        // found Viroqua and stations tagged "environment".
        var want = [["Viro", "EE"], ["Estland", "EE"], ["Finnland", "FI"], ["Kreeka", "GR"],
                    ["Mehhiko", "MX"], ["Tšehhi", "CZ"], ["tsehhi", "CZ"], ["VIRO ", "EE"]]
        for (var i = 0; i < want.length; i++)
            compare(_ccAll(want[i][0]), want[i][1], want[i][0])
        // "Island" is Iceland in Estonian and an English word as well: typed
        // alone it stays a search for the word in station names.
        compare(_ccAll("Island"), "")
        compare(_ccAll("Viroqua"), "")
        compare(_ccAll(""), "")
        // Beside a genre the word is the country the genre is asked inside.
        var r = SL.facetQuery("rock viro", _ccAll)
        verify(r !== null)
        compare(r.tags, ["rock"]); compare(r.cc, "EE")
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

    function test_a_fence_read_without_in_steps_aside_for_an_empty_answer() {
        // Measured 2026-11-10: "new jersey" was read as "new" in Jersey, the
        // name and the tag both answered nothing there, "new" has no stem, and
        // the popup said No matching stations over six stations of that name.
        compare(_empty({ bareScope: true, stemCount: 0 }), "astyped")
        // Before the stems: "synthwav" inside Britain is a longer shot than
        // the two words as a name.
        compare(_empty({ bareScope: true }), "astyped")
        compare(_empty({ bareScope: true, mode: "genre", stemCount: 0 }), "astyped")
        // Rows, or a network that never answered, end the search as before.
        compare(_empty({ bareScope: true, count: 1 }), "done")
        compare(_empty({ bareScope: true, gotAnswer: false }), "done")
        // Only the flag itself: a fence the listener spelled with "in" stays.
        compare(_empty({ bareScope: false, stemCount: 0 }), "done")
        compare(_empty({ bareScope: "true", stemCount: 0 }), "done")
        compare(_empty({ bareScope: 1, stemCount: 0 }), "done")
    }

    function test_a_station_name_typed_with_its_country_has_a_second_reading() {
        // Measured 2026-11-10: one row with no votes for the three words as a
        // name, four for "retro fm" inside EE.
        var r = SL.nameInCountry("retro fm eesti", _ccAll)
        verify(r !== null)
        compare(r.text, "retro fm"); compare(r.cc, "EE"); compare(r.country, "eesti")
        // The station it was deliberately left for has the reading too, as a fallback.
        r = SL.nameInCountry("virgin radio uk", _ccAll)
        verify(r !== null)
        compare(r.text, "virgin radio"); compare(r.cc, "GB")
        // Any place, the listener's own case, a country of several words.
        r = SL.nameInCountry("Eesti Retro FM", _ccAll)
        verify(r !== null)
        compare(r.text, "Retro FM"); compare(r.cc, "EE"); compare(r.country, "eesti")
        r = SL.nameInCountry("retro eesti fm", _ccAll)
        verify(r !== null)
        compare(r.text, "retro fm")
        r = SL.nameInCountry("Radio 2 New Zealand", _ccAll)
        verify(r !== null)
        compare(r.text, "Radio 2"); compare(r.cc, "NZ"); compare(r.country, "new zealand")
        r = SL.nameInCountry("classic fm united kingdom", _ccAll)
        verify(r !== null)
        compare(r.text, "classic fm"); compare(r.cc, "GB")
        // Three unknown words are a name to the facets, and get this reading.
        r = SL.nameInCountry("sounds of silence uk", _ccAll)
        verify(r !== null)
        compare(r.text, "sounds of silence"); compare(r.cc, "GB")
    }

    function test_what_is_no_name_beside_one_country_has_no_second_reading() {
        // A wish the facets already read was fenced on the first reading.
        compare(SL.nameInCountry("synthwave uk", _ccAll), null)
        compare(SL.nameInCountry("rock 80 uk", _ccAll), null)
        // No country, a country alone, two countries.
        compare(SL.nameInCountry("retro fm", _ccAll), null)
        compare(SL.nameInCountry("uk", _ccAll), null)
        compare(SL.nameInCountry("united kingdom", _ccAll), null)
        compare(SL.nameInCountry("radio finland france", _ccAll), null)
        // Six words at most, like the facets.
        verify(SL.nameInCountry("one two three four fm uk", _ccAll) !== null)
        compare(SL.nameInCountry("one two three four five fm uk", _ccAll), null)
        // Nothing typed, no text, no resolver, a resolver that answers no string.
        compare(SL.nameInCountry("", _ccAll), null)
        compare(SL.nameInCountry("   ", _ccAll), null)
        compare(SL.nameInCountry(null, _ccAll), null)
        compare(SL.nameInCountry(undefined, _ccAll), null)
        compare(SL.nameInCountry(44, _ccAll), null)
        compare(SL.nameInCountry("retro fm eesti", null), null)
        compare(SL.nameInCountry("retro fm eesti"), null)
        compare(SL.nameInCountry("retro fm eesti", function() { return 7 }), null)
        var far = "fm "
        for (var i = 0; i < 4000; i++) far += "x"
        compare(SL.nameInCountry(far, _ccAll), null)
        var r = SL.nameInCountry(far + " uk", _ccAll)
        verify(r !== null)
        compare(r.text, far)
    }

    function test_a_thin_answer_to_a_name_with_a_country_asks_inside_the_country() {
        compare(_empty({ inCountry: true }), "incountry")            // before the stems
        compare(_empty({ inCountry: true, stemCount: 0 }), "incountry")
        // "retro fm eesti" had one row. Under three is next to nothing.
        compare(_empty({ inCountry: true, count: 1 }), "incountry")
        compare(_empty({ inCountry: true, count: 2 }), "incountry")
        compare(_empty({ inCountry: true, count: 3 }), "done")
        compare(_empty({ inCountry: true, count: 30 }), "done")
        // A thin answer without that reading is an answer.
        compare(_empty({ count: 1 }), "done")
        compare(_empty({ inCountry: false, count: 1 }), "done")
        compare(_empty({ inCountry: "yes", count: 1 }), "done")
        compare(_empty({ inCountry: 1 }), "stems")
        // Only where a name is what was asked for, and only on a real answer.
        compare(_empty({ inCountry: true, count: 1, mode: "genre" }), "done")
        compare(_empty({ inCountry: true, mode: "language" }), "done")
        compare(_empty({ inCountry: true, mode: "country" }), "done")
        compare(_empty({ inCountry: true, gotAnswer: false }), "done")
        compare(_empty({ inCountry: true, count: 1, gotAnswer: false }), "done")
        // A fence that found nothing steps aside first.
        compare(_empty({ inCountry: true, inheritedScope: true }), "unscope")
        compare(_empty({ inCountry: true, bareScope: true }), "astyped")
    }

    // The directory's own list knows Jersey; the hand aliases do not.
    function _ccJersey(name) {
        return SL.fold(name) === "jersey" ? "JE" : _ccAll(name)
    }

    function test_a_country_beside_an_unknown_word_is_read_as_a_guess() {
        var r = SL.reading("new jersey", "all", _ccJersey)
        verify(r.scoped !== null)
        compare(r.cc, "")
        compare(r.scoped.text, "new"); compare(r.scoped.cc, "JE"); compare(r.scoped.country, "jersey")
        compare(r.bareScope, true)
        // The retry reads the same words as a name and nothing else.
        r = SL.reading("new jersey", "all", _ccJersey, true)
        compare(r.cc, ""); compare(r.scoped, null); compare(r.bareScope, false)
        // The reading itself stays: synthwave in the UK is still a wish.
        r = SL.reading("synthwave uk", "all", _ccAll)
        verify(r.scoped !== null)
        compare(r.scoped.text, "synthwave"); compare(r.scoped.cc, "GB"); compare(r.bareScope, true)
        r = SL.reading("bbc wales", "all", _ccAll)
        verify(r.scoped !== null)
        compare(r.scoped.text, "bbc"); compare(r.scoped.cc, "GB"); compare(r.bareScope, true)
    }

    function test_a_country_beside_a_genre_or_after_in_is_no_guess() {
        var r = SL.reading("rock uk", "all", _ccAll)
        verify(r.scoped !== null)
        compare(r.scoped.text, "rock"); compare(r.scoped.cc, "GB"); compare(r.bareScope, false)
        r = SL.reading("rock 80 uk", "genre", _ccAll)
        verify(r.scoped !== null)
        compare(r.scoped.text, "rock 80"); compare(r.bareScope, false)
        // "in" is the listener's own word and the retry does not take it away.
        r = SL.reading("synthwave in UK", "all", _ccAll)
        verify(r.scoped !== null)
        compare(r.scoped.text, "synthwave"); compare(r.scoped.cc, "GB"); compare(r.scoped.country, "UK")
        compare(r.bareScope, false)
        r = SL.reading("synthwave in UK", "all", _ccAll, true)
        verify(r.scoped !== null)
        compare(r.scoped.cc, "GB"); compare(r.bareScope, false)
    }

    function test_the_whole_text_as_a_country_and_the_modes_that_read_no_fence() {
        var r = SL.reading("uk", "all", _ccAll)
        compare(r.cc, "GB"); compare(r.scoped, null); compare(r.bareScope, false)
        r = SL.reading("  United Kingdom ", "country", _ccAll)
        compare(r.cc, "GB"); compare(r.scoped, null)
        // The country mode reads the text as the country, with "in" or without.
        r = SL.reading("jazz in uk", "country", _ccAll)
        compare(r.cc, ""); compare(r.scoped, null)
        // The language mode knows "in" and no facets.
        r = SL.reading("synthwave uk", "language", _ccAll)
        compare(r.scoped, null); compare(r.bareScope, false)
        r = SL.reading("english in uk", "language", _ccAll)
        verify(r.scoped !== null)
        compare(r.scoped.cc, "GB")
        // A station name is left alone, and so is a sentence.
        compare(SL.reading("virgin radio uk", "all", _ccAll).scoped, null)
        compare(SL.reading("rock pop jazz soul funk disco uk", "all", _ccAll).scoped, null)
    }

    function test_a_reading_of_nothing_is_no_reading() {
        var none = [SL.reading("", "all", _ccAll), SL.reading(null, "all", _ccAll),
                    SL.reading(undefined, "all", _ccAll), SL.reading("   ", "genre", _ccAll),
                    SL.reading("rock uk", "all", null), SL.reading("rock uk", "all"),
                    SL.reading("rock uk", undefined, _ccAll)]
        for (var i = 0; i < none.length; i++) {
            compare(none[i].cc, "", i); compare(none[i].scoped, null, i); compare(none[i].bareScope, false, i)
        }
        // A resolver that answers no string is a resolver that said no.
        var r = SL.reading("rock uk", "all", function() { return undefined })
        compare(r.cc, ""); compare(r.scoped, null)
    }

    // The resolver the widget builds: the hand aliases, then the directory's list.
    function _ccWith(api) {
        return function(q) { return SL.countryCode(q, SL.countryAliases(), api) }
    }

    function test_the_directorys_country_list_changes_how_a_text_is_read() {
        // What the first search of a session has, and what every later one has.
        var first = SL.countryMapFromApi([])
        var later = SL.countryMapFromApi([{ name: "Portugal", iso_3166_1: "PT" },
                                          { name: "Jersey", iso_3166_1: "JE" }])
        compare(SL.countryAliases()[SL.fold("portugal")], undefined)
        compare(SL.countryCode("Portugal", SL.countryAliases(), first), "")
        compare(SL.countryCode("Portugal", SL.countryAliases(), later), "PT")
        verify(SL.readingKey("portugal", "all", _ccWith(first)) !== SL.readingKey("portugal", "all", _ccWith(later)))
        verify(SL.readingKey("Portugal", "country", _ccWith(first)) !== SL.readingKey("Portugal", "country", _ccWith(later)))
        // A fence the list makes readable is a new reading too, either way.
        verify(SL.readingKey("fado in portugal", "all", _ccWith(first)) !== SL.readingKey("fado in portugal", "all", _ccWith(later)))
        verify(SL.readingKey("rock jersey", "all", _ccWith(first)) !== SL.readingKey("rock jersey", "all", _ccWith(later)))
        verify(SL.readingKey("fado in portugal", "all", _ccWith(later)) !== SL.readingKey("rock in portugal", "all", _ccWith(later)))
    }

    function test_a_text_the_list_reads_no_differently_has_one_key() {
        var first = SL.countryMapFromApi([])
        var later = SL.countryMapFromApi([{ name: "Portugal", iso_3166_1: "PT" }])
        var same = ["nova radio", "uk", "rock uk", "70s in UK", "jazz", "portugalia", "x"]
        for (var i = 0; i < same.length; i++)
            compare(SL.readingKey(same[i], "all", _ccWith(first)),
                    SL.readingKey(same[i], "all", _ccWith(later)), same[i])
        // In the Genre and Language modes a country name is a tag or a language.
        compare(SL.readingKey("portugal", "genre", _ccWith(first)), SL.readingKey("portugal", "genre", _ccWith(later)))
        compare(SL.readingKey("portugal", "language", _ccWith(first)), SL.readingKey("portugal", "language", _ccWith(later)))
        // Nothing typed, or no resolver at all, is one and the same reading.
        compare(SL.readingKey("", "all", _ccWith(first)), SL.readingKey("", "all", _ccWith(later)))
        compare(SL.readingKey(null, "all", _ccWith(first)), SL.readingKey("   ", "all", _ccWith(later)))
        compare(SL.readingKey("portugal", "all", null), SL.readingKey("portugal", "all", undefined))
        compare(typeof SL.readingKey("portugal", "all", _ccWith(later)), "string")
        // The parts cannot run into each other: a fence is not a longer country.
        verify(SL.readingKey("rock in uk", "all", _ccWith(first)) !== SL.readingKey("uk", "all", _ccWith(first)))
        var far = ""
        for (var j = 0; j < 3000; j++) far += "p"
        compare(SL.readingKey(far, "all", _ccWith(first)), SL.readingKey(far, "all", _ccWith(later)))
    }

    function test_an_objects_own_furniture_is_no_country() {
        // Measured: with the map the session started on, ({})["constructor"]
        // is a function, and it went on towards countrycode=.
        var maps = [SL.countryMapFromApi([]), {}, SL.countryMapFromApi(null)]
        var words = ["constructor", "toString", "valueOf", "hasOwnProperty", "__proto__", "prototype"]
        for (var m = 0; m < maps.length; m++)
            for (var w = 0; w < words.length; w++) {
                compare(SL.countryCode(words[w], SL.countryAliases(), maps[m]), "", words[w])
                compare(SL.countryCode(words[w], maps[m], maps[m]), "", words[w])
            }
        compare(Object.getPrototypeOf(SL.countryMapFromApi([])), null)
        // What a map inherits is not in the map, even when it looks like a code.
        compare(SL.countryCode("x", Object.create({ x: "GB" }), Object.create({ x: "FI" })), "")
    }

    function test_a_country_code_comes_from_the_hand_map_first() {
        var api = SL.countryMapFromApi([{ name: "Georgia", iso_3166_1: "GE" }, { name: "Estonia", iso_3166_1: "XX" }])
        compare(SL.countryCode("Georgia", SL.countryAliases(), api), "GE")
        compare(SL.countryCode("  eesti ", SL.countryAliases(), api), "EE")
        compare(SL.countryCode("Estonia", SL.countryAliases(), api), "EE")     // the hand map's word
        compare(SL.countryCode("turgi", SL.countryAliases(), api), "TR")       // accent-blind
        // No text, a text that is no string, maps that are no maps.
        compare(SL.countryCode("", SL.countryAliases(), api), "")
        compare(SL.countryCode(null, SL.countryAliases(), api), "")
        compare(SL.countryCode(44, SL.countryAliases(), api), "")
        compare(SL.countryCode("uk", null, undefined), "")
        compare(SL.countryCode("uk", "uk", 7), "")
        compare(SL.countryCode("georgia", null, api), "GE")
        // Only a two-letter code is a code, whatever a map was filled with.
        compare(SL.countryCode("x", { x: "GBR" }, { x: 5 }), "")
        compare(SL.countryCode("x", { x: "gb" }, { x: "FI" }), "FI")
        var far = ""
        for (var i = 0; i < 3000; i++) far += "p"
        compare(SL.countryCode(far, SL.countryAliases(), api), "")
    }

    function test_inside_a_guessed_fence_the_rows_with_every_typed_word_lead() {
        // The name answer for "bbc" inside GB, by votes; "bbc Wales" was 39th.
        var rows = [{ name: "BBC Radio 1" }, { name: "BBC Radio 4" }, { name: "BBC World Service" },
                    { name: "bbc Wales" }, { name: "BBC Radio Cymru" }, { name: "BBC Radio Wales" }]
        var lead = SL.fenceLead("bbc wales")
        // The list takes the answer twice: the leads, then what is left.
        var shown = rows.filter(lead).concat(rows.filter(function(r) { return !lead(r) }))
        compare(shown.map(function(r) { return r.name }),
                ["bbc Wales", "BBC Radio Wales", "BBC Radio 1", "BBC Radio 4",
                 "BBC World Service", "BBC Radio Cymru"])
        // Any order, fold-blind, and the filter keeps no count: every such row leads.
        verify(SL.fenceLead("Wales BBC")({ name: "bbc wales" }))
        verify(SL.fenceLead("jarvi soome")({ name: "Järviradio Soome" }))
        verify(lead({ name: "BBC Wales" })); verify(lead({ name: "BBC Wales" }))
        // One word missing is no lead.
        verify(!lead({ name: "Wales Online" }))
    }

    function test_a_lead_filter_without_words_or_names_keeps_nothing() {
        verify(!SL.fenceLead("")({ name: "BBC Wales" }))
        verify(!SL.fenceLead(null)({ name: "BBC Wales" }))
        verify(!SL.fenceLead("   ")({ name: "" }))
        var lead = SL.fenceLead("bbc wales")
        verify(!lead(null)); verify(!lead(undefined)); verify(!lead({}))
        verify(!lead({ name: null })); verify(!lead({ name: 7 })); verify(!lead("bbc wales"))
        // A name past any honest length is read like any other.
        var far = "bbc "
        for (var i = 0; i < 5000; i++) far += "x"
        verify(lead({ name: far + " wales" }))
        verify(!lead({ name: far }))
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

    // The wait before a cover lookup. Measured on 29 song changes: the old
    // fixed 1.5 s was 87% of the time from a new title to its cover.
    function test_a_title_that_stood_does_not_wait_out_the_flap_window() {
        compare(SL.artWaitMs(false, 5000), 200)
        compare(SL.artWaitMs(false, 180000), 200)
        // The first title after an empty header has nothing to flap against.
        compare(SL.artWaitMs(true, 0), 200)
        compare(SL.artWaitMs(true, undefined), 200)
        // A change on the heels of another keeps the full window.
        compare(SL.artWaitMs(false, 0), 1500)
        compare(SL.artWaitMs(false, 1200), 1500)
        // Four seconds is where a title has stood long enough.
        compare(SL.artWaitMs(false, 3999), 1500)
        compare(SL.artWaitMs(false, 4000), 200)
        // No span, a span that is no number, a clock that went backwards:
        // nothing says the title stood, so it waits.
        compare(SL.artWaitMs(false, undefined), 1500)
        compare(SL.artWaitMs(false, null), 1500)
        compare(SL.artWaitMs(false, NaN), 1500)
        compare(SL.artWaitMs(false, "soon"), 1500)
        compare(SL.artWaitMs(false, -60000), 1500)
        compare(SL.artWaitMs(undefined, undefined), 1500)
        // Only a real true is a first title.
        compare(SL.artWaitMs("yes", 0), 1500)
        // A span as long as the clock itself, the engine's first call.
        compare(SL.artWaitMs(false, Date.now()), 200)
        compare(SL.artWaitMs(false, Infinity), 200)
    }

    // Whether a cover lookup that ended on a timeout or a refusal is asked
    // once more, and after how long.
    function test_a_cover_lookup_that_timed_out_is_asked_once_more() {
        compare(SL.artRetryMs(true, "artist song", "artist song", "", true), 25000)
        // Another track having had its second attempt is no reason against.
        compare(SL.artRetryMs(true, "artist song", "artist song", "some other song", true), 25000)
        // Everybody answered and nobody had it: that is final.
        compare(SL.artRetryMs(false, "artist song", "artist song", "", true), -1)
        // The track changed while the chain ran or the wait lasted.
        compare(SL.artRetryMs(true, "artist song", "next song", "", true), -1)
        compare(SL.artRetryMs(true, "artist song", "", "", true), -1)
        // This track has had its second attempt.
        compare(SL.artRetryMs(true, "artist song", "artist song", "artist song", true), -1)
        // Covers are switched off.
        compare(SL.artRetryMs(true, "artist song", "artist song", "", false), -1)
        compare(SL.artRetryMs(true, "artist song", "artist song", "", undefined), -1)
        // No key is no track, even when nothing plays either.
        compare(SL.artRetryMs(true, "", "", "", true), -1)
        compare(SL.artRetryMs(true, "", "", "some other song", true), -1)
        compare(SL.artRetryMs(true, null, null, null, true), -1)
        compare(SL.artRetryMs(true, undefined, undefined, undefined, true), -1)
        compare(SL.artRetryMs(), -1)
        // Only a real true is a transient end.
        compare(SL.artRetryMs("timeout", "artist song", "artist song", "", true), -1)
        compare(SL.artRetryMs(undefined, "artist song", "artist song", "", true), -1)
        var key = ""
        for (var i = 0; i < 1000; i++) key += "song "
        compare(SL.artRetryMs(true, key, key, "", true), 25000)
        compare(SL.artRetryMs(true, key, key + "x", "", true), -1)
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

    function test_the_settings_country_search_knows_the_everyday_names() {
        // Measured 2026-11-10: bycountry/uk answered a hundred rows, every one
        // Ukrainian, and bycountry/usa none. The popup reads both words right.
        var bare = "https://de1.api.radio-browser.info/json/stations"
        compare(SL.directoryBase("de1", "bycountry", "uk"), bare + "/bycountrycodeexact/GB")
        compare(SL.directoryBase("de1", "bycountry", "usa"), bare + "/bycountrycodeexact/US")
        // As the popup folds it: case, accents and spaces are no difference.
        compare(SL.directoryBase("de1", "bycountry", "  UK "), bare + "/bycountrycodeexact/GB")
        compare(SL.directoryBase("de1", "bycountry", "United   States"), bare + "/bycountrycodeexact/US")
        compare(SL.directoryBase("de1", "bycountry", "Eesti"), bare + "/bycountrycodeexact/EE")
        compare(SL.directoryBase("de1", "bycountry", "turgi"), bare + "/bycountrycodeexact/TR")
        compare(SL.directoryBase("de1", "bycountry", "Türgi"), bare + "/bycountrycodeexact/TR")
        // The page is asked the same way on the code road.
        compare(SL.directoryPage(SL.directoryBase("de1", "bycountry", "uk"), 100, 100),
                bare + "/bycountrycodeexact/GB?hidebroken=true&order=votes&reverse=true&limit=100&offset=100")
        compare(SL.rehost(SL.directoryBase("de1", "bycountry", "uk"), "nl1"),
                "https://nl1.api.radio-browser.info/json/stations/bycountrycodeexact/GB")
    }

    function test_a_country_word_no_alias_knows_is_asked_as_before() {
        var bare = "https://de1.api.radio-browser.info/json/stations"
        compare(SL.directoryBase("de1", "bycountry", "Portugal"), bare + "/bycountry/Portugal")
        compare(SL.directoryBase("de1", "bycountry", "ukr"), bare + "/bycountry/ukr")
        compare(SL.directoryBase("de1", "bycountry", "uk usa"), bare + "/bycountry/uk%20usa")
        // Names of an object's own furniture are no countries.
        compare(SL.directoryBase("de1", "bycountry", "constructor"), bare + "/bycountry/constructor")
        compare(SL.directoryBase("de1", "bycountry", "__proto__"), bare + "/bycountry/__proto__")
        compare(SL.directoryBase("de1", "bycountry", "toString"), bare + "/bycountry/toString")
        // Nothing typed is the bare list, a number is a word like any other.
        compare(SL.directoryBase("de1", "bycountry", "   "), bare)
        compare(SL.directoryBase("de1", "bycountry", null), bare)
        compare(SL.directoryBase("de1", "bycountry", 44), bare + "/bycountry/44")
        var far = ""
        for (var i = 0; i < 3000; i++) far += "u"
        compare(SL.directoryBase("de1", "bycountry", far), bare + "/bycountry/" + far)
        // Only the country road reads a country: "uk" is a name and a tag elsewhere.
        compare(SL.directoryBase("de1", "byname", "uk"), bare + "/byname/uk")
        compare(SL.directoryBase("de1", "bytag", "uk"), bare + "/bytag/uk")
        compare(SL.directoryBase("de1", "bylanguage", "usa"), bare + "/bylanguage/usa")
        // The code road is made here and never typed in.
        compare(SL.directoryBase("de1", "bycountrycodeexact", "GB"), bare + "/byname/GB")
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

    // ── a directory row the list already holds ──────────────────────────
    readonly property string _grooveUuid: "960cf833-0601-11e8-ae97-52543be04c81"

    function test_a_saved_station_is_known_by_its_directory_uuid() {
        // Measured 2026-11-10: saved at ice3, listed at ice2, one record.
        var saved = [{ hostname: "http://ice3.somafm.com/groovesalad-128-mp3", uuid: _grooveUuid }]
        var row = { url_resolved: "https://ice2.somafm.com/groovesalad-128-mp3",
                    url: "https://somafm.com/groovesalad.pls", stationuuid: _grooveUuid }
        verify(SL.knownStation(saved, row))
        compare(SL.knownStationAt(saved, row), 0)
        // Another record at another address is another station.
        var other = { url_resolved: "https://ice2.somafm.com/dronezone-128-mp3",
                      url: "https://somafm.com/dronezone.pls",
                      stationuuid: "11111111-0601-11e8-ae97-52543be04c81" }
        verify(!SL.knownStation(saved, other))
        compare(SL.knownStationAt(saved, other), -1)
    }

    function test_a_saved_station_is_known_by_either_address_of_the_row() {
        var saved = [{ hostname: "https://a.example/one", uuid: "" },
                     { hostname: "http://Stream.Example:80/live/", uuid: "" },
                     { hostname: "https://b.example/list.pls", uuid: "" }]
        // The resolved address, in the other scheme and without the slash.
        compare(SL.knownStationAt(saved, { url_resolved: "https://stream.example/live", url: "", stationuuid: "" }), 1)
        // The row's own address, where the saved row sits at the playlist.
        compare(SL.knownStationAt(saved, { url_resolved: "https://cdn.example/x.mp3",
                                           url: "https://b.example/list.pls", stationuuid: "" }), 2)
        // A mount is case-sensitive: another path is another station.
        compare(SL.knownStationAt(saved, { url_resolved: "https://stream.example/LIVE", url: "", stationuuid: "" }), -1)
        // The first saved row that matches is the answer.
        saved.push({ hostname: "https://a.example/one", uuid: "" })
        compare(SL.knownStationAt(saved, { url_resolved: "http://a.example/one", url: "", stationuuid: "" }), 0)
    }

    // The popup and the settings page hand over the rows of their models,
    // which keep a role per row the way the saved list does.
    ListModel { id: savedModel; dynamicRoles: true }

    function test_the_rows_of_a_station_model_are_known_too() {
        savedModel.clear()
        savedModel.append({ hostname: "https://first.example/a", name: "First" })
        savedModel.append({ hostname: "http://ice3.somafm.com/groovesalad-128-mp3", prev: "", uuid: _grooveUuid })
        var saved = []
        for (var i = 0; i < savedModel.count; i++) saved.push(savedModel.get(i))
        compare(SL.knownStationAt(saved, { url_resolved: "https://ice2.somafm.com/groovesalad-128-mp3",
                                           url: "", stationuuid: _grooveUuid }), 1)
        compare(SL.knownStationAt(saved, { url_resolved: "http://first.example/a/", url: "", stationuuid: "" }), 0)
        // The directory's row as a model row, the way the settings page holds it.
        savedModel.append({ url_resolved: "https://first.example/a", url: "", stationuuid: "" })
        compare(SL.knownStationAt(saved, savedModel.get(2)), 0)
    }

    function test_a_healed_station_is_known_by_where_it_was() {
        var saved = [{ hostname: "https://new.example/live", prev: "http://old.example/live", uuid: "" }]
        verify(SL.knownStation(saved, { url_resolved: "https://old.example/live", url: "", stationuuid: "" }))
        verify(SL.knownStation(saved, { url_resolved: "https://x.example/y", url: "http://old.example/live/", stationuuid: "" }))
        verify(!SL.knownStation(saved, { url_resolved: "https://older.example/live", url: "", stationuuid: "" }))
    }

    function test_nothing_is_known_by_an_empty_uuid_or_an_empty_address() {
        // Two rows without a uuid are not one station for that.
        verify(!SL.knownStation([{ hostname: "https://a.example/one", uuid: "" }],
                                { url_resolved: "https://b.example/two", url: "", stationuuid: "" }))
        verify(!SL.knownStation([{ hostname: "https://a.example/one" }],
                                { url_resolved: "https://b.example/two" }))
        // An empty prev is no address, and neither is a row's missing url.
        verify(!SL.knownStation([{ hostname: "https://a.example/one", prev: "", uuid: "" }],
                                { url_resolved: "https://b.example/two", url: "", stationuuid: "" }))
        verify(!SL.knownStation([{ hostname: "", prev: "", uuid: "" }], { url_resolved: "", url: "", stationuuid: "" }))
        verify(!SL.knownStation([{ hostname: "  ", uuid: " " }], { url_resolved: " ", url: "  ", stationuuid: " " }))
    }

    function test_a_broken_list_or_row_knows_nothing_and_throws_nothing() {
        var row = { url_resolved: "https://a.example/one", url: "", stationuuid: "u-1" }
        compare(SL.knownStationAt(null, row), -1)
        compare(SL.knownStationAt(undefined, row), -1)
        compare(SL.knownStationAt("https://a.example/one", row), -1)
        compare(SL.knownStationAt([], row), -1)
        compare(SL.knownStationAt([{ hostname: "https://a.example/one", uuid: "u-1" }], null), -1)
        compare(SL.knownStationAt([{ hostname: "https://a.example/one", uuid: "u-1" }], "u-1"), -1)
        // Rows that are no rows are stepped over, and the good one is found.
        compare(SL.knownStationAt([null, 7, "x", { hostname: 5, uuid: 6 },
                                   { hostname: "https://a.example/one" }], row), 4)
        // The catalogue types its fields as strings and a mirror may not.
        compare(SL.knownStationAt([{ hostname: "https://a.example/one", uuid: "u-1" }],
                                  { url_resolved: 12, url: ["x"], stationuuid: { a: 1 } }), -1)
        // A uuid that is a property name is only a string.
        compare(SL.knownStationAt([{ hostname: "https://a.example/one", uuid: "constructor" }],
                                  { url_resolved: "https://z.example/", url: "", stationuuid: "constructor" }), 0)
        // An address past any honest length is compared like any other.
        var far = "https://a.example/"
        for (var i = 0; i < 3000; i++) far += "x"
        compare(SL.knownStationAt([{ hostname: far, uuid: "" }], { url_resolved: far + "/", url: "", stationuuid: "" }), 0)
        compare(SL.knownStationAt([{ hostname: far, uuid: "" }], { url_resolved: far + "y", url: "", stationuuid: "" }), -1)
    }

    // ── knownStation: the saved rows an answer named ─────────────────────
    function test_a_known_row_names_the_saved_station_it_is() {
        var saved = [{ hostname: "https://first.example/a", uuid: "" },
                     { hostname: "http://ice3.somafm.com/groovesalad-128-mp3", prev: "", uuid: _grooveUuid }]
        var named = []
        // Listed at another server under the same uuid: the list's own address is kept.
        verify(SL.knownStation(saved, { url_resolved: "https://ice2.somafm.com/groovesalad-128-mp3",
                                        url: "", stationuuid: _grooveUuid }, named))
        compare(named.length, 1)
        compare(named[0].url_resolved, "http://ice3.somafm.com/groovesalad-128-mp3")
        compare(named[0].url, "")
        compare(named[0].stationuuid, _grooveUuid)
        // What it kept finds that saved row again.
        compare(SL.knownStationAt(saved, named[0]), 1)
        // A row the list does not hold names nothing.
        verify(!SL.knownStation(saved, { url_resolved: "https://nobody.example/x", url: "", stationuuid: "n-1" }, named))
        compare(named.length, 1)
    }

    function test_a_station_named_twice_is_kept_once() {
        var saved = [{ hostname: "https://first.example/a", uuid: "f-1" }, { hostname: "https://second.example/b", uuid: "" }]
        var named = []
        // One answer walked twice, the http twin of the row, and the next page's copy.
        verify(SL.knownStation(saved, { url_resolved: "https://first.example/a", url: "", stationuuid: "" }, named))
        verify(SL.knownStation(saved, { url_resolved: "http://first.example/a/", url: "", stationuuid: "" }, named))
        verify(SL.knownStation(saved, { url_resolved: "https://moved.example/a", url: "", stationuuid: "f-1" }, named))
        compare(named.length, 1)
        verify(SL.knownStation(saved, { url_resolved: "https://second.example/b", url: "", stationuuid: "" }, named))
        compare(named.length, 2)
        compare(named[1].url_resolved, "https://second.example/b")
        compare(named[1].stationuuid, "")
        // Stations added by hand carry no uuid, and two of them are two stations.
        var byHand = [{ hostname: "https://one.example/a", uuid: "" }, { hostname: "https://two.example/b", uuid: "" }]
        named = []
        verify(SL.knownStation(byHand, { url_resolved: "https://one.example/a", url: "", stationuuid: "" }, named))
        verify(SL.knownStation(byHand, { url_resolved: "https://two.example/b", url: "", stationuuid: "" }, named))
        compare(named.length, 2)
        compare(SL.knownStationAt(byHand, named[1]), 1)
    }

    function test_a_healed_station_is_named_by_where_it_stands_now() {
        var saved = [{ hostname: "https://new.example/live", prev: "http://old.example/live", uuid: "" }]
        var named = []
        verify(SL.knownStation(saved, { url_resolved: "https://old.example/live", url: "", stationuuid: "" }, named))
        compare(named.length, 1)
        compare(named[0].url_resolved, "https://new.example/live")
        // The list is reloaded with the row moved once more: still found, by where it was.
        var later = [{ hostname: "https://newer.example/live", prev: "https://new.example/live", uuid: "" }]
        compare(SL.knownStationAt(later, named[0]), 0)
    }

    function test_no_list_to_name_into_still_answers() {
        var saved = [{ hostname: "https://first.example/a", uuid: "f-1" }]
        var row = { url_resolved: "https://first.example/a", url: "", stationuuid: "f-1" }
        var none = [undefined, null, "", "x", 7, {}, { length: 0 }]
        for (var i = 0; i < none.length; i++) {
            verify(SL.knownStation(saved, row, none[i]))
            verify(!SL.knownStation(saved, { url_resolved: "https://b.example/", url: "", stationuuid: "" }, none[i]))
        }
        verify(SL.knownStation(saved, row))
        // A saved row whose fields are no strings is named with empty ones.
        var odd = [{ hostname: "https://first.example/a", uuid: 12 }], named = []
        verify(SL.knownStation(odd, row, named))
        compare(named.length, 1)
        compare(named[0].stationuuid, "")
        compare(named[0].url_resolved, "https://first.example/a")
        // A broken list or row names nothing and throws nothing.
        named = []
        verify(!SL.knownStation(null, row, named))
        verify(!SL.knownStation(saved, null, named))
        compare(named.length, 0)
        // What already stands in the list and is no row is stepped over.
        named = [null, 7, "x"]
        verify(SL.knownStation(saved, row, named))
        compare(named.length, 4)
    }

    function test_a_long_answer_names_every_saved_station_once() {
        var saved = [], named = []
        for (var i = 0; i < 300; i++) saved.push({ hostname: "https://s" + i + ".example/live", uuid: "u-" + i, prev: "" })
        for (var pass = 0; pass < 2; pass++)
            for (var k = 0; k < 300; k++)
                verify(SL.knownStation(saved, { url_resolved: "http://s" + k + ".example/live/", url: "", stationuuid: "" }, named))
        compare(named.length, 300)
        compare(named[299].stationuuid, "u-299")
        compare(SL.knownStationAt(saved, named[150]), 150)
    }

    // ── pageAfter: where "Show more" stands ──────────────────────────────
    // The search asks for fifty rows a page and shows thirty a click.
    readonly property string _qs50: "/json/stations/search?name=nova&hidebroken=true&order=votes&reverse=true&limit=50"

    function test_a_page_nothing_was_dropped_from_goes_on_where_the_cap_cut_it() {
        // Fifty rows, none saved: the walk stops at the thirtieth.
        var first = SL.pageAfter(_qs50, 0, 50, 30)
        compare(first.at, 30)
        compare(first.more, true)
        // The next page is asked from there and cut at thirty again.
        var second = SL.pageAfter(_qs50, first.at, 50, 30)
        compare(second.at, 60)
        compare(second.more, true)
    }

    function test_a_full_page_half_saved_still_has_a_next_one() {
        // Fifty rows, twenty-five of them the listener's own: twenty-five are
        // shown, under the cap, and every row was walked. The page was full,
        // so the directory may hold a fifty-first.
        var p = SL.pageAfter(_qs50, 0, 50, 50)
        compare(p.at, 50)
        compare(p.more, true)
    }

    function test_a_next_page_of_thirty_duplicates_and_twenty_new_still_has_one_behind_it() {
        // Asked from row 30. Twenty rows go in, short of the thirty the click
        // had room for, and the next page starts behind all fifty.
        var p = SL.pageAfter(_qs50, 30, 50, 50)
        compare(p.at, 80)
        compare(p.more, true)
    }

    function test_a_page_of_nothing_but_duplicates_is_asked_past() {
        // The same numbers whatever the dedup left: what is shown is no input.
        var p = SL.pageAfter(_qs50, 80, 50, 50)
        compare(p.at, 130)
        compare(p.more, true)
    }

    function test_a_short_page_is_the_end_of_the_list() {
        // Twelve rows answered a query that asked for fifty.
        compare(SL.pageAfter(_qs50, 0, 12, 12).more, false)
        compare(SL.pageAfter(_qs50, 0, 12, 12).at, 12)
        // One row short of a full page is short; the full page is not.
        compare(SL.pageAfter(_qs50, 0, 49, 49).more, false)
        compare(SL.pageAfter(_qs50, 0, 50, 50).more, true)
        // Thirty rows fill the cap exactly and the walk still reached the end.
        compare(SL.pageAfter(_qs50, 0, 30, 30).more, false)
        // A short page the cap cut has its tail still unshown.
        compare(SL.pageAfter(_qs50, 0, 40, 30).more, true)
        compare(SL.pageAfter(_qs50, 0, 40, 30).at, 30)
        // The last rows of the list, a short page of duplicates: nothing behind it.
        compare(SL.pageAfter(_qs50, 100, 7, 7).more, false)
        compare(SL.pageAfter(_qs50, 100, 7, 7).at, 107)
    }

    function test_an_empty_page_ends_the_list_where_it_stood() {
        var p = SL.pageAfter(_qs50, 100, 0, 0)
        compare(p.at, 100)
        compare(p.more, false)
    }

    function test_before_any_answer_there_is_no_next_page() {
        compare(SL.pageAfter().at, 0)
        compare(SL.pageAfter().more, false)
        compare(SL.pageAfter(null, null, null, null).more, false)
        compare(SL.pageAfter(undefined, undefined, undefined, undefined).at, 0)
        compare(SL.pageAfter("", 0, 0, 0).more, false)
    }

    function test_a_query_without_a_limit_has_no_full_page() {
        // Asked without a limit the directory sends the whole list.
        var whole = "/json/stations/search?name=nova"
        compare(SL.pageAfter(whole, 0, 50, 50).more, false)
        compare(SL.pageAfter(whole, 0, 50, 30).more, true)
        compare(SL.pageAfter("", 0, 50, 50).more, false)
        compare(SL.pageAfter(null, 0, 50, 50).more, false)
        // Only the query's own limit counts: not a name that holds the word,
        // not a limit of nothing, not one that is no number.
        compare(SL.pageAfter("/json/stations/search?name=limit=50", 0, 50, 50).more, false)
        compare(SL.pageAfter("/json/stations/search?name=x&nolimit=50", 0, 50, 50).more, false)
        compare(SL.pageAfter("/json/stations/search?name=x&limit=0", 0, 50, 50).more, false)
        compare(SL.pageAfter("/json/stations/search?name=x&limit=fifty", 0, 50, 50).more, false)
        compare(SL.pageAfter("/json/stations/search?limit=50&name=x", 0, 50, 50).more, true)
        compare(SL.pageAfter("/json/stations/search?name=x&limit=20", 0, 20, 20).more, true)
        compare(SL.pageAfter("/json/stations/search?name=x&limit=20", 0, 19, 19).more, false)
    }

    function test_counts_that_are_no_counts_read_as_nothing() {
        // A walk cannot pass more rows than the answer carried.
        compare(SL.pageAfter(_qs50, 0, 50, 80).at, 50)
        compare(SL.pageAfter(_qs50, 0, 12, 80).more, false)
        // Below zero, not a number, no number at all.
        compare(SL.pageAfter(_qs50, -30, 50, 30).at, 30)
        compare(SL.pageAfter(_qs50, NaN, 50, 30).at, 30)
        compare(SL.pageAfter(_qs50, "x", 50, 30).at, 30)
        compare(SL.pageAfter(_qs50, 30, -5, -5).at, 30)
        compare(SL.pageAfter(_qs50, 30, -5, -5).more, false)
        compare(SL.pageAfter(_qs50, 30, 50, NaN).at, 30)
        compare(SL.pageAfter(_qs50, 30, 50, NaN).more, true)
        compare(SL.pageAfter(_qs50, 30, {}, []).more, false)
        // Numbers that came as text, and halves of a row.
        compare(SL.pageAfter(_qs50, "30", "50", "50").at, 80)
        compare(SL.pageAfter(_qs50, "30", "50", "50").more, true)
        compare(SL.pageAfter(_qs50, 30.9, 50.9, 30.9).at, 60)
        // A query that is no string.
        compare(SL.pageAfter(50, 0, 50, 50).more, false)
        compare(SL.pageAfter({ limit: 50 }, 0, 50, 50).more, false)
    }

    function test_a_list_and_a_query_past_any_honest_length_are_only_numbers() {
        // A mirror that ignores the limit and sends everything it has.
        var p = SL.pageAfter(_qs50, 1000000000, 100000, 100000)
        compare(p.at, 1000100000)
        compare(p.more, true)
        compare(SL.pageAfter(_qs50, 0, 100000, 30).at, 30)
        var name = ""
        for (var i = 0; i < 20000; i++) name += "limit=50x"
        compare(SL.pageAfter("/json/stations/search?name=" + name + "&limit=50", 0, 50, 50).more, true)
        compare(SL.pageAfter("/json/stations/search?name=" + name, 0, 50, 50).more, false)
        // A page size no directory serves is still only a size.
        compare(SL.pageAfter("/json/stations/search?name=x&limit=99999999999999999999999", 0, 50, 50).more, false)
    }

    // ── A directory answer that is no list ────────────────────────────────

    function test_a_directory_answer_is_its_rows() {
        compare(SL.directoryRows(200, "[]").length, 0)
        var rows = SL.directoryRows(200, '[{"name":"A","url":"http://a.example/s"},{"name":"B"}]')
        compare(rows.length, 2)
        compare(rows[0].name, "A")
        var many = []
        for (var i = 0; i < 2000; i++) many.push({ "name": "s" + i })
        compare(SL.directoryRows(200, JSON.stringify(many)).length, 2000)
    }

    function test_json_that_is_no_list_is_no_answer() {
        // The settings search parsed first and counted after: a body of
        // "null" set its retry counter back to 0 and then threw on .length,
        // so the page asked again without end, and an error object read as
        // an empty result. Neither is a list.
        compare(SL.directoryRows(200, "null"), null)
        compare(SL.directoryRows(200, '{"error":"busy"}'), null)
        compare(SL.directoryRows(200, '"[]"'), null)
        compare(SL.directoryRows(200, "42"), null)
        compare(SL.directoryRows(200, "true"), null)
    }

    function test_a_page_or_nothing_is_no_answer() {
        compare(SL.directoryRows(200, "<html>Sign in to the hotel wifi</html>"), null)
        compare(SL.directoryRows(200, ""), null)
        compare(SL.directoryRows(200, undefined), null)
        compare(SL.directoryRows(200, null), null)
    }

    function test_any_other_status_is_no_answer_whatever_the_body() {
        compare(SL.directoryRows(503, "[]"), null)
        compare(SL.directoryRows(0, "[]"), null)
        compare(SL.directoryRows(204, "[]"), null)
        compare(SL.directoryRows("200", "[]"), null)
        compare(SL.directoryRows(undefined, "[]"), null)
    }

    // ── tagListPaged: the name list or the tag list ──────────────────────
    function test_a_genre_page_of_nothing_but_saved_stations_is_the_list_that_is_paged() {
        // "jazz": no station of that name, and the fifty tagged ones all saved.
        // Nothing went onto the web list; the page was full, so it may go on.
        verify(SL.tagListPaged(true, false, 50, true))
        // The same with a name list that goes on behind its leads.
        verify(SL.tagListPaged(true, true, 50, true))
        // The two answers as pageAfter reads them, every row of each walked.
        var names = SL.pageAfter(_qs50, 0, 0, 0), tags = SL.pageAfter(_qs50, 0, 50, 50)
        verify(SL.tagListPaged(true, names.more, 50, tags.more))
    }

    function test_a_genre_list_that_has_run_out_leaves_the_paging_to_the_names() {
        // Three tagged stations, a short page walked to its end, names that go on.
        verify(!SL.tagListPaged(true, true, 3, false))
        verify(!SL.tagListPaged(true, true, 1, false))
        verify(!SL.tagListPaged(true, true, 49, false))
        // A full page may have another behind it; so has a short one the cap cut.
        verify(SL.tagListPaged(true, true, 50, true))
        verify(SL.tagListPaged(true, true, 40, true))
        // With the names run out too it stays the genre's list. Neither goes on.
        verify(SL.tagListPaged(true, false, 3, false))
    }

    function test_a_plain_words_names_are_paged_while_they_go_on() {
        // "nova": half of its first fifty names saved, and a tag list of any size.
        verify(!SL.tagListPaged(false, true, 50, true))
        verify(!SL.tagListPaged(false, true, 2, false))
        // The names have run out: the tag list follows, whatever went on screen.
        verify(SL.tagListPaged(false, false, 50, true))
        verify(SL.tagListPaged(false, false, 2, false))
    }

    function test_a_tag_answer_of_no_rows_is_never_the_list_that_is_paged() {
        verify(!SL.tagListPaged(true, false, 0, false))
        verify(!SL.tagListPaged(true, true, 0, false))
        verify(!SL.tagListPaged(false, false, 0, false))
        // No rows and a claim of more: still no list to page.
        verify(!SL.tagListPaged(true, false, 0, true))
        // One row is an answer.
        verify(SL.tagListPaged(true, false, 1, false))
        verify(SL.tagListPaged(false, false, 1, false))
        // Nothing said at all.
        verify(!SL.tagListPaged())
        verify(!SL.tagListPaged(null, null, null, null))
        verify(!SL.tagListPaged(true, false))
        verify(!SL.tagListPaged(true, false, undefined, true))
    }

    function test_the_two_lists_are_told_apart_by_true_alone() {
        // A genre flag that is no true is a plain word: the names come first.
        var flags = ["true", 1, {}, [], "jazz", null, undefined]
        for (var i = 0; i < flags.length; i++) {
            verify(!SL.tagListPaged(flags[i], true, 50, true))
            verify(SL.tagListPaged(flags[i], false, 50, true))
        }
        // Names that are not known to go on have run out, and so has a tag list.
        var more = ["true", 1, {}, null, undefined, 0, ""]
        for (var k = 0; k < more.length; k++) {
            verify(SL.tagListPaged(false, more[k], 2, false))
            verify(!SL.tagListPaged(true, true, 50, more[k]))
        }
        // Counts that are no counts are no rows; text that is a number is one.
        var none = [NaN, -3, {}, [], "x", null]
        for (var j = 0; j < none.length; j++)
            verify(!SL.tagListPaged(true, false, none[j], true))
        verify(SL.tagListPaged(true, true, "50", true))
    }

    function test_a_tag_answer_past_any_honest_length_is_read_the_same() {
        verify(SL.tagListPaged(true, true, 100000, true))
        verify(!SL.tagListPaged(false, true, 100000, true))
        verify(SL.tagListPaged(false, false, 100000, true))
        verify(!SL.tagListPaged(true, true, 100000, false))
    }

    // ── pageOpen: the ceiling on the rows shown ──────────────────────────
    function test_the_ceiling_is_held_against_the_rows_on_screen() {
        var more = SL.pageAfter(_qs50, 270, 50, 50)
        // 270 rows up, a page of 49 duplicates and one new station: 271.
        verify(SL.pageOpen(more, 271, 300))
        verify(SL.pageOpen(more, 285, 300))
        // One row under the ceiling there is room for one more.
        verify(SL.pageOpen(more, 299, 300))
        // At the ceiling, and past it, the list has stopped.
        verify(!SL.pageOpen(more, 300, 300))
        verify(!SL.pageOpen(more, 301, 300))
        // An ordinary page far from it, and a first page of nothing but saved stations.
        verify(SL.pageOpen(more, 30, 300))
        verify(SL.pageOpen(more, 0, 300))
        // The ceiling is the caller's number.
        verify(SL.pageOpen(more, 4, 5))
        verify(!SL.pageOpen(more, 5, 5))
    }

    function test_a_list_that_has_ended_is_closed_however_few_rows_show() {
        var ended = SL.pageAfter(_qs50, 50, 7, 7)
        verify(!SL.pageOpen(ended, 0, 300))
        verify(!SL.pageOpen(ended, 57, 300))
        verify(!SL.pageOpen(ended, 299, 300))
        // No answer yet.
        verify(!SL.pageOpen(SL.pageAfter(), 0, 300))
    }

    function test_a_page_or_a_count_that_is_none_is_closed() {
        var pages = [undefined, null, "", "more", 7, true, [], {}, { more: "true" }, { more: 1 }, { at: 50 }]
        for (var i = 0; i < pages.length; i++)
            verify(!SL.pageOpen(pages[i], 0, 300))
        verify(!SL.pageOpen())
        var more = { at: 50, more: true }
        var none = [undefined, null, NaN, "12", "", {}, []]
        for (var k = 0; k < none.length; k++) {
            verify(!SL.pageOpen(more, none[k], 300))
            verify(!SL.pageOpen(more, 12, none[k]))
        }
        // No ceiling to speak of leaves no room.
        verify(!SL.pageOpen(more, 0, 0))
        verify(!SL.pageOpen(more, 0, -300))
    }

    function test_counts_past_any_honest_length_are_only_numbers() {
        var more = { at: 1000000000, more: true }
        verify(!SL.pageOpen(more, 1000000000, 300))
        verify(SL.pageOpen(more, 5, 1000000000))
        verify(SL.pageOpen(more, 999999999, 1000000000))
        verify(!SL.pageOpen(more, Infinity, 300))
    }

    // ── emptyNext: the listener's own stations are an answer ─────────────
    function test_saved_stations_an_answer_named_are_no_empty_answer() {
        // Fifty saved jazz stations and no web row: nothing is asked again.
        compare(_empty({ own: 50 }), "done")
        compare(_empty({ own: 1 }), "done")
        compare(_empty({ own: 50, inheritedScope: true }), "done")
        compare(_empty({ own: 50, bareScope: true }), "done")
        compare(_empty({ own: 50, mode: "genre", inheritedScope: true }), "done")
        // Without them the answer is as empty as it was.
        compare(_empty({ own: 0 }), "stems")
        compare(_empty({ own: 0, inheritedScope: true }), "unscope")
        compare(_empty({ own: 0, bareScope: true }), "astyped")
        compare(_empty({}), "stems")
    }

    function test_a_thin_answer_counts_the_listeners_own_stations_too() {
        // A name with its country still asks inside the country under three rows.
        compare(_empty({ count: 1, own: 1, inCountry: true }), "incountry")
        compare(_empty({ count: 0, own: 2, inCountry: true }), "incountry")
        compare(_empty({ count: 0, own: 0, inCountry: true }), "incountry")
        // Three found, web rows or the listener's own, is an answer.
        compare(_empty({ count: 1, own: 2, inCountry: true }), "done")
        compare(_empty({ count: 0, own: 3, inCountry: true }), "done")
        compare(_empty({ count: 2, own: 1, inCountry: true }), "done")
    }

    function test_an_own_that_is_no_count_names_no_station() {
        var none = [undefined, null, NaN, -5, "", "x", {}, []]
        for (var i = 0; i < none.length; i++) {
            compare(_empty({ own: none[i] }), "stems")
            compare(_empty({ own: none[i], inheritedScope: true }), "unscope")
            compare(_empty({ count: 3, own: none[i] }), "done")
        }
        compare(_empty({ own: "4" }), "done")
        compare(_empty({ own: 2.9 }), "done")
        compare(_empty({ own: 1000000 }), "done")
        // No answer from the network stays no answer, whatever was named before it.
        compare(_empty({ own: 50, gotAnswer: false }), "done")
        // A web count that is no count is none, and the two are added, not joined.
        compare(_empty({ count: undefined, own: 50 }), "done")
        compare(_empty({ count: NaN, own: 0 }), "stems")
        compare(_empty({ count: "1", own: "1", inCountry: true }), "incountry")
        compare(_empty({ count: "1", own: "2", inCountry: true }), "done")
    }
}
