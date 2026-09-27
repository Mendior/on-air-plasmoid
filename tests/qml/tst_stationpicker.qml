// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The alarm's station box. Seen in the running widget on 2026-09-21: after
// the station list reloaded the box was empty and "Add" was grey until a
// station was picked again. The list reloads by clear-and-append, and a
// combo answers a clear with index -1 and never picks again on its own.
import QtQuick
import QtTest

import "../../package/contents/ui" as Ui

Item {
    id: harness
    width: 300
    height: 60

    ListModel { id: stations }

    Ui.StationPicker {
        id: picker
        model: stations
    }

    function fill(names) {
        stations.clear()
        for (var i = 0; i < names.length; i++)
            stations.append({ "name": names[i], "hostname": "http://x/" + i })
    }

    TestCase {
        name: "StationPicker"
        when: windowShown

        function init() {
            harness.fill([])
            picker._picked = ""
        }

        function test_a_reload_does_not_leave_the_box_empty() {
            harness.fill(["Alpha", "Beta", "Gamma"])
            compare(picker.currentIndex, 0)
            harness.fill(["Alpha", "Beta", "Gamma"])
            compare(picker.currentIndex, 0)
            compare(picker.currentText, "Alpha")
        }

        function test_the_listeners_pick_survives_a_reload() {
            harness.fill(["Alpha", "Beta", "Gamma"])
            picker.currentIndex = 2
            picker.activated(2)
            harness.fill(["Zulu", "Alpha", "Gamma", "Beta"])   // reordered, one added
            compare(picker.currentText, "Gamma")
            compare(picker.currentIndex, 2)
        }

        function test_a_pick_that_left_the_list_falls_back_to_the_first_row() {
            harness.fill(["Alpha", "Beta", "Gamma"])
            picker.currentIndex = 1
            picker.activated(1)
            harness.fill(["Alpha", "Gamma"])
            compare(picker.currentIndex, 0)
            compare(picker.currentText, "Alpha")
        }

        function test_an_empty_list_is_an_empty_box() {
            harness.fill(["Alpha"])
            harness.fill([])
            compare(picker.currentIndex, -1)
        }
    }
}
