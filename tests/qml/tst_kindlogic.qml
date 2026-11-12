// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// What a start does about a stream that may be Ogg FLAC: when it asks, what
// it makes of the answer, and how the answers are kept. The numbers behind
// the rules are in KindLogic.js.
import QtQuick
import QtTest

import "../../package/contents/ui/KindLogic.js" as KL

TestCase {
    name: "KindLogic"

    readonly property string bare: "https://stream.example.org/rock-flac"
    readonly property string token: "https://cdn.example.net/live?token=abc123&sid=7"

    function _rows(codec, host) {
        var row = { "name": "Rock", "hostname": host || bare, "favicon": "", "active": true };
        if (codec !== undefined) row.codec = codec;
        return JSON.stringify([row]);
    }

    function test_a_label_is_a_hint_when_it_names_the_family() {
        var yes = ["flac", "FLAC", "ogg", "OGG", "Ogg Vorbis", "opus", " vorbis ", "ogg/flac"];
        for (var i = 0; i < yes.length; i++) verify(KL.labelHints(yes[i]), yes[i])
        var no = ["", " ", "mp3", "AAC+", "UNKNOWN", "fla", "og g"];
        for (i = 0; i < no.length; i++) verify(!KL.labelHints(no[i]), no[i])
        var junk = [null, undefined, 0, 7, true, {}, [], ["flac"]];
        for (i = 0; i < junk.length; i++) verify(!KL.labelHints(junk[i]), String(junk[i]))
        verify(KL.labelHints(new Array(5000).join("x") + "flac"))
    }

    function test_the_road_before_was_the_ending_and_the_auditions_label() {
        var relay = ["http://x.example/live.flac", "http://x.example/live.ogg", "http://x.example/live.opus",
                     "http://x.example/LIVE.OGG", "http://x.example/a.ogg?sid=1"];
        for (var i = 0; i < relay.length; i++) compare(KL.roadBefore(relay[i], ""), "relay", relay[i])
        compare(KL.roadBefore(bare, "FLAC"), "relay")
        compare(KL.roadBefore(bare, "ogg"), "relay")
        compare(KL.roadBefore("http://x.example/live.mp3", "Ogg Vorbis"), "relay")
        // The .oga ending was never known, nor an ending behind a #.
        var plain = [bare, "http://x.example/live.oga", "http://x.example/live.ogg#now", "http://x.example/live.mp3",
                     "http://x.example/a?f=b.flac", "http://x.example/live.ogg/", "http://flac.example/live", ""];
        for (i = 0; i < plain.length; i++) compare(KL.roadBefore(plain[i], ""), "plain", plain[i])
        compare(KL.roadBefore(bare, "mp3"), "plain")
        var junk = [null, undefined, 7, {}, []];
        for (i = 0; i < junk.length; i++) {
            compare(KL.roadBefore(junk[i], ""), "plain", String(junk[i]))
            compare(KL.roadBefore(bare, junk[i]), "plain", String(junk[i]))
        }
        compare(KL.roadBefore("http://x.example/" + new Array(4000).join("a") + ".ogg", ""), "relay")
    }

    function test_a_hint_is_a_flac_ending_or_a_label_on_an_ending_that_says_nothing() {
        verify(KL.hinted(bare, "flac"))
        verify(KL.hinted(bare, "OGG"))
        verify(KL.hinted("http://x.example/live.flac", ""))
        verify(KL.hinted("http://x.example/live.flac", null))
        verify(KL.hinted("http://x.example/LIVE.FLAC?sid=1", "mp3"))
        verify(KL.hinted("http://x.example/live.mp3", "ogg"))
        verify(!KL.hinted(bare, ""))
        verify(!KL.hinted(bare, "mp3"))
        verify(!KL.hinted("http://x.example/live.mp3", "aac"))
        // An ending the relay already takes is not asked about, whatever
        // the label says: no answer takes an Ogg stream off the relay.
        var ogg = ["http://x.example/live.ogg", "http://x.example/live.opus",
                   "http://x.example/LIVE.OGG", "http://x.example/a.opus?sid=1"];
        for (var i = 0; i < ogg.length; i++) {
            verify(!KL.hinted(ogg[i], ""), ogg[i])
            verify(!KL.hinted(ogg[i], "FLAC"), ogg[i])
        }
        // .oga is Ogg by its name and was never relayed on it, so it is the
        // one Ogg ending an answer can still move: FLAC inside freezes on
        // the plain start. The ending is the hint, with a label or without.
        var oga = ["http://x.example/live.oga", "http://x.example/LIVE.OGA", "http://x.example/live.oga?sid=1"];
        for (var j = 0; j < oga.length; j++) {
            verify(KL.hinted(oga[j], "FLAC"), oga[j])
            verify(KL.hinted(oga[j], ""), oga[j])
            verify(KL.hinted(oga[j], "mp3"), oga[j])
            compare(KL.roadBefore(oga[j], ""), "plain", oga[j])
        }
        // Every ending the old road relays is one the question skips, and
        // the other way round: the two readings cannot drift apart.
        var endings = ["ogg", "opus", "oga", "flac", "spx", "mp3", "aac", "mka", ""];
        for (var k = 0; k < endings.length; k++) {
            var at = "http://x.example/live" + (endings[k] ? "." + endings[k] : "");
            var relayedByEnding = KL.roadBefore(at, "") === "relay";
            if (relayedByEnding && endings[k] !== "flac") verify(!KL.hinted(at, "flac"), at)
            if (!relayedByEnding) verify(KL.hinted(at, "flac"), at)
        }
        // A playlist and HLS are never relayed, whatever their label says,
        // and a file or nothing at all is no station.
        verify(!KL.hinted("http://x.example/list.m3u", "flac"))
        verify(!KL.hinted("http://x.example/list.pls", "ogg"))
        verify(!KL.hinted("http://x.example/hls/live.m3u8", "flac"))
        verify(!KL.hinted("file:///home/me/song.flac", "flac"))
        verify(!KL.hinted("", "flac"))
        verify(!KL.hinted(null, "flac"))
        verify(!KL.hinted(undefined, undefined))
        verify(KL.hinted("http://x.example/" + new Array(4000).join("a") + ".flac", ""))
    }

    function test_the_label_is_the_callers_or_the_saved_rows_own_address() {
        compare(KL.labelFor("FLAC", "[]", bare), "flac")
        compare(KL.labelFor("  Ogg ", _rows("mp3"), bare), "ogg")
        compare(KL.labelFor("", _rows(" FLAC "), bare), "flac")
        compare(KL.labelFor("   ", _rows("ogg"), bare), "ogg")
        compare(KL.labelFor(null, JSON.parse(_rows("opus")), bare), "opus")
        // Another address finds nothing, however near its spelling.
        compare(KL.labelFor("", _rows("flac"), bare + "-192"), "")
        compare(KL.labelFor("", _rows("flac"), bare + "/"), "")
        compare(KL.labelFor("", _rows("flac"), bare.replace("https:", "http:")), "")
        compare(KL.labelFor("", _rows("flac", "http://x.example/list.m3u"), "http://x.example/stream"), "")
        // Two rows on one address: the first that says anything.
        var twins = JSON.stringify([{ "hostname": bare }, { "hostname": bare, "codec": "" },
                                    { "hostname": bare, "codec": "ogg" }, { "hostname": bare, "codec": "mp3" }]);
        compare(KL.labelFor("", twins, bare), "ogg")
        // No list, odd rows, no address.
        var none = [null, undefined, "", "not json", "{}", "[", 42, { "hostname": bare, "codec": "flac" }];
        for (var i = 0; i < none.length; i++) compare(KL.labelFor("", none[i], bare), "", String(none[i]))
        var odd = [null, 5, "x", [], {}, { "hostname": 7, "codec": "flac" }, { "codec": "flac" },
                   { "hostname": bare, "codec": 5 }, { "hostname": bare, "codec": null }];
        compare(KL.labelFor("", odd, bare), "")
        compare(KL.labelFor("", odd, "7"), "")
        compare(KL.labelFor("", [{ "hostname": "", "codec": "flac" }, { "codec": "flac" }], ""), "")
        compare(KL.labelFor("", [{ "codec": "flac" }], undefined), "")
        compare(KL.labelFor(7, "[]", bare), "")
        // A label is cut where the list cuts it on save.
        compare(KL.labelFor("", _rows("flac" + new Array(101).join("x")), bare).length, 16)
        compare(KL.labelFor("flac" + new Array(101).join("x"), "[]", bare).length, 16)
    }

    function test_an_address_is_saved_when_a_row_holds_exactly_it() {
        verify(KL.isSaved(_rows(), bare))
        verify(KL.isSaved(JSON.parse(_rows()), bare))
        verify(KL.isSaved(_rows(undefined, token), token))
        verify(!KL.isSaved(_rows(), bare + "/"))
        verify(!KL.isSaved(_rows(undefined, token), token + "x"))
        verify(!KL.isSaved("[]", bare))
        verify(!KL.isSaved("not json", bare))
        verify(!KL.isSaved(null, bare))
        verify(!KL.isSaved([null, 5, { "hostname": 7 }], "7"))
        verify(!KL.isSaved([{ "hostname": "" }, {}], ""))
        verify(!KL.isSaved(_rows(), undefined))
        var many = [];
        for (var i = 0; i < 500; i++) many.push({ "hostname": bare + "/" + i });
        verify(KL.isSaved(many, bare + "/499"))
        verify(!KL.isSaved(many, bare + "/500"))
    }

    function test_the_helpers_answer_is_one_of_four_words() {
        compare(KL.answerOf("ogg-flac\n"), "ogg-flac")
        compare(KL.answerOf("ogg\n"), "ogg")
        compare(KL.answerOf("flac"), "flac")
        compare(KL.answerOf("  other \r\n"), "other")
        var no = ["", "\n", "OGG-FLAC", "ogg-flac ogg", "ogg-flac\nother", "oggflac", "Traceback (most recent call last):",
                  "python3: can't open file", "ogg-", "-flac", new Array(100000).join("ogg-flac")];
        for (var i = 0; i < no.length; i++) compare(KL.answerOf(no[i]), "", no[i].substring(0, 30))
        var junk = [null, undefined, 0, 7, {}, ["ogg-flac"]];
        for (i = 0; i < junk.length; i++) compare(KL.answerOf(junk[i]), "", String(junk[i]))
    }

    function test_the_map_keeps_one_kind_an_address() {
        var m = KL.mapWith("{}", bare, "ogg-flac");
        compare(KL.kindAt(m, bare), "ogg-flac")
        compare(KL.kindAt(m, bare + "/"), "")
        compare(KL.kindAt(m, token), "")
        m = KL.mapWith(m, token, "other");
        compare(KL.kindAt(m, token), "other")
        compare(KL.kindAt(m, bare), "ogg-flac")
        // The same address again: one entry, the new kind, and it is the newest.
        m = KL.mapWith(m, bare, "flac");
        compare(KL.kindAt(m, bare), "flac")
        compare(Object.keys(JSON.parse(m)).length, 2)
        compare(Object.keys(JSON.parse(m))[1], bare)
        m = KL.mapWithout(m, token);
        compare(KL.kindAt(m, token), "")
        compare(KL.kindAt(m, bare), "flac")
        compare(KL.mapWithout(m, bare), "{}")
        compare(KL.mapWithout(m, "http://never.example/x"), m)
    }

    function test_a_map_that_is_not_one_reads_as_empty() {
        var bad = ["", "not json", "[", "[]", "null", "7", "\"x\"", "[[\"" + bare + "\",\"flac\"]]", null, undefined, 7, {}, []];
        for (var i = 0; i < bad.length; i++) {
            compare(KL.kindAt(bad[i], bare), "", String(bad[i]))
            compare(KL.mapWithout(bad[i], bare), "{}", String(bad[i]))
            compare(KL.kindAt(KL.mapWith(bad[i], bare, "ogg"), bare), "ogg", String(bad[i]))
        }
        // Entries that would never have been written are not read either.
        var odd = JSON.stringify({ "ftp://x.example/a": "flac", "file:///a.flac": "flac", "x": "ogg", "": "ogg",
                                   "http://ok.example/a": "ogg-flac", "http://b.example/a": "mp3",
                                   "http://c.example/a": 7, "http://d.example/a": null, "http://e.example/a": ["ogg"] });
        compare(KL.kindAt(odd, "ftp://x.example/a"), "")
        compare(KL.kindAt(odd, "x"), "")
        compare(KL.kindAt(odd, "http://b.example/a"), "")
        compare(KL.kindAt(odd, "http://c.example/a"), "")
        compare(KL.kindAt(odd, "http://ok.example/a"), "ogg-flac")
        compare(KL.mapWithout(odd, "http://none.example/"), "{\"http://ok.example/a\":\"ogg-flac\"}")
        compare(KL.kindAt("{\"__proto__\":\"ogg\",\"http://ok.example/a\":\"flac\"}", "__proto__"), "")
        compare(KL.kindAt(odd, null), "")
        compare(KL.kindAt(odd, undefined), "")
        compare(KL.kindAt(odd, 7), "")
    }

    function test_nothing_is_written_that_would_not_be_read() {
        var m = KL.mapWith("{}", bare, "ogg");
        compare(KL.mapWith(m, bare + "2", "mp3"), m)
        compare(KL.mapWith(m, bare + "2", ""), m)
        compare(KL.mapWith(m, bare + "2", null), m)
        compare(KL.mapWith(m, "ftp://x.example/a", "ogg"), m)
        compare(KL.mapWith(m, "", "ogg"), m)
        compare(KL.mapWith(m, null, "ogg"), m)
        var far = "http://x.example/" + new Array(2048 - 17 + 1).join("a");
        compare(far.length, 2048)
        compare(KL.kindAt(KL.mapWith(m, far, "ogg"), far), "ogg")
        compare(KL.mapWith(m, far + "a", "ogg"), m)
    }

    function test_the_map_stops_at_its_cap_and_lets_the_oldest_go() {
        var m = "{}";
        for (var i = 0; i < 64; i++) m = KL.mapWith(m, bare + "/" + i, "ogg");
        compare(Object.keys(JSON.parse(m)).length, 64)
        compare(KL.kindAt(m, bare + "/0"), "ogg")
        m = KL.mapWith(m, bare + "/64", "ogg-flac");
        compare(Object.keys(JSON.parse(m)).length, 64)
        compare(KL.kindAt(m, bare + "/0"), "")
        compare(KL.kindAt(m, bare + "/1"), "ogg")
        compare(KL.kindAt(m, bare + "/64"), "ogg-flac")
        // An entry written again is the newest, so it outlives the next one in.
        m = KL.mapWith(m, bare + "/1", "ogg");
        m = KL.mapWith(m, bare + "/65", "ogg");
        compare(KL.kindAt(m, bare + "/1"), "ogg")
        compare(KL.kindAt(m, bare + "/2"), "")
        // Another cap, and one that is no cap.
        compare(Object.keys(JSON.parse(KL.mapWith(m, bare + "/66", "ogg", 3))).length, 3)
        compare(Object.keys(JSON.parse(KL.mapWith(m, bare + "/66", "ogg", 0))).length, 64)
        compare(Object.keys(JSON.parse(KL.mapWith(m, bare + "/66", "ogg", -5))).length, 64)
        compare(Object.keys(JSON.parse(KL.mapWith(m, bare + "/66", "ogg", "x"))).length, 64)
        compare(Object.keys(JSON.parse(KL.mapWith(m, bare + "/66", "ogg", 2.5))).length, 64)
        // A map grown past the cap by hand comes back inside it.
        var big = {};
        for (i = 0; i < 200; i++) big[bare + "/h" + i] = "flac";
        m = KL.mapWith(JSON.stringify(big), bare, "ogg");
        compare(Object.keys(JSON.parse(m)).length, 64)
        compare(KL.kindAt(m, bare), "ogg")
        compare(KL.kindAt(m, bare + "/h199"), "flac")
        compare(KL.kindAt(m, bare + "/h0"), "")
    }

    function test_only_addresses_still_saved_stay_in_the_map() {
        var m = KL.mapWith(KL.mapWith("{}", bare, "ogg-flac"), token, "other");
        compare(KL.mapKept(m, _rows()), "{\"" + bare + "\":\"ogg-flac\"}")
        compare(KL.mapKept(m, JSON.stringify([{ "hostname": token }, { "hostname": bare }])), m)
        // A heal moved the row: the old address's entry does not follow it.
        compare(KL.mapKept(m, _rows("flac", bare + "-new")), "{}")
        compare(KL.mapKept(m, "[]"), "{}")
        compare(KL.mapKept(m, "not json"), "{}")
        compare(KL.mapKept(m, null), "{}")
        compare(KL.mapKept("not json", _rows()), "{}")
        compare(KL.mapKept(null, null), "{}")
    }

    readonly property var none: ({ relay: false, ask: false, pull: false })
    readonly property var relayed: ({ relay: true, ask: false, pull: false })

    function test_a_known_stream_starts_by_what_it_is() {
        // Ogg FLAC: the relay at once. Plain FLAC and anything that is no
        // Ogg: the plain start. Whatever the ending or the label says, and
        // with nothing left to ask.
        var anywhere = [bare, "http://x.example/live.flac", "http://x.example/live.mp3"];
        for (var i = 0; i < anywhere.length; i++) {
            compare(KL.plan(anywhere[i], "ogg-flac", "", ""), relayed, anywhere[i])
            compare(KL.plan(anywhere[i], "ogg-flac", "MP3", "mp3"), relayed, anywhere[i])
            compare(KL.plan(anywhere[i], "flac", "FLAC", "flac"), none, anywhere[i])
            compare(KL.plan(anywhere[i], "other", "FLAC", "flac"), none, anywhere[i])
        }
    }

    function test_vorbis_and_opus_keep_the_road_they_had() {
        // Known or not, never asked about once known, never taken off it.
        compare(KL.plan(bare, "ogg", "", "ogg"), none)
        compare(KL.plan(bare, "ogg", "OGG", "ogg"), relayed)
        compare(KL.plan("http://x.example/live.flac", "ogg", "", ""), relayed)
        // An Ogg ending is the relay as ever, and nothing is asked, because
        // no answer would change it.
        var ogg = ["http://x.example/live.ogg", "http://x.example/live.opus"];
        for (var i = 0; i < ogg.length; i++) {
            compare(KL.plan(ogg[i], "", "", ""), relayed, ogg[i])
            compare(KL.plan(ogg[i], "", "FLAC", "flac"), relayed, ogg[i])
            compare(KL.plan(ogg[i], "ogg", "", ""), relayed, ogg[i])
        }
        // .oga was plain, and starts plainly still; what it holds is asked,
        // because Ogg FLAC there would stand frozen until the rescue.
        compare(KL.plan("http://x.example/live.oga", "", "", "FLAC"), { relay: false, ask: true, pull: false })
        compare(KL.plan("http://x.example/live.oga", "", "", "ogg"), { relay: false, ask: true, pull: false })
        compare(KL.plan("http://x.example/live.oga", "", "", ""), { relay: false, ask: true, pull: false })
        // An audition's label sends it to the relay as before; the answer
        // may take plain FLAC or no Ogg at all back off it.
        compare(KL.plan("http://x.example/live.oga", "", "OGG", "ogg"), { relay: true, ask: true, pull: true })
        // Once known, never asked again.
        compare(KL.plan("http://x.example/live.oga", "ogg", "", "ogg"), none)
        compare(KL.plan("http://x.example/live.oga", "ogg-flac", "", ""), relayed)
    }

    function test_an_unknown_stream_takes_its_old_road_and_is_asked_about_on_a_hint() {
        // A saved row at a bare address with a label: plain as before, and
        // the answer may send it to the relay.
        compare(KL.plan(bare, "", "", "flac"), { relay: false, ask: true, pull: false })
        compare(KL.plan(bare, "", "", "OGG"), { relay: false, ask: true, pull: false })
        // An audition with a label, and a .flac ending: the relay as before,
        // and the answer may take it back.
        compare(KL.plan(bare, "", "FLAC", "flac"), { relay: true, ask: true, pull: true })
        compare(KL.plan("http://x.example/live.flac", "", "", ""), { relay: true, ask: true, pull: true })
        compare(KL.plan("http://x.example/live.flac", "", "mp3", "mp3"), { relay: true, ask: true, pull: true })
        // No hint: plain, nothing asked.
        compare(KL.plan(bare, "", "", ""), none)
        compare(KL.plan(bare, "", "mp3", "mp3"), none)
        compare(KL.plan("http://x.example/live.mp3", "", "", ""), none)
        // A kind nobody wrote is no kind.
        compare(KL.plan(bare, "mp3", "", "flac"), { relay: false, ask: true, pull: false })
        compare(KL.plan(bare, null, "", "flac"), { relay: false, ask: true, pull: false })
        compare(KL.plan(bare, undefined, undefined, undefined), none)
    }

    function test_what_the_relay_cannot_carry_is_never_relayed_and_never_asked_about() {
        var never = ["http://x.example/list.m3u", "http://x.example/a.pls", "http://x.example/hls/a.m3u8",
                     "file:///home/me/a.flac", "", null, undefined, 7];
        for (var i = 0; i < never.length; i++) {
            compare(KL.plan(never[i], "ogg-flac", "FLAC", "flac"), none, String(never[i]))
            compare(KL.plan(never[i], "", "FLAC", "flac"), none, String(never[i]))
            compare(KL.plan(never[i], "ogg", "OGG", "ogg"), none, String(never[i]))
        }
    }

    function test_a_command_names_its_question() {
        compare(KL.seqOf(": SK_RUN; export LC_ALL=C LANGUAGE=C; timeout 6 python3 'x' 'y'; true # 42"), 42)
        compare(KL.seqOf(": SK_URL; whatever # 7\n"), 7)
        compare(KL.seqOf("true # 0"), 0)
        compare(KL.seqOf("true # 12 # 13"), 13)
        compare(KL.seqOf("true #9"), -1)
        compare(KL.seqOf("true # x"), -1)
        compare(KL.seqOf("# 5 and more"), -1)
        compare(KL.seqOf(""), -1)
        compare(KL.seqOf(null), -1)
        compare(KL.seqOf(undefined), -1)
        compare(KL.seqOf(new Array(100000).join("x") + " # 31"), 31)
    }

    function test_the_address_goes_into_a_file_and_never_to_the_helper() {
        var c = KL.buildAsk({ url: token, urlPath: "/run/user/1000/arp-icy-src-9.kind12",
                              scriptPath: "/opt/on air/streamkind.py", seq: 12 });
        verify(c.write.indexOf(": SK_URL; umask 077; printf '%s' '" + token + "' > '/run/user/1000/arp-icy-src-9.kind12'") === 0)
        verify(c.write.indexOf("__SK_URL_OK__") !== -1 && c.write.indexOf("__SK_URL_FAIL__") !== -1)
        compare(KL.seqOf(c.write), 12)
        verify(c.run.indexOf(": SK_RUN; ") === 0)
        verify(c.run.indexOf("python3 '/opt/on air/streamkind.py' '/run/user/1000/arp-icy-src-9.kind12'") !== -1)
        verify(c.run.indexOf("token") === -1, "the address is on the helper's command line")
        verify(c.run.indexOf("cdn.example.net") === -1)
        verify(c.run.indexOf("rm -f '/run/user/1000/arp-icy-src-9.kind12'") !== -1)
        verify(c.run.indexOf("timeout ") !== -1)
        compare(KL.seqOf(c.run), 12)
    }

    function test_a_sweep_removes_one_file_and_names_its_question() {
        compare(KL.buildSweep("/run/user/1000/arp-icy-src-7.kind41", 41),
                ": SK_RM; rm -f '/run/user/1000/arp-icy-src-7.kind41'; true # 41")
        compare(KL.seqOf(KL.buildSweep("/run/x.kind0", 0)), 0)
        // A path with a quote and a space in it stays one word.
        compare(KL.buildSweep("/run/it's here/a.kind7", 7), ": SK_RM; rm -f '/run/it'\\''s here/a.kind7'; true # 7")
        // Nothing is removed on a guess: no path, no number, no command.
        var none = [["", 41], [null, 41], [undefined, 41], [7, 41], ["/run/x.kind41", -1], ["/run/x.kind41", undefined],
                    ["/run/x.kind41", NaN], ["/run/x.kind41", "41"]];
        for (var i = 0; i < none.length; i++)
            compare(KL.buildSweep(none[i][0], none[i][1]), "", JSON.stringify(none[i]))
        // A path as long as a path may get.
        var longPath = "/run/" + new Array(4000).join("a") + ".kind9";
        verify(KL.buildSweep(longPath, 9).indexOf(longPath) !== -1)
    }

    function test_a_hostile_address_or_path_stays_quoted() {
        var evil = "http://x.example/a';touch /tmp/pwned;'$(id)`id`";
        var c = KL.buildAsk({ url: evil, urlPath: "/run/it's/k", scriptPath: "/opt/o'n/streamkind.py", seq: 3 });
        verify(c.write.indexOf("'http://x.example/a'\\'';touch /tmp/pwned;'\\''$(id)`id`'") !== -1)
        verify(c.write.indexOf("> '/run/it'\\''s/k'") !== -1)
        verify(c.run.indexOf("'/opt/o'\\''n/streamkind.py' '/run/it'\\''s/k'") !== -1)
        // Nothing to ask with: no commands at all rather than half of one.
        var none = [null, undefined, {}, { url: "", urlPath: "/k", scriptPath: "/s", seq: 1 },
                    { url: bare, urlPath: "", scriptPath: "/s", seq: 1 }, { url: bare, urlPath: "/k", scriptPath: "", seq: 1 },
                    { url: bare, urlPath: "/k", scriptPath: "/s" }, { url: bare, urlPath: "/k", scriptPath: "/s", seq: -1 },
                    { url: 7, urlPath: "/k", scriptPath: "/s", seq: 1 }];
        for (var i = 0; i < none.length; i++) compare(KL.buildAsk(none[i]), { write: "", run: "" }, String(i))
    }
}
