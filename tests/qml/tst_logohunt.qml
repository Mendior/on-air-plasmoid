// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The logo hunt's network half against stand-in requests: which addresses
// it asks, in what order, which it never asks, and what it keeps. Every
// answer is scripted per address; anything unscripted is a 404.
import QtQuick
import QtTest
import "../../package/contents/ui"

TestCase {
    id: tc
    name: "LogoHunt"

    Component {
        id: huntComp
        LogoHunt {}
    }

    // address -> { status, text, bytes, finalUrl, loadingText, loadingBytes, hang }
    property var routes: ({})
    property var opened: []
    property var sent: []
    property var armed: []
    property int cleared: 0
    property int abortsInHandler: 0

    function fakeRequest() {
        var x = {
            readyState: 0, status: 0, responseText: "", response: null, responseURL: "",
            responseType: "", LOADING: 3, DONE: 4, url: "", headers: ({}), aborts: 0,
            inHandler: false, onreadystatechange: null,
            open: function(method, url) { x.url = url; x.readyState = 1; tc.opened.push(url); },
            setRequestHeader: function(k, v) { x.headers[k] = v; },
            send: function() { tc.sent.push(x); Qt.callLater(function() { tc.answer(x); }); },
            abort: function() {
                x.aborts++;
                if (x.inHandler) tc.abortsInHandler++;
                if (x.readyState === 4) return;
                x.readyState = 4; x.status = 0; x.responseText = ""; x.response = null;
                x.fire();
            },
            fire: function() {
                x.inHandler = true;
                try { if (x.onreadystatechange) x.onreadystatechange(); } finally { x.inHandler = false; }
            }
        };
        return x;
    }

    function answer(x) {
        if (x.readyState === 4) return;
        var r = routes[x.url] || { status: 404, text: "Not Found" };
        if (r.hang) return;
        // noResponseUrl: a Qt that does not name where its redirects ended.
        x.responseURL = r.noResponseUrl ? "" : (r.finalUrl || x.url);
        x.status = r.status;
        x.readyState = 3;
        if (r.loadingText !== undefined) {
            x.responseText = r.loadingText;
            x.fire();
        }
        if (r.loadingBytes !== undefined) {
            x.response = r.loadingBytes.buffer;
            x.fire();
        }
        if (x.readyState === 4) return;
        x.readyState = 4;
        x.responseText = r.text || "";
        x.response = r.bytes ? new Uint8Array(r.bytes).buffer : null;
        x.fire();
    }

    function make() {
        tc.opened = [];
        tc.sent = [];
        tc.armed = [];
        tc.cleared = 0;
        tc.abortsInHandler = 0;
        var app = {
            _armXhrTimeout: function(xhr, ms) { var t = { xhr: xhr, ms: ms }; tc.armed.push(t); return t; },
            _clearXhrTimeout: function(t) { if (t) tc.cleared++; }
        };
        return huntComp.createObject(tc, { app: app, makeRequest: function() { return tc.fakeRequest(); } });
    }

    function huntFor(homepage) {
        var h = make();
        var out = { done: false, url: undefined, calls: 0 };
        h.huntHomepage(homepage, function(u) { out.done = true; out.url = u; out.calls++; });
        tryVerify(function() { return out.done; }, 5000);
        wait(20);
        h.destroy();
        return out;
    }

    function probeWith(cands) {
        var h = make();
        var out = { done: false, best: undefined };
        h.probe(cands, function(b) { out.done = true; out.best = b; });
        tryVerify(function() { return out.done; }, 5000);
        h.destroy();
        return out.best;
    }

    // ── fixtures ──────────────────────────────────────────────────────────

    function be16(n) { return [(n >>> 8) & 255, n & 255] }
    function be32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255] }
    function png(w, h) {
        return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
            .concat(be32(w), be32(h), [8, 6, 0, 0, 0, 0, 0, 0, 0])
    }
    // SOI, then a progressive frame header like Kadi's logo-og-1.jpg.
    function jpeg(w, h) {
        return [0xFF, 0xD8, 0xFF, 0xC2, 0x00, 0x11, 0x08].concat(be16(h), be16(w),
                                                                 [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
    }
    // An ICO with one 16x16 entry, as Kadi's favicon.ico.
    function ico16() {
        return [0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0, 0x68, 5, 0, 0, 22, 0, 0, 0, 0, 0]
    }
    function htmlWith(head) {
        return "<!DOCTYPE html>\n<html lang=\"et\"><head><meta charset=\"UTF-8\">\n" + head
            + "\n<title>Raadio Kadi</title></head><body><p>Raadio Kadi, the station's own page, long"
            + " enough to read as one.</p></body></html>"
    }

    readonly property string kadiPage: "https://kadi.ee/"
    readonly property string kadiIcon: "https://kadi.ee/wp-content/themes/raadio/img/favicon.ico"
    readonly property string kadiOg: "https://kadi.ee/wp-content/uploads/2022/01/logo-og-1.jpg"

    // Raadio Kadi as it answered on 2026-11-02: the shortcut icon is a 16x16
    // ICO, the og:image a 1200x1200 JPEG that is the logo, and
    // /apple-touch-icon.png a 404.
    function kadiRoutes() {
        var r = {};
        r[kadiPage] = { status: 200, text: htmlWith(
            '<link rel="shortcut icon" href="' + kadiIcon + '">\n'
            + '<meta property="og:image" content="' + kadiOg + '" />\n'
            + '<meta property="og:image:width" content="1200" />') };
        r[kadiIcon] = { status: 200, bytes: ico16() };
        r[kadiOg] = { status: 200, bytes: jpeg(1200, 1200) };
        return r;
    }

    // ── what it asks and keeps ────────────────────────────────────────────

    function test_raadio_kadi_gets_its_og_image_not_its_favicon() {
        tc.routes = kadiRoutes();
        var out = huntFor(kadiPage);
        compare(out.url, kadiOg);
        compare(out.calls, 1);
        // The page, Apple's path (404), the logo. The 16 px icon is never
        // fetched once a large square is in hand.
        compare(tc.opened, [kadiPage, "https://kadi.ee/apple-touch-icon.png", kadiOg]);
    }

    function test_the_page_and_the_pictures_are_asked_as_the_settings_page_asks() {
        tc.routes = kadiRoutes();
        huntFor(kadiPage);
        compare(tc.sent.length, 3);
        verify(/^Mozilla\/5\.0 \(compatible; OnAir\/\d{4}\.\d+\)$/.test(tc.sent[0].headers["User-Agent"]),
               tc.sent[0].headers["User-Agent"]);
        compare(tc.sent[0].headers["Accept"], "text/html,application/xhtml+xml,*/*");
        for (var i = 1; i < tc.sent.length; i++) {
            verify(/^OnAir\/\d{4}\.\d+$/.test(tc.sent[i].headers["User-Agent"]), tc.sent[i].headers["User-Agent"]);
            compare(tc.sent[i].responseType, "arraybuffer");
        }
    }

    function test_every_request_has_its_timer_and_lets_go_of_it() {
        tc.routes = kadiRoutes();
        var h = make();
        compare(h.pageTimeoutMs, 12000);
        compare(h.probeTimeoutMs, 6000);
        h.destroy();
        huntFor(kadiPage);
        compare(tc.sent.length, 3);
        compare(tc.armed.length, tc.sent.length);
        compare(tc.armed[0].ms, 12000);
        for (var i = 1; i < tc.armed.length; i++) compare(tc.armed[i].ms, 6000);
        compare(tc.cleared, tc.sent.length);
    }

    function test_a_page_that_names_nothing_still_gets_its_well_known_paths() {
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith("<meta name=\"x\" content=\"y\">") };
        r["https://r.example/favicon-192x192.png"] = { status: 200, bytes: png(192, 192) };
        tc.routes = r;
        var out = huntFor("https://r.example/");
        compare(out.url, "https://r.example/favicon-192x192.png");
        compare(tc.opened, ["https://r.example/", "https://r.example/apple-touch-icon.png",
                            "https://r.example/apple-touch-icon-precomposed.png",
                            "https://r.example/favicon-194x194.png", "https://r.example/favicon-192x192.png"]);
    }

    function test_a_landlords_page_lends_only_the_stations_own_picture() {
        var page = "https://laut.fm/mangoradio", og = "https://assets.laut.fm/abc?t=_640x640"
        var r = {}
        r[page] = { status: 200, text: htmlWith(
            '<link rel="apple-touch-icon" sizes="180x180" href="/assets/images/touch-icons/apple-touch-icon.png">'
            + '<meta property="og:image" content="' + og + '">') }
        r["https://laut.fm/assets/images/touch-icons/apple-touch-icon.png"] = { status: 200, bytes: png(180, 180) }
        r[og] = { status: 200, bytes: jpeg(640, 640) }
        tc.routes = r
        compare(huntFor(page).url, og)
        compare(tc.opened, [page, og], "the landlord's own icons were asked")
    }

    function test_a_homepage_that_forwards_to_a_landlord_is_read_as_the_landlords() {
        var page = "https://station.example/", landed = "https://laut.fm/station"
        var og = "https://assets.laut.fm/def?t=_640x640"
        var r = {}
        r[page] = { status: 200, finalUrl: landed, text: htmlWith(
            '<link rel="apple-touch-icon" sizes="180x180" href="/assets/images/touch-icons/apple-touch-icon.png">'
            + '<meta property="og:image" content="' + og + '">') }
        r["https://laut.fm/assets/images/touch-icons/apple-touch-icon.png"] = { status: 200, bytes: png(180, 180) }
        r[og] = { status: 200, bytes: jpeg(640, 640) }
        tc.routes = r
        compare(huntFor(page).url, og)
        compare(tc.opened, [page, og], "the landlord's own icons were asked")
    }

    function test_a_bare_favicon_is_taken_when_it_is_more_than_a_tab_icon() {
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith("") };
        r["https://r.example/favicon.ico"] = { status: 200, bytes: ico16() };
        tc.routes = r;
        // A 16 px icon blown up in the list reads as a broken logo, and saved
        // it would stand for good: the station keeps its initials instead.
        var out = huntFor("https://r.example/");
        compare(out.url, "");
        compare(tc.opened.length, 8);
        var ico64 = ico16();
        ico64[6] = 64; ico64[7] = 64;
        r["https://r.example/favicon.ico"] = { status: 200, bytes: ico64 };
        tc.routes = r;
        compare(huntFor("https://r.example/").url, "https://r.example/favicon.ico");
    }

    function test_a_hunt_nobody_clicked_trusts_no_answer_whose_end_is_unnamed() {
        // Qt names where its own redirects ended in responseURL (measured on
        // 6.12). An answer without it cannot be shown to come from a public
        // host, and the popup's hunt runs with no click at all.
        var r = kadiRoutes();
        r[kadiPage].noResponseUrl = true;
        tc.routes = r;
        compare(huntFor(kadiPage).url, "", "the page is read anyway");
        r = kadiRoutes();
        r[kadiOg].noResponseUrl = true;
        tc.routes = r;
        compare(huntFor(kadiPage).url, "", "the picture is kept anyway");
    }

    function test_the_settings_button_still_takes_an_answer_whose_end_is_unnamed() {
        var r = kadiRoutes();
        r[kadiOg].noResponseUrl = true;
        tc.routes = r;
        var best = probeWith([{ url: kadiOg, kind: "og" }]);
        verify(best !== null);
        compare(best.url, kadiOg);
    }

    function test_a_page_naming_forty_icons_is_asked_six_or_twelve_times() {
        var head = "", r = {}, i = 0;
        for (i = 0; i < 40; i++) head += '<link rel="icon" href="/i' + i + '.png">';
        r["https://r.example/"] = { status: 200, text: htmlWith(head) };
        for (i = 0; i < 40; i++) r["https://r.example/i" + i + ".png"] = { status: 200, bytes: png(16, 16) };
        tc.routes = r;
        var out = huntFor("https://r.example/");
        compare(tc.opened.length, 1 + 6);
        compare(out.url, "", "forty tab icons are still no logo");
        // None of them real: the old walk's way, to the limit.
        r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith(head) };
        tc.routes = r;
        out = huntFor("https://r.example/");
        compare(tc.opened.length, 1 + 12);
        compare(out.url, "");
    }

    function test_the_best_of_what_answered_is_kept_not_the_first() {
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith(
            '<link rel="icon" href="/small.png"><link rel="icon" href="/banner.jpg">'
            + '<link rel="icon" href="/mid.png">') };
        r["https://r.example/small.png"] = { status: 200, bytes: png(24, 24) };
        r["https://r.example/banner.jpg"] = { status: 200, bytes: jpeg(1200, 630) };
        r["https://r.example/mid.png"] = { status: 200, bytes: png(64, 64) };
        tc.routes = r;
        compare(huntFor("https://r.example/").url, "https://r.example/mid.png");
        // Six were asked: three that answered and three guesses that did not.
        compare(tc.opened.length, 1 + 6);
    }

    // ── what it never asks ────────────────────────────────────────────────

    function test_a_homepage_on_a_private_host_is_never_fetched() {
        var spellings = ["http://192.168.1.1/", "http://10.0.0.5:8080/", "http://127.0.0.1/",
                         "http://localhost/", "http://[::1]/", "http://2130706433/",
                         "http://100.64.0.7/", "http://%31%32%37.0.0.1/", "file:///etc/passwd", ""];
        for (var i = 0; i < spellings.length; i++) {
            tc.routes = {};
            var out = huntFor(spellings[i]);
            compare(out.url, "", spellings[i]);
            compare(tc.opened, [], spellings[i]);
        }
    }

    function test_a_page_redirected_into_the_lan_offers_nothing() {
        var r = {};
        r["https://r.example/"] = { status: 200, finalUrl: "http://192.168.1.1/admin",
                                    text: htmlWith('<link rel="icon" href="https://cdn.example/logo.png">') };
        r["https://cdn.example/logo.png"] = { status: 200, bytes: png(512, 512) };
        tc.routes = r;
        var out = huntFor("https://r.example/");
        compare(out.url, "");
        // The internal page's links were never read; only the public
        // origin's own well-known paths were asked.
        verify(tc.opened.indexOf("https://cdn.example/logo.png") === -1);
        for (var i = 1; i < tc.opened.length; i++)
            compare(tc.opened[i].indexOf("https://r.example/"), 0);
    }

    function test_an_icon_the_page_names_on_a_private_host_is_never_fetched() {
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith(
            '<link rel="icon" href="http://10.0.0.5/logo.png"><link rel="icon" href="http://localhost:631/x.png">') };
        tc.routes = r;
        huntFor("https://r.example/");
        verify(tc.opened.indexOf("http://10.0.0.5/logo.png") === -1);
        verify(tc.opened.indexOf("http://localhost:631/x.png") === -1);
    }

    function test_a_page_served_where_a_picture_was_asked_is_not_kept() {
        // The soft 404: a well-known path answered 200 with the site's
        // own error page.
        var html = htmlWith(""), a = [];
        for (var i = 0; i < html.length; i++) a.push(html.charCodeAt(i));
        var r = {};
        r["https://r.example/"] = { status: 200, text: html };
        r["https://r.example/apple-touch-icon.png"] = { status: 200, bytes: a };
        tc.routes = r;
        compare(huntFor("https://r.example/").url, "");
    }

    function test_a_picture_sent_with_an_error_status_is_not_kept() {
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith('<link rel="icon" href="/logo.png">') };
        r["https://r.example/logo.png"] = { status: 404, bytes: png(512, 512) };
        tc.routes = r;
        compare(huntFor("https://r.example/").url, "");
    }

    function test_a_picture_redirected_into_the_lan_is_not_kept() {
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith('<link rel="icon" href="/logo.png">') };
        r["https://r.example/logo.png"] = { status: 200, finalUrl: "http://192.168.1.1/cam.jpg",
                                            bytes: jpeg(640, 640) };
        tc.routes = r;
        compare(huntFor("https://r.example/").url, "");
    }

    // The settings page passes the same list through probe(), stream host
    // paths included, so a station streaming from the listener's own LAN
    // is not asked either.
    function test_the_settings_button_keeps_a_logo_only_a_dead_one_gives_way() {
        var own = "https://r.example/press/logo-1024.png", small = "https://r.example/favicon-32x32.png"
        var r = {}
        r[own] = { status: 200, bytes: png(1024, 1024) }
        r[small] = { status: 200, bytes: png(32, 32) }
        tc.routes = r
        compare(probeWith([{ url: own, kind: "current" }, { url: small, kind: "page" }]).url, own)
        r[own] = { status: 404, text: "gone" }
        tc.routes = r
        compare(probeWith([{ url: own, kind: "current" }, { url: small, kind: "page" }]).url, small)
    }

    function test_a_candidate_on_a_private_host_is_never_asked_by_either_road() {
        var r = {};
        r["https://cdn.example/logo.png"] = { status: 200, bytes: png(256, 256) };
        tc.routes = r;
        var lan = ["http://192.168.1.10:8000/favicon.ico", "http://192.168.1.10:8000/apple-touch-icon.png",
                   "http://10.0.0.5/logo.png", "http://127.0.0.1:631/x.png", "http://localhost/x.png",
                   "http://[::1]/x.png", "http://[fe80::1]/x.png", "http://0177.0.0.1/x.png",
                   "http://100.64.0.7/x.png", "http://169.254.169.254/latest/x.png"];
        var cands = lan.map(function(u) { return { url: u, kind: "page" }; });
        var best = probeWith(cands.concat([{ url: "https://cdn.example/logo.png", kind: "page" }]));
        verify(best !== null, "the public candidate was asked");
        compare(best.url, "https://cdn.example/logo.png");
        compare(best.size, { width: 256, height: 256 });
        compare(tc.opened, ["https://cdn.example/logo.png"]);
    }

    // ── what it cuts off ──────────────────────────────────────────────────

    function test_a_page_that_never_ends_is_cut_and_its_head_still_read() {
        var head = '<link rel="apple-touch-icon" href="/apple-touch-icon-180.png">';
        var body = htmlWith(head);
        while (body.length <= 524288) body += "<p>" + "x".repeat(4000) + "</p>";
        var r = {};
        r["https://r.example/"] = { status: 200, loadingText: body, text: body + "<p>more</p>" };
        r["https://r.example/apple-touch-icon-180.png"] = { status: 200, bytes: png(180, 180) };
        tc.routes = r;
        var out = huntFor("https://r.example/");
        compare(out.url, "https://r.example/apple-touch-icon-180.png");
        compare(tc.sent[0].aborts, 1);
        compare(tc.abortsInHandler, 0);
    }

    function test_a_picture_that_never_ends_is_no_logo() {
        var big = new Uint8Array(524289);
        var head = png(512, 512);
        for (var i = 0; i < head.length; i++) big[i] = head[i];
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith('<link rel="icon" href="/huge.png">') };
        r["https://r.example/huge.png"] = { status: 200, loadingBytes: big, bytes: head };
        tc.routes = r;
        var out = huntFor("https://r.example/");
        compare(out.url, "");
        var huge = tc.sent.filter(function(x) { return x.url === "https://r.example/huge.png"; });
        compare(huge.length, 1);
        compare(huge[0].aborts, 1);
        compare(tc.abortsInHandler, 0);
    }

    function test_a_whole_answer_over_the_cap_is_no_logo_either() {
        var big = png(512, 512);
        while (big.length <= 524288) big = big.concat(new Array(65536).fill(0));
        var r = {};
        r["https://r.example/"] = { status: 200, text: htmlWith('<link rel="icon" href="/huge.png">') };
        r["https://r.example/huge.png"] = { status: 200, bytes: big };
        tc.routes = r;
        compare(huntFor("https://r.example/").url, "");
    }

    function test_a_silent_host_is_given_up_on_by_its_timer() {
        var r = {};
        r["https://r.example/"] = { hang: true };
        r["https://r.example/apple-touch-icon.png"] = { status: 200, bytes: png(180, 180) };
        tc.routes = r;
        var h = make();
        var out = { done: false, url: undefined };
        h.huntHomepage("https://r.example/", function(u) { out.done = true; out.url = u; });
        tryVerify(function() { return tc.armed.length === 1; }, 2000);
        wait(50);
        verify(!out.done);
        // What the real timer does when it fires.
        tc.armed[0].xhr.abort();
        tryVerify(function() { return out.done; }, 5000);
        compare(out.url, "https://r.example/apple-touch-icon.png");
        compare(tc.abortsInHandler, 0);
        h.destroy();
    }

    function test_a_request_that_cannot_even_be_opened_ends_the_hunt_cleanly() {
        var h = make();
        h.makeRequest = function() {
            var x = tc.fakeRequest();
            x.open = function() { throw new Error("bad url"); };
            return x;
        };
        var out = { done: false, url: undefined };
        h.huntHomepage("https://r.example/", function(u) { out.done = true; out.url = u; });
        tryVerify(function() { return out.done; }, 5000);
        compare(out.url, "");
        h.destroy();
    }

    function test_nothing_to_ask_is_answered_with_nothing() {
        compare(probeWith([]), null);
        compare(probeWith(null), null);
        compare(tc.opened, []);
    }
}
