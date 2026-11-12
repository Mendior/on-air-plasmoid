// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Which row the output box shows for a list of outputs and a configured one.
import QtQuick
import QtTest

import "../../package/contents/ui/OutputLogic.js" as OL

TestCase {
    name: "OutputLogic"

    readonly property var jbl: ({ id: "bluez_output.jbl", description: "JBL Flip 7" })
    readonly property var usb: ({ id: "alsa_output.usb", description: "USB Audio" })
    readonly property var all: ({ id: "onair_combined_48", description: "All" })

    function test_the_first_row_is_the_systems_default_and_the_rest_are_the_outputs_in_their_order() {
        compare(OL.rowNames("System default output", [jbl, usb]), ["System default output", "JBL Flip 7", "USB Audio"])
        compare(OL.rowNames("System default output", [usb, jbl]), ["System default output", "USB Audio", "JBL Flip 7"])
    }

    function test_the_row_shown_is_the_configured_outputs_own() {
        compare(OL.rowFor([jbl, usb], "alsa_output.usb"), 2)
        compare(OL.rowFor([jbl, usb], "bluez_output.jbl"), 1)
        compare(OL.rowFor([jbl, usb], ""), 0)
    }

    // The group of all outputs leaves the list when it is switched off and
    // joins it again, at the head, when it is switched back on.
    function test_a_list_that_loses_the_configured_output_and_gets_it_back() {
        compare(OL.rowFor([all, jbl, usb], "onair_combined_48"), 1)
        compare(OL.rowFor([jbl, usb], "onair_combined_48"), 0)
        compare(OL.rowFor([all, jbl, usb], "onair_combined_48"), 1)
    }

    // A speaker that is switched off at login: the sound follows the default
    // until it connects, and so does the box.
    function test_an_output_absent_at_start_reads_as_the_default_until_it_comes() {
        compare(OL.rowFor([usb], "bluez_output.jbl"), 0)
        compare(OL.rowFor([usb, jbl], "bluez_output.jbl"), 2)
    }

    function test_a_list_that_only_changes_its_order_moves_the_row_with_the_output() {
        compare(OL.rowFor([all, jbl, usb], "alsa_output.usb"), 3)
        compare(OL.rowFor([usb, all, jbl], "alsa_output.usb"), 1)
        compare(OL.rowFor([jbl, usb, all], "alsa_output.usb"), 2)
    }

    // Two speakers of one model read alike. The row goes by the output's id.
    function test_two_outputs_of_one_description_are_told_apart_by_their_id() {
        var one = { id: "bluez_output.AA", description: "JBL Flip 7" }
        var two = { id: "bluez_output.BB", description: "JBL Flip 7" }
        compare(OL.rowNames("Default", [one, two]), ["Default", "JBL Flip 7", "JBL Flip 7"])
        compare(OL.rowFor([one, two], "bluez_output.BB"), 2)
        compare(OL.idAt([one, two], 2), "bluez_output.BB")
        compare(OL.idAt([one, two], 1), "bluez_output.AA")
    }

    function test_an_empty_list_has_the_default_row_alone() {
        compare(OL.rowNames("Default", []), ["Default"])
        compare(OL.rowFor([], "alsa_output.usb"), 0)
        compare(OL.rowFor([], ""), 0)
        compare(OL.idAt([], 0), "")
        compare(OL.idAt([], 1), "")
    }

    function test_a_row_chosen_is_the_output_standing_in_it() {
        compare(OL.idAt([jbl, usb], 0), "")
        compare(OL.idAt([jbl, usb], 1), "bluez_output.jbl")
        compare(OL.idAt([jbl, usb], 2), "alsa_output.usb")
    }

    // The list can shrink between the moment a row is drawn and the click on it.
    function test_a_row_that_is_no_longer_there_chooses_the_default() {
        compare(OL.idAt([jbl], 2), "")
        compare(OL.idAt([jbl, usb], -1), "")
        compare(OL.idAt([jbl, usb], 1.5), "")
        compare(OL.idAt([jbl, usb], NaN), "")
        compare(OL.idAt([jbl, usb], "1"), "")
        compare(OL.idAt([jbl, usb], undefined), "")
    }

    // Qt hands the list over as a sequence, which Array.isArray() denies
    // (measured: "[object V4Sequence]"), and each id as bytes that only
    // String() turns into the name. Both have to count.
    function test_a_list_that_is_not_an_array_and_ids_that_are_not_strings_count_all_the_same() {
        var bytes = function(name) { return { toString: function() { return name } } }
        var seq = { length: 2, 0: { id: bytes("bluez_output.jbl"), description: "JBL Flip 7" },
                    1: { id: bytes("alsa_output.usb"), description: "USB Audio" } }
        compare(OL.rowNames("Default", seq), ["Default", "JBL Flip 7", "USB Audio"])
        compare(OL.rowFor(seq, "alsa_output.usb"), 2)
        compare(OL.idAt(seq, 1), "bluez_output.jbl")
    }

    function test_a_list_that_is_no_list_is_an_empty_one_data() {
        return [{ tag: "nothing", outs: undefined }, { tag: "null", outs: null }, { tag: "a word", outs: "alsa_output.usb" },
                { tag: "a number", outs: 3 }, { tag: "an object without a length", outs: {} },
                { tag: "a length below nothing", outs: { length: -1 } }, { tag: "a length in words", outs: { length: "2" } },
                { tag: "a broken length", outs: { length: 1.5 } }]
    }
    function test_a_list_that_is_no_list_is_an_empty_one(data) {
        compare(OL.rowNames("Default", data.outs), ["Default"])
        compare(OL.rowFor(data.outs, "alsa_output.usb"), 0)
        compare(OL.idAt(data.outs, 1), "")
        compare(OL.idAt(data.outs, 0), "")
        compare(OL.idAt(data.outs, NaN), "")
    }

    function test_an_entry_that_is_no_output_keeps_its_row_and_matches_nothing() {
        var odd = [null, { description: "No id" }, usb, { id: 7, description: 9 }, undefined]
        compare(OL.rowNames("Default", odd), ["Default", "", "No id", "USB Audio", "9", ""])
        compare(OL.rowFor(odd, "alsa_output.usb"), 3)
        compare(OL.rowFor(odd, "7"), 4)
        compare(OL.rowFor(odd, "undefined"), 0)
        // Nothing configured is the default, not the first entry that has no id.
        compare(OL.rowFor(odd, ""), 0)
        compare(OL.rowFor(odd, "null"), 0)
        compare(OL.idAt(odd, 1), "")
        compare(OL.idAt(odd, 2), "")
        compare(OL.idAt(odd, 4), "7")
    }

    function test_a_configured_output_that_is_no_name_reads_as_the_default_data() {
        return [{ tag: "nothing", wanted: undefined }, { tag: "null", wanted: null }, { tag: "a number", wanted: 1 },
                { tag: "an object", wanted: {} }, { tag: "true", wanted: true }]
    }
    function test_a_configured_output_that_is_no_name_reads_as_the_default(data) {
        compare(OL.rowFor([jbl, usb], data.wanted), 0)
    }

    function test_a_thousand_outputs_still_find_the_last_one() {
        var many = []
        for (var i = 0; i < 1000; i++) many.push({ id: "out" + i, description: "Output " + i })
        compare(OL.rowNames("Default", many).length, 1001)
        compare(OL.rowFor(many, "out999"), 1000)
        compare(OL.idAt(many, 1000), "out999")
        compare(OL.rowFor(many, new Array(5000).join("x")), 0)
    }
}
