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

}
