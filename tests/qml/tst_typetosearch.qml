// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Open-and-type with real key events. The station page sends a printable
// key nobody claimed into the search field, and "/" focuses it. With the
// search row switched off in Appearance both still did, into a field that
// was not on screen: the list was filtered by letters nobody saw, and the
// focus stayed in the hidden field, so Space typed a space and no longer
// stopped the radio. This hosts the same three handlers over a field that
// can be hidden and presses the keys.
import QtQuick
import QtQuick.Controls as QQC2
import QtTest

import "../../package/contents/ui/ViewLogic.js" as ViewLogic

FocusScope {
    id: page
    width: 300
    height: 200
    focus: true

    property bool showSearchRow: true
    property string searchFilter: ""
    property int toggles: 0

    function _inputFocused() { return filterField.activeFocus }

    function typeToSearch(event) {
        var ch = ViewLogic.typedChar(page.showSearchRow !== false,
                                     event.modifiers & (Qt.ControlModifier | Qt.AltModifier), event.text)
        if (ch === "") return false
        filterField.forceActiveFocus()
        filterField.text = filterField.text + ch
        filterField.cursorPosition = filterField.text.length
        return true
    }

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            if (filterField.text !== "") {
                filterField.text = ""
                event.accepted = true
            }
        } else if (event.key === Qt.Key_Space && !_inputFocused()) {
            page.toggles++
            event.accepted = true
        } else if (!_inputFocused() && typeToSearch(event)) {
            event.accepted = true
        }
    }

    Column {
        Row {
            visible: page.showSearchRow !== false
            QQC2.TextField {
                id: filterField
                onTextChanged: page.searchFilter = text
            }
        }
        Item {
            id: stationView
            width: 100
            height: 100
            focus: true
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Slash && page.showSearchRow !== false) {
                    filterField.forceActiveFocus()
                    event.accepted = true
                }
            }
        }
    }

    TestCase {
        name: "TypeToSearch"
        when: windowShown

        function init() {
            page.showSearchRow = true
            filterField.text = ""
            page.toggles = 0
            stationView.forceActiveFocus()
        }

        function test_a_letter_lands_in_the_field_while_the_row_is_shown() {
            keyClick(Qt.Key_J)
            compare(page.searchFilter, "j")
            verify(filterField.activeFocus)
        }

        function test_slash_focuses_the_field_and_is_not_typed() {
            keyClick(Qt.Key_Slash)
            verify(filterField.activeFocus)
            compare(page.searchFilter, "")
        }

        function test_a_letter_with_the_row_hidden_leaves_the_filter_and_the_focus_alone() {
            page.showSearchRow = false
            keyClick(Qt.Key_J)
            compare(page.searchFilter, "")
            verify(!filterField.activeFocus, "the hidden field took the focus")
            verify(stationView.activeFocus)
        }

        function test_slash_with_the_row_hidden_does_nothing() {
            page.showSearchRow = false
            keyClick(Qt.Key_Slash)
            compare(page.searchFilter, "")
            verify(!filterField.activeFocus, "the hidden field took the focus")
            verify(stationView.activeFocus)
        }

        function test_space_stays_play_and_stop_after_letters_with_the_row_hidden() {
            page.showSearchRow = false
            keyClick(Qt.Key_J)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Space)
            compare(page.toggles, 1)
            compare(page.searchFilter, "")
        }

        function test_a_chord_types_nothing() {
            keyClick(Qt.Key_J, Qt.ControlModifier)
            keyClick(Qt.Key_J, Qt.AltModifier)
            compare(page.searchFilter, "")
            verify(stationView.activeFocus)
        }

        function test_space_is_play_and_stop_on_the_list() {
            keyClick(Qt.Key_Space)
            compare(page.toggles, 1)
            compare(page.searchFilter, "")
        }
    }
}
