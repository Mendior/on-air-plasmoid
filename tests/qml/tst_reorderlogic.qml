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
