// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// ViewLogic's rules that need no view to stand in: what a key press, a tab
// switch or an empty page decides. They have their own file because every
// test in tst_viewlogic waits for its ListView to draw a frame first, about
// two seconds each when the test itself moves nothing (measured: five rule
// tests took that file from 5 s to 15 s).
import QtQuick
import QtTest

import "../../package/contents/ui/ViewLogic.js" as VL

TestCase {
    name: "ViewRules"

    // Open-and-type. The row hidden is the report: every letter filtered
    // the list from a field that was not on screen.
    function test_a_letter_goes_to_the_search_field_only_while_its_row_is_shown() {
        compare(VL.typedChar(true, false, "j"), "j")
        compare(VL.typedChar(false, false, "j"), "")
        compare(VL.typedChar(false, false, "/"), "")
        // Only a plain true shows the row: a switch nobody can read is
        // no licence to type into a field that may be hidden.
        compare(VL.typedChar(undefined, false, "j"), "")
        compare(VL.typedChar(null, false, "j"), "")
    }

    function test_what_is_typed_is_the_printable_character_itself() {
        compare(VL.typedChar(true, false, "J"), "J")
        compare(VL.typedChar(true, false, "8"), "8")
        compare(VL.typedChar(true, false, "ä"), "ä")
        compare(VL.typedChar(true, false, "/"), "/")
        // The first printable one, and the last before DEL.
        compare(VL.typedChar(true, false, "!"), "!")
        compare(VL.typedChar(true, false, "~"), "~")
        compare(VL.typedChar(true, false, String.fromCharCode(0x80)), String.fromCharCode(0x80))
    }

    function test_space_and_the_control_keys_are_not_text() {
        compare(VL.typedChar(true, false, " "), "")
        compare(VL.typedChar(true, false, "\t"), "")
        compare(VL.typedChar(true, false, "\r"), "")
        compare(VL.typedChar(true, false, String.fromCharCode(0x1b)), "")
        compare(VL.typedChar(true, false, String.fromCharCode(0x7f)), "")
    }

    function test_a_chord_is_left_to_whoever_owns_it() {
        compare(VL.typedChar(true, true, "j"), "")
        // The handler passes the masked modifiers, a number.
        compare(VL.typedChar(true, 0x04000000, "j"), "")
        compare(VL.typedChar(true, 0, "j"), "j")
    }

    function test_a_press_without_one_character_of_text_types_nothing() {
        compare(VL.typedChar(true, false, ""), "")
        compare(VL.typedChar(true, false, null), "")
        compare(VL.typedChar(true, false, undefined), "")
        compare(VL.typedChar(true, false, 7), "")
        compare(VL.typedChar(true, false, "ab"), "")
        compare(VL.typedChar(true, false, new Array(5000).join("x")), "")
    }

    // The tabs. off(1) is every page shown but Playing.
    function off() {
        var s = [true, true, true, true, true]
        for (var i = 0; i < arguments.length; i++) s[arguments[i]] = false
        return s
    }

    function test_a_page_that_has_its_tab_is_where_the_listener_stays() {
        for (var i = 0; i <= 4; i++) {
            compare(VL.nextVisibleView(i, 1, off()), i)
            compare(VL.nextVisibleView(i, -1, off()), i)
        }
        compare(VL.nextVisibleView(2, -1, off(1)), 2)
    }

    function test_a_step_back_onto_a_hidden_page_walks_on_back() {
        // The report: Playing off, back from My Music.
        compare(VL.nextVisibleView(1, -1, off(1)), 0)
        compare(VL.nextVisibleView(2, -1, off(1, 2)), 0)
        compare(VL.nextVisibleView(3, -1, off(3)), 2)
    }

    function test_a_step_forward_onto_a_hidden_page_walks_on_forward() {
        compare(VL.nextVisibleView(1, 1, off(1)), 2)
        compare(VL.nextVisibleView(1, 1, off(1, 2)), 3)
        compare(VL.nextVisibleView(3, 1, off(3)), 4)
    }

    function test_with_nothing_left_that_way_the_walk_turns_round() {
        compare(VL.nextVisibleView(0, -1, off(0)), 1)
        compare(VL.nextVisibleView(1, -1, off(0, 1)), 2)
        compare(VL.nextVisibleView(4, 1, off(4)), 3)
        compare(VL.nextVisibleView(3, 1, off(3, 4)), 2)
        // The one page left, from either side.
        compare(VL.nextVisibleView(0, 1, off(0, 1, 2, 4)), 3)
        compare(VL.nextVisibleView(4, -1, off(0, 1, 2, 4)), 3)
    }

    function test_a_tab_switched_off_under_the_listener_walks_forward() {
        // No step was taken, so there is no direction: forward, as before.
        compare(VL.nextVisibleView(2, 0, off(2)), 3)
        compare(VL.nextVisibleView(2, undefined, off(2)), 3)
        compare(VL.nextVisibleView(2, NaN, off(2)), 3)
    }

    function test_a_page_number_outside_the_pages_counts_from_the_nearer_end() {
        compare(VL.nextVisibleView(-1, 1, off()), 0)
        compare(VL.nextVisibleView(-7, -1, off(0)), 1)
        compare(VL.nextVisibleView(5, 1, off()), 4)
        compare(VL.nextVisibleView(99, 1, off(4)), 3)
        compare(VL.nextVisibleView(undefined, 1, off(0)), 1)
        compare(VL.nextVisibleView(NaN, 1, off()), 0)
        compare(VL.nextVisibleView("2", 1, off()), 2)
        compare(VL.nextVisibleView(2.9, 1, off()), 2)
    }

    function test_no_page_shown_is_page_zero() {
        compare(VL.nextVisibleView(3, 1, off(0, 1, 2, 3, 4)), 0)
        compare(VL.nextVisibleView(3, -1, []), 0)
        compare(VL.nextVisibleView(3, 1, null), 0)
        compare(VL.nextVisibleView(3, 1, undefined), 0)
        compare(VL.nextVisibleView(3, 1, "shown"), 0)
        compare(VL.firstVisibleView(off(0, 1, 2, 3, 4)), 0)
        compare(VL.firstVisibleView([]), 0)
        compare(VL.firstVisibleView(null), 0)
        compare(VL.firstVisibleView(undefined), 0)
    }

    function test_only_a_plain_true_is_a_page_with_a_tab() {
        compare(VL.nextVisibleView(0, 1, ["yes", 1, {}, true, "true"]), 3)
        compare(VL.firstVisibleView(["yes", 1, {}, true, "true"]), 3)
    }

    function test_escape_goes_home_to_the_first_page_that_has_a_tab() {
        compare(VL.firstVisibleView(off()), 0)
        // The report: Stations off, home is Playing.
        compare(VL.firstVisibleView(off(0)), 1)
        compare(VL.firstVisibleView(off(0, 1)), 2)
        compare(VL.firstVisibleView(off(0, 1, 2, 3)), 4)
        compare(VL.firstVisibleView(off(1, 2, 3, 4)), 0)
    }

    function test_the_walk_does_not_depend_on_there_being_five_pages() {
        var many = []
        for (var i = 0; i < 400; i++) many.push(i !== 250)
        compare(VL.nextVisibleView(250, -1, many), 249)
        compare(VL.nextVisibleView(250, 1, many), 251)
        compare(VL.nextVisibleView(1000, 1, many), 399)
        compare(VL.firstVisibleView(many), 0)
        compare(VL.firstVisibleView([true]), 0)
        compare(VL.nextVisibleView(0, -1, [false, true]), 1)
    }

    // The empty station list. Arguments: favourites view, how many are
    // starred, what is typed, whether the directory failed to answer.
    function test_a_favourites_view_with_nothing_starred_asks_for_a_star() {
        compare(VL.emptyList(true, 0, "", false), "favorites")
        // The directory being down changes nothing about having no stars.
        compare(VL.emptyList(true, 0, "", true), "favorites")
    }

    function test_a_search_among_favourites_that_finds_none_is_no_match() {
        // The report: three starred, a search that matches none of them.
        compare(VL.emptyList(true, 3, "zzz", false), "nomatch")
        compare(VL.emptyList(true, 1, "z", false), "nomatch")
        // Typed with nothing starred is still a search.
        compare(VL.emptyList(true, 0, "zzz", false), "nomatch")
    }

    function test_an_unreachable_directory_is_said_in_the_favourites_view_too() {
        compare(VL.emptyList(true, 3, "zzz", true), "unreachable")
        compare(VL.emptyList(true, 0, "zzz", true), "unreachable")
        compare(VL.emptyList(true, 3, "", true), "unreachable")
    }

    function test_starred_names_with_no_rows_left_are_not_called_no_favourites() {
        compare(VL.emptyList(true, 2, "", false), "none")
    }

    function test_the_full_list_says_what_it_always_said() {
        compare(VL.emptyList(false, 0, "", false), "none")
        compare(VL.emptyList(false, 5, "", false), "none")
        compare(VL.emptyList(false, 0, "jazz", false), "nomatch")
        compare(VL.emptyList(false, 5, "jazz", false), "nomatch")
        compare(VL.emptyList(false, 0, "jazz", true), "unreachable")
        compare(VL.emptyList(false, 0, "", true), "unreachable")
    }

    function test_anything_typed_is_a_search() {
        compare(VL.emptyList(true, 0, " ", false), "nomatch")
        compare(VL.emptyList(true, 0, 80, false), "nomatch")
        compare(VL.emptyList(true, 0, new Array(10001).join("x"), false), "nomatch")
        // Nothing readable is nothing typed.
        compare(VL.emptyList(true, 0, null, false), "favorites")
        compare(VL.emptyList(true, 0, undefined, false), "favorites")
        compare(VL.emptyList(false, 0, null, false), "none")
    }

    function test_a_count_nobody_can_read_is_no_favourites() {
        compare(VL.emptyList(true, undefined, "", false), "favorites")
        compare(VL.emptyList(true, null, "", false), "favorites")
        compare(VL.emptyList(true, NaN, "", false), "favorites")
        compare(VL.emptyList(true, -1, "", false), "favorites")
        compare(VL.emptyList(true, "3", "", false), "none")
        compare(VL.emptyList(true, 1e9, "", false), "none")
    }

    function test_only_a_plain_true_is_the_favourites_view_or_a_failure() {
        compare(VL.emptyList("yes", 0, "", false), "none")
        compare(VL.emptyList(1, 0, "", false), "none")
        compare(VL.emptyList(undefined, 0, "", false), "none")
        compare(VL.emptyList(false, 0, "", "true"), "none")
        compare(VL.emptyList(false, 0, "", 1), "none")
    }

    // The chips. What the button then draws is measured in tst_chiplabel.
    function test_an_ampersand_inside_a_word_is_doubled() {
        compare(VL.chipLabel("r&b"), "r&&b")
        compare(VL.chipLabel("at&t"), "at&&t")
        compare(VL.chipLabel("1&1"), "1&&1")
        compare(VL.chipLabel("rock&roll&soul"), "rock&&roll&&soul")
        compare(VL.chipLabel("&b"), "&&b")
    }

    function test_an_ampersand_before_a_space_is_left_to_the_button() {
        compare(VL.chipLabel("drum & bass"), "drum & bass")
        compare(VL.chipLabel("r & b"), "r & b")
        compare(VL.chipLabel("& "), "& ")
        compare(VL.chipLabel("tom&jerry & co"), "tom&&jerry & co")
    }

    function test_ampersands_side_by_side_and_at_the_end_are_doubled() {
        compare(VL.chipLabel("&&"), "&&&&")
        compare(VL.chipLabel("&"), "&&")
        compare(VL.chipLabel("a&"), "a&&")
        compare(VL.chipLabel("r&&b"), "r&&&&b")
        // The second of a pair keeps its space.
        compare(VL.chipLabel("a && b"), "a &&& b")
    }

    function test_a_chip_without_an_ampersand_is_its_own_label() {
        compare(VL.chipLabel("jazz"), "jazz")
        compare(VL.chipLabel("80s"), "80s")
        compare(VL.chipLabel("Soome"), "Soome")
        compare(VL.chipLabel(" "), " ")
    }

    function test_nothing_readable_is_an_empty_label() {
        compare(VL.chipLabel(""), "")
        compare(VL.chipLabel(null), "")
        compare(VL.chipLabel(undefined), "")
        compare(VL.chipLabel(80), "80")
    }

    function test_a_very_long_chip_keeps_every_ampersand() {
        var raw = new Array(5001).join("&x")
        var label = VL.chipLabel(raw)
        compare(label.length, 15000)
        compare(label.substring(0, 6), "&&x&&x")
        compare(label.replace(/&&/g, "&"), raw)
    }

    // A row that is a button, under the keyboard. The row here is a stand-in
    // that counts its clicks; tst_rowkeys presses the keys on real delegates.
    function fakeRow(shown) {
        return { visible: shown, clicks: 0, clicked: function() { this.clicks++ } }
    }
    function press(key, held) {
        return { key: key, isAutoRepeat: held === true, accepted: false }
    }

    function test_return_enter_and_space_each_press_the_row_once() {
        var keys = [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space]
        for (var i = 0; i < keys.length; i++) {
            var row = fakeRow(true)
            var ev = press(keys[i])
            compare(VL.pressRow(ev, row), true)
            compare(row.clicks, 1)
            compare(ev.accepted, true)
        }
    }

    function test_a_key_held_down_presses_the_row_once() {
        // One press, then what the keyboard sends while the key stays down.
        var row = fakeRow(true)
        VL.pressRow(press(Qt.Key_Space), row)
        for (var i = 0; i < 50; i++) {
            var ev = press(Qt.Key_Space, true)
            compare(VL.pressRow(ev, row), true)
            compare(ev.accepted, true, "a repeat left alone reaches the button under the row")
        }
        compare(row.clicks, 1)
        // Let go and press again: that is a second press.
        VL.pressRow(press(Qt.Key_Space), row)
        compare(row.clicks, 2)
    }

    function test_a_row_that_is_not_on_screen_is_not_pressed() {
        var row = fakeRow(false)
        var ev = press(Qt.Key_Return)
        compare(VL.pressRow(ev, row), true)
        compare(row.clicks, 0)
        compare(ev.accepted, true)
        // Only a plain true is a row on screen.
        var odd = [undefined, null, 0, 1, "true"]
        for (var i = 0; i < odd.length; i++) {
            var r = fakeRow(odd[i])
            VL.pressRow(press(Qt.Key_Space), r)
            compare(r.clicks, 0, String(odd[i]))
        }
    }

    function test_any_other_key_is_left_alone() {
        var keys = [Qt.Key_Tab, Qt.Key_Backtab, Qt.Key_Escape, Qt.Key_M, Qt.Key_Up, Qt.Key_Down,
                    Qt.Key_Select, Qt.Key_Shift, 0, -1, undefined, null, "Return"]
        for (var i = 0; i < keys.length; i++) {
            var row = fakeRow(true)
            var ev = press(keys[i])
            compare(VL.pressRow(ev, row), false, String(keys[i]))
            compare(row.clicks, 0)
            compare(ev.accepted, false)
        }
    }

    function test_no_event_or_no_row_is_nothing_to_press() {
        var row = fakeRow(true)
        compare(VL.pressRow(null, row), false)
        compare(VL.pressRow(undefined, row), false)
        compare(VL.pressRow({}, row), false)
        compare(row.clicks, 0)
        var ev = press(Qt.Key_Return)
        compare(VL.pressRow(ev, null), false)
        compare(VL.pressRow(ev, undefined), false)
        compare(VL.pressRow(ev), false)
        compare(ev.accepted, false)
        compare(VL.pressRow(), false)
    }
}
