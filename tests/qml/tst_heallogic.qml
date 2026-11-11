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

    function test_an_edit_that_stays_with_the_station_keeps_its_uuid() {
        // Renamed only.
        verify(HL.editKeepsIdentity("Vikerraadio", "http://icecast.err.ee/vikerraadio.mp3",
                                    "Viker", "http://icecast.err.ee/vikerraadio.mp3"));
        // Scheme and a trailing slash are not a move, even under a shared roof.
        verify(HL.editKeepsIdentity("Jazz", "http://stream.zeno.fm/abc/", "My Jazz", "https://stream.zeno.fm/abc"));
        // A new mount on the station's own domain, same name.
        verify(HL.editKeepsIdentity("Vikerraadio", "http://icecast.err.ee/vikerraadio.mp3",
                                    "  vikerraadio ", "https://icecast.err.ee/vikerraadio.opus"));
        // Another host under the same registrable name.
        verify(HL.editKeepsIdentity("BBC Radio 1", "http://stream.live.bbc.co.uk/r1",
                                    "BBC Radio 1", "http://media.bbc.co.uk/r1.m3u8"));
        verify(HL.editKeepsIdentity("Radio X", "http://1.2.3.4:8000/live", "Radio X", "http://1.2.3.4:8010/live"));
        verify(HL.editKeepsIdentity(null, null, undefined, undefined));
        // A name that arrives as a number is still a name (a station called 80).
        verify(HL.editKeepsIdentity(80, "http://a.example/1", "80", "http://a.example/2"));
    }

    function test_an_edit_that_leaves_the_station_drops_its_uuid() {
        // The row was pointed at another station altogether.
        verify(!HL.editKeepsIdentity("Vikerraadio", "http://icecast.err.ee/vikerraadio.mp3",
                                     "Groove Salad", "https://ice1.somafm.com/groovesalad-128-mp3"));
        // A sister station under the same roof is still another station.
        verify(!HL.editKeepsIdentity("Vikerraadio", "http://icecast.err.ee/vikerraadio.mp3",
                                     "Raadio 2", "http://icecast.err.ee/raadio2.mp3"));
        // Same name on a new domain proves nothing: names are not unique.
        verify(!HL.editKeepsIdentity("Radio 1", "http://icecast.err.ee/r1.mp3", "Radio 1", "http://stream.bbc.co.uk/r1"));
        verify(!HL.editKeepsIdentity("Radio 1", "http://a.bbc.co.uk/r1", "Radio 1", "http://a.itv.co.uk/r1"));
        // A landlord's domain proves nothing either.
        verify(!HL.editKeepsIdentity("Jazz", "https://stream.zeno.fm/abc", "Jazz", "https://stream.zeno.fm/xyz"));
        // An address no parser finds a host in.
        verify(!HL.editKeepsIdentity("Radio X", "http://radiox.example/live", "Radio X", "mms://radiox.example/live"));
        verify(!HL.editKeepsIdentity("Radio X", "http://radiox.example/live", "Radio X", "radiox.example/live2"));
    }

    function test_two_spellings_of_one_address_fold_together() {
        compare(HL.addrKey("  HTTPS://Stream.Example/live/ "), "stream.example/live");
        compare(HL.addrKey("http://stream.example/live"), "stream.example/live");
        compare(HL.addrKey(null), "");
    }

    // The name rung. Shaped after the five exact-name rows "Rock FM" answered
    // with on 2026-09-21, in the directory's vote order: four countries, the
    // second Spanish mount an HLS playlist, the Russian one without a bitrate.
    function row(name, cc, url, br, ok) {
        return { name: name, countrycode: cc, country: cc, url_resolved: url,
                 bitrate: br, lastcheckok: ok === undefined ? 1 : ok };
    }
    function rock() {
        return [ row("ROCK FM", "RU", "http://nashe1.hostingradio.ru/rock-128.mp3", 0),
                 row("Rock FM", "ES", "http://flucast26-h-cloud.flumotion.com/cope/rockfm-low.mp3", 96),
                 row("Rock FM", "EE", "https://edge02.cdn.bitflip.ee:8888/rck", 320),
                 row("Rock FM", "ES", "http://rockfm.cope.stream.flumotion.com/cope/rockfm/playlist.m3u8", 64),
                 row("Rock FM", "LT", "https://stream2.rockfm.lt/crf128.mp3", 128) ];
    }
    readonly property string dead: "http://198.51.100.7:8000/rock"
    function order(o) {
        var out = [];
        for (var i = 0; i < o.cands.length; i++) out.push(o.cands[i].cc + o.cands[i].bitrate);
        return out.join(" ");
    }
    function urls(list) {
        var out = [];
        for (var i = 0; i < list.length; i++) out.push(list[i].url);
        return out.join(" ");
    }

    function test_a_wake_up_gets_the_old_ladder_row_for_row() {
        // The old ladder, built the old way: every row of the fixture passes
        // the gates with the exact name, so it is rank() over score 2.
        var old = HL.rank([
            { url: "http://nashe1.hostingradio.ru/rock-128.mp3", score: 2, bitrate: 0, hls: false },
            { url: "http://flucast26-h-cloud.flumotion.com/cope/rockfm-low.mp3", score: 2, bitrate: 96, hls: false },
            { url: "https://edge02.cdn.bitflip.ee:8888/rck", score: 2, bitrate: 320, hls: false },
            { url: "http://rockfm.cope.stream.flumotion.com/cope/rockfm/playlist.m3u8", score: 2, bitrate: 64, hls: true },
            { url: "https://stream2.rockfm.lt/crf128.mp3", score: 2, bitrate: 128, hls: false } ]);
        compare(old.length, 5);
        var o = HL.ladder(rock(), dead, "Rock FM", "", true);
        compare(o.cands.length, 5);
        compare(o.refused, 0);
        compare(urls(o.cands), urls(old));
        // Knowing the country moves nothing either: an alarm's four
        // auditions are the same four, in the same order.
        var k = HL.ladder(rock(), dead, "Rock FM", "LT", true);
        compare(k.cands.length, 5);
        compare(k.refused, 0);
        compare(urls(k.cands), urls(old));
        compare(HL.searchTail(true), "&hidebroken=true&order=votes&reverse=true&limit=30");
    }

    function test_a_wake_up_row_still_says_whether_it_is_a_stranger() {
        var k = HL.ladder(rock(), dead, "Rock FM", "LT", true);
        compare(k.cands.length, 5);
        compare(order(k), "EE320 LT128 ES96 RU0 ES64");
        compare(k.cands[0].kin, false);    // the Estonian one plays first, and is named
        compare(k.cands[0].near, false);
        compare(k.cands[1].kin, true);     // the listener's own station needs no warning
    }

    function test_namesakes_from_several_countries_are_not_auditioned() {
        var o = HL.ladder(rock(), dead, "Rock FM", "", false);
        compare(o.cands.length, 0);
        compare(o.refused, 5);
    }

    function test_the_uuid_records_country_picks_the_listeners_station() {
        var o = HL.ladder(rock(), dead, "Rock FM", "es", false);
        compare(o.cands.length, 2);
        compare(order(o), "ES96 ES64");
        compare(o.refused, 3);
        compare(o.cands[0].kin, true);
        compare(o.cands[1].hls, true);     // HLS is still the last door
        // A code that is no code is no witness.
        var bad = HL.ladder(rock(), dead, "Rock FM", "Spain", false);
        compare(bad.cands.length, 0);
    }

    function test_with_a_witness_a_countryless_row_is_left_out() {
        var rows = rock();
        rows.push(row("Rock FM", "", "http://rockfm.example.com.tr:9450/stream", 128));
        var o = HL.ladder(rows, dead, "Rock FM", "ES", false);
        compare(o.cands.length, 2);
        compare(order(o), "ES96 ES64");
        compare(o.refused, 4);
    }

    function test_the_stations_own_broken_record_testifies_to_its_country() {
        var own = rock();
        own.push(row("Rock FM", "ES", dead, 128, 0));
        var o = HL.ladder(own, dead, "Rock FM", "", false);
        compare(o.cands.length, 2);        // the broken record itself never auditions
        compare(order(o), "ES96 ES64");
        compare(o.cands[0].kin, true);
        compare(o.refused, 3);
        compare(HL.homeCountry(own, " https://198.51.100.7:8000/rock/ "), "ES");
        compare(HL.homeCountry(rock(), dead), "");
        // Two records of the one address under two countries prove nothing.
        own.push(row("Rock FM", "PT", dead, 128, 0));
        compare(HL.homeCountry(own, dead), "");
        compare(HL.homeCountry(null, null), "");
    }

    function test_one_country_agreeing_with_itself_auditions_but_is_not_vouched_for() {
        var all = rock();
        var o = HL.ladder([all[1], all[3]], dead, "Rock FM", "", false);
        compare(o.cands.length, 2);
        compare(o.refused, 0);
        compare(o.cands[0].near, true);
        compare(o.cands[0].kin, false);
    }

    function test_a_row_without_a_country_abstains() {
        var all = rock();
        var blank = row("Rock FM", "", "http://rockfm.example.com.tr:9450/stream", 128);
        var o = HL.ladder([all[1], all[3], blank], dead, "Rock FM", "", false);
        compare(o.cands.length, 2);
        compare(order(o), "ES96 ES64");
        compare(o.refused, 1);
        compare(o.cands[0].near, true);
        compare(o.cands[0].kin, false);
        var p = HL.ladder([blank, all[1]], dead, "Rock FM", "", false);
        compare(p.cands.length, 1);
        compare(p.cands[0].cc, "ES");
        compare(p.refused, 1);
    }

    function test_rows_without_a_country_cannot_agree() {
        var a = row("Rock FM", "", "http://a.example/rock", 128);
        var b = row("Rock FM", null, "http://b.example/rock", 128);
        var two = HL.ladder([a, b], dead, "Rock FM", "", false);
        compare(two.cands.length, 0);
        compare(two.refused, 2);
        // Alone it is the only answer there is, as it always was.
        var one = HL.ladder([a], dead, "Rock FM", "", false);
        compare(one.cands.length, 1);
        compare(one.refused, 0);
        compare(one.cands[0].cc, "??");
        compare(one.cands[0].kin, false);
    }

    function test_the_own_domain_still_wins_and_keeps_its_exact_verdict() {
        var o = HL.ladder(rock(), "https://stream2.rockfm.lt/old-mount", "Rock FM", "", false);
        compare(o.cands.length, 1);
        compare(o.refused, 4);
        compare(o.cands[0].cc, "LT");
        compare(o.cands[0].score, 4);
        compare(o.cands[0].exact, true);   // what the commit gate reads for a permanent write
        compare(o.cands[0].kin, true);
    }

    function test_a_shared_host_earns_no_home_bonus_and_is_no_witness() {
        var rows = [ row("Rock FM", "ES", "https://stream.zeno.fm/aaa", 128),
                     row("Rock FM", "ES", "http://flucast26-h-cloud.flumotion.com/cope/rockfm-low.mp3", 96) ];
        var o = HL.ladder(rows, "https://stream.zeno.fm/dead", "Rock FM", "", false);
        compare(o.cands.length, 2);
        compare(o.cands[0].score, 2);
        compare(o.cands[0].home, false);
        compare(o.cands[0].kin, false);    // the rows agree; nobody vouched
        compare(HL.homeCountry(rows, "https://stream.zeno.fm/dead"), "");
    }

    function test_the_ladder_gates_rows_before_it_scores_them() {
        var junk = [ row("Rock FM", "ES", "file:///etc/passwd", 128),
                     row("Rock FM", "ES", "http://a.example/rock.m3u", 128),
                     row("Rock FM", "ES", "http://b.example/rock", 128, 0),
                     row("Rock FM", "ES", dead, 128),
                     row("Radio Tango", "ES", "http://c.example/tango", 128) ];
        var none = HL.ladder(junk, dead, "Rock FM", "ES", true);
        compare(none.cands.length, 0);
        var good = row("Rock FM", "ES", "http://d.example/rock", 128000);
        good.favicon = "http://d.example/logo.png";
        junk.push(good);
        var o = HL.ladder(junk, dead, "Rock FM", "ES", true);
        compare(o.cands.length, 1);
        compare(o.cands[0].bitrate, 128);
        compare(o.cands[0].favicon, undefined);   // a name search's logo never travels
    }

    function test_a_contains_only_answer_is_held_to_the_same_question() {
        var us = row("Smooth Jazz Radio", "US", "http://a.example/smooth", 128);
        var gb = row("Jazz FM", "GB", "http://b.example/jazzfm", 128);
        var two = HL.ladder([us, gb], dead, "Jazz", "", false);
        compare(two.cands.length, 0);
        compare(two.refused, 2);
        var one = HL.ladder([us], dead, "Jazz", "", false);
        compare(one.cands.length, 1);
        compare(one.cands[0].near, true);
        compare(one.cands[0].kin, false);
    }

    function test_the_exact_tier_decides_and_foreign_contains_rows_go() {
        var o = HL.ladder([ row("Rock FM", "ES", "http://a.example/rock", 96),
                            row("Rock FM Romania", "RO", "https://live.rockfm.ro/rockfm.aacp", 80) ],
                          dead, "Rock FM", "", false);
        compare(o.cands.length, 1);
        compare(o.cands[0].cc, "ES");
        compare(o.refused, 1);
    }

    function test_an_ordinary_heal_asks_for_broken_rows_too() {
        compare(HL.searchTail(false), "&order=votes&reverse=true&limit=30");
        compare(HL.searchTail(undefined), "&order=votes&reverse=true&limit=30");
    }

    function test_the_stopgap_notice_names_a_stranger_and_only_a_stranger() {
        compare(HL.strangerLabel({ name: "Rock FM", kin: false }, "Estonia"), "Rock FM (Estonia)");
        compare(HL.strangerLabel({ name: "Rock FM", kin: false }, ""), "Rock FM");
        compare(HL.strangerLabel({ name: "Rock FM", kin: true }, "Spain"), "");
        compare(HL.strangerLabel({ url: "http://x", byUuid: true }, "Spain"), "");
        compare(HL.strangerLabel({ name: "<img src=x>Rock &amp; FM" }, ""), "img src=x Rock amp; FM");
        compare(HL.strangerLabel(null, "Spain"), "");
    }

    function test_garbage_in_empty_ladder_out() {
        var o = HL.ladder(null, "", "", "", false);
        compare(o.cands.length, 0);
        compare(o.refused, 0);
        var p = HL.ladder([null, {}, "x"], undefined, undefined, undefined, true);
        compare(p.cands.length, 0);
        compare(p.refused, 0);
    }
    function test_one_station_filed_under_many_countries_is_not_a_crowd_of_namesakes() {
        var rows = [ row("Dance Wave!", "HU", "https://dancewave.online/dance.mp3", 128),
                     row("Dance Wave!", "GR", "https://dancewave.online/dance.ogg", 160),
                     row("Dance Wave!", "AF", "https://dancewave.online/dance.aac", 64),
                     row("Dance Wave!", "", "https://dancewave.online/dance.opus", 96) ];
        var o = HL.ladder(rows, dead, "Dance Wave!", "", false);
        compare(o.cands.length, 4);
        compare(o.refused, 0);
        compare(o.cands[0].near, true);
        compare(o.cands[0].kin, false);
        // A uuid record filed under yet another country changes nothing: the
        // filing is noise under this roof.
        var k = HL.ladder(rows, dead, "Dance Wave!", "CA", false);
        compare(k.cands.length, 4);
        compare(k.cands[0].kin, false);
        // One foreign broadcaster with two mounts is still a foreigner.
        var f = HL.ladder([rows[0], row("Dance Wave!", "HU", "https://dancewave.online/dance.ogg", 160)],
                          dead, "Dance Wave!", "ES", false);
        compare(f.cands.length, 0);
        compare(f.refused, 2);
        // A second roof brings the question back.
        rows.push(row("Dance Wave!", "US", "https://squat.example/dw", 320));
        var p = HL.ladder(rows, dead, "Dance Wave!", "", false);
        compare(p.cands.length, 0);
        compare(p.refused, 5);
        // A landlord is no roof.
        var z = HL.ladder([ row("Rock FM", "ES", "https://stream.zeno.fm/aaa", 128),
                            row("Rock FM", "EE", "https://stream.zeno.fm/bbb", 128) ], dead, "Rock FM", "", false);
        compare(z.cands.length, 0);
    }

    // ── the directory's own answer, and the lock that stands on it ──────
    // The logo gate the widget hands in (FaviconLogic.webUrlOrEmpty): here
    // a stand-in that keeps https and drops everything else.
    function _gate(u) { return String(u || "").indexOf("https://") === 0 ? String(u) : "" }

    function _reply(rows, status) {
        return { status: status === undefined ? 200 : status,
                 responseText: rows === null ? "" : JSON.stringify(rows) }
    }

    function test_nobody_answered_is_not_the_directory_saying_no() {
        // Every mirror down hands the callback null, and a captive portal
        // hands it a page. Neither is the directory saying the station is
        // gone, and the ladder must be able to tell them apart from "the
        // uuid is unknown", which IS an answer.
        compare(HL.uuidRung(null, dead, false, _gate), null)
        compare(HL.uuidRung({ status: 503, responseText: "[]" }, dead, false, _gate), null)
        compare(HL.uuidRung({ status: 200, responseText: "<html>portal</html>" }, dead, false, _gate), null)
        compare(HL.uuidRung({ status: 200, responseText: "null" }, dead, false, _gate), null)
        compare(HL.uuidRung(_reply([]), dead, false, _gate).length, 0)
        compare(HL.uuidRung(_reply([{ url: "http://a.example/x", lastcheckok: "0" }]), dead, false, _gate).length, 0)
    }

    function test_the_stations_own_front_door_is_tried_too() {
        // url_resolved is where the checker ended up last time; url is the
        // door the station handed in. A station added from the search saves
        // url_resolved, so when that dies the front door is all there is.
        var row = { url: "http://front.example/live.pls", url_resolved: dead,
                    lastcheckok: "1", favicon: "https://front.example/logo.png" }
        var o = HL.uuidRung(_reply([row]), dead, false, _gate)
        compare(o.length, 1)
        compare(o[0].url, "http://front.example/live.pls")
        compare(o[0].byUuid, true)
        compare(o[0].favicon, "https://front.example/logo.png")
        // Both doors alive: the resolved one leads, the front one follows.
        row.url_resolved = "http://cdn.example/s1"
        o = HL.uuidRung(_reply([row]), dead, false, _gate)
        compare(o.length, 2)
        compare(o[0].url, "http://cdn.example/s1")
        compare(o[1].url, "http://front.example/live.pls")
        // One door twice is one door.
        o = HL.uuidRung(_reply([{ url: "http://cdn.example/s1", url_resolved: "http://cdn.example/s1",
                                  lastcheckok: "1" }]), dead, false, _gate)
        compare(o.length, 1)
        // A wake-up keeps the single door it has always had.
        row.url_resolved = "http://cdn.example/s1"
        compare(HL.uuidRung(_reply([row]), dead, true, _gate).length, 1)
        // The catalogue is publicly writable: only http(s) reaches the player.
        compare(HL.uuidRung(_reply([{ url: "file:///etc/passwd", url_resolved: "data:x",
                                      lastcheckok: "1" }]), dead, false, _gate).length, 0)
    }

    function test_the_router_goes_before_the_edge_it_hands_out() {
        // router.euddn.net kept one token for every station from January to
        // November 2026 while the edges it hands out rotated and le0x's
        // certificate expired (measured 2026-11-02). The station's own door
        // of the same family leads; anything else keeps the old order.
        var edge = "https://le302.euddn.net/0e97/elmar.aac"
        var router = "https://router.euddn.net/8103/elmar.aac"
        compare(HL.frontDoor({ url: router, url_resolved: edge }), [router, edge])
        // A playlist or HLS list stays behind: the alarm and the recorder
        // play an address as it is, so a saved one has to be a stream.
        compare(HL.frontDoor({ url: "https://somafm.com/groovesalad.pls",
                               url_resolved: "https://ice2.somafm.com/groovesalad-128-mp3" }),
                ["https://ice2.somafm.com/groovesalad-128-mp3", "https://somafm.com/groovesalad.pls"])
        compare(HL.frontDoor({ url: "https://somafm.com/hls/gs/program.m3u8",
                               url_resolved: "https://ice2.somafm.com/gs-128-mp3" })[0],
                "https://ice2.somafm.com/gs-128-mp3")
        compare(HL.frontDoor({ url: "https://www.station.example/live", url_resolved: "https://cdn.example.net/s1" }),
                ["https://cdn.example.net/s1", "https://www.station.example/live"], "another family")
        compare(HL.frontDoor({ url: router, url_resolved: router }), [router])
        compare(HL.frontDoor({ url: "", url_resolved: edge }), [edge])
        compare(HL.frontDoor({ url: router }), [router])
        compare(HL.frontDoor({ url: "file:///etc/passwd", url_resolved: "data:x" }), [])
        compare(HL.frontDoor(null), [])
    }

    function test_the_identity_rung_auditions_the_router_first() {
        var row = { url: "https://router.euddn.net/8103/elmar.aac",
                    url_resolved: "https://le302.euddn.net/0e97/elmar.aac", lastcheckok: "1" }
        var o = HL.uuidRung(_reply([row]), dead, false, _gate)
        compare(o.length, 2)
        compare(o[0].url, row.url)
        compare(o[1].url, row.url_resolved)
        o = HL.uuidRung(_reply([row]), dead, true, _gate)
        compare(o.length, 1)
        compare(o[0].url, row.url, "the wake-up's single door is the router too")
        // A row that already saved the router and lost it still has the edge.
        o = HL.uuidRung(_reply([row]), row.url, true, _gate)
        compare(o.length, 1)
        compare(o[0].url, row.url_resolved)
    }

    function test_the_name_rung_hands_out_the_router_too() {
        var res = HL.ladder([{ name: "Raadio Elmar", lastcheckok: 1, url: "https://router.euddn.net/8103/elmar.aac",
                               url_resolved: "https://le302.euddn.net/0e97/elmar.aac", countrycode: "EE" }],
                            "https://le06.euddn.net/06c6/elmar.aac", "Raadio Elmar", "EE", false)
        compare(res.cands.length, 1)
        compare(res.cands[0].url, "https://router.euddn.net/8103/elmar.aac")
        // The saved address is the router itself: the edge is offered instead.
        res = HL.ladder([{ name: "Raadio Elmar", lastcheckok: 1, url: "https://router.euddn.net/8103/elmar.aac",
                           url_resolved: "https://le302.euddn.net/0e97/elmar.aac", countrycode: "EE" }],
                        "https://router.euddn.net/8103/elmar.aac", "Raadio Elmar", "EE", false)
        compare(res.cands.length, 1)
        compare(res.cands[0].url, "https://le302.euddn.net/0e97/elmar.aac")
    }

    function test_the_uuid_records_country_comes_back_or_is_empty() {
        compare(HL.uuidCountry(_reply([{ countrycode: "EE" }])), "EE")
        compare(HL.uuidCountry(_reply([{}])), "")
        compare(HL.uuidCountry(_reply([])), "")
        compare(HL.uuidCountry(null), "")
        compare(HL.uuidCountry({ status: 200, responseText: "<html>" }), "")
    }

    function test_a_directory_that_answered_leaves_the_old_road_alone() {
        compare(HL.unheard(true, 0, undefined, 1000000), null)
        compare(HL.unheard(true, 3, -900000, 1000000), null)
    }

    function test_an_unreachable_directory_gives_the_lock_back_and_says_so() {
        // First give-up of an outage: speak, and leave a stamp that holds
        // nothing, so the next knock may ask again.
        var d = HL.unheard(false, 0, undefined, 1000000)
        verify(d !== null, "a directory nobody reached must answer with a verdict")
        compare(d.say, true)
        compare(d.stamp, -1000000)
        verify(!HL.lockHolds(d.stamp, 1000000 + 1000))
        // A later knock of the same outage asks again and stays quiet, and
        // the mark of WHEN the listener was told survives it: ten minutes
        // from that moment, not from this knock, the outage may be told
        // about again.
        d = HL.unheard(false, 2, -1000000, 1030000)
        compare(d.say, false)
        compare(d.stamp, -1000000)
        verify(!HL.lockHolds(d.stamp, 1030000))
        // Nothing was ever said and this is a later knock: no mark to keep.
        d = HL.unheard(false, 2, undefined, 1030000)
        compare(d.say, false)
        compare(d.stamp, 0)
        verify(!HL.lockHolds(0, 1030000))
    }

    function test_a_stream_that_buffers_and_dies_is_not_told_again() {
        // Every buffer resets the knock count, so the ring comes round at
        // the first knock's pace. Inside ten minutes of the telling the
        // lock goes back on: the saved address is alive enough to buffer.
        var d = HL.unheard(false, 0, -1000000, 1000000 + 60000)
        verify(d !== null, "a directory nobody reached must answer with a verdict")
        compare(d.say, false)
        compare(d.stamp, 1000000)
        verify(HL.lockHolds(d.stamp, 1000000 + 60000))
        // Ten minutes on, the outage may be told about again.
        d = HL.unheard(false, 0, -1000000, 1000000 + 600001)
        compare(d.say, true)
        compare(d.stamp, -(1000000 + 600001))
    }

    function test_the_lookup_lock_holds_for_ten_minutes_and_not_on_nothing() {
        verify(HL.lockHolds(1000000, 1000000))
        verify(HL.lockHolds(1000000, 1000000 + 599999))
        verify(!HL.lockHolds(1000000, 1000000 + 600000))
        verify(!HL.lockHolds(undefined, 1000000))
        verify(!HL.lockHolds(0, 1000000))
        verify(!HL.lockHolds(-1000000, 1000000))
    }

    // --- one address, two spellings ------------------------------------------

    function test_the_same_door_is_the_same_scheme_host_and_path() {
        verify(HL.sameDoor("http://Stream.Example.org/live/", "http://stream.example.org/live"));
        verify(HL.sameDoor(" https://h.example/x ", "https://h.example/x"));
        // The scheme moving IS the move: a TLS port that closed leaves the
        // plain one, and that address has to be saved.
        verify(!HL.sameDoor("https://h.example/x", "http://h.example/x"));
        // Icecast mounts are case-sensitive.
        verify(!HL.sameDoor("http://h.example/Live", "http://h.example/live"));
        verify(!HL.sameDoor("http://h.example/a?x=1", "http://h.example/a?x=2"));
        verify(!HL.sameDoor("", ""));
        verify(!HL.sameDoor(null, undefined));
        verify(!HL.sameDoor("http://h.example/x", 42));
    }

    function test_a_row_whose_two_addresses_are_one_door_offers_it_once() {
        var doors = HL.frontDoor({ url: "http://Stream.Example.org/live/",
                                   url_resolved: "http://stream.example.org/live" });
        compare(doors.length, 1);
    }

    function test_the_saved_address_in_another_spelling_is_not_auditioned_again() {
        var reply = { status: 200, responseText: JSON.stringify([{
            url: "http://Stream.Example.org/live/", url_resolved: "http://stream.example.org/live",
            lastcheckok: 1 }]) };
        compare(HL.uuidRung(reply, "http://stream.example.org/live", false, function(f) { return ""; }).length, 0);
        var res = HL.ladder([{ name: "Radio X", url_resolved: "http://Stream.Example.org/live/",
                               lastcheckok: 1, countrycode: "EE" }],
                            "http://stream.example.org/live", "Radio X", "", false);
        compare(res.cands.length, 0);
    }

    function test_a_door_into_the_listeners_own_network_is_no_door() {
        // The catalogue is publicly writable and nobody clicked: a row may
        // not send the player knocking on the router or the printer.
        compare(HL.frontDoor({ url: "http://192.168.1.1/x", url_resolved: "http://127.0.0.1:631/y" }).length, 0);
        compare(HL.frontDoor({ url: "http://100.100.5.5/live", url_resolved: "http://[::1]:8000/live" }).length, 0);
        compare(HL.frontDoor({ url: "http://192.168.1.1/x", url_resolved: "http://a.example/live" }),
                ["http://a.example/live"]);
    }

    function test_a_row_with_a_name_that_is_no_string_does_not_take_the_answer_down() {
        // One odd row used to throw and the catch dropped all thirty.
        var res = HL.ladder([{ name: 123, url_resolved: "http://a.example/x", lastcheckok: 1, countrycode: "EE" },
                             { name: "Radio X", url_resolved: "http://b.example/y", lastcheckok: 1, countrycode: "EE" }],
                            "http://dead.example/z", "Radio X", "EE", false);
        compare(res.cands.length, 1);
        compare(res.cands[0].url, "http://b.example/y");
        compare(HL.normName(123), "123");
    }

    function test_more_landlords_and_a_bare_address_with_another_port() {
        // Rent-a-stream hosts in the shipped list and in a real one.
        verify(HL.sharedBase("fast-serv.com"));
        verify(HL.sharedBase("asurahosting.com"));
        verify(HL.sharedBase("streamerr.co"));
        verify(HL.sharedBase("streemlion.com"));
        verify(HL.sharedBase("listen2myradio.com"));
        // One address, two ports: two servers, and the second is nobody's
        // home just because the number is the same.
        var res = HL.ladder([{ name: "Radio X", url_resolved: "http://203.0.113.5:8010/", lastcheckok: 1,
                               countrycode: "EE" }],
                            "http://203.0.113.5:8000/live", "Radio X", "EE", false);
        compare(res.cands.length, 1);
        verify(!res.cands[0].home);
        res = HL.ladder([{ name: "Radio X", url_resolved: "http://203.0.113.5:8000/hi", lastcheckok: 1,
                           countrycode: "EE" }],
                        "http://203.0.113.5:8000/live", "Radio X", "EE", false);
        verify(res.cands[0].home);
    }

    // --- the same mount on another server ------------------------------------
    // Measured 2026-11-10: Sky Media moved five mounts off four of its edges
    // around 2026-10-22. The saved addresses answer 404, the directory has no
    // usable row for most of them, and every one of them plays from
    // skymedia-live.bitflip.ee/<mount>, which hands out edge41..43.

    function test_a_mount_has_a_name_of_its_own_or_none() {
        compare(HL.mountOf("https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b"), "RETRO");
        compare(HL.mountOf("https://edge05.cdn.bitflip.ee:8888/retro1.mp3"), "retro1.mp3");
        compare(HL.mountOf("https://edge05.cdn.bitflip.ee:8888/RetroJ6ulud"), "RetroJ6ulud");
        compare(HL.mountOf("https://edge02.cdn.bitflip.ee:8888/KISS"), "KISS");
        compare(HL.mountOf("http://a.example:8000/stream"), "");
        compare(HL.mountOf("http://a.example:8000/live.mp3"), "");
        compare(HL.mountOf("http://a.example:8000/listen.aac?sid=1"), "");
        compare(HL.mountOf("http://a.example:8000/;"), "");
        compare(HL.mountOf("http://a.example:8000/"), "");
        compare(HL.mountOf("http://a.example:8000"), "");
        compare(HL.mountOf("http://a.example/NRJ"), "");       // three letters name nothing
        compare(HL.mountOf("http://a.example/128"), "");
        compare(HL.mountOf("file:///etc/passwd"), "");
        compare(HL.mountOf(null), "");
        compare(HL.mountOf(undefined), "");
        compare(HL.mountOf(42), "");
    }

    function test_the_same_mount_on_a_sibling_edge_is_the_same_station() {
        var saved = "https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b";
        verify(HL.mountTwin(saved, "https://edge43.cdn.bitflip.ee:8888/RETRO?_i=5b9ae0ef"));
        verify(HL.mountTwin(saved, "https://edge42.cdn.bitflip.ee:8888/RETRO"));
        verify(!HL.mountTwin(saved, "https://edge43.cdn.bitflip.ee:8888/RETRO_AAC"));  // another mount
        verify(!HL.mountTwin(saved, "https://edge43.cdn.bitflip.ee:8888/retro"));      // case is part of a mount
        verify(!HL.mountTwin(saved, "https://edge43.cdn.bitflip.ee:9000/RETRO"));      // another port, another server
        verify(!HL.mountTwin(saved, "http://edge43.cdn.bitflip.ee:8888/RETRO"));       // another scheme
        verify(!HL.mountTwin(saved, "https://skymedia-live.bitflip.ee/RETRO"));        // no edge of that family
        verify(!HL.mountTwin(saved, "https://other.cdn.bitflip.ee:8888/RETRO"));       // nor is this, port or no port
        // Numbers inside the domain itself are not an edge's number.
        verify(!HL.mountTwin("http://s1.radio1.example:8000/RETRO", "http://s1.radio2.example:8000/RETRO"));
        verify(!HL.mountTwin(saved, "https://edge43.cdn.evil.example:8888/RETRO"));
        verify(!HL.mountTwin(saved, "https://stream.skymedia.ee/live/RETRO"));
    }

    function test_a_twin_needs_a_home_and_a_name() {
        // A landlord's numbered hosts hold strangers.
        verify(!HL.mountTwin("http://s1.streamtheworld.com/KISSFM", "http://s2.streamtheworld.com/KISSFM"));
        // "stream" is every station's mount.
        verify(!HL.mountTwin("http://s1.host.example:8000/stream", "http://s2.host.example:8000/stream"));
        // Two bare addresses are two machines.
        verify(!HL.mountTwin("http://203.0.113.5:8000/RETRO", "http://203.0.113.6:8000/RETRO"));
        verify(!HL.mountTwin(null, undefined));
        verify(!HL.mountTwin("", ""));
        verify(!HL.mountTwin("ftp://a.example/RETRO", "ftp://b.example/RETRO"));
    }

    function test_the_guess_is_the_saved_mount_under_a_relatives_roof() {
        var saved = "https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b";
        compare(HL.kinGuess(saved, "https://skymedia-live.bitflip.ee/SKYPLUS"),
                "https://skymedia-live.bitflip.ee/RETRO");
        compare(HL.kinGuess(saved, "https://edge43.cdn.bitflip.ee:8888/RETRO_AAC?_i=1"),
                "https://edge43.cdn.bitflip.ee:8888/RETRO");
        compare(HL.kinGuess(saved, "https://edge02.cdn.bitflip.ee:8888/KISS"), "");    // the dead server itself
        compare(HL.kinGuess(saved, "https://stream.skymedia.ee/live/RETRO_AAC"), "");  // another domain is no roof of ours
        compare(HL.kinGuess("http://a.example:8000/stream", "http://b.example:8000/x"), "");
        compare(HL.kinGuess("http://x.zeno.fm/abcd1234", "http://y.zeno.fm/zzzz9999"), "");
        compare(HL.kinGuess("http://203.0.113.5:8000/RETRO", "http://203.0.113.5:9000/x"), "");
        compare(HL.kinGuess(saved, null), "");
        compare(HL.kinGuess(undefined, saved), "");
    }

    function test_an_answer_is_a_stream_or_it_is_not() {
        verify(HL.aliveAnswer(200, "audio/mpeg"));
        verify(HL.aliveAnswer(206, "audio/aac"));
        verify(HL.aliveAnswer(200, "application/ogg"));
        verify(HL.aliveAnswer(200, ""));                      // an old SHOUTcast says nothing
        verify(!HL.aliveAnswer(200, "text/html; charset=utf-8"));   // an error page with a polite status
        verify(!HL.aliveAnswer(200, "application/json"));
        verify(!HL.aliveAnswer(404, "audio/mpeg"));
        verify(!HL.aliveAnswer(302, "audio/mpeg"));
        verify(!HL.aliveAnswer(0, ""));
        verify(!HL.aliveAnswer(undefined, null));
    }

    function test_a_guess_is_taken_only_when_it_lands_on_the_twin() {
        var saved = "https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b";
        var door = "https://skymedia-live.bitflip.ee/RETRO";
        verify(HL.kinAccepts(saved, door, 200, "audio/mpeg", "https://edge43.cdn.bitflip.ee:8888/RETRO?_i=77"));
        verify(HL.kinAccepts(saved, "https://edge42.cdn.bitflip.ee:8888/RETRO", 200, "audio/mpeg",
                             "https://edge42.cdn.bitflip.ee:8888/RETRO"));
        verify(!HL.kinAccepts(saved, "https://edge06.cdn.bitflip.ee:8888/RETRO", 404, "text/html",
                              "https://edge06.cdn.bitflip.ee:8888/RETRO"));
        verify(!HL.kinAccepts(saved, door, 200, "text/html", "https://edge43.cdn.bitflip.ee:8888/RETRO"));
        verify(!HL.kinAccepts(saved, door, 200, "audio/mpeg", "https://edge43.cdn.bitflip.ee:8888/SKYPLUS"));
        // An edge that looks the part but hands the listener on elsewhere.
        verify(!HL.kinAccepts(saved, "https://edge42.cdn.bitflip.ee:8888/RETRO", 200, "audio/mpeg",
                              "https://elsewhere.example/RETRO"));
        // Qt did not say where the answer came from, and the door itself is
        // no edge: nothing ties this sound to the saved mount.
        verify(!HL.kinAccepts(saved, door, 200, "audio/mpeg", ""));
        verify(!HL.kinAccepts(saved, door, 200, "audio/mpeg", "http://192.168.1.10:8888/RETRO"));
        verify(!HL.kinAccepts(saved, door, undefined, null, undefined));
    }

    function test_the_leads_are_our_own_roofs_and_the_directorys_doors() {
        var saved = "https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b";
        var leads = HL.kinLeads(saved,
            [{ hostname: "https://skymedia-live.bitflip.ee/SKYPLUS" },
             { hostname: "https://ice.leviracloud.eu/star320-mp3" },      // somebody else's roof
             { hostname: saved }, null, { name: "no address" }],
            [{ url: "https://stream.skymedia.ee/live/RETRO_AAC",
               url_resolved: "https://edge43.cdn.bitflip.ee:8888/RETRO_AAC?_i=9" }, null, {}]);
        compare(leads, ["https://skymedia-live.bitflip.ee/SKYPLUS",
                        "https://edge43.cdn.bitflip.ee:8888/RETRO_AAC?_i=9",
                        "https://stream.skymedia.ee/live/RETRO_AAC"]);
        compare(HL.kinLeads(saved, null, undefined), []);
    }

    function test_the_plan_tries_our_own_roofs_before_strangers_doors() {
        var saved = "https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b";
        var plan = HL.kinPlan(saved, [
            "https://stream.skymedia.ee/live/RETRO_AAC",
            "https://edge02.cdn.bitflip.ee:8888/KISS",
            "https://skymedia-live.bitflip.ee/SKYPLUS",
            "https://edge06.cdn.bitflip.ee:8888/kadi",
            "https://skymedia-live.bitflip.ee/NRJ",
            saved, "", null, "file:///x", "http://192.168.1.5/RETRO"]);
        compare(plan.guesses, ["https://skymedia-live.bitflip.ee/RETRO",
                               "https://edge06.cdn.bitflip.ee:8888/RETRO"]);
        compare(plan.doors, ["https://stream.skymedia.ee/live/RETRO_AAC"]);
    }

    function test_the_plan_is_short_and_empty_where_nothing_can_be_proven() {
        var saved = "https://edge02.cdn.bitflip.ee:8888/RETRO";
        var many = [];
        for (var i = 10; i < 40; i++) {
            many.push("https://edge" + i + ".cdn.bitflip.ee:8888/x");
            many.push("https://door" + i + ".example/x");
        }
        var plan = HL.kinPlan(saved, many);
        compare(plan.guesses.length, 6);
        compare(plan.doors.length, 3);
        // A mount called "stream", a landlord's host and a bare address
        // cannot have a twin, so nobody is asked.
        compare(HL.kinPlan("http://a.example:8000/stream", many).guesses.length, 0);
        compare(HL.kinPlan("http://a.example:8000/stream", many).doors.length, 0);
        compare(HL.kinPlan("http://s1.zeno.fm/abcd1234", ["http://s2.zeno.fm/x"]).guesses.length, 0);
        compare(HL.kinPlan(null, null).doors.length, 0);
    }

    function test_the_wider_question_is_the_first_word_that_names_the_station() {
        compare(HL.kinWord("Retro fm disco"), "retro");
        compare(HL.kinWord("Raadio Relax International"), "relax");
        compare(HL.kinWord("The Radio Station"), "");
        compare(HL.kinWord("Radio 2"), "");
        compare(HL.kinWord("FM 100"), "");
        compare(HL.kinWord("Ретро FM"), "ретро");
        compare(HL.kinWord("Raadio Elmar"), "elmar");
        compare(HL.kinWord(null), "");
        compare(HL.kinWord(42), "");
    }

    // --- one failure is not a death ------------------------------------------

    function test_one_failure_earns_the_saved_address_a_second_knock() {
        var now = 1000000000;
        verify(HL.knockFirst(undefined, now));
        verify(HL.knockFirst(0, now));
        verify(!HL.knockFirst(now - 59000, now));    // it just had one and failed again
        verify(HL.knockFirst(now - 61000, now));
        verify(HL.knockFirst(NaN, now));
        verify(HL.knockFirst(now + 5000, now));      // a clock that jumped back blocks nothing
    }

    function test_a_move_is_written_only_over_an_address_that_stayed_dead() {
        var t = 1000000000;
        compare(HL.moveWhen("permanent", t - 300000, t), "now");
        compare(HL.moveWhen("permanent", t - 299000, t), "later");
        compare(HL.moveWhen("permanent", 0, t), "later");          // nobody saw it die
        compare(HL.moveWhen("permanent", undefined, t), "later");
        compare(HL.moveWhen("permanent", t + 5000, t), "later");   // a clock that went back proves nothing
        compare(HL.moveWhen("stopgap", t - 3600000, t), "never");
        compare(HL.moveWhen(undefined, t - 3600000, t), "never");
    }

    function test_the_second_look_comes_when_the_five_minutes_are_up() {
        var t = 1000000000;
        compare(HL.proofWaitMs(t - 100000, t), 200000);
        compare(HL.proofWaitMs(0, t), 300000);
        compare(HL.proofWaitMs(undefined, t), 300000);
        compare(HL.proofWaitMs(t - 900000, t), 1000);    // overdue: at once, but not inside this turn
        compare(HL.proofWaitMs(t + 5000, t), 300000);
    }

    function test_a_reply_is_its_rows_or_nothing() {
        compare(HL.replyRows({ status: 200, responseText: '[{"name":"a"},{"name":"b"}]' }).length, 2);
        compare(HL.replyRows({ status: 200, responseText: '{"error":"x"}' }), []);
        compare(HL.replyRows({ status: 200, responseText: "<html>portal</html>" }), []);
        compare(HL.replyRows({ status: 503, responseText: "[]" }), []);
        compare(HL.replyRows({ status: 404, responseText: '[{"name":"a"}]' }), []);
        compare(HL.replyRows(null), []);
        compare(HL.replyRows(undefined), []);
    }

    function test_only_a_named_mount_on_the_stations_own_domain_can_have_a_twin() {
        verify(HL.kinPossible("https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b"));
        verify(!HL.kinPossible("http://a.example:8000/stream"));
        verify(!HL.kinPossible("http://s1.zeno.fm/abcd1234"));
        verify(!HL.kinPossible("http://203.0.113.5:8000/RETRO"));
        verify(!HL.kinPossible("file:///RETRO"));
        verify(!HL.kinPossible(null));
    }

    function test_the_row_that_moves_is_the_one_that_plays() {
        var dead = "https://edge05.cdn.bitflip.ee:8888/RetroJ6ulud";
        var rows = [{ name: "Retro Love", hostname: dead, active: false },
                    { name: "Other name", hostname: dead, active: true },
                    { name: "Retro Love", hostname: dead, active: true },
                    { name: "Kiss FM", hostname: "https://edge02.cdn.bitflip.ee:8888/KISS", active: true }];
        compare(HL.movedRow(rows, dead, "retro  love"), 2);     // the playing name, switched on
        compare(HL.movedRow(rows, dead, "Nobody"), 1);          // else one that is switched on
        compare(HL.movedRow(rows, dead, ""), 1);
        compare(HL.movedRow([rows[0]], dead, "Retro Love"), 0); // else the one there is
        compare(HL.movedRow(rows, "https://gone.example/x", "Retro Love"), -1);
        compare(HL.movedRow(null, dead, "x"), -1);
        compare(HL.movedRow([null, {}, { hostname: dead }], dead, undefined), 2);
    }

    function test_the_wider_question_names_one_word_and_the_country_it_knows() {
        compare(HL.kinSearchPath("Raadio Relax International", "ee"),
                "/json/stations/search?name=relax&countrycode=EE&hidebroken=true&order=votes&reverse=true&limit=30");
        compare(HL.kinSearchPath("Retro fm disco", ""),
                "/json/stations/search?name=retro&hidebroken=true&order=votes&reverse=true&limit=30");
        // A country that is not a two-letter code is no country.
        compare(HL.kinSearchPath("Retro fm disco", "Estonia"), HL.kinSearchPath("Retro fm disco", ""));
        compare(HL.kinSearchPath("Retro fm disco", "e&e"), HL.kinSearchPath("Retro fm disco", ""));
        compare(HL.kinSearchPath("Retro fm disco", undefined), HL.kinSearchPath("Retro fm disco", ""));
        compare(HL.kinSearchPath("Ретро FM", "RU"),
                "/json/stations/search?name=%D1%80%D0%B5%D1%82%D1%80%D0%BE&countrycode=RU&hidebroken=true&order=votes&reverse=true&limit=30");
        compare(HL.kinSearchPath("Radio 2", "EE"), "");
        compare(HL.kinSearchPath(null, "EE"), "");
    }

    function test_a_country_domain_says_where_a_station_is_from() {
        compare(HL.tldCountry("https://edge03.cdn.bitflip.ee:8888/relax"), "EE");
        compare(HL.tldCountry("http://stream.live.bbc.co.uk/r1"), "GB");
        compare(HL.tldCountry("http://icecast.yle.fi/x"), "FI");
        // Two letters sold to everyone say nothing about a country.
        compare(HL.tldCountry("http://stream.zeno.fm/abc"), "");
        compare(HL.tldCountry("http://live.station.tv/x"), "");
        compare(HL.tldCountry("http://x.radio.co/y"), "");
        compare(HL.tldCountry("http://relay.example.io/y"), "");
        compare(HL.tldCountry("https://ice1.somafm.com/groovesalad"), "");
        compare(HL.tldCountry("http://203.0.113.5:8000/live"), "");
        compare(HL.tldCountry("file:///x.ee"), "");
        compare(HL.tldCountry(null), "");
    }

    // ── The second look, and a directory that is unwell ───────────────────

    function test_the_second_look_keeps_a_living_address_and_moves_a_gone_one() {
        compare(HL.proofVerdict(200, "audio/mpeg", 1), "keep")
        compare(HL.proofVerdict(200, "", 3), "keep")            // an old SHOUTcast names no type
        compare(HL.proofVerdict(404, "text/html", 1), "move")
        compare(HL.proofVerdict(403, "", 1), "move")
        compare(HL.proofVerdict(410, "", 1), "move")
    }

    function test_silence_is_no_proof_until_it_has_lasted() {
        // The move used to be written on the first look that was not a
        // stream. A look that timed out says nothing about the address: the
        // connection may have been slow for three seconds.
        compare(HL.proofVerdict(0, "", 1), "again")
        compare(HL.proofVerdict(0, "", HL.PROOF_LOOKS - 1), "again")
        compare(HL.proofVerdict(0, "", HL.PROOF_LOOKS), "move")
        compare(HL.proofVerdict(0, "", HL.PROOF_LOOKS + 40), "move")
    }

    function test_a_server_that_answers_something_else_is_still_there() {
        // Busy, asking for a login, sending us on, or a page behind a 200:
        // somebody is at the address. However long that lasts it is not the
        // address being gone.
        var there = [[500, ""], [503, ""], [429, ""], [401, ""], [301, ""], [200, "text/html"],
                     [200, "application/json"]]
        for (var i = 0; i < there.length; i++) {
            compare(HL.proofVerdict(there[i][0], there[i][1], 1), "again", "status " + there[i][0])
            compare(HL.proofVerdict(there[i][0], there[i][1], 99), "again", "status " + there[i][0])
        }
    }

    function test_an_answer_qt_cannot_place_never_moves_a_station() {
        // KinHunt reports -1 for an answer whose last hop Qt does not name.
        // On a Qt that never names it every look is one of these, alive or
        // not, and counting them as silence would move a living station.
        compare(HL.proofVerdict(-1, "", 1), "again")
        compare(HL.proofVerdict(-1, "", HL.PROOF_LOOKS), "again")
        compare(HL.proofVerdict(-1, "", 99), "again")
    }

    function test_the_second_look_with_nothing_readable_decides_nothing() {
        compare(HL.proofVerdict(undefined, undefined, undefined), "again")
        compare(HL.proofVerdict(NaN, null, NaN), "again")
        compare(HL.proofVerdict("404", "", 1), "again")
        compare(HL.proofVerdict(0, "", undefined), "again")
        compare(HL.proofVerdict(0, "", -5), "again")
        compare(HL.proofVerdict(null, "", 99), "again")
    }

    function test_a_page_behind_a_200_is_not_the_directorys_answer() {
        // Counted as an answer it stamped the ten-minute lock and the
        // listener was told the station is nowhere, by a directory that had
        // only sent its error page.
        verify(HL.answered(_reply([])))
        verify(HL.answered(_reply([{ url: "http://a.example/x" }])))
        verify(!HL.answered({ status: 200, responseText: "<html>portal</html>" }))
        verify(!HL.answered({ status: 200, responseText: "{\"error\":\"busy\"}" }))
        verify(!HL.answered({ status: 200, responseText: "null" }))
        verify(!HL.answered({ status: 200, responseText: "" }))
        verify(!HL.answered({ status: 200 }))
        verify(!HL.answered({ status: 503, responseText: "[]" }))
        verify(!HL.answered(null))
        verify(!HL.answered(undefined))
        var many = []
        for (var i = 0; i < 3000; i++) many.push({ url: "http://a.example/" + i })
        verify(HL.answered(_reply(many)))
    }
}
