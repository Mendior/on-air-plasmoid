// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The round button's tooltip. It is drawn inside the window the button is
// in, because a tooltip that is a window of its own was placed by the
// button's position inside its window, read as a place on the screen: in
// the player's own window the Stop button at (800, 686) got its tip at
// (162, 473).
import QtQuick
import QtQuick.Templates as T
import QtTest

import "../../package/contents/ui" as Ui

Item {
    id: root
    width: 300
    height: 200

    // What the button reads off main.qml.
    property color accent: "#3BEE96"
    property color accentTextOn: "#000000"

    Ui.CircleButton {
        id: button
        x: 120
        y: 100
        tooltipText: "Stop"
    }

    Ui.CircleButton {
        id: mute
        x: 20
        y: 100
    }

    TestCase {
        name: "ButtonTip"
        when: windowShown

        function tipOf(b) {
            for (var i = 0; i < b.data.length; i++)
                if (b.data[i] instanceof T.ToolTip) return b.data[i]
            return null
        }

        function init() {
            failOnWarning(/.?/)
            button.tooltipText = "Stop"
            button.enabledState = true
            mouseMove(root, 5, 5)
            tryCompare(button, "pointed", false)
        }

        function test_the_tip_is_a_part_of_the_buttons_own_window() {
            var tip = tipOf(button)
            verify(tip !== null)
            compare(tip.parent, button)
            compare(tip.text, "Stop")
            compare(tip.visible, false)
        }

        function test_the_tip_comes_up_over_the_button_the_pointer_rests_on() {
            var tip = tipOf(button)
            mouseMove(button, button.width / 2, button.height / 2)
            compare(button.pointed, true)
            tryCompare(tip, "opened", true)
            // Centred on the button and above it, in the button's own coordinates.
            fuzzyCompare(tip.x, (button.width - tip.width) / 2, 1)
            verify(tip.y + tip.height <= 0)
            mouseMove(root, 5, 5)
            compare(button.pointed, false)
            tryCompare(tip, "visible", false)
        }

        function test_the_tip_waits_the_systems_delay_and_does_not_flash_under_a_passing_pointer() {
            var tip = tipOf(button)
            verify(tip.delay > 0)
            mouseMove(button, button.width / 2, button.height / 2)
            compare(tip.opened, false)
            mouseMove(root, 5, 5)
            wait(tip.delay + 100)
            compare(tip.opened, false)
        }

        function test_a_button_with_nothing_to_say_shows_no_tip() {
            var tip = tipOf(mute)
            mouseMove(mute, mute.width / 2, mute.height / 2)
            compare(mute.pointed, true)
            wait(tip.delay + 200)
            compare(tip.visible, false)
            button.tooltipText = ""
            mouseMove(button, button.width / 2, button.height / 2)
            wait(tipOf(button).delay + 200)
            compare(tipOf(button).visible, false)
        }

        // A button that cannot be pressed still says what it is, and the tip
        // is often the only place that says why it cannot.
        function test_a_button_that_is_switched_off_still_shows_its_tip() {
            button.enabledState = false
            mouseMove(button, button.width / 2, button.height / 2)
            compare(button.pointed, true)
            compare(button.hovered, false)
            tryCompare(tipOf(button), "opened", true)
        }

        function test_a_new_text_under_the_pointer_is_the_text_shown() {
            mouseMove(button, button.width / 2, button.height / 2)
            tryCompare(tipOf(button), "opened", true)
            button.tooltipText = "Play"
            compare(tipOf(button).text, "Play")
            compare(tipOf(button).visible, true)
        }

        function test_a_text_longer_than_a_line_is_wrapped_and_not_cut() {
            var words = new Array(60).join("a very long reason ")
            button.tooltipText = words
            compare(tipOf(button).text, words)
            mouseMove(button, button.width / 2, button.height / 2)
            tryCompare(tipOf(button), "opened", true)
            verify(tipOf(button).width < root.width * 2)
        }
    }
}
