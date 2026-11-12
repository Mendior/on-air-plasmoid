// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The header's corner: the pin that keeps the popup open, and the button that
// sends the face to a window of its own and brings it back.
import QtQuick
import QtTest

import "../../package/contents/ui" as Ui

Item {
    id: shell
    width: 300
    height: 100

    // The buttons' names call i18n(); qmltestrunner has no KLocalizedContext.
    function i18n(s) { return s }

    property int moves: 0
    property var pins: []

    Ui.SeatButtons {
        id: corner
        anchors.top: parent.top
        anchors.right: parent.right
        onMoveAsked: shell.moves++
        onPinToggled: (on) => shell.pins.push(on)
    }

    TestCase {
        name: "SeatButtons"
        when: windowShown

        readonly property Item windowButton: findChild(corner, "windowButton")
        readonly property Item pinButton: findChild(corner, "pinButton")

        function tipOf(button) {
            for (var i = 0; i < button.children.length; i++)
                if (button.children[i].hasOwnProperty("delay") && button.children[i].hasOwnProperty("text")) return button.children[i]
            for (var j = 0; j < button.data.length; j++)
                if (button.data[j].hasOwnProperty("delay") && button.data[j].hasOwnProperty("text")) return button.data[j]
            return null
        }

        function init() {
            failOnWarning(/.?/)
            corner.planar = false
            corner.inWindow = false
            corner.pinned = false
            shell.moves = 0
            shell.pins = []
            // The Row places a button that just came back on its next polish.
            tryCompare(corner, "width", windowButton.width + pinButton.width)
            tryCompare(pinButton, "x", windowButton.width)
        }

        function test_in_the_popup_the_corner_offers_the_window_and_the_pin() {
            verify(windowButton.visible)
            verify(pinButton.visible)
            compare(windowButton.icon.name, "window-new")
            compare(windowButton.Accessible.name, "Open in its own window")
            compare(pinButton.icon.name, "window-pin")
            compare(pinButton.Accessible.name, "Keep open")
            tryCompare(corner, "width", windowButton.width + pinButton.width)
            verify(corner.width > 0)
        }

        // A window stays up by itself: the pin would be a switch for nothing.
        function test_in_the_window_the_corner_offers_the_way_back_and_no_pin() {
            corner.inWindow = true
            verify(windowButton.visible)
            verify(!pinButton.visible)
            compare(windowButton.icon.name, "window-minimize-pip")
            compare(windowButton.Accessible.name, "Back to the panel")
            tryCompare(corner, "width", windowButton.width)
        }

        // The desktop form shows the face inline: no popup to pin, and no
        // window offered. The heading reads the corner's width for its margin.
        function test_on_the_desktop_the_corner_is_empty_and_takes_no_room() {
            corner.planar = true
            verify(!windowButton.visible)
            verify(!pinButton.visible)
            tryCompare(corner, "width", 0)
        }

        // Not a state the widget reaches, but a face that did end up in a
        // window must never be left there without a way back.
        function test_a_face_in_a_window_always_has_the_way_back() {
            corner.planar = true
            corner.inWindow = true
            verify(windowButton.visible)
            verify(!pinButton.visible)
        }

        function test_a_click_on_the_window_button_asks_for_the_move_once() {
            mouseClick(windowButton)
            compare(shell.moves, 1)
            compare(shell.pins, [])
            corner.inWindow = true
            mouseClick(windowButton)
            compare(shell.moves, 2)
        }

        // The pin is drawn from the config key, not from the last click: a
        // popup pinned in the settings of another session shows as pinned.
        function test_the_pin_shows_what_the_config_holds() {
            compare(pinButton.checked, false)
            corner.pinned = true
            compare(pinButton.checked, true)
            corner.pinned = false
            compare(pinButton.checked, false)
        }

        function test_the_pin_reports_each_toggle() {
            mouseClick(pinButton)
            compare(shell.pins, [true])
            compare(shell.moves, 0)
            corner.pinned = true
            mouseClick(pinButton)
            compare(shell.pins, [true, false])
        }

        function test_the_window_button_is_a_button_and_not_a_switch() {
            compare(windowButton.checkable, false)
            mouseClick(windowButton)
            compare(windowButton.checked, false)
        }

        function test_each_button_says_in_a_tooltip_what_its_name_says() {
            compare(tipOf(windowButton).text, "Open in its own window")
            corner.inWindow = true
            compare(tipOf(windowButton).text, "Back to the panel")
            compare(tipOf(pinButton).text, "Keep open")
        }

        // Tab reaches them; a click must not pull the keyboard off the face,
        // where Space is play and stop.
        function test_a_click_leaves_the_keyboard_where_it_was() {
            compare(windowButton.focusPolicy, Qt.TabFocus)
            compare(pinButton.focusPolicy, Qt.TabFocus)
        }
    }
}
