// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The hunt for a mount that moved to another server of its own CDN, against
// stand-in requests: which addresses it asks, in what order, which it never
// asks, and which answer it takes. The addresses and answers are the ones
// measured on 2026-11-10, when five Sky Media mounts had left their edges.
// Anything unscripted is a 404 page.
import QtQuick
import QtTest
import "../../package/contents/ui"

TestCase {
    id: tc
    name: "KinHunt"

    Component {
        id: huntComp
        KinHunt {}
    }

    // address -> { status, type, finalUrl, noResponseUrl, hang }
    property var routes: ({})
    property var opened: []
    property var sent: []
    property var armed: []
    property int cleared: 0
    property int abortsInHandler: 0

    readonly property string saved: "https://edge02.cdn.bitflip.ee:8888/RETRO?_i=258f436b"

    function fakeRequest() {
        var x = {
            readyState: 0, status: 0, responseURL: "", HEADERS_RECEIVED: 2, LOADING: 3, DONE: 4,
            url: "", headers: ({}), type: "", aborts: 0, inHandler: false, onreadystatechange: null,
            open: function(method, url) { x.url = url; x.readyState = 1; tc.opened.push(url); },
            setRequestHeader: function(k, v) { x.headers[k] = v; },
            getResponseHeader: function(k) { return k === "Content-Type" ? x.type : ""; },
            send: function() { tc.sent.push(x); Qt.callLater(function() { tc.answer(x); }); },
            abort: function() {
                x.aborts++;
                if (x.inHandler) tc.abortsInHandler++;
                if (x.readyState === 4) return;
                // As Qt does it: the status goes, the address it ended on stays.
                x.readyState = 4; x.status = 0;
                x.fire();
            },
            fire: function() {
                x.inHandler = true;
                try { if (x.onreadystatechange) x.onreadystatechange(); } finally { x.inHandler = false; }
            }
        };
        return x;
    }

    // A stream never ends by itself: the answer stops at its headers and
    // only the hunt's own abort brings the request to DONE.
    function answer(x) {
        if (x.readyState === 4) return;
        var r = routes[x.url] || { status: 404, type: "text/html" };
        if (r.hang) return;
        x.status = r.status;
        x.type = r.type || "";
        x.readyState = 2;
        x.fire();
        // Qt 6.12 names the last hop only after the headers.
        x.responseURL = r.noResponseUrl ? "" : (r.finalUrl || x.url);
    }

    function make() {
        tc.routes = ({});
        tc.opened = [];
        tc.sent = [];
        tc.armed = [];
        tc.cleared = 0;
        tc.abortsInHandler = 0;
        var app = {
            _armXhrTimeout: function(xhr, ms) { tc.armed.push({ xhr: xhr, ms: ms }); return tc.armed.length; },
            _clearXhrTimeout: function(t) { tc.cleared++; }
        };
        return createTemporaryObject(huntComp, tc, { app: app, makeRequest: tc.fakeRequest });
    }

    function found(h, leads) {
        var out = { done: false, url: null, calls: 0 };
        h.find(tc.saved, leads, function(u) { out.done = true; out.url = u; out.calls++; });
        tryCompare(out, "done", true, 2000);
        wait(20);
        return out;
    }

    function test_a_door_of_the_stations_own_domain_finds_the_moved_mount() {
        var h = make();
        tc.routes["https://skymedia-live.bitflip.ee/RETRO"] = {
            status: 200, type: "audio/mpeg", finalUrl: "https://edge43.cdn.bitflip.ee:8888/RETRO?_i=77" };
        var r = found(h, ["https://skymedia-live.bitflip.ee/SKYPLUS"]);
        // The door is what gets saved: it is on the station's own domain,
        // and it will still be right when edge43 is gone too.
        compare(r.url, "https://skymedia-live.bitflip.ee/RETRO");
        compare(tc.opened, ["https://skymedia-live.bitflip.ee/RETRO"]);
        compare(tc.sent[0].headers["User-Agent"], "OnAir/2026.44");
        compare(r.calls, 1);
    }

    function test_a_strangers_door_only_names_a_living_relative() {
        var h = make();
        tc.routes["https://stream.skymedia.ee/live/RETRO_AAC"] = {
            status: 200, type: "audio/aac", finalUrl: "https://edge43.cdn.bitflip.ee:8888/RETRO_AAC?_i=5" };
        tc.routes["https://edge43.cdn.bitflip.ee:8888/RETRO"] = { status: 200, type: "audio/mpeg" };
        var r = found(h, ["https://edge06.cdn.bitflip.ee:8888/kadi",
                          "https://stream.skymedia.ee/live/RETRO_AAC"]);
        // Never the door on the other domain, and never its 88 kb/s mount.
        compare(r.url, "https://edge43.cdn.bitflip.ee:8888/RETRO");
        compare(tc.opened, ["https://edge06.cdn.bitflip.ee:8888/RETRO",
                            "https://stream.skymedia.ee/live/RETRO_AAC",
                            "https://edge43.cdn.bitflip.ee:8888/RETRO"]);
    }

    function test_nothing_found_says_so_after_asking_everyone_once() {
        var h = make();
        var r = found(h, ["https://edge06.cdn.bitflip.ee:8888/kadi",
                          "https://edge01.cdn.bitflip.ee:8888/NRJ",
                          "https://edge06.cdn.bitflip.ee:8888/other",
                          "https://door.example/x"]);
        compare(r.url, "");
        compare(tc.opened, ["https://edge06.cdn.bitflip.ee:8888/RETRO",
                            "https://edge01.cdn.bitflip.ee:8888/RETRO",
                            "https://door.example/x"]);
        compare(r.calls, 1);
    }

    function test_an_error_page_behind_a_polite_status_is_not_the_station() {
        var h = make();
        tc.routes["https://skymedia-live.bitflip.ee/RETRO"] = {
            status: 200, type: "text/html; charset=utf-8",
            finalUrl: "https://edge43.cdn.bitflip.ee:8888/RETRO" };
        compare(found(h, ["https://skymedia-live.bitflip.ee/SKYPLUS"]).url, "");
    }

    function test_a_door_that_lands_on_another_mount_is_not_the_station() {
        var h = make();
        tc.routes["https://skymedia-live.bitflip.ee/RETRO"] = {
            status: 200, type: "audio/mpeg", finalUrl: "https://edge43.cdn.bitflip.ee:8888/SKYPLUS" };
        compare(found(h, ["https://skymedia-live.bitflip.ee/SKYPLUS"]).url, "");
    }

    function test_an_answer_qt_cannot_place_is_no_answer() {
        // An older Qt leaves responseURL empty; the hunt then proves nothing
        // and finds nothing, which is the safe way to be wrong.
        var h = make();
        tc.routes["https://skymedia-live.bitflip.ee/RETRO"] = {
            status: 200, type: "audio/mpeg", noResponseUrl: true };
        tc.routes["https://edge43.cdn.bitflip.ee:8888/RETRO"] = {
            status: 200, type: "audio/mpeg", noResponseUrl: true };
        compare(found(h, ["https://skymedia-live.bitflip.ee/SKYPLUS",
                          "https://edge43.cdn.bitflip.ee:8888/x"]).url, "");
    }

    function test_a_door_that_leads_into_the_house_is_dropped() {
        var h = make();
        tc.routes["https://door.example/x"] = {
            status: 200, type: "audio/mpeg", finalUrl: "http://192.168.1.10:8888/RETRO" };
        var r = found(h, ["https://door.example/x", "http://192.168.1.5:8888/y", "http://localhost/z"]);
        compare(r.url, "");
        // The private leads were never asked at all.
        compare(tc.opened, ["https://door.example/x"]);
    }

    function test_a_host_that_does_not_answer_costs_one_timer_and_the_hunt_goes_on() {
        var h = make();
        tc.routes["https://edge06.cdn.bitflip.ee:8888/RETRO"] = { hang: true };
        tc.routes["https://edge43.cdn.bitflip.ee:8888/RETRO"] = { status: 200, type: "audio/mpeg" };
        var out = { done: false, url: null };
        h.find(tc.saved, ["https://edge06.cdn.bitflip.ee:8888/kadi", "https://edge43.cdn.bitflip.ee:8888/x"],
               function(u) { out.done = true; out.url = u; });
        tryVerify(function() { return tc.armed.length === 1; }, 1000);
        compare(tc.armed[0].ms, h.probeTimeoutMs);
        wait(30);
        verify(!out.done);
        // main.qml's timer aborts from outside the handler, as this does.
        tc.armed[0].xhr.abort();
        tryCompare(out, "done", true, 2000);
        compare(out.url, "https://edge43.cdn.bitflip.ee:8888/RETRO");
    }

    function test_a_newer_hunt_silences_the_older_one() {
        var h = make();
        tc.routes["https://skymedia-live.bitflip.ee/RETRO"] = {
            status: 200, type: "audio/mpeg", finalUrl: "https://edge43.cdn.bitflip.ee:8888/RETRO" };
        var first = 0, second = { done: false, url: null };
        h.find(tc.saved, ["https://skymedia-live.bitflip.ee/SKYPLUS"], function(u) { first++; });
        h.find(tc.saved, ["https://skymedia-live.bitflip.ee/SKYPLUS"],
               function(u) { second.done = true; second.url = u; });
        tryCompare(second, "done", true, 2000);
        wait(30);
        compare(first, 0);
        compare(second.url, "https://skymedia-live.bitflip.ee/RETRO");
        // cancel() does the same without a successor.
        var third = 0;
        h.find(tc.saved, ["https://skymedia-live.bitflip.ee/SKYPLUS"], function(u) { third++; });
        h.cancel();
        wait(60);
        compare(third, 0);
    }

    function test_a_mount_with_no_name_of_its_own_asks_nobody() {
        var h = make();
        var out = { done: false, url: null };
        h.find("http://a.example:8000/stream", ["http://b.example:8000/x", "http://door.other/y"],
               function(u) { out.done = true; out.url = u; });
        tryCompare(out, "done", true, 2000);
        compare(out.url, "");
        compare(tc.opened.length, 0);
    }

    function test_no_request_is_aborted_from_inside_its_own_handler() {
        var h = make();
        tc.routes["https://skymedia-live.bitflip.ee/RETRO"] = {
            status: 200, type: "audio/mpeg", finalUrl: "https://edge43.cdn.bitflip.ee:8888/RETRO" };
        found(h, ["https://edge06.cdn.bitflip.ee:8888/kadi", "https://skymedia-live.bitflip.ee/SKYPLUS",
                  "https://door.example/x"]);
        verify(tc.sent.length >= 2);
        compare(tc.abortsInHandler, 0);
        for (var i = 0; i < tc.sent.length; i++)
            compare(tc.sent[i].aborts, 1);
    }

    function test_one_question_reports_what_it_saw() {
        var h = make();
        tc.routes["https://edge02.cdn.bitflip.ee:8888/RETRO"] = { status: 404, type: "text/html" };
        var got = null;
        h.probe("https://edge02.cdn.bitflip.ee:8888/RETRO", function(s, t, l) { got = [s, t, l]; });
        tryVerify(function() { return got !== null; }, 1000);
        compare(got, [404, "text/html", "https://edge02.cdn.bitflip.ee:8888/RETRO"]);
        got = null;
        h.probe("http://192.168.1.1/x", function(s, t, l) { got = [s, t, l]; });
        tryVerify(function() { return got !== null; }, 1000);
        compare(got, [0, "", ""]);
        got = null;
        h.probe("file:///etc/passwd", function(s, t, l) { got = [s, t, l]; });
        tryVerify(function() { return got !== null; }, 1000);
        compare(got, [0, "", ""]);
        // Refused before anything left the machine, not after the answer.
        compare(tc.opened, ["https://edge02.cdn.bitflip.ee:8888/RETRO"]);
    }

    function test_an_answer_with_no_place_is_told_apart_from_no_answer() {
        // Both used to come back as 0. The second look counts silence and
        // must never count this one.
        var h = make();
        tc.routes["https://edge02.cdn.bitflip.ee:8888/RETRO"] = { status: 404, type: "text/html", noResponseUrl: true };
        tc.routes["https://door.example/x"] = { status: 200, type: "audio/mpeg", finalUrl: "http://192.168.1.10/x" };
        tc.routes["https://gone.example/x"] = { hang: true };
        var got = null;
        h.probe("https://edge02.cdn.bitflip.ee:8888/RETRO", function(s, t, l) { got = [s, t, l]; });
        tryVerify(function() { return got !== null; }, 1000);
        compare(got, [-1, "", ""]);
        got = null;
        h.probe("https://door.example/x", function(s, t, l) { got = [s, t, l]; });
        tryVerify(function() { return got !== null; }, 1000);
        compare(got, [-1, "", ""]);
        got = null;
        h.probe("https://gone.example/x", function(s, t, l) { got = [s, t, l]; });
        // The third request of this test, and the only one left waiting.
        tryVerify(function() { return tc.armed.length === 3; }, 1000);
        tc.armed[2].xhr.abort();
        tryVerify(function() { return got !== null; }, 1000);
        compare(got, [0, "", ""]);
    }

    // The verdicts of looks at one move, one after another.
    function looked(h, move, times) {
        var said = [];
        for (var i = 0; i < times; i++) {
            var before = said.length;
            h.proof(move, function(v) { said.push(v); });
            if (tc.routes[move.oldUrl] && tc.routes[move.oldUrl].hang) {
                tryVerify(function() { return tc.armed.length === i + 1; }, 1000);
                tc.armed[i].xhr.abort();
            }
            tryVerify(function() { return said.length === before + 1; }, 1000);
        }
        return said;
    }

    // The verdicts of looks at one move whose old address answers
    // differently each time: a route per look, in order.
    function lookedThrough(h, move, answers) {
        var said = [];
        for (var i = 0; i < answers.length; i++) {
            var before = said.length, timers = tc.armed.length;
            tc.routes[move.oldUrl] = answers[i];
            h.proof(move, function(v) { said.push(v); });
            tryVerify(function() { return tc.armed.length === timers + 1; }, 1000);
            if (answers[i].hang) tc.armed[timers].xhr.abort();
            tryVerify(function() { return said.length === before + 1; }, 1000);
        }
        return said;
    }

    function test_only_silence_in_a_row_counts_as_silence() {
        // Three looks were enough whatever the first two had been: busy,
        // then rate-limited, then one timeout, and the station was moved on
        // the strength of a single unanswered look.
        var gone = { hang: true }, busy = { status: 503, type: "text/html" }, limited = { status: 429, type: "" };
        var h = make();
        var move = { oldUrl: "https://edge02.cdn.bitflip.ee:8888/RETRO" };
        compare(lookedThrough(h, move, [busy, limited, gone]), ["again", "again", "again"]);
        // Two more unanswered looks after that one make three in a row.
        compare(lookedThrough(h, move, [gone, gone]), ["again", "move"]);
    }

    function test_an_answer_between_two_silences_starts_the_count_again() {
        var gone = { hang: true }, busy = { status: 503, type: "text/html" };
        var h = make();
        var move = { oldUrl: "https://edge02.cdn.bitflip.ee:8888/RETRO" };
        compare(lookedThrough(h, move, [gone, gone, busy, gone, gone]), ["again", "again", "again", "again", "again"]);
        compare(lookedThrough(h, move, [gone]), ["move"]);
    }

    function test_an_answer_with_no_place_does_not_count_towards_silence() {
        // On a Qt that names no last hop a living stream gives these, and
        // one timeout after two of them moved the station.
        var gone = { hang: true }, unplaced = { status: 200, type: "audio/mpeg", noResponseUrl: true };
        var h = make();
        var move = { oldUrl: "https://edge02.cdn.bitflip.ee:8888/RETRO" };
        compare(lookedThrough(h, move, [unplaced, unplaced, gone]), ["again", "again", "again"]);
    }

    function test_the_second_look_moves_at_once_what_the_server_calls_gone() {
        var h = make();
        var move = { oldUrl: "https://edge02.cdn.bitflip.ee:8888/RETRO" };
        tc.routes[move.oldUrl] = { status: 404, type: "text/html" };
        compare(looked(h, move, 1), ["move"]);
        // The server spoke: that is its word, not a silence to count.
        compare(move.silent, 0);
    }

    function test_the_second_look_keeps_an_address_that_plays_again() {
        var h = make();
        var move = { oldUrl: "https://edge02.cdn.bitflip.ee:8888/RETRO" };
        tc.routes[move.oldUrl] = { status: 200, type: "audio/mpeg" };
        compare(looked(h, move, 1), ["keep"]);
    }

    function test_a_silent_address_is_looked_at_three_times_before_it_moves() {
        var h = make();
        var move = { oldUrl: "https://edge02.cdn.bitflip.ee:8888/RETRO" };
        tc.routes[move.oldUrl] = { hang: true };
        compare(looked(h, move, 3), ["again", "again", "move"]);
        // Another move starts its own count.
        var other = { oldUrl: move.oldUrl };
        var h2 = make();
        tc.routes[other.oldUrl] = { hang: true };
        compare(looked(h2, other, 1), ["again"]);
    }

    function test_an_answer_with_no_place_never_becomes_a_move() {
        var h = make();
        var move = { oldUrl: "https://edge02.cdn.bitflip.ee:8888/RETRO" };
        tc.routes[move.oldUrl] = { status: 200, type: "audio/mpeg", noResponseUrl: true };
        compare(looked(h, move, 5), ["again", "again", "again", "again", "again"]);
    }

    function test_a_door_landing_on_a_server_already_asked_asks_it_no_second_time() {
        var h = make();
        tc.routes["https://stream.skymedia.ee/live/RETRO_AAC"] = {
            status: 200, type: "audio/aac", finalUrl: "https://edge43.cdn.bitflip.ee:8888/RETRO_AAC" };
        var r = found(h, ["https://edge43.cdn.bitflip.ee:8888/x", "https://stream.skymedia.ee/live/RETRO_AAC"]);
        compare(r.url, "");
        compare(tc.opened, ["https://edge43.cdn.bitflip.ee:8888/RETRO",
                            "https://stream.skymedia.ee/live/RETRO_AAC"]);
    }

    // --- both passes of the rung ---------------------------------------------

    function searched(h, o) {
        var out = { done: false, url: null, calls: 0, asked: [] };
        o.saved = o.saved || tc.saved;
        o.ask = function(path, onRows) {
            out.asked.push(path);
            Qt.callLater(function() { onRows(o.answer || []); });
        };
        h.search(o, function(u) { out.done = true; out.url = u; out.calls++; });
        tryCompare(out, "done", true, 2000);
        wait(20);
        return out;
    }

    function test_a_relative_in_the_listeners_own_list_spares_the_directory() {
        var h = make();
        tc.routes["https://skymedia-live.bitflip.ee/RETRO"] = {
            status: 200, type: "audio/mpeg", finalUrl: "https://edge43.cdn.bitflip.ee:8888/RETRO" };
        var r = searched(h, { name: "Retro FM Estonia", cc: "EE", wide: true, rows: [],
                              own: [{ hostname: "https://skymedia-live.bitflip.ee/SKYPLUS" },
                                    { hostname: "https://ice.leviracloud.eu/star320-mp3" }] });
        compare(r.url, "https://skymedia-live.bitflip.ee/RETRO");
        compare(r.asked.length, 0);
    }

    function test_an_empty_ladder_asks_the_directory_once_for_the_family() {
        var h = make();
        tc.routes["https://stream.relaxfm.ee/relax"] = {
            status: 200, type: "audio/aac", finalUrl: "https://edge43.cdn.bitflip.ee:8888/relax?_i=4" };
        tc.routes["https://edge43.cdn.bitflip.ee:8888/international"] = { status: 200, type: "audio/aac" };
        var r = searched(h, { saved: "https://edge03.cdn.bitflip.ee:8888/international?_i=a237b49c",
                              name: "Raadio Relax International", cc: "ee", wide: true, own: [], rows: [],
                              answer: [{ name: "Relax FM Eesti", url: "https://stream.relaxfm.ee/relax",
                                         url_resolved: "https://stream.relaxfm.ee/relax" }] });
        compare(r.asked, ["/json/stations/search?name=relax&countrycode=EE&hidebroken=true&order=votes&reverse=true&limit=30"]);
        compare(r.url, "https://edge43.cdn.bitflip.ee:8888/international");
        compare(r.calls, 1);
    }

    function test_a_ladder_with_someone_left_to_play_asks_nothing_wider() {
        var h = make();
        var r = searched(h, { name: "Raadio Relax International", cc: "EE", wide: false, own: [], rows: [] });
        compare(r.url, "");
        compare(r.asked.length, 0);
    }

    function test_a_name_with_no_word_of_its_own_asks_nothing_wider() {
        var h = make();
        var r = searched(h, { name: "Radio 2", cc: "EE", wide: true, own: [], rows: [] });
        compare(r.url, "");
        compare(r.asked.length, 0);
    }

    function test_the_wider_pass_does_not_ask_the_listeners_rows_again() {
        var h = make();
        var r = searched(h, { name: "Retro fm disco", cc: "", wide: true, rows: [],
                              own: [{ hostname: "https://edge06.cdn.bitflip.ee:8888/kadi" }],
                              answer: [{ name: "y", url_resolved: "https://edge01.cdn.bitflip.ee:8888/NRJ" }] });
        // No country came with the row, so the saved address's own domain names it.
        compare(r.asked, ["/json/stations/search?name=retro&countrycode=EE&hidebroken=true&order=votes&reverse=true&limit=30"]);
        compare(r.url, "");
        // edge06 said no in the first pass and is not asked a second time.
        compare(tc.opened, ["https://edge06.cdn.bitflip.ee:8888/RETRO",
                            "https://edge01.cdn.bitflip.ee:8888/RETRO"]);
    }

    function test_a_directory_answer_that_comes_after_a_cancel_is_dropped() {
        var h = make();
        var late = null, done = 0;
        h.search({ saved: tc.saved, name: "Retro fm disco", cc: "", wide: true, own: [], rows: [],
                   ask: function(path, onRows) { late = onRows; } }, function(u) { done++; });
        tryVerify(function() { return late !== null; }, 1000);
        h.cancel();
        late([{ name: "x", url_resolved: "https://edge43.cdn.bitflip.ee:8888/x" }]);
        wait(60);
        compare(done, 0);
        compare(tc.opened.length, 0);
    }

    function test_no_request_starts_in_the_callers_own_turn() {
        // The heal arrives from inside a directory request's handler, and a
        // request started in there takes the shell down.
        var h = make();
        h.find(tc.saved, ["https://edge06.cdn.bitflip.ee:8888/kadi"], function(u) {});
        compare(tc.opened.length, 0);
        tryVerify(function() { return tc.opened.length === 1; }, 1000);
    }
}
