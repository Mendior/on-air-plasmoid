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

    // ── what a homepage says about its logo ───────────────────────────────

    // Raadio Kadi's homepage as it answered on 2026-11-02, the tags that
    // matter and one that does not.
    readonly property string kadiHead:
        '<link rel="shortcut icon" href="https://kadi.ee/wp-content/themes/raadio/img/favicon.ico">\n'
        + '<meta property="og:image" content="https://kadi.ee/wp-content/uploads/2022/01/logo-og-1.jpg" />\n'
        + '<meta property="og:image:width" content="1200" />\n'
        + "<link rel='stylesheet' id='dashicons-css' href='https://kadi.ee/wp-includes/css/dashicons.min.css?ver=7.1.4' media='all' />\n"

    function test_origin_is_scheme_host_and_port() {
        compare(FL.originOf("https://kadi.ee/"), "https://kadi.ee")
        compare(FL.originOf("https://edge06.cdn.bitflip.ee:8888/kadi"), "https://edge06.cdn.bitflip.ee:8888")
        compare(FL.originOf("HTTP://A.B/x?y"), "HTTP://A.B")
        compare(FL.originOf("kadi.ee/x"), "")
        compare(FL.originOf("ftp://a.b/x"), "")
        compare(FL.originOf(""), "")
    }

    function test_a_link_is_made_absolute_against_its_page() {
        var page = "https://kadi.ee/raadio/index.php?x=1#top"
        compare(FL.resolveUrl("https://cdn.kadi.ee/a.png", page), "https://cdn.kadi.ee/a.png")
        compare(FL.resolveUrl("//cdn.kadi.ee/a.png", page), "https://cdn.kadi.ee/a.png")
        compare(FL.resolveUrl("/img/a.png", page), "https://kadi.ee/img/a.png")
        compare(FL.resolveUrl("img/a.png", page), "https://kadi.ee/raadio/img/a.png")
        compare(FL.resolveUrl("  /img/a.png  ", page), "https://kadi.ee/img/a.png")
        // A page address with no path keeps the link at its root.
        compare(FL.resolveUrl("a.png", "https://kadi.ee"), "https://kadi.ee/a.png")
    }

    function test_a_link_that_is_no_address_resolves_to_nothing() {
        var page = "https://kadi.ee/"
        compare(FL.resolveUrl("#logo", page), "")
        compare(FL.resolveUrl("data:image/png;base64,AAAA", page), "")
        compare(FL.resolveUrl("javascript:alert(1)", page), "")
        compare(FL.resolveUrl("", page), "")
        compare(FL.resolveUrl(null, page), "")
        compare(FL.resolveUrl(undefined, page), "")
        // Nothing to resolve a relative link against.
        compare(FL.resolveUrl("a.png", ""), "")
        compare(FL.resolveUrl("/a.png", "kadi.ee"), "")
    }

    function test_the_icon_links_and_og_image_of_a_page_in_order() {
        compare(FL.extractIconLinks(kadiHead, "https://kadi.ee/"), [
            { url: "https://kadi.ee/wp-content/themes/raadio/img/favicon.ico", kind: "page" },
            { url: "https://kadi.ee/wp-content/uploads/2022/01/logo-og-1.jpg", kind: "share" }
        ])
        var html = '<link rel=icon href=/a.png>'
            + "<link href='/b.png' rel='apple-touch-icon' sizes='180x180'>"
            + '<link rel="fluid-icon" href="c.png" />'
            + '<link rel="stylesheet" href="/e.css">'
            + '<link rel="preload" href="/f.png">'
            + '<link rel="icon">'
            + '<link rel="icon" href="/a.png">'
            + '<meta name="og:image" content="/g.jpg">'
            + '<meta property="og:image" content="/b.png">'
        compare(FL.extractIconLinks(html, "https://r.ee/x/"), [
            { url: "https://r.ee/a.png", kind: "page" }, { url: "https://r.ee/b.png", kind: "page" },
            { url: "https://r.ee/x/c.png", kind: "page" }, { url: "https://r.ee/g.jpg", kind: "share" }
        ])
    }

    function test_a_hostile_page_is_read_in_a_moment() {
        // A homepage comes from a record anyone can file, and the popup reads
        // it with no click. A 96 KiB head of "<meta/name='og:image'" and no
        // ">" kept the old patterns busy for 125 s on Qt 6.12, the whole
        // shell frozen with them (measured 2026-11-03).
        var unit = "<meta/name='og:image'", body = ""
        while (body.length < 98304) body += unit
        var t0 = Date.now()
        compare(FL.extractIconLinks(body, "https://r.ee/"), [])
        var took = Date.now() - t0
        verify(took < 2000, "the og:image flood took " + took + " ms")
        body = ""
        while (body.length < 98304) body += "<link "
        t0 = Date.now()
        compare(FL.extractIconLinks(body, "https://r.ee/"), [])
        took = Date.now() - t0
        verify(took < 2000, "the link flood took " + took + " ms")
    }

    function test_a_tag_past_the_cap_is_passed_over_and_the_next_one_read() {
        var huge = '<link rel="icon" data-x="' + new Array(3000).join("y") + '" href="/huge.png">'
        compare(FL.extractIconLinks(huge + '<link rel="icon" href="/small.png">', "https://r.ee/"),
                [{ url: "https://r.ee/small.png", kind: "page" }])
    }

    function test_an_og_image_is_read_whichever_attribute_comes_first() {
        compare(FL.extractIconLinks('<meta content="/og.jpg" property="og:image">', "https://r.ee/"),
                [{ url: "https://r.ee/og.jpg", kind: "share" }])
        // A self-closing tag with a bare address keeps its address whole.
        compare(FL.extractIconLinks('<link rel=icon href=/x.png/>', "https://r.ee/"),
                [{ url: "https://r.ee/x.png", kind: "page" }])
    }

    function test_a_pinned_tab_mask_is_no_logo() {
        // Safari's mask-icon is one flat colour on transparency that the
        // browser tints itself; as a logo it is a black shape.
        compare(FL.extractIconLinks('<link rel="mask-icon" href="/safari-pinned-tab.svg" color="#5bbad5">'
                                    + '<link rel="icon" href="/favicon.svg">', "https://r.ee/"),
                [{ url: "https://r.ee/favicon.svg", kind: "page" }])
    }

    function test_a_hunt_keeps_the_logo_a_row_has_unless_something_beats_it() {
        // Re-fetch all asks the row's own logo first: the find that is that
        // very logo changes nothing, and anything else beat it or found it dead.
        var own = "https://r.ee/press/logo-1024.png"
        var tiny = { url: "https://r.ee/favicon.ico", size: { width: 16, height: 16 } }
        verify(!FL.keepsFind({ url: own, size: { width: 1024, height: 1024 } }, own, false))
        verify(FL.keepsFind(tiny, own, false), "the row's own logo did not answer")
        verify(FL.keepsFind(tiny, "", false), "a row with no logo takes what there is")
        // An upgrade looks only for something larger than its tab-sized logo.
        verify(!FL.keepsFind(tiny, "https://r.ee/favicon-16x16.png", true))
        verify(FL.keepsFind({ url: "https://r.ee/logo.png", size: { width: 512, height: 512 } }, "https://r.ee/favicon-16x16.png", true))
        verify(!FL.keepsFind(null, own, false))
        // The row's own logo is asked first, whatever its kind of address.
        compare(FL.probeOrder([{ url: "https://r.ee/a.png", kind: "page" },
                               { url: "https://www.google.com/s2/favicons?domain=r.ee&sz=64", kind: "current" }])[0],
                "https://www.google.com/s2/favicons?domain=r.ee&sz=64")
    }

    function test_a_landlords_page_offers_only_its_og_image() {
        // laut.fm/mangoradio named laut.fm's own 180 px apple-touch-icon and
        // had the station's picture as og:image (measured 2026-11-03).
        verify(FL.landlordPage("https://laut.fm/mangoradio"))
        verify(FL.landlordPage("https://zeno.fm/radio/x/"))
        verify(!FL.landlordPage("https://kadi.ee/"))
        verify(!FL.landlordPage(""))
        var images = [{ url: "https://laut.fm/assets/apple-touch-icon.png", kind: "page" },
                      { url: "https://assets.laut.fm/abc?t=_640x640", kind: "share" }]
        compare(FL.homepageCandidates(images, "https://laut.fm/mangoradio"),
                [{ url: "https://assets.laut.fm/abc?t=_640x640", kind: "share" }])
        var own = FL.homepageCandidates([{ url: "https://kadi.ee/i.png", kind: "page" }], "https://kadi.ee/")
        compare(own.length, 1 + 7)
        compare(own[0].url, "https://kadi.ee/i.png")
        compare(own[1].url, "https://kadi.ee/apple-touch-icon.png")
        compare(FL.homepageCandidates(null, "https://kadi.ee/").length, 7)
    }

    function test_the_well_known_icon_paths_of_an_origin() {
        compare(FL.wellKnownIcons("https://kadi.ee"), [
            { url: "https://kadi.ee/apple-touch-icon.png", kind: "guess" },
            { url: "https://kadi.ee/apple-touch-icon-precomposed.png", kind: "guess" },
            { url: "https://kadi.ee/favicon-194x194.png", kind: "guess" },
            { url: "https://kadi.ee/favicon-192x192.png", kind: "guess" },
            { url: "https://kadi.ee/favicon-96x96.png", kind: "guess" },
            { url: "https://kadi.ee/favicon-32x32.png", kind: "guess" },
            { url: "https://kadi.ee/favicon.ico", kind: "guess" }
        ])
        compare(FL.wellKnownIcons(""), [])
        compare(FL.wellKnownIcons(null), [])
        compare(FL.wellKnownIcons(undefined), [])
    }

    function test_a_page_with_nothing_to_offer_offers_nothing() {
        compare(FL.extractIconLinks("", "https://r.ee/"), [])
        compare(FL.extractIconLinks(null, "https://r.ee/"), [])
        compare(FL.extractIconLinks("<html><body>no icons</body></html>", "https://r.ee/"), [])
        // An inline picture is not an address anybody can fetch.
        compare(FL.extractIconLinks('<link rel="icon" href="data:image/png;base64,AAAA">', "https://r.ee/"), [])
    }

    function bytes(list) {
        return new Uint8Array(list)
    }

    function test_the_picture_formats_qt_decodes_are_pictures() {
        verify(FL.looksLikeImageBytes(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))   // PNG
        verify(FL.looksLikeImageBytes(bytes([0xFF, 0xD8, 0xFF, 0xE0])))               // JPEG
        verify(FL.looksLikeImageBytes(bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])))   // GIF
        verify(FL.looksLikeImageBytes(bytes([0x00, 0x00, 0x01, 0x00])))               // ICO
        verify(FL.looksLikeImageBytes(bytes([0x00, 0x00, 0x02, 0x00])))               // CUR
        verify(FL.looksLikeImageBytes(bytes([0x42, 0x4D, 0x00, 0x00])))               // BMP
        verify(FL.looksLikeImageBytes(bytes([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4,
                                             0x57, 0x45, 0x42, 0x50])))               // WebP
        var svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>'
        var a = []
        for (var i = 0; i < svg.length; i++) a.push(svg.charCodeAt(i))
        verify(FL.looksLikeImageBytes(bytes(a)))
    }

    function test_a_page_or_a_short_reply_is_no_picture() {
        var html = "<!DOCTYPE html><html><head><title>404</title></head></html>"
        var a = []
        for (var i = 0; i < html.length; i++) a.push(html.charCodeAt(i))
        verify(!FL.looksLikeImageBytes(bytes(a)))
        verify(!FL.looksLikeImageBytes(bytes([0x89, 0x50, 0x4E])))
        // RIFF that is not WebP (a WAV file).
        verify(!FL.looksLikeImageBytes(bytes([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4,
                                              0x57, 0x41, 0x56, 0x45])))
        verify(!FL.looksLikeImageBytes(bytes([])))
        verify(!FL.looksLikeImageBytes(null))
        verify(!FL.looksLikeImageBytes(undefined))
    }

    function test_the_logo_addresses_that_are_small_by_construction() {
        verify(FL.tinyLogoUrl("https://kadi.ee/favicon.ico"))
        verify(FL.tinyLogoUrl("https://kadi.ee/wp-content/themes/raadio/img/favicon.ico"))
        verify(FL.tinyLogoUrl("https://kadi.ee/favicon.ico?v=2"))
        verify(FL.tinyLogoUrl("favicon.ico"))
        verify(FL.tinyLogoUrl("https://r.ee/favicon-16x16.png"))
        verify(FL.tinyLogoUrl("https://r.ee/favicon-32x32.png"))
        verify(FL.tinyLogoUrl("https://www.google.com/s2/favicons?domain=kadi.ee&sz=128"))
        verify(!FL.tinyLogoUrl("https://r.ee/favicon-192x192.png"))
        verify(!FL.tinyLogoUrl("https://r.ee/apple-touch-icon.png"))
        verify(!FL.tinyLogoUrl("https://r.ee/myfavicon.icon"))
        verify(!FL.tinyLogoUrl(""))
        verify(!FL.tinyLogoUrl(null))
    }

    // ── imageSize: what a picture's header says ───────────────────────────

    function be16(n) { return [(n >>> 8) & 255, n & 255] }
    function le16(n) { return [n & 255, (n >>> 8) & 255] }
    function be32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255] }
    function le24(n) { return [n & 255, (n >>> 8) & 255, (n >>> 16) & 255] }
    // Payload bytes that never contain 0xFF, so nothing in them reads as a
    // marker by accident.
    function filler(n) {
        var a = []
        for (var i = 0; i < n; i++) a.push(i % 251)
        return a
    }
    function ascii(s) {
        var a = []
        for (var i = 0; i < s.length; i++) a.push(s.charCodeAt(i))
        return a
    }
    function size(w, h) { return { width: w, height: h } }

    function pngHead(w, h) {
        return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
            .concat(ascii("IHDR"), be32(w), be32(h), [8, 6, 0, 0, 0])
    }
    function gifHead(w, h) { return ascii("GIF89a").concat(le16(w), le16(h), [0xF7, 0, 0]) }
    // One directory entry per [width, height], in the order given; 256 is
    // written as 0, the way the format spells it.
    function icoHead(kind, sizes) {
        var out = [0, 0, kind, 0].concat(le16(sizes.length))
        for (var i = 0; i < sizes.length; i++)
            out = out.concat([sizes[i][0] % 256, sizes[i][1] % 256, 0, 0, 1, 0, 32, 0],
                             [0x68, 5, 0, 0], le16(6 + 16 * sizes.length + 1406 * i), [0, 0])
        return out
    }
    function segment(marker, payload) { return [0xFF, marker].concat(be16(payload.length + 2), payload) }
    function sof(marker, w, h) {
        return segment(marker, [8].concat(be16(h), be16(w), [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]))
    }
    function jpeg(parts) {
        var out = [0xFF, 0xD8]
        for (var i = 0; i < parts.length; i++) out = out.concat(parts[i])
        return out
    }
    // Raadio Kadi's logo-og-1.jpg up to its first scan, segment for segment
    // (JFIF, Ducky, Adobe, DQT, SOF2 at byte 213, DHT), with the payloads
    // replaced by filler.
    function kadiJpeg(w, h) {
        return jpeg([segment(0xE0, filler(14)), segment(0xEC, filler(15)), segment(0xEE, filler(36)),
                     segment(0xDB, filler(130)), sof(0xC2, w, h), segment(0xC4, filler(318)),
                     segment(0xDA, filler(10))])
    }
    function webp(tag, chunk) {
        return ascii("RIFF").concat([0x40, 0x0F, 0, 0], ascii("WEBP"), ascii(tag),
                                    le16(chunk.length), [0, 0], chunk)
    }
    // VP8 frame tag, start code, then 14 bits of size and 2 of scale each.
    function vp8(w, h, scale) {
        return webp("VP8 ", [0x50, 0x0D, 0x00, 0x9D, 0x01, 0x2A]
                    .concat(le16(w | (scale << 14)), le16(h | (scale << 14)), filler(8)))
    }
    // Above the two sizes sit the alpha flag (bit 28) and the version.
    function vp8l(w, h, alpha) {
        var bits = (w - 1) + (h - 1) * 16384 + (alpha ? 268435456 : 0)
        return webp("VP8L", [0x2F, bits % 256, Math.floor(bits / 256) % 256,
                             Math.floor(bits / 65536) % 256, Math.floor(bits / 16777216) % 256]
                    .concat(filler(8)))
    }
    function vp8x(w, h) { return webp("VP8X", [0x10, 0, 0, 0].concat(le24(w - 1), le24(h - 1))) }

    function test_a_png_says_its_size_in_ihdr() {
        compare(FL.imageSize(bytes(pngHead(200, 100))), size(200, 100))
        compare(FL.imageSize(bytes(pngHead(180, 180).concat(filler(40)))), size(180, 180))
        // A line of a picture is reported as it is; the ranking judges it.
        compare(FL.imageSize(bytes(pngHead(1, 10000))), size(1, 10000))
        // Four bytes of width are read whole, never as a negative number.
        compare(FL.imageSize(bytes(pngHead(4294967295, 1))), size(4294967295, 1))
    }

    function test_a_png_cut_short_or_out_of_shape_has_no_size() {
        var head = pngHead(200, 100)
        compare(FL.imageSize(bytes(head.slice(0, 24))), size(200, 100))
        compare(FL.imageSize(bytes(head.slice(0, 23))), null)
        // Apple's CgBI chunk ahead of IHDR is not a PNG Qt can show.
        var cgbi = head.slice(0, 12).concat(ascii("CgBI"), head.slice(16))
        compare(FL.imageSize(bytes(cgbi)), null)
        compare(FL.imageSize(bytes(pngHead(0, 100))), null)
        compare(FL.imageSize(bytes(pngHead(100, 0))), null)
    }

    function test_a_gif_says_its_logical_screen() {
        compare(FL.imageSize(bytes(gifHead(64, 48))), size(64, 48))
        compare(FL.imageSize(bytes(ascii("GIF87a").concat(le16(300), le16(2)))), size(300, 2))
        compare(FL.imageSize(bytes(gifHead(64, 48).slice(0, 9))), null)
        compare(FL.imageSize(bytes(gifHead(0, 48))), null)
    }

    function test_an_icon_is_as_big_as_the_entry_qt_paints() {
        // Raadio Kadi's favicon.ico: one 16x16 entry.
        compare(FL.imageSize(bytes(icoHead(1, [[16, 16]]))), size(16, 16))
        // Several entries: the first, whatever comes after it.
        compare(FL.imageSize(bytes(icoHead(1, [[16, 16], [256, 256]]))), size(16, 16))
        compare(FL.imageSize(bytes(icoHead(1, [[48, 48], [32, 32], [16, 16]]))), size(48, 48))
        compare(FL.imageSize(bytes(icoHead(1, [[256, 256], [16, 16]]))), size(256, 256))
        compare(FL.imageSize(bytes(icoHead(1, [[256, 128]]))), size(256, 128))
        // A cursor file has the same directory.
        compare(FL.imageSize(bytes(icoHead(2, [[32, 32]]))), size(32, 32))
    }

    function test_an_icon_without_a_whole_first_entry_has_no_size() {
        var head = icoHead(1, [[48, 48], [16, 16]])
        compare(FL.imageSize(bytes(head.slice(0, 22))), size(48, 48))
        compare(FL.imageSize(bytes(head.slice(0, 21))), null)
        compare(FL.imageSize(bytes(icoHead(1, []).concat(filler(16)))), null)
    }

    function test_a_jpeg_says_its_size_in_the_first_frame_header() {
        var kadi = kadiJpeg(1200, 1200)
        // The fixture is Kadi's file in shape: the frame header at 213.
        compare(kadi[213], 0xFF)
        compare(kadi[214], 0xC2)
        compare(FL.imageSize(bytes(kadi)), size(1200, 1200))
        compare(FL.imageSize(bytes(jpeg([segment(0xE0, filler(14)), segment(0xDB, filler(65)),
                                         sof(0xC0, 640, 480), segment(0xDA, filler(10))]))), size(640, 480))
        // Width and height sit in that order on the wire: height first.
        compare(FL.imageSize(bytes(jpeg([sof(0xC1, 300, 7000)]))), size(300, 7000))
        // Fill bytes may stand before any marker, and a few markers carry
        // no length at all.
        compare(FL.imageSize(bytes([0xFF, 0xD8, 0xFF, 0xFF, 0xFF].concat(sof(0xC0, 96, 96).slice(1)))), size(96, 96))
        compare(FL.imageSize(bytes(jpeg([[0xFF, 0xD0], [0xFF, 0x01], [0xFF, 0xD8], sof(0xC0, 96, 96)]))), size(96, 96))
    }

    function test_a_jpeg_thumbnail_is_not_the_picture() {
        // An EXIF block carries a whole small JPEG of its own, frame header
        // included, ahead of the real one. Reading byte by byte finds that
        // one first.
        var exif = ascii("Exif").concat([0, 0], filler(40), [0xFF, 0xD8], sof(0xC0, 160, 120),
                                        [0xFF, 0xD9], filler(20))
        compare(FL.imageSize(bytes(jpeg([segment(0xE1, exif), segment(0xDB, filler(65)),
                                         sof(0xC0, 640, 640), segment(0xDA, filler(10))]))), size(640, 640))
        // The tables that share the C0-CF range are no frame header.
        compare(FL.imageSize(bytes(jpeg([segment(0xC4, filler(20)), segment(0xCC, filler(4)),
                                         segment(0xC8, filler(6)), sof(0xC0, 200, 200)]))), size(200, 200))
    }

    function test_a_jpeg_that_stops_before_its_frame_header_has_no_size() {
        var kadi = kadiJpeg(1200, 1200)
        // The width's last byte is byte 221.
        compare(FL.imageSize(bytes(kadi.slice(0, 222))), size(1200, 1200))
        compare(FL.imageSize(bytes(kadi.slice(0, 221))), null)
        compare(FL.imageSize(bytes(kadi.slice(0, 213))), null)
        // A scan or the end of the image before any frame header.
        compare(FL.imageSize(bytes(jpeg([segment(0xE0, filler(14)), segment(0xDA, filler(10)),
                                         sof(0xC0, 64, 64)]))), null)
        compare(FL.imageSize(bytes(jpeg([[0xFF, 0xD9, 0x00, 0x02], sof(0xC0, 64, 64)]))), null)
        // Lost the chain of segments, or a length that cannot be one.
        compare(FL.imageSize(bytes([0xFF, 0xD8, 0x00, 0x10].concat(sof(0xC0, 64, 64)))), null)
        compare(FL.imageSize(bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01].concat(sof(0xC0, 64, 64)))), null)
        // A frame whose height comes later (DNL) says nothing usable here.
        compare(FL.imageSize(bytes(jpeg([sof(0xC0, 64, 0)]))), null)
    }

    function test_a_webp_says_its_size_in_each_of_its_three_headers() {
        compare(FL.imageSize(bytes(vp8(300, 200, 0))), size(300, 200))
        // The two scale bits above each size are not part of it.
        compare(FL.imageSize(bytes(vp8(300, 200, 3))), size(300, 200))
        compare(FL.imageSize(bytes(vp8l(1000, 750))), size(1000, 750))
        compare(FL.imageSize(bytes(vp8l(16384, 1))), size(16384, 1))
        compare(FL.imageSize(bytes(vp8l(1, 16384))), size(1, 16384))
        // A lossless logo with transparency sets the alpha flag right
        // above the height, measured on a PIL-encoded file.
        compare(FL.imageSize(bytes(vp8l(1000, 5000, true))), size(1000, 5000))
        compare(FL.imageSize(bytes(vp8x(2000, 1500))), size(2000, 1500))
        compare(FL.imageSize(bytes(vp8x(70000, 300))), size(70000, 300))
    }

    function test_a_webp_cut_short_or_of_another_kind_has_no_size() {
        var x = vp8x(512, 512)
        compare(FL.imageSize(bytes(x.slice(0, 30))), size(512, 512))
        compare(FL.imageSize(bytes(x.slice(0, 29))), null)
        compare(FL.imageSize(bytes(vp8(300, 200, 0).slice(0, 29))), null)
        // Cut before the byte that holds the top of the height.
        compare(FL.imageSize(bytes(vp8l(1000, 5000))), size(1000, 5000))
        compare(FL.imageSize(bytes(vp8l(1000, 5000).slice(0, 24))), null)
        // A VP8 frame that is not a key frame has no start code.
        var inter = vp8(300, 200, 0)
        inter[23] = 0
        compare(FL.imageSize(bytes(inter)), null)
        var lossless = vp8l(1000, 750)
        lossless[20] = 0x2E
        compare(FL.imageSize(bytes(lossless)), null)
        compare(FL.imageSize(bytes(webp("ALPH", filler(20)))), null)
        // RIFX is the big-endian RIFF of other formats, never WebP.
        var rifx = vp8x(512, 512)
        rifx[3] = 0x58
        compare(FL.imageSize(bytes(rifx)), null)
    }

    function test_what_is_no_picture_with_a_size_answers_null() {
        compare(FL.imageSize(bytes(ascii('<svg xmlns="http://www.w3.org/2000/svg" width="512"></svg>'))), null)
        compare(FL.imageSize(bytes([0x42, 0x4D].concat(filler(60)))), null)
        compare(FL.imageSize(bytes(ascii("<!DOCTYPE html><html><head></head></html>"))), null)
        compare(FL.imageSize(bytes([])), null)
        compare(FL.imageSize(bytes([0x89, 0x50, 0x4E, 0x47])), null)
        compare(FL.imageSize(null), null)
        compare(FL.imageSize(undefined), null)
    }

    // ── which picture a logo hunt keeps ───────────────────────────────────

    readonly property string kadiIcon: "https://kadi.ee/wp-content/themes/raadio/img/favicon.ico"
    readonly property string kadiOg: "https://kadi.ee/wp-content/uploads/2022/01/logo-og-1.jpg"
    readonly property string logo: "https://r.ee/img/logo.png"

    function test_a_large_square_ranks_first() {
        compare(FL.logoRank(kadiOg, size(1200, 1200)), 0)
        compare(FL.logoRank(logo, size(96, 96)), 0)
        compare(FL.logoRank(logo, size(95, 95)), 1)
        compare(FL.logoRank(logo, size(33, 33)), 1)
        compare(FL.logoRank(logo, size(32, 32)), 4)
        compare(FL.logoRank(kadiIcon, size(16, 16)), 4)
    }

    function test_square_enough_is_five_to_four_either_way() {
        compare(FL.logoRank(logo, size(120, 96)), 0)
        compare(FL.logoRank(logo, size(121, 96)), 3)
        compare(FL.logoRank(logo, size(96, 120)), 0)
        compare(FL.logoRank(logo, size(96, 121)), 3)
        compare(FL.logoRank(logo, size(50, 40)), 1)
        compare(FL.logoRank(logo, size(51, 40)), 3)
        // The sharing banner shape.
        compare(FL.logoRank(logo, size(1200, 630)), 3)
    }

    function test_a_thin_strip_is_tiny_however_long() {
        compare(FL.logoRank(logo, size(1, 10000)), 4)
        compare(FL.logoRank(logo, size(10000, 32)), 4)
        compare(FL.logoRank(logo, size(10000, 33)), 3)
    }

    function test_a_picture_without_a_size_ranks_between_shapes() {
        compare(FL.logoRank("https://r.ee/logo.svg", null), 2)
        compare(FL.logoRank("https://r.ee/favicon.ico", null), 4)
        compare(FL.logoRank("https://r.ee/favicon-32x32.png", null), 4)
    }

    function test_google_ranks_tiny_whatever_it_answers() {
        compare(FL.logoRank("https://www.google.com/s2/favicons?domain=kadi.ee&sz=128", size(128, 128)), 4)
        compare(FL.logoRank("https://www.google.com/s2/favicons?domain=kadi.ee&sz=128", null), 4)
        // A bare favicon.ico is judged by the picture Qt paints from it.
        compare(FL.logoRank("https://r.ee/favicon.ico", size(48, 48)), 1)
        compare(FL.logoRank("https://r.ee/favicon.ico", size(256, 256)), 0)
    }

    function test_the_best_of_raadio_kadi_is_its_og_image() {
        var found = [{ url: kadiIcon, size: size(16, 16) }, { url: kadiOg, size: size(1200, 1200) }]
        compare(FL.bestLogo(found).url, kadiOg)
        compare(FL.bestLogo(found.slice().reverse()).url, kadiOg)
    }

    function test_the_best_is_by_rank_then_side_then_order() {
        var banner = { url: "https://r.ee/share.jpg", size: size(1200, 630) }
        var icon48 = { url: "https://r.ee/i48.png", size: size(48, 48) }
        var icon64 = { url: "https://r.ee/i64.png", size: size(64, 64) }
        var svg = { url: "https://r.ee/logo.svg", size: null }
        var tiny = { url: "https://r.ee/favicon.ico", size: size(16, 16) }
        compare(FL.bestLogo([banner, icon48]).url, icon48.url)
        compare(FL.bestLogo([icon48, icon64]).url, icon64.url)
        compare(FL.bestLogo([icon64, { url: "https://r.ee/other.png", size: size(64, 64) }]).url, icon64.url)
        compare(FL.bestLogo([banner, svg]).url, svg.url)
        compare(FL.bestLogo([tiny, banner]).url, banner.url)
        compare(FL.bestLogo([tiny, svg]).url, svg.url)
        // Two large squares: the longer shorter side.
        compare(FL.bestLogo([{ url: "https://r.ee/a.png", size: size(180, 180) },
                             { url: "https://r.ee/b.png", size: size(512, 500) }]).url, "https://r.ee/b.png")
    }

    function test_the_best_of_nothing_is_nothing() {
        compare(FL.bestLogo([]), null)
        compare(FL.bestLogo(null), null)
        compare(FL.bestLogo(undefined), null)
        compare(FL.bestLogo([null, undefined]), null)
        compare(FL.bestLogo([null, { url: logo, size: size(16, 16) }]).url, logo)
    }

    function page(u) { return { url: u, kind: "page" } }
    function share(u) { return { url: u, kind: "share" } }
    function guess(u) { return { url: u, kind: "guess" } }
    function host(u) { return { url: u, kind: "host" } }
    function guesses(origin) {
        return ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/favicon-194x194.png",
                "/favicon-192x192.png", "/favicon-96x96.png", "/favicon-32x32.png", "/favicon.ico"]
            .map(function(p) { return guess(origin + p) })
    }

    function test_raadio_kadi_is_asked_the_apple_path_then_its_og_image() {
        var cands = [page(kadiIcon), share(kadiOg)].concat(guesses("https://kadi.ee"))
        compare(FL.probeOrder(cands), [
            "https://kadi.ee/apple-touch-icon.png",
            kadiOg,
            "https://kadi.ee/apple-touch-icon-precomposed.png",
            "https://kadi.ee/favicon-194x194.png",
            "https://kadi.ee/favicon-192x192.png",
            "https://kadi.ee/favicon-96x96.png",
            kadiIcon,
            "https://kadi.ee/favicon-32x32.png",
            "https://kadi.ee/favicon.ico"
        ])
    }

    function test_what_the_page_names_goes_first_in_its_own_order() {
        var cands = [guess("https://r.ee/apple-touch-icon.png"), share("https://r.ee/og.jpg"),
                     page("https://r.ee/b.png"), page("https://r.ee/favicon-16x16.png"),
                     page("https://r.ee/a.png"), guess("https://www.google.com/s2/favicons?domain=r.ee&sz=128"),
                     guess("https://r.ee/favicon-192x192.png"), page("https://r.ee/apple-touch-icon.png")]
        compare(FL.probeOrder(cands), [
            "https://r.ee/b.png", "https://r.ee/a.png", "https://r.ee/apple-touch-icon.png",
            "https://r.ee/og.jpg", "https://r.ee/favicon-192x192.png", "https://r.ee/favicon-16x16.png",
            "https://www.google.com/s2/favicons?domain=r.ee&sz=128"
        ])
    }

    function test_the_og_image_goes_ahead_of_the_guesses_wherever_it_was_listed() {
        compare(FL.probeOrder([guess("https://r.ee/favicon-192x192.png"), share("https://r.ee/og.jpg"),
                               guess("https://r.ee/apple-touch-icon.png")]),
                ["https://r.ee/apple-touch-icon.png", "https://r.ee/og.jpg", "https://r.ee/favicon-192x192.png"])
    }

    function test_the_stream_hosts_paths_wait_behind_everything_the_homepage_offers() {
        // Raadio Kadi through the settings page: its stream lives on a CDN
        // whose own icon, if it has one, is the CDN's.
        var edge = "https://edge06.cdn.bitflip.ee:8888"
        var cands = [page(kadiIcon), share(kadiOg)].concat(guesses("https://kadi.ee"),
            [host(edge + "/apple-touch-icon.png"), host(edge + "/favicon-192x192.png"),
             host(edge + "/favicon-32x32.png"), host(edge + "/favicon.ico")])
        compare(FL.probeOrder(cands), [
            "https://kadi.ee/apple-touch-icon.png",
            kadiOg,
            "https://kadi.ee/apple-touch-icon-precomposed.png",
            "https://kadi.ee/favicon-194x194.png",
            "https://kadi.ee/favicon-192x192.png",
            "https://kadi.ee/favicon-96x96.png",
            edge + "/apple-touch-icon.png",
            edge + "/favicon-192x192.png",
            kadiIcon,
            "https://kadi.ee/favicon-32x32.png",
            "https://kadi.ee/favicon.ico",
            edge + "/favicon-32x32.png",
            edge + "/favicon.ico"
        ])
        // Listed first, still asked after the homepage's own guesses.
        compare(FL.probeOrder([host(edge + "/favicon-192x192.png"), guess("https://kadi.ee/favicon-96x96.png")]),
                ["https://kadi.ee/favicon-96x96.png", edge + "/favicon-192x192.png"])
    }

    function test_google_is_asked_last_wherever_it_was_listed() {
        var g = "https://www.google.com/s2/favicons?domain=r.ee&sz=128"
        compare(FL.probeOrder([guess(g), guess("https://r.ee/favicon.ico"), page("https://r.ee/favicon.ico?v=2")]),
                ["https://r.ee/favicon.ico", "https://r.ee/favicon.ico?v=2", g])
    }

    function test_an_order_of_nothing_is_empty() {
        compare(FL.probeOrder([]), [])
        compare(FL.probeOrder(null), [])
        compare(FL.probeOrder(undefined), [])
        compare(FL.probeOrder([null, {}, { url: "" }, { kind: "page" }, { url: 42, kind: "page" }]), [])
        compare(FL.probeOrder([page(logo), page(logo), guess(logo)]), [logo])
    }

    function test_a_large_square_ends_the_hunt_at_once() {
        compare(FL.huntSettled([{ url: kadiOg, size: size(1200, 1200) }], 2), true)
        compare(FL.huntSettled([{ url: logo, size: size(96, 96) }], 1), true)
        compare(FL.huntSettled([{ url: logo, size: size(95, 95) }], 1), false)
        compare(FL.huntSettled([{ url: "https://r.ee/logo.svg", size: null }], 1), false)
    }

    function test_a_real_picture_in_hand_stops_the_hunt_at_the_cap() {
        var small = [{ url: kadiIcon, size: size(16, 16) }]
        compare(FL.PROBE_CAP, 6)
        compare(FL.huntSettled(small, 5), false)
        compare(FL.huntSettled(small, 6), true)
        compare(FL.huntSettled(small, 7), true)
    }

    function test_with_nothing_real_the_hunt_goes_on_to_the_limit() {
        compare(FL.PROBE_LIMIT, 12)
        compare(FL.huntSettled([], 0), false)
        compare(FL.huntSettled([], 6), false)
        compare(FL.huntSettled([], 11), false)
        compare(FL.huntSettled([], 12), true)
        compare(FL.huntSettled(null, 12), true)
        compare(FL.huntSettled(undefined, 3), false)
    }

    // ── pickHomepage: whose page a name search may send the hunt to ───────

    // Raadio Kadi's record as the directory gave it on 2026-11-02: no logo,
    // a homepage.
    readonly property var kadiRow: ({ name: "Raadio Kadi", countrycode: "EE",
        url: "https://edge06.cdn.bitflip.ee:8888/kadi", url_resolved: "https://edge06.cdn.bitflip.ee:8888/kadi",
        favicon: "", homepage: "https://kadi.ee/" })

    function test_raadio_kadi_lends_its_own_homepage() {
        compare(FL.pickFavicon([kadiRow], norm("Raadio Kadi"), norm, kadiRow.url, 30), "")
        compare(FL.pickHomepage([kadiRow], norm("Raadio Kadi"), norm, kadiRow.url, 30), "https://kadi.ee/")
    }

    function test_a_name_from_three_countries_lends_nobody_its_homepage() {
        compare(FL.pickHomepage(rock, norm("Rock FM"), norm, stranger, 30), "")
    }

    function test_the_own_record_lends_its_homepage_among_namesakes() {
        var saved = "https://flucast26-h-cloud.flumotion.com/cope/rockfm-low.mp3/"
        compare(FL.pickHomepage(rock, norm("Rock FM"), norm, saved, 30), "http://www.rockfm.fm/")
    }

    function test_a_homepage_on_a_private_host_is_lent_to_nobody() {
        var own = { name: "Kodu", countrycode: "EE", url: "http://192.168.1.10:8000/kodu", favicon: "",
                    homepage: "http://192.168.1.10/" }
        var roof = { name: "Kodu", countrycode: "EE", url: "http://192.168.1.10:8000/kodu2", favicon: "",
                     homepage: "https://kodu.example/" }
        compare(FL.pickHomepage([own], norm("Kodu"), norm, own.url, 30), "")
        compare(FL.pickHomepage([own, roof], norm("Kodu"), norm, own.url, 30), "https://kodu.example/")
        compare(FL.pickHomepage([{ name: "Kodu", url: own.url, homepage: "file:///etc/" }], norm("Kodu"), norm, own.url, 30), "")
    }

    function test_pick_homepage_answers_garbage_with_nothing() {
        compare(FL.pickHomepage(null, norm("Kadi"), norm, "", 30), "")
        compare(FL.pickHomepage([], norm("Kadi"), norm, "", 30), "")
        compare(FL.pickHomepage([kadiRow], "", norm, kadiRow.url, 30), "")
        compare(FL.pickHomepage([kadiRow], norm("Raadio Kadi"), null, kadiRow.url, 30), "")
        compare(FL.pickHomepage([null, { name: "Raadio Kadi" }], norm("Raadio Kadi"), norm, "", 0), "")
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
