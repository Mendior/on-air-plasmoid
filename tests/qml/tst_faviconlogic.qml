// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The favicon gate, the backfill's directory-row picker and the monogram
// math — the pure pieces behind "every station gets a face".
import QtQuick
import QtTest

import "../../package/contents/ui/FaviconLogic.js" as FL

TestCase {
    name: "FaviconLogic"

    // ── webUrlOrEmpty: the one gate to Image.source and the shell ─────────

    function test_gate_passes_plain_web_urls() {
        compare(FL.webUrlOrEmpty("https://a.b/f.png"), "https://a.b/f.png")
        compare(FL.webUrlOrEmpty("http://a.b/f.ico"), "http://a.b/f.ico")
        compare(FL.webUrlOrEmpty("  https://a.b/x  "), "https://a.b/x")
        compare(FL.webUrlOrEmpty("HTTPS://A.B/x"), "HTTPS://A.B/x")
    }

    function test_gate_rejects_everything_else() {
        compare(FL.webUrlOrEmpty("file:///etc/passwd"), "")
        compare(FL.webUrlOrEmpty("data:image/png;base64,AAAA"), "")
        compare(FL.webUrlOrEmpty("javascript:alert(1)"), "")
        compare(FL.webUrlOrEmpty("sky.ee/favicon.ico"), "")   // scheme-less
        compare(FL.webUrlOrEmpty("null"), "")
    }

    function test_web_url_refuses_private_hosts() {
        // A catalogue row is publicly writable and this string reaches an
        // Image.source and syncFavicons' curl — an http(s) scheme aimed at
        // the listener's own network is still a clickless GET into it.
        compare(FL.webUrlOrEmpty("http://127.0.0.1/f.png"), "")
        compare(FL.webUrlOrEmpty("http://192.168.1.1:8080/f.png"), "")
        compare(FL.webUrlOrEmpty("http://[::1]/f.png"), "")
        compare(FL.webUrlOrEmpty("http://localhost/f.png"), "")
        compare(FL.webUrlOrEmpty("http://%31%32%37.0.0.1/f.png"), "")
        compare(FL.webUrlOrEmpty("http://10.0.0.5/f.png"), "")
        // Public logo hosts are untouched.
        compare(FL.webUrlOrEmpty("https://cdn.example.com/logo.png"),
                "https://cdn.example.com/logo.png")
        compare(FL.webUrlOrEmpty(" null "), "")
        compare(FL.webUrlOrEmpty(""), "")
        compare(FL.webUrlOrEmpty(undefined), "")
        compare(FL.webUrlOrEmpty(null), "")
        compare(FL.webUrlOrEmpty(42), "")
    }

    // ── pickFavicon: the backfill's exact-name donor rule ─────────────────

    function norm(s) {
        // stand-in for HealLogic.normName: lowercase, strip non-alnum
        return String(s).toLowerCase().replace(/[^a-z0-9]/g, "")
    }

    function test_pick_first_gated_favicon() {
        var rows = [
            { name: "A", favicon: "" },
            { name: "B", favicon: "file:///x" },
            { name: "C", favicon: "https://c.ee/l.png" },
            { name: "D", favicon: "https://d.ee/l.png" }
        ]
        compare(FL.pickFavicon(rows), "https://c.ee/l.png")
    }

    function test_pick_with_wantnorm_requires_exact_name_match() {
        var rows = [
            { name: "Sky Plus Latvia", favicon: "https://wrong.example/l.png" },
            { name: "Sky Plus", favicon: "https://sky.ee/l.png" }
        ]
        compare(FL.pickFavicon(rows, norm("Sky Plus"), norm), "https://sky.ee/l.png")
        // No exact match anywhere -> nothing, never the near-namesake.
        compare(FL.pickFavicon(rows, norm("Sky Plus Estonia"), norm), "")
    }

    function test_pick_handles_garbage() {
        compare(FL.pickFavicon([], null, null), "")
        compare(FL.pickFavicon(null, null, null), "")
        compare(FL.pickFavicon([null, {}, { name: "x" }], null, null), "")
        // wantNorm given but no normFn: fail closed.
        compare(FL.pickFavicon([{ name: "x", favicon: "https://a/l.png" }], "x", null), "")
    }

    // ── donorRows: who may speak for a saved station ──────────────────────

    // The ten most voted rows "Rock FM" answered with on 2026-09-21, in the
    // directory's order; name, countrycode, both addresses, favicon and
    // homepage as they came, every other field left out.
    readonly property var rock: [
        { name: "ROCK FM", countrycode: "RU",
          url: "http://nashe1.hostingradio.ru/rock-128.mp3",
          url_resolved: "http://nashe1.hostingradio.ru/rock-128.mp3",
          favicon: "https://lh3.googleusercontent.com/D3taObR7tfyhwDFY40VS8DIVri7iif5RuzI9C-mXxRwF41vGZ_dO_n6MWM57P-mZczFC=w300",
          homepage: "http://www.rockfm.ru/" },
        { name: "Rock FM", countrycode: "ES",
          url: "http://rockfm.cope.stream.flumotion.com/cope/rockfm-low.mp3.m3u",
          url_resolved: "http://flucast26-h-cloud.flumotion.com/cope/rockfm-low.mp3",
          favicon: "https://www.rockfm.fm/estaticos/apple-touch-icon-192x192.png",
          homepage: "http://www.rockfm.fm/" },
        { name: "Rock FM", countrycode: "EE",
          url: "https://edge02.cdn.bitflip.ee:8888/rck?_i=5f5ab186",
          url_resolved: "https://edge02.cdn.bitflip.ee:8888/rck?_i=5f5ab186",
          favicon: "https://sky.ee/favicon.ico", homepage: "https://sky.ee/rockfm" },
        { name: "Rock FM", countrycode: "ES",
          url: "http://rockfm.cope.stream.flumotion.com/cope/rockfm/playlist.m3u8",
          url_resolved: "http://rockfm.cope.stream.flumotion.com/cope/rockfm/playlist.m3u8",
          favicon: "https://www.rockfm.fm/estaticos/apple-touch-icon-192x192.png",
          homepage: "http://www.rockfm.fm/" },
        { name: "Power FM - Rock FM", countrycode: "HU",
          url: "http://s39.myradiostream.com:11590/listen/;.mp3",
          url_resolved: "http://s39.myradiostream.com:11590/listen/;.mp3",
          favicon: "", homepage: "http://www.powerfm.hu/rockfm.html" },
        { name: "Rock Fm Hard Rock", countrycode: "RO",
          url: "https://live.rockfm.ro/hard.rock", url_resolved: "https://live.rockfm.ro/hard.rock",
          favicon: "https://media.bauerradio.com/image/upload/c_crop,g_custom/v1606737505/brand_manager/stations/qyxv7nnrvwnnokjxrxgi.jpg",
          homepage: "https://www.rockfm.ro/" },
        { name: "Rock Fm Ballads", countrycode: "RO",
          url: "https://live.rockfm.ro/ballads.rock", url_resolved: "https://live.rockfm.ro/ballads.rock",
          favicon: "", homepage: "https://www.rockfm.ro/" },
        { name: "Rock FM 94.5 Turkey", countrycode: "",
          url: "http://rockfm.rockfm.com.tr:9450/stream", url_resolved: "http://rockfm.rockfm.com.tr:9450/stream",
          favicon: "", homepage: "" },
        { name: "ROCK FM Classic Rock", countrycode: "US",
          url: "https://audiotainment-sw.streamabc.net/atsw-classicrock-mp3-128-253854",
          url_resolved: "https://audiotainment-sw.streamabc.net/atsw-classicrock-mp3-128-253854",
          favicon: "http://www.my-radios.com/favicon.ico", homepage: "" },
        { name: "ROCK FM, 70s", countrycode: "RU",
          url: "http://jfm1.hostingradio.ru:14536/rock70.mp3", url_resolved: "http://jfm1.hostingradio.ru:14536/rock70.mp3",
          favicon: "https://www.rockfm.ru/favicons/apple-touch-icon.png", homepage: "" } ]
    // Sixteenth in the same answer: the Lithuanian one, 539 votes.
    readonly property var rockLt: ({ name: "Rock FM", countrycode: "LT",
          url: "https://stream2.rockfm.lt/crf128.mp3", url_resolved: "https://stream2.rockfm.lt/crf128.mp3",
          favicon: "https://rockfm.lt/wp-content/uploads/2024/11/logo-fav-100x100.png",
          homepage: "https://rockfm.lt/" })
    // The three exact-name rows among the twenty most voted "Kiss FM" rows,
    // same day: two Spanish ones without a logo, one Ukrainian with.
    readonly property var kiss: [
        { name: "KISS FM", countrycode: "ES", favicon: "", homepage: "https://www.kissfm.es/",
          url_resolved: "https://adhandler.kissfmradio.cires21.com/get_link?url=https://bbkissfm.kissfmradio.cires21.com/bbkissfm.mp3" },
        { name: "Kiss FM", countrycode: "ES", favicon: "", homepage: "https://www.kissfm.es/",
          url_resolved: "https://adhandler.kissfmradio.cires21.com/get_link?url=https://bbkissfm.kissfmradio.cires21.com/bbkissfm.mp3&lang=es" },
        { name: "Kiss FM", countrycode: "UA", homepage: "https://www.kissfm.ua/",
          url_resolved: "https://online.kissfm.ua/KissFM_HD",
          favicon: "https://play-lh.googleusercontent.com/tfpSUUVjoePVQ9FAD1rnu6xgnapf1RUjg-iPMx8dwKOWQL1aJ69aNto4je6PHednhA=w240-h480-rw" } ]
    // The five exact-name rows among the ten most voted "Radio Nova" rows,
    // same day: four countries, and the French one listed twice on a
    // landlord's domain (infomaniak.ch), once as http and once as https.
    readonly property var nova: [
        { name: "Radio Nova", countrycode: "FR",
          url_resolved: "http://novazz.ice.infomaniak.ch/novazz-128.mp3",
          favicon: "https://www.nova.fr/wp-content/uploads/sites/2/2021/02/cropped-favicon.png?fit=180%2c180&#038;quality=75" },
        { name: "Radio Nova", countrycode: "IE",
          url_resolved: "https://stream.audioxi.com/NOVA?aw_0_1st.playerid=liveradio.ie",
          favicon: "https://www.nova.ie/wp-content/uploads/2024/11/cropped-favicon-180x180.png" },
        { name: "RADIO NOVA", countrycode: "FR",
          url_resolved: "https://novazz.ice.infomaniak.ch/novazz-128.mp3",
          favicon: "https://www.nova.fr/wp-content/uploads/sites/2/2020/10/NOVA_CARD_HD.png?resize=560%2C664&quality=75" },
        { name: "Radio Nova", countrycode: "PT", url_resolved: "http://centova.radios.pt:9528/",
          favicon: "http://www.radionova.fm/favicon.ico" },
        { name: "Radio Nova", countrycode: "FI",
          url_resolved: "https://stream.bauermedia.fi/radionova/radionova_128.mp3",
          favicon: "https://www.radionova.fi/templates/radionova/images/favicon-96x96.png" } ]
    // A hand-added station the directory has never heard of.
    readonly property string stranger: "http://198.51.100.7:8000/rock"

    function test_a_name_from_three_countries_lends_nobody_a_logo() {
        var d = FL.donorRows(rock, norm("Rock FM"), norm, stranger, 30)
        compare(d.length, 0)
        // Today this is the Russian station's logo, saved to the list.
        compare(FL.pickFavicon(rock, norm("Rock FM"), norm, stranger, 30), "")
        compare(FL.pickFavicon(rock, norm("Rock FM"), norm), "")
    }

    function test_the_stations_own_record_lends_its_logo_among_namesakes() {
        // Saved as https with a trailing slash, listed as http without.
        var saved = "https://flucast26-h-cloud.flumotion.com/cope/rockfm-low.mp3/"
        var d = FL.donorRows(rock, norm("Rock FM"), norm, saved, 30)
        compare(d.length, 2)
        compare(d[0].url_resolved, "http://flucast26-h-cloud.flumotion.com/cope/rockfm-low.mp3")
        compare(d[1].countrycode, "ES")     // its sibling mount under the same roof
        compare(d[0].homepage, "http://www.rockfm.fm/")
        compare(FL.pickFavicon(rock, norm("Rock FM"), norm, saved, 30),
                "https://www.rockfm.fm/estaticos/apple-touch-icon-192x192.png")
    }

    function test_the_own_record_needs_no_roof_and_no_scheme() {
        // infomaniak.ch is a landlord, so nothing but the address itself can
        // tell the French station from the other three. Saved as https with
        // a slash; the directory lists the address twice, http first.
        var saved = "https://novazz.ice.infomaniak.ch/novazz-128.mp3/"
        var d = FL.donorRows(nova, norm("Radio Nova"), norm, saved, 30)
        compare(d.length, 2)
        compare(d[0].countrycode, "FR")
        compare(d[1].countrycode, "FR")
        compare(FL.pickFavicon(nova, norm("Radio Nova"), norm, saved, 30), nova[0].favicon)
        // Anybody else asking by that name gets nothing.
        d = FL.donorRows(nova, norm("Radio Nova"), norm, stranger, 30)
        compare(d.length, 0)
        // The playlist address the directory keeps in `url` is the station
        // too, wherever it resolves to.
        var rows = [rock[0], { name: "Rock FM", countrycode: "ES", favicon: "https://a.example.es/l.png",
                               url: "http://lists.example.es/rock.m3u",
                               url_resolved: "http://cdn7.zeno.fm/abc" }]
        d = FL.donorRows(rows, norm("Rock FM"), norm, "http://lists.example.es/rock.m3u", 30)
        compare(d.length, 1)
        compare(d[0].countrycode, "ES")
    }

    function test_the_own_base_domain_lends_and_a_landlord_does_not() {
        var all = rock.concat([rockLt])
        var d = FL.donorRows(all, norm("Rock FM"), norm, "https://stream2.rockfm.lt/an-older-mount", 30)
        compare(d.length, 1)
        compare(d[0].countrycode, "LT")
        compare(FL.pickFavicon(all, norm("Rock FM"), norm, "https://stream2.rockfm.lt/an-older-mount", 30),
                "https://rockfm.lt/wp-content/uploads/2024/11/logo-fav-100x100.png")
        // hostingradio.ru rents mounts to thousands: a roof in common with
        // the Russian row proves nothing.
        d = FL.donorRows(all, norm("Rock FM"), norm, "http://tenant.hostingradio.ru/other-128.mp3", 30)
        compare(d.length, 0)
        // Under the own roof the NAME still has to be the saved one: a side
        // channel's artwork is not the station's.
        d = FL.donorRows(all, norm("Rock FM"), norm, "https://live.rockfm.ro/rockfm.aacp", 30)
        compare(d.length, 0)
    }

    function test_rows_without_a_logo_still_vote() {
        var d = FL.donorRows(kiss, norm("Kiss FM"), norm, stranger, 0)
        compare(d.length, 0)
        // Counting only rows that carry a logo would call the Ukrainian one
        // unanimous and hand it to the Spanish station.
        compare(FL.pickFavicon(kiss, norm("Kiss FM"), norm, stranger, 0), "")
    }

    function test_a_full_page_closes_the_name_road() {
        var rows = [{ name: "Sky Plus", countrycode: "EE", url_resolved: "https://edge.sky.ee/skyplus",
                      favicon: "https://sky.ee/l.png" }]
        for (var i = 1; i < 10; i++)
            rows.push({ name: "Sky Plus " + i, countrycode: "LV",
                        url_resolved: "https://s" + i + ".example.lv/live", favicon: "" })
        compare(rows.length, 10)
        var d = FL.donorRows(rows, norm("Sky Plus"), norm, stranger, 10)
        compare(d.length, 0)
        // The same ten rows when thirty were asked for: nothing is hidden.
        d = FL.donorRows(rows, norm("Sky Plus"), norm, stranger, 30)
        compare(d.length, 1)
        // A full page never closes the identity roads.
        d = FL.donorRows(rows, norm("Sky Plus"), norm, "http://edge.sky.ee/skyplus", 10)
        compare(d.length, 1)
        compare(FL.pickFavicon(rows, norm("Sky Plus"), norm, "http://edge.sky.ee/skyplus", 10),
                "https://sky.ee/l.png")
    }

    function test_a_row_without_a_country_agrees_with_nobody() {
        var rows = [
            { name: "Rock FM", countrycode: "ES", url_resolved: "https://a.example.es/rock", favicon: "https://a.example.es/l.png" },
            { name: "Rock FM", countrycode: "", url_resolved: "https://b.example.com/rock", favicon: "" } ]
        var d = FL.donorRows(rows, norm("Rock FM"), norm, stranger, 30)
        compare(d.length, 0)
        // Two such rows have nothing in common to agree on.
        d = FL.donorRows([rows[1], { name: "Rock FM", url_resolved: "https://c.example.org/rock",
                                     favicon: "https://c.example.org/l.png" }],
                         norm("Rock FM"), norm, stranger, 30)
        compare(d.length, 0)
        // Alone it is the only station of that name there is.
        d = FL.donorRows([rows[1]], norm("Rock FM"), norm, stranger, 30)
        compare(d.length, 1)
    }

    function test_the_own_record_votes_under_another_name() {
        // The listener calls it "Nova"; the directory files the address as
        // "Radio Nova", France, without a logo. The one exact "Nova" is
        // somebody else, and the own record says so.
        var rows = [
            { name: "Radio Nova", countrycode: "FR", favicon: "",
              url_resolved: "http://novazz.ice.infomaniak.ch/novazz-128.mp3" },
            { name: "NOVA", countrycode: "AU", favicon: "https://nova.example.au/l.png",
              url_resolved: "https://stream.example.au/nova" } ]
        var d = FL.donorRows(rows, norm("Nova"), norm, "http://novazz.ice.infomaniak.ch/novazz-128.mp3", 30)
        compare(d.length, 1)
        compare(d[0].countrycode, "FR")
        compare(FL.pickFavicon(rows, norm("Nova"), norm, "http://novazz.ice.infomaniak.ch/novazz-128.mp3", 30), "")
    }

    function test_one_country_or_one_roof_is_one_station() {
        // The two French rows alone: a landlord's roof is no witness, the
        // country is, and the name means one station here.
        var d = FL.donorRows([nova[0], nova[2]], norm("Radio Nova"), norm, stranger, 30)
        compare(d.length, 2)
        // Two countries on paper, one non-shared roof: a broadcaster's mounts.
        var rows = [
            { name: "Radio X", countrycode: "DE", url_resolved: "https://a.radiox.example/hi", favicon: "" },
            { name: "Radio X", countrycode: "AT", url_resolved: "https://b.radiox.example/lo", favicon: "https://radiox.example/l.png" } ]
        d = FL.donorRows(rows, norm("Radio X"), norm, stranger, 30)
        compare(d.length, 2)
        compare(FL.pickFavicon(rows, norm("Radio X"), norm, stranger, 30), "https://radiox.example/l.png")
        // The same two under a landlord, and the roof is no witness.
        rows[0].url_resolved = "https://a.zeno.fm/hi"
        rows[1].url_resolved = "https://b.zeno.fm/lo"
        d = FL.donorRows(rows, norm("Radio X"), norm, stranger, 30)
        compare(d.length, 0)
    }

    function test_donor_rows_answer_garbage_with_nothing() {
        compare(FL.donorRows(null, "x", norm, "", 0).length, 0)
        compare(FL.donorRows([], "x", norm, "", 0).length, 0)
        compare(FL.donorRows([null, {}, { name: "x" }], "", norm, "", 0).length, 0)
        compare(FL.donorRows([{ name: "x" }], "x", null, "", 0).length, 0)
        // No address to compare, no limit known: the name road alone.
        compare(FL.donorRows([null, { name: "x" }], "x", norm).length, 1)
        compare(FL.donorRows([{ name: "x" }], "x", norm, undefined, undefined).length, 1)
    }

    // ── monogramText ──────────────────────────────────────────────────────

    function test_monogram_two_words() {
        compare(FL.monogramText("Raadio Elmar"), "RE")
        compare(FL.monogramText("Sky Plus"), "SP")
        compare(FL.monogramText("HITS RADIO ESTONIA"), "HR")
        compare(FL.monogramText("Võmba FM"), "VF")
    }

    function test_monogram_single_word() {
        compare(FL.monogramText("Elmar"), "EL")
        compare(FL.monogramText("R2"), "R2")
        compare(FL.monogramText("Õ"), "Õ")
    }

    function test_monogram_keeps_diacritics() {
        compare(FL.monogramText("Õhtune Ärikanal"), "ÕÄ")
    }

    function test_monogram_speaks_other_scripts() {
        compare(FL.monogramText("Ελληνικό Ράδιο"), "ΕΡ")     // Greek
        compare(FL.monogramText("Радио Маяк"), "РМ")          // Cyrillic
        compare(FL.monogramText("東京 FM"), "東F")             // CJK + Latin
        compare(FL.monogramText("ラジオ"), "ラジ")             // kana, one token
    }

    function test_monogram_strips_leading_punctuation() {
        compare(FL.monogramText("«Radio» +Nova"), "RN")
        compare(FL.monogramText("...Beat FM"), "BF")
    }

    function test_monogram_garbage_is_empty() {
        compare(FL.monogramText(""), "")
        compare(FL.monogramText("   "), "")
        compare(FL.monogramText("«»..."), "")
        compare(FL.monogramText(undefined), "")
        compare(FL.monogramText(null), "")
    }

    // ── monogramHue ───────────────────────────────────────────────────────

    function test_hue_is_deterministic_and_case_blind() {
        compare(FL.monogramHue("Raadio Elmar"), FL.monogramHue("Raadio Elmar"))
        compare(FL.monogramHue("Sky Plus"), FL.monogramHue("sky plus"))
        compare(FL.monogramHue(" Sky Plus "), FL.monogramHue("Sky Plus"))
    }

    function test_hue_stays_in_the_safe_band() {
        var names = ["Raadio Elmar", "Sky Plus", "R2", "Võmba FM", "x", "",
                     "HITS RADIO ESTONIA", "Retro FM Estonia", "Raadio Kuku"]
        for (var i = 0; i < names.length; i++) {
            var h = FL.monogramHue(names[i])
            verify(h >= 90 && h <= 230, names[i] + " -> " + h)
        }
    }

    function test_hue_spreads_across_names() {
        // Not a strict requirement, but the three demo stations must not
        // all collapse onto one color — that would defeat the point.
        var a = FL.monogramHue("Raadio Elmar")
        var b = FL.monogramHue("Sky Plus")
        var c = FL.monogramHue("Raadio Kuku")
        verify(!(a === b && b === c))
    }
}
