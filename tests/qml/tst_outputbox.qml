// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The output box over a list that changes under it. Seen on a panel with a
// Bluetooth and a USB speaker: the group of all outputs was switched off and
// on again, the sound and the config came back to the group, and the box
// went on reading "System default output" for more than a minute, with the
// group's row standing in its opened list.
import QtQuick
import QtTest

import "../../package/contents/ui" as Ui

Item {
    id: shell
    width: 320
    height: 200

    readonly property var jbl: ({ id: "bluez_output.jbl", description: "JBL Flip 7" })
    readonly property var usb: ({ id: "alsa_output.usb", description: "USB Audio" })
    readonly property var all: ({ id: "onair_combined_48", description: "All" })

    Ui.OutputBox {
        id: box
        width: 300
        firstRow: "System default output"
    }

    SignalSpy {
        id: chosenSpy
        target: box
        signalName: "chosen"
    }

    TestCase {
        name: "OutputBox"
        when: windowShown

        function init() {
            failOnWarning(/.?/)
            box.wanted = ""
            box.outs = [shell.jbl, shell.usb]
            compare(box.currentIndex, 0)
            chosenSpy.clear()
        }

        function shows(row, text) {
            compare(box.currentIndex, row)
            compare(box.displayText, text)
            compare(box.currentText, text)
        }

        function test_the_box_lists_the_default_and_the_outputs_and_shows_the_configured_one() {
            compare(box.model, ["System default output", "JBL Flip 7", "USB Audio"])
            compare(box.count, 3)
            shows(0, "System default output")
            box.wanted = "alsa_output.usb"
            shows(2, "USB Audio")
            box.wanted = ""
            shows(0, "System default output")
        }

        // The panel's own sequence: the config names the group, and the
        // group joins the list a moment later.
        function test_the_group_named_first_and_listed_after_gets_its_row() {
            box.wanted = "onair_combined_48"
            shows(0, "System default output")
            box.outs = [shell.all, shell.jbl, shell.usb]
            shows(1, "All")
        }

        function test_the_group_listed_first_and_named_after_gets_its_row() {
            box.outs = [shell.all, shell.jbl, shell.usb]
            shows(0, "System default output")
            box.wanted = "onair_combined_48"
            shows(1, "All")
        }

        function test_off_and_on_again_the_groups_row_comes_back_every_time() {
            for (var round = 0; round < 3; round++) {
                box.wanted = "onair_combined_48"
                box.outs = [shell.all, shell.jbl, shell.usb]
                shows(1, "All")
                box.wanted = ""
                box.outs = [shell.jbl, shell.usb]
                shows(0, "System default output")
            }
        }

        // The key stays on the group while a speaker drops out and the group
        // is rebuilt: the list loses the group and gets it back.
        function test_a_configured_output_that_leaves_the_list_and_returns_has_its_row_again() {
            box.wanted = "onair_combined_48"
            box.outs = [shell.all, shell.jbl, shell.usb]
            shows(1, "All")
            box.outs = [shell.jbl, shell.usb]
            shows(0, "System default output")
            box.outs = [shell.all, shell.jbl, shell.usb]
            shows(1, "All")
            box.outs = [shell.usb]
            shows(0, "System default output")
            box.outs = [shell.usb, shell.all]
            shows(2, "All")
        }

        function test_an_output_absent_at_start_gets_its_row_when_it_connects() {
            box.wanted = "bluez_output.late"
            shows(0, "System default output")
            box.outs = [shell.jbl, shell.usb, { id: "bluez_output.late", description: "Late speaker" }]
            shows(3, "Late speaker")
        }

        function test_a_list_that_only_changes_its_order_keeps_the_output_shown() {
            box.wanted = "alsa_output.usb"
            shows(2, "USB Audio")
            box.outs = [shell.usb, shell.jbl]
            shows(1, "USB Audio")
            box.outs = [shell.jbl, shell.usb]
            shows(2, "USB Audio")
        }

        function test_a_list_handed_over_again_unchanged_moves_nothing() {
            box.wanted = "alsa_output.usb"
            box.outs = [shell.jbl, shell.usb]
            shows(2, "USB Audio")
        }

        function test_two_outputs_of_one_description_show_the_one_that_is_configured() {
            box.outs = [{ id: "bluez_output.AA", description: "JBL Flip 7" }, { id: "bluez_output.BB", description: "JBL Flip 7" }]
            box.wanted = "bluez_output.BB"
            compare(box.currentIndex, 2)
            box.wanted = "bluez_output.AA"
            compare(box.currentIndex, 1)
        }

        function test_an_empty_list_leaves_the_default_row_alone() {
            box.wanted = "alsa_output.usb"
            box.outs = []
            compare(box.count, 1)
            shows(0, "System default output")
            box.outs = [shell.usb]
            shows(1, "USB Audio")
        }

        function test_a_list_that_is_no_list_is_shown_as_an_empty_one() {
            box.wanted = "alsa_output.usb"
            box.outs = null
            shows(0, "System default output")
            box.outs = undefined
            compare(box.count, 1)
            box.outs = [shell.jbl, shell.usb]
            shows(2, "USB Audio")
        }

        function test_a_long_list_shows_its_last_output() {
            var many = []
            for (var i = 0; i < 300; i++) many.push({ id: "out" + i, description: "Output " + i })
            box.wanted = "out299"
            box.outs = many
            shows(300, "Output 299")
        }

        // Putting the row right is drawing, nothing more: the choice is the
        // listener's, and only a choice may move the sound.
        function test_a_row_put_right_by_the_list_chooses_nothing() {
            box.wanted = "onair_combined_48"
            box.outs = [shell.all, shell.jbl, shell.usb]
            box.outs = [shell.jbl, shell.usb]
            box.outs = [shell.all, shell.jbl, shell.usb]
            box.wanted = ""
            compare(chosenSpy.count, 0)
        }

        function test_choosing_a_row_names_the_output_standing_in_it_once() {
            box.outs = [shell.all, shell.jbl, shell.usb]
            box.activated(3)
            compare(chosenSpy.count, 1)
            compare(chosenSpy.signalArguments[0][0], "alsa_output.usb")
            box.activated(0)
            compare(chosenSpy.count, 2)
            compare(chosenSpy.signalArguments[1][0], "")
        }

        function test_the_keyboard_chooses_the_next_row_as_the_list_stands() {
            box.outs = [shell.all, shell.jbl, shell.usb]
            box.forceActiveFocus()
            keyClick(Qt.Key_Down)
            compare(chosenSpy.count, 1)
            compare(chosenSpy.signalArguments[0][0], "onair_combined_48")
            compare(box.currentIndex, 1)
        }

        // The click answers for itself: what the box shows afterwards is the
        // config's word, also when the config did not take the choice.
        function test_a_choice_the_config_takes_is_the_row_shown() {
            box.outs = [shell.all, shell.jbl, shell.usb]
            box.forceActiveFocus()
            keyClick(Qt.Key_Down)
            box.wanted = chosenSpy.signalArguments[0][0]
            shows(1, "All")
            box.outs = [shell.jbl, shell.usb]
            shows(0, "System default output")
            box.outs = [shell.all, shell.jbl, shell.usb]
            shows(1, "All")
        }
    }
}
