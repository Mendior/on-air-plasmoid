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
}
