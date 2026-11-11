// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The field every saved row carries besides its address, prev, and the
// address cleaner it goes through. The settings pages' merge trusts prev to
// follow a moved station, so junk must never reach it.
import QtQuick
import QtTest

import "../../package/contents/ui/DoorLogic.js" as DL

TestCase {
    name: "DoorLogic"

    readonly property string edge: "https://le06.euddn.net/06c6e9fec40c/elmar.aac"
    readonly property string u1: "1ee96040-bfb6-4209-9ab8-14a26ff73ad0"

    function test_clean_addr_keeps_web_addresses_only() {
        compare(DL.cleanAddr("  https://a.example/x  "), "https://a.example/x");
        compare(DL.cleanAddr("HTTP://A.example/x"), "HTTP://A.example/x");
        compare(DL.cleanAddr("ftp://a.example/x"), "");
        compare(DL.cleanAddr("file:///home/me/song.mp3"), "");
        compare(DL.cleanAddr("javascript:alert(1)"), "");
        compare(DL.cleanAddr(""), "");
        compare(DL.cleanAddr(null), "");
        compare(DL.cleanAddr(undefined), "");
        compare(DL.cleanAddr(42), "");
        compare(DL.cleanAddr({}), "");
    }

    function test_clean_addr_draws_the_line_at_2048() {
        var head = "https://a.example/";
        var exact = head + new Array(2048 - head.length + 1).join("x");
        compare(exact.length, 2048);
        compare(DL.cleanAddr(exact), exact);
        compare(DL.cleanAddr(exact + "x"), "");
    }

    function test_normalize_fills_prev_and_keeps_the_rest() {
        var row = { "name": "Raadio Elmar", "hostname": edge, "uuid": u1, "active": true };
        var out = DL.normalize(row);
        compare(out.prev, "");
        compare(out.name, "Raadio Elmar");
        compare(out.uuid, u1);
        compare(out.active, true);
        verify(row.prev === undefined, "the row handed in was changed");
    }

    function test_normalize_drops_a_prev_that_is_the_saved_address() {
        var out = DL.normalize({ "hostname": edge, "prev": edge.replace("https://", "http://").toUpperCase() + "/" });
        compare(out.prev, "");
        out = DL.normalize({ "hostname": edge, "prev": "https://le03.euddn.net/aa/elmar.aac" });
        compare(out.prev, "https://le03.euddn.net/aa/elmar.aac");
    }

    // ── the Edit dialog, against a list the popup wrote meanwhile ────────
    readonly property string router: "https://router.euddn.net/8103046e16/elmar.aac"

    function _r(name, host, extra) {
        var o = { "name": name, "hostname": host, "favicon": "", "active": true };
        for (var k in (extra || {})) o[k] = extra[k];
        return o;
    }

    function test_the_dialog_finds_its_row_where_it_was_opened() {
        var rows = [_r("A", "http://a.example/s"), _r("Elmar", edge), _r("C", "http://c.example/s")];
        compare(DL.editRowIndex(rows, 1, { "hostname": edge, "name": "Elmar" }), 1);
    }

    function test_the_dialog_follows_its_row_through_a_heal_and_a_removal() {
        // The heal moved it: its old address is prev now.
        var moved = [_r("A", "http://a.example/s"), _r("Elmar", router, { "prev": edge })];
        compare(DL.editRowIndex(moved, 1, { "hostname": edge, "name": "Elmar" }), 1);
        // A row above it went: it is one up.
        compare(DL.editRowIndex([_r("Elmar", edge), _r("C", "http://c.example/s")], 1, { "hostname": edge, "name": "Elmar" }), 0);
        // Both at once.
        compare(DL.editRowIndex([_r("Elmar", router, { "prev": edge })], 1, { "hostname": edge, "name": "Elmar" }), 0);
    }

    function test_the_dialog_prefers_its_own_row_and_an_address_over_a_history() {
        // The same station saved twice: the one the dialog was opened on.
        var twins = [_r("Elmar", edge), _r("B", "http://b.example/s"), _r("Elmar", edge)];
        compare(DL.editRowIndex(twins, 2, { "hostname": edge, "name": "Elmar" }), 2);
        compare(DL.editRowIndex(twins, 0, { "hostname": edge, "name": "Elmar" }), 0);
        // Another row that left this address behind is not this row.
        var other = [_r("X", router, { "prev": edge }), _r("Elmar", edge)];
        compare(DL.editRowIndex(other, 0, { "hostname": edge, "name": "Elmar" }), 1);
    }

    function test_the_dialog_finds_a_row_whatever_address_was_typed() {
        // The Add dialog takes any address, and such a row used to come back
        // twice from every Edit: the old one kept, the edited one appended.
        var rows = [_r("Kadi", "kadi.example/stream"), _r("Cam", "rtsp://cam.example/live")];
        compare(DL.editRowIndex(rows, 0, { "hostname": "kadi.example/stream", "name": "Kadi" }), 0);
        compare(DL.editRowIndex(rows, 1, { "hostname": "rtsp://cam.example/live", "name": "Cam" }), 1);
    }

    function test_the_dialog_knows_its_twin_by_the_name_it_opened_with() {
        // Two rows on one address and the heal moved the one being edited:
        // the other one, still at the address, is not it.
        var healed = [_r("T", "http://b.example/s", { "prev": "http://h.example/s" }), _r("T two", "http://h.example/s")];
        compare(DL.editRowIndex(healed, 0, { "hostname": "http://h.example/s", "name": "T" }), 0);
        // A row above went: the second twin is one up, not the first.
        var shifted = [_r("T", "http://h.example/s"), _r("T two", "http://h.example/s")];
        compare(DL.editRowIndex(shifted, 2, { "hostname": "http://h.example/s", "name": "T two" }), 1);
    }

    function test_the_dialog_never_lands_on_another_station_at_its_address() {
        // The row being edited was removed in the popup; another station on
        // the same address is not it, and the edit comes back as a row of its own.
        var rows = [_r("Other", "http://h.example/s"), _r("C", "http://c.example/s")];
        compare(DL.editRowIndex(rows, 0, { "hostname": "http://h.example/s", "name": "Mine" }), -1);
        compare(DL.editRowIndex([_r("Other", "http://b.example/s", { "prev": "http://h.example/s" })], 0,
                                { "hostname": "http://h.example/s", "name": "Mine" }), -1);
    }

    function test_the_dialog_finds_nothing_where_its_row_is_gone() {
        compare(DL.editRowIndex([_r("A", "http://a.example/s")], 1, { "hostname": edge, "name": "Elmar" }), -1);
        compare(DL.editRowIndex([], 0, { "hostname": edge, "name": "Elmar" }), -1);
        compare(DL.editRowIndex(null, 0, { "hostname": edge, "name": "Elmar" }), -1);
        compare(DL.editRowIndex([_r("A", "")], 0, { "hostname": "", "name": "A" }), -1);
        compare(DL.editRowIndex([_r("A", "x")], 0, null), -1);
    }

    function test_a_rename_after_a_heal_keeps_what_the_popup_wrote() {
        // Measured on the page on 2026-11-02: the OK of a rename put the
        // station back on the edge the heal had moved it off, dropped prev
        // and the uuid, and lost the logo the popup had found meanwhile.
        var live = _r("Elmar", router, { "prev": edge, "uuid": u1, "favicon": "https://e.example/l.png" });
        var opened = { "name": "Elmar", "hostname": edge, "favicon": "", "active": true };
        var shown = { "name": "Raadio Elmar", "hostname": edge, "favicon": "", "active": true };
        var out = DL.editedRow(live, opened, shown, shown);
        compare(out.name, "Raadio Elmar");
        compare(out.hostname, router);
        compare(out.prev, edge);
        compare(out.uuid, u1);
        compare(out.favicon, "https://e.example/l.png");
        compare(out.active, true);
        compare(live.name, "Elmar", "the live row was changed");
    }

    function test_an_address_the_listener_changed_starts_without_history() {
        var live = _r("Elmar", router, { "prev": edge, "uuid": u1 });
        var opened = { "name": "Elmar", "hostname": edge, "favicon": "", "active": true };
        // Another station on another domain: the uuid goes with the history.
        var shown = { "name": "Elmar", "hostname": "http://other.example/live ", "favicon": "", "active": true };
        var clean = { "name": "Elmar", "hostname": "http://other.example/live", "favicon": "", "active": true };
        var out = DL.editedRow(live, opened, shown, clean);
        compare(out.hostname, "http://other.example/live");
        compare(out.prev, "");
        compare(out.uuid, "");
        // Another mount of the station's own domain, same name: the uuid stays.
        shown = { "name": "Elmar", "hostname": "https://le03.euddn.net/aa/elmar.aac", "favicon": "", "active": true };
        out = DL.editedRow(live, opened, shown, shown);
        compare(out.hostname, "https://le03.euddn.net/aa/elmar.aac");
        compare(out.prev, "");
        compare(out.uuid, u1);
    }

    function test_each_field_the_listener_touched_is_theirs() {
        var live = _r("Elmar", edge, { "favicon": "https://e.example/l.png" });
        var opened = { "name": "Elmar", "hostname": edge, "favicon": "https://e.example/l.png", "active": true };
        var shown = { "name": "Elmar", "hostname": edge, "favicon": "e.example/new.png", "active": false };
        var clean = { "name": "Elmar", "hostname": edge, "favicon": "https://e.example/new.png", "active": false };
        var out = DL.editedRow(live, opened, shown, clean);
        compare(out.favicon, "https://e.example/new.png");
        compare(out.active, false);
        // A name field emptied takes what the page makes of it.
        shown = { "name": "", "hostname": edge, "favicon": "https://e.example/l.png", "active": true };
        clean = { "name": edge, "hostname": edge, "favicon": "https://e.example/l.png", "active": true };
        compare(DL.editedRow(live, opened, shown, clean).name, edge);
    }

    function test_normalize_refuses_what_is_not_a_web_address() {
        var out = DL.normalize({ "hostname": edge, "prev": "javascript:alert(1)" });
        compare(out.prev, "");
        out = DL.normalize({ "hostname": edge, "prev": ["x"] });
        compare(out.prev, "");
        compare(DL.normalize(null), null);
        compare(DL.normalize("x"), "x");
    }

    // ── a station file picked in the Import dialog ───────────────────────
    // The Stations page used to empty its list before it had looked at the
    // file, so a wrong pick cost the listener every station.
    readonly property var exported: [
        { "active": true, "country": "Estonia", "favicon": "https://e.example/l.png",
          "hostname": router, "name": "Raadio Elmar" },
        { "active": false, "favicon": "", "hostname": "http://b.example/s", "name": "Beta", "uuid": u1 },
        { "active": true, "bitrate": 900, "codec": "flac", "favicon": "",
          "hostname": "https://f.example/flac", "name": "Mast FLAC", "uuid": "",
          "prev": "https://old.example/flac" }
    ]

    // One row as text with its keys in order, so a failure names the field.
    function _flat(row) {
        if (row === null || typeof row !== "object") return String(row);
        var keys = Object.keys(row).sort(), out = [];
        for (var i = 0; i < keys.length; i++) out.push(keys[i] + "=" + JSON.stringify(row[keys[i]]));
        return out.join(" ");
    }
    function _names(rows) {
        if (!Array.isArray(rows)) return String(rows);
        return rows.map(function(r) { return r.name; }).join(",");
    }

    function test_a_file_that_is_no_list_gives_no_rows() {
        compare(DL.importedRows({}), null, "an object root");
        compare(DL.importedRows({ "stations": exported }), null, "a list wrapped in an object");
        compare(DL.importedRows([]), null, "an empty array");
        compare(DL.importedRows("http://a.example/s"), null, "a JSON string");
        compare(DL.importedRows(42), null);
        compare(DL.importedRows(true), null);
        compare(DL.importedRows(null), null);
        compare(DL.importedRows(undefined), null);
    }

    function test_another_programs_array_gives_no_rows() {
        compare(DL.importedRows([{ "title": "Jazz", "url": "http://a.example/s" }, { "id": 1 }]), null,
                "objects with no hostname");
        compare(DL.importedRows([1, 2, 3]), null);
        compare(DL.importedRows(["http://a.example/s"]), null, "bare strings");
        compare(DL.importedRows([[{ "name": "A", "hostname": "http://a.example/s" }]]), null,
                "a list inside a list");
        compare(DL.importedRows([null, null]), null);
    }

    function test_rows_that_are_no_station_are_left_out() {
        var a = { "name": "A", "hostname": "http://a.example/s" };
        var b = { "name": "B", "hostname": "http://b.example/s" };
        var c = { "name": "C", "hostname": "http://c.example/s" };
        var rows = DL.importedRows([a, null, b, 7, "x", ["y"], { "name": "no address" },
                                    { "name": "empty", "hostname": "" }, { "name": "blank", "hostname": "   " },
                                    { "name": "number", "hostname": 42 }, { "name": "object", "hostname": {} },
                                    { "name": "null", "hostname": null }, c]);
        compare(_names(rows), "A,B,C");
    }

    function test_the_import_can_say_how_many_rows_it_left_out() {
        var a = { "name": "A", "hostname": "http://a.example/s" };
        var whole = [a, a, a];
        compare(DL.importLeftOut(whole, DL.importedRows(whole)), 0);
        var holed = [a, null, { "name": "no address" }, a, 7];
        compare(DL.importLeftOut(holed, DL.importedRows(holed)), 3);
        // Past the cap the rows are stations too, and they are still not in the list.
        var many = [];
        for (var i = 0; i < DL.IMPORT_ROWS + 4; i++) many.push(a);
        compare(DL.importLeftOut(many, DL.importedRows(many)), 4);
        // A file that was refused has nothing to count.
        compare(DL.importLeftOut([null], DL.importedRows([null])), 0);
        compare(DL.importLeftOut({}, null), 0);
        compare(DL.importLeftOut(undefined, undefined), 0);
        compare(DL.importLeftOut([a], [a, a]), 0);
    }

    function test_the_widgets_own_export_comes_back_whole() {
        var file = JSON.parse(JSON.stringify(exported));
        var rows = DL.importedRows(file);
        verify(Array.isArray(rows), "the widget's own export was refused");
        compare(rows.length, exported.length);
        for (var i = 0; i < exported.length; i++)
            compare(_flat(rows[i]), _flat(exported[i]), "row " + i);
        compare(rows[2].codec, "flac");
        compare(rows[2].bitrate, 900);
        compare(JSON.stringify(file), JSON.stringify(exported), "the parsed file was changed");
        verify(rows[0] !== file[0], "a row of the file was handed back as it was");
    }

    function test_a_plain_row_gets_its_four_fields_and_no_more() {
        var rows = DL.importedRows([{ "hostname": "http://a.example/s", "junk": 1, "objectName": "x",
                                      "homepage": "http://a.example/" }]);
        compare(_flat(rows[0]), _flat({ "name": "http://a.example/s", "hostname": "http://a.example/s",
                                        "favicon": "", "active": true }));
        // A name that is no text is no name.
        rows = DL.importedRows([{ "hostname": "http://a.example/s", "name": { "en": "A" } }]);
        compare(_names(rows), "http://a.example/s");
        rows = DL.importedRows([{ "hostname": "http://a.example/s", "name": 1337 }]);
        compare(_names(rows), "1337");
    }

    function test_every_field_arrives_as_the_list_keeps_it() {
        var host = "http://a.example/s";
        function one(extra) {
            var o = { "name": "A", "hostname": host };
            for (var k in extra) o[k] = extra[k];
            var rows = DL.importedRows([o]);
            return (rows && rows[0]) || {};
        }
        compare(one({}).active, true, "a row that does not say is shown");
        compare(one({ "active": false }).active, false);
        compare(one({ "active": "false" }).active, false);
        compare(one({ "active": 0 }).active, false);
        compare(one({ "active": true }).active, true);
        compare(one({ "favicon": "https://a.example/l.png" }).favicon, "https://a.example/l.png");
        compare(one({ "favicon": "file:///etc/passwd" }).favicon, "");
        compare(one({ "favicon": "http://192.168.1.1/l.png" }).favicon, "", "a logo on the listener's own network");
        compare(one({ "favicon": null }).favicon, "");
        compare(one({ "codec": "FLAC" }).codec, "flac");
        compare(one({ "codec": null }).codec, "");
        compare(one({ "bitrate": "128" }).bitrate, 128);
        compare(one({ "bitrate": 128.9 }).bitrate, 128);
        compare(one({ "bitrate": -5 }).bitrate, 0);
        compare(one({ "bitrate": "fast" }).bitrate, 0);
        compare(one({ "bitrate": null }).bitrate, 0);
        compare(one({ "country": 372 }).country, "372");
        compare(one({ "uuid": u1 }).uuid, u1);
        compare(one({ "prev": "https://old.example/s" }).prev, "https://old.example/s");
        verify(one({ "prev": "javascript:alert(1)" }).prev === undefined, "junk reached prev");
        verify(one({ "prev": host + "/" }).prev === undefined, "prev names the row's own address");
        verify(one({}).codec === undefined && one({}).bitrate === undefined && one({}).country === undefined
               && one({}).uuid === undefined, "a field the file never had was made up");
    }

    function test_five_hundred_rows_are_the_most_a_file_gives() {
        var file = [];
        for (var i = 0; i < 500; i++) file.push({ "name": "S" + i, "hostname": "http://s.example/" + i });
        var rows = DL.importedRows(file);
        compare(rows.length, 500);
        compare(rows[0].name, "S0");
        compare(rows[499].name, "S499");
        file.push({ "name": "S500", "hostname": "http://s.example/500" });
        rows = DL.importedRows(file);
        compare(rows.length, 500);
        compare(rows[499].name, "S499", "the file's order was not kept");
    }

    function test_a_field_is_cut_at_five_hundred_characters() {
        var big = new Array(10001).join("n");
        var rows = DL.importedRows([{ "name": big, "hostname": "http://a.example/" + big,
                                      "country": big, "uuid": big, "codec": big.toUpperCase(),
                                      "favicon": "https://a.example/" + big }]);
        compare(_names(rows).length, 500);
        compare(rows[0].hostname.length, 500);
        compare(rows[0].hostname.substring(0, 17), "http://a.example/");
        compare(rows[0].country.length, 500);
        compare(rows[0].uuid.length, 500);
        compare(rows[0].codec, new Array(17).join("n"));
        compare(rows[0].favicon.length, 500);
        var exact = new Array(501).join("n");
        compare(_names(DL.importedRows([{ "name": exact, "hostname": "http://a.example/s" }])), exact);
    }

}
