// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The popup list's reorder decisions: what the filtered model shows, when
// a rebuild may be skipped for an in-place patch, and how a live drag's
// final index translates into the engine's insert-before slot. Every one
// of these has an off-by-one waiting — they live under tests.
import QtQuick
import QtTest

import "../../package/contents/ui/ReorderLogic.js" as RL

TestCase {
    name: "ReorderLogic"

    function _st(name, host, favicon) {
        return { name: name, hostname: host || ("http://" + name + ".example/s"),
                 favicon: favicon || "", active: true }
    }
    function _fakeModel(rows) {
        return {
            rows: rows,
            patches: [],
            count: rows.length,
            get: function(i) { return this.rows[i] },
            setProperty: function(i, k, v) {
                this.rows[i][k] = v
                this.patches.push(i + ":" + k)
            }
        }
    }

    // ── buildFilteredRows ────────────────────────────────────────────────

    function test_main_list_rows_carry_their_positions() {
        var rows = RL.buildFilteredRows([_st("A"), _st("B"), _st("C")], [], "", false)
        compare(rows.length, 3)
        compare(rows[0].name, "A")
        compare(rows[2].originalIndex, 2)
        compare(rows[1].active, true)
    }

    function test_filter_is_fold_blind_like_the_search() {
        var rows = RL.buildFilteredRows(
            [_st("Sõbra Raadio"), _st("Radio Nova")], [], "sobra", false)
        compare(rows.length, 1)
        compare(rows[0].name, "Sõbra Raadio")
        compare(rows[0].originalIndex, 0)
    }

    function test_favorites_follow_their_own_order_and_skip_hidden() {
        // "Gone" is a favorite whose station was deactivated — it keeps its
        // favorite status but cannot be shown; the rows skip it silently.
        var rows = RL.buildFilteredRows(
            [_st("A"), _st("B"), _st("C")], ["C", "Gone", "A"], "", true)
        compare(rows.length, 2)
        compare(rows[0].name, "C")
        compare(rows[0].originalIndex, 2)
        compare(rows[1].name, "A")
        compare(rows[1].originalIndex, 0)
    }

    function test_duplicate_names_resolve_to_the_first_station() {
        var rows = RL.buildFilteredRows(
            [_st("Twin", "http://one/"), _st("Twin", "http://two/")],
            ["Twin"], "", true)
        compare(rows.length, 1)
        compare(rows[0].hostname, "http://one/")
        compare(rows[0].originalIndex, 0)
    }

    function test_a_station_named_constructor_is_not_an_object_property() {
        var rows = RL.buildFilteredRows(
            [_st("constructor")], ["constructor"], "", true)
        compare(rows.length, 1)
        compare(rows[0].name, "constructor")
        // ...and a favorite by a prototype name with NO such station stays out.
        compare(RL.buildFilteredRows([_st("A")], ["toString"], "", true).length, 0)
    }

    function test_filter_applies_inside_the_favorites_view_too() {
        var rows = RL.buildFilteredRows(
            [_st("Jazz FM"), _st("Rock FM")], ["Rock FM", "Jazz FM"], "jazz", true)
        compare(rows.length, 1)
        compare(rows[0].name, "Jazz FM")
    }

    // ── syncModelToRows ──────────────────────────────────────────────────

    function test_identical_sequence_patches_nothing_and_skips_rebuild() {
        var m = _fakeModel([
            { name: "A", hostname: "h1", favicon: "f1", active: true, originalIndex: 0 },
            { name: "B", hostname: "h2", favicon: "f2", active: true, originalIndex: 1 }])
        verify(RL.syncModelToRows(m, [
            { name: "A", hostname: "h1", favicon: "f1", active: true, originalIndex: 0 },
            { name: "B", hostname: "h2", favicon: "f2", active: true, originalIndex: 1 }]))
        compare(m.patches.length, 0)
    }

    function test_same_stations_new_numbers_are_patched_in_place() {
        // The view moved a row live; the rebuilt rows carry the same
        // stations in the same (already-moved) order but fresh
        // originalIndex values — the model must be patched, NOT rebuilt.
        var m = _fakeModel([
            { name: "B", hostname: "h2", favicon: "", active: true, originalIndex: 1 },
            { name: "A", hostname: "h1", favicon: "", active: true, originalIndex: 0 }])
        verify(RL.syncModelToRows(m, [
            { name: "B", hostname: "h2", favicon: "", active: true, originalIndex: 0 },
            { name: "A", hostname: "h1", favicon: "", active: true, originalIndex: 1 }]))
        compare(m.rows[0].originalIndex, 0)
        compare(m.rows[1].originalIndex, 1)
        compare(m.patches.length, 2)
    }

    function test_a_backfilled_logo_lands_without_a_rebuild() {
        var m = _fakeModel([
            { name: "A", hostname: "h1", favicon: "", active: true, originalIndex: 0 }])
        verify(RL.syncModelToRows(m, [
            { name: "A", hostname: "h1", favicon: "http://x/l.png", active: true, originalIndex: 0 }]))
        compare(m.rows[0].favicon, "http://x/l.png")
    }

    function test_a_different_sequence_demands_a_rebuild() {
        var m = _fakeModel([
            { name: "A", hostname: "h1", favicon: "", active: true, originalIndex: 0 },
            { name: "B", hostname: "h2", favicon: "", active: true, originalIndex: 1 }])
        // Different order without fresh numbers, a rename, a length change,
        // and a same-name different-station swap all refuse the patch road.
        verify(!RL.syncModelToRows(m, [
            { name: "B", hostname: "h2", favicon: "", active: true, originalIndex: 1 },
            { name: "A", hostname: "h1", favicon: "", active: true, originalIndex: 0 }]))
        verify(!RL.syncModelToRows(m, [
            { name: "A", hostname: "h1", favicon: "", active: true, originalIndex: 0 }]))
        verify(!RL.syncModelToRows(m, [
            { name: "A", hostname: "h1", favicon: "", active: true, originalIndex: 0 },
            { name: "B", hostname: "OTHER", favicon: "", active: true, originalIndex: 1 }]))
    }

    // ── savedRows ────────────────────────────────────────────────────────

    // dynamicRoles like StationsModel.qml: those rows are QObjects, and
    // their objectName is what came along into the saved JSON.
    ListModel { id: savedModel; dynamicRoles: true }

    function test_a_saved_row_is_its_roles_and_nothing_else() {
        savedModel.clear()
        savedModel.append({ name: "Alpha", hostname: "http://a.example/s", favicon: "", active: true })
        savedModel.append({ name: "Beta", hostname: "http://b.example/s", favicon: "x.png", active: false })
        var rows = RL.savedRows(savedModel)
        compare(rows.length, 2)
        for (var i = 0; i < rows.length; i++)
            compare(Object.keys(rows[i]).sort().join(","), "active,favicon,hostname,name", "row " + i)
        compare(rows[1].name, "Beta")
        compare(rows[1].hostname, "http://b.example/s")
        compare(rows[1].favicon, "x.png")
        compare(rows[1].active, false)
    }

    function test_an_empty_prev_is_not_written_down() {
        // Every model row carries prev (DoorLogic.normalize gives it, so a
        // role's shape is set by the first row); the stored list keeps only
        // the ones that say something.
        savedModel.clear()
        savedModel.append({ name: "Alpha", hostname: "http://a.example/s", favicon: "", active: true, prev: "" })
        savedModel.append({ name: "Beta", hostname: "http://b.example/s", favicon: "", active: true,
                            prev: "http://old.example/b" })
        var rows = RL.savedRows(savedModel)
        compare(Object.keys(rows[0]).sort().join(","), "active,favicon,hostname,name")
        compare(rows[1].prev, "http://old.example/b")
    }

    // ── mergeExternal ────────────────────────────────────────────────────

    function _norm(o) {
        var keys = Object.keys(o).filter(function(k) { return o[k] !== undefined }).sort()
        var flat = {}
        for (var i = 0; i < keys.length; i++) flat[keys[i]] = o[keys[i]]
        return JSON.stringify(flat)
    }
    function _row(name, host, extra) {
        var r = { name: name, hostname: host }
        for (var k in (extra || {})) r[k] = extra[k]
        return r
    }
    function _hosts(rows) { return rows.map(function(r) { return r.name + "@" + r.hostname }).join(",") }

    function test_merge_keeps_a_row_removed_here_removed() {
        var base = [_row("A", "a"), _row("B", "b"), _row("G", "g")]
        var cur = [_row("A", "a"), _row("G", "g")]
        var ext = [_row("A", "a", { favicon: "l" }), _row("B", "b"), _row("G", "g")]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "A@a,G@g")
        compare(m.rows[0].favicon, "l", "the popup's change to a row untouched here still lands")
        verify(m.changed)
    }

    function test_merge_follows_a_move_in_place() {
        var base = [_row("A", "a"), _row("B", "b1"), _row("G", "g")]
        var cur = [_row("A", "a"), _row("B", "b1"), _row("G", "g", { active: false })]
        var ext = [_row("A", "a"), _row("B", "b2", { prev: "b1" }), _row("G", "g")]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "A@a,B@b2,G@g")
        compare(m.rows[2].active, false, "the local edit stays")
        verify(m.changed)
    }

    function test_merge_carries_a_move_onto_a_row_renamed_here() {
        // A rename here and a heal there used to leave the renamed row on the
        // dead address, and the popup's next load then lost its favorite: the
        // name it knew sat nowhere, and its old address held nothing.
        var base = [_row("A", "a"), _row("B", "b1", { uuid: "u" })]
        var cur = [_row("A", "a"), _row("B mine", "b1", { uuid: "u" })]
        var ext = [_row("A", "a"), _row("B", "b2", { prev: "b1", uuid: "u" })]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "A@a,B mine@b2")
        compare(m.rows[1].prev, "b1")
        compare(m.rows[1].uuid, "u")
        verify(m.changed)
    }

    function test_merge_takes_what_the_popup_found_for_a_row_edited_here() {
        var base = [_row("A", "a", { favicon: "" })]
        var cur = [_row("A mine", "a", { favicon: "" })]
        var ext = [_row("A", "a", { favicon: "l" })]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(m.rows[0].name, "A mine", "the edit here")
        compare(m.rows[0].favicon, "l", "the logo the popup found")
        // A field changed on both sides is this page's.
        cur = [_row("A", "a", { favicon: "mine" })]
        compare(RL.mergeExternal(base, cur, ext, _norm).rows[0].favicon, "mine")
    }

    function test_merge_does_not_take_one_rows_old_address_for_another_row() {
        // R was healed off a shoutcast port long ago and still says so in
        // prev; a new station S lives there now. The popup moves S, with an
        // edit pending here: S used to vanish and R came twice.
        var ip = "http://1.2.3.4:8000/stream"
        var base = [_row("S", ip), _row("R", "http://r.example/live", { prev: ip }), _row("Z", "z")]
        var cur = [_row("S", ip), _row("R", "http://r.example/live", { prev: ip }), _row("Z", "z", { active: false })]
        var ext = [_row("S", "http://s.example/new", { prev: ip }), _row("R", "http://r.example/live", { prev: ip }), _row("Z", "z")]
        compare(_hosts(RL.mergeExternal(base, cur, ext, _norm).rows),
                "S@http://s.example/new,R@http://r.example/live,Z@z")
        // The popup removed S: R once, in its own place.
        ext = [_row("R", "http://r.example/live", { prev: ip }), _row("Z", "z")]
        compare(_hosts(RL.mergeExternal(base, cur, ext, _norm).rows), "R@http://r.example/live,Z@z")
    }

    function test_merge_follows_a_heal_onto_an_address_another_row_holds() {
        // Kadi was also saved at its new address. The popup healed the old row
        // onto it with an edit pending here: the page dropped a station.
        var base = [_row("Kadi", "old", { uuid: "u1" }), _row("Zed", "z"), _row("Kadi new", "new")]
        var cur = [_row("Kadi", "old", { uuid: "u1" }), _row("Zed", "z", { active: false }), _row("Kadi new", "new")]
        var ext = [_row("Kadi", "new", { uuid: "u1", prev: "old" }), _row("Zed", "z"), _row("Kadi new", "new")]
        compare(_hosts(RL.mergeExternal(base, cur, ext, _norm).rows), "Kadi@new,Zed@z,Kadi new@new")
        // The second row removed here: the healed one still stays.
        cur = [_row("Kadi", "old", { uuid: "u1" }), _row("Zed", "z", { active: false })]
        compare(_hosts(RL.mergeExternal(base, cur, ext, _norm).rows), "Kadi@new,Zed@z")
    }

    function test_merge_follows_the_twin_the_popup_healed_not_the_other() {
        var base = [_row("T1", "h", { uuid: "u1" }), _row("T2", "h", { uuid: "u2", favicon: "l2" })]
        var cur = [_row("T1 mine", "h", { uuid: "u1" }), _row("T2", "h", { uuid: "u2", favicon: "l2" })]
        var ext = [_row("T1", "b", { uuid: "u1", prev: "h" }), _row("T2", "h", { uuid: "u2", favicon: "l2" })]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "T1 mine@b,T2@h")
        compare(m.rows[0].uuid, "u1")
        compare(m.rows[1].favicon, "l2")
    }

    function test_merge_drops_the_twin_the_popup_removed_not_the_other() {
        var base = [_row("T", "h"), _row("X", "x"), _row("T two", "h")]
        var cur = [_row("T", "h"), _row("X", "x"), _row("T two", "h", { active: false })]
        var ext = [_row("X", "x"), _row("T two", "h")]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "X@x,T two@h")
        compare(m.rows[1].active, false)
        // The first twin removed here: the second keeps its own changes.
        cur = [_row("X", "x"), _row("T two", "h")]
        ext = [_row("T", "h", { favicon: "lt" }), _row("X", "x"), _row("T two", "h", { favicon: "l2" })]
        m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "X@x,T two@h")
        compare(m.rows[1].favicon, "l2")
    }

    function test_merge_takes_another_station_the_popup_added_at_a_held_address() {
        var base = [_row("A", "h")]
        var cur = [_row("A", "h", { active: false })]
        var ext = [_row("A", "h"), _row("B", "h")]
        compare(_hosts(RL.mergeExternal(base, cur, ext, _norm).rows), "A@h,B@h")
    }

    function test_merge_tells_a_healed_twin_from_the_one_it_landed_on() {
        // The same station starred twice: the heal moves the first onto the
        // second's address while the page removes the second.
        var base = [_row("R", "x1", { uuid: "u", favicon: "mine" }), _row("R", "x2", { uuid: "u", active: false, favicon: "f2" })]
        var cur = [_row("R", "x1", { uuid: "u", favicon: "mine" })]
        var ext = [_row("R", "x2", { uuid: "u", prev: "x1", favicon: "mine" }), _row("R", "x2", { uuid: "u", active: false, favicon: "f2" })]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "R@x2")
        compare(m.rows[0].favicon, "mine")
        compare(m.rows[0].prev, "x1")
        compare(m.rows[0].active, undefined)
    }

    function test_merge_leaves_a_row_moved_here_onto_another_rows_address_alone() {
        var base = [_row("Alpha", "a"), _row("Beta", "b", { uuid: "ub" })]
        var cur = [_row("Alpha", "b"), _row("Beta", "b", { uuid: "ub" })]
        var ext = [_row("Alpha", "a"), _row("Beta", "bnew", { uuid: "ub", prev: "b" })]
        compare(_hosts(RL.mergeExternal(base, cur, ext, _norm).rows), "Alpha@b,Beta@bnew")
        // Renamed and dragged above its twin, then the other twin trashed in the popup.
        base = [_row("Kadi", "x"), _row("Kadi AAC", "x")]
        cur = [_row("Kadi AAC mine", "x"), _row("Kadi", "x")]
        ext = [_row("Kadi AAC", "x", { favicon: "l" })]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "Kadi AAC mine@x")
        compare(m.rows[0].favicon, "l")
    }

    function test_merge_gives_a_row_added_here_nothing_of_one_moved_away_here() {
        // B moved to y on this page, and a new Z took its old address: the
        // popup's logo for B is B's, not Z's.
        var base = [_row("B", "x")]
        var cur = [_row("B", "y"), _row("Z", "x")]
        var ext = [_row("B", "x", { favicon: "lb" })]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "B@y,Z@x")
        compare(m.rows[1].favicon, undefined, "the new row took the moved one's logo")
    }

    function test_merge_reads_an_empty_field_and_a_missing_one_alike() {
        // A starred row is saved with "prev": "", the page keeps none: the
        // heal's prev used to be taken for a change made here and dropped.
        var base = [_row("Beta", "edge", { prev: "" })]
        var cur = [_row("Beta mine", "edge")]
        var ext = [_row("Beta", "router", { prev: "edge" })]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "Beta mine@router")
        compare(m.rows[0].prev, "edge")
    }

    function test_merge_pairs_two_rows_on_one_address_in_their_order() {
        // One station saved twice: the popup's change to the first lands on
        // the first, and neither row goes.
        var base = [_row("T", "h"), _row("T two", "h")]
        var cur = [_row("T", "h"), _row("T two", "h", { active: false })]
        var ext = [_row("T", "h", { favicon: "l" }), _row("T two", "h")]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "T@h,T two@h")
        compare(m.rows[0].favicon, "l")
        compare(m.rows[1].active, false)
    }

    function test_merge_does_not_bring_back_a_moved_row_removed_here() {
        var base = [_row("A", "a"), _row("B", "b1")]
        var cur = [_row("A", "a")]
        var ext = [_row("A", "a"), _row("B", "b2", { prev: "b1" })]
        compare(_hosts(RL.mergeExternal(base, cur, ext, _norm).rows), "A@a")
    }

    function test_merge_takes_rows_added_on_either_side_once() {
        var base = [_row("A", "a")]
        var cur = [_row("A", "a"), _row("N", "n")]
        var ext = [_row("A", "a"), _row("P", "p"), _row("N", "n")]
        var m = RL.mergeExternal(base, cur, ext, _norm)
        compare(_hosts(m.rows), "A@a,N@n,P@p")
        verify(m.changed)
    }

    function test_merge_follows_a_deletion_outside_and_reports_nothing_when_nothing_moved() {
        var base = [_row("A", "a"), _row("B", "b")]
        var cur = [_row("A", "a", { active: false }), _row("B", "b")]
        compare(_hosts(RL.mergeExternal(base, cur, [_row("A", "a")], _norm).rows), "A@a")
        var same = RL.mergeExternal(base, cur, base, _norm)
        compare(_hosts(same.rows), "A@a,B@b")
        verify(!same.changed)
    }

    function test_saved_rows_are_copies_the_model_does_not_follow() {
        savedModel.clear()
        savedModel.append({ name: "Alpha", hostname: "http://a.example/s", favicon: "", active: true })
        var rows = RL.savedRows(savedModel)
        rows[0].name = "changed"
        compare(savedModel.get(0).name, "Alpha")
        compare(RL.savedRows({ count: 0 }).length, 0)
    }

    // ── commitSlot ───────────────────────────────────────────────────────

    function test_commit_slot_translates_final_index_to_insert_before() {
        compare(RL.commitSlot(2, 5), 6)   // moved down: removal shift eats one
        compare(RL.commitSlot(5, 2), 2)   // moved up: they coincide
        compare(RL.commitSlot(3, 3), 3)   // no move (caller skips anyway)
        compare(RL.commitSlot(0, 1), 2)   // one step down from the top
        compare(RL.commitSlot(1, 0), 0)   // one step up to the top
    }

    // ── dragTarget ───────────────────────────────────────────────────────

    function test_drag_target_trusts_a_real_hit() {
        compare(RL.dragTarget(4, 300, 1000, 48, 2, 10), 4)
    }

    function test_drag_target_clamps_only_the_real_misses() {
        compare(RL.dragTarget(-1, -30, 1000, 48, 2, 10), 0)      // above the list
        compare(RL.dragTarget(-1, 995, 1000, 48, 2, 10), 9)      // below the list
        compare(RL.dragTarget(-1, 500, 1000, 48, 2, 10), 2)      // spacing gap: stay
    }
}
