// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The record drawn where a station has no cover: that it is drawn at all,
// in the colours it is handed, and again when they change.
import QtQuick
import QtTest

import "../../package/contents/ui"

Item {
    id: root
    width: 200
    height: 200

    VinylDisc {
        id: disc
        anchors.fill: parent
        tintA: "#3BEE96"
        tintB: "#2BB3A3"
        property int paints: 0
        onPainted: paints++
    }

    TestCase {
        name: "VinylDisc"
        when: windowShown

        function test_a_colour_is_spelled_the_way_a_canvas_reads_it() {
            compare(disc.cssRgba(Qt.rgba(1, 0, 0, 1), 0.5), "rgba(255,0,0,0.5)");
            compare(disc.cssRgba(Qt.rgba(0, 0, 0, 1), 0), "rgba(0,0,0,0)");
            compare(disc.cssRgba(Qt.color("#3BEE96"), 0.14), "rgba(59,238,150,0.14)");
        }

        function test_the_record_is_drawn_and_has_a_hole_in_the_middle() {
            tryVerify(function() { return disc.paints > 0; }, 5000);
            var shot = grabImage(disc);
            // The spindle hole, the label ring round it and the record itself.
            compare(shot.pixel(100, 100), Qt.color("#0a0a0a"));
            compare(shot.pixel(100, 80), Qt.color("#1f1f1f"));
            verify(shot.red(100, 20) < 0x40 && shot.green(100, 20) < 0x40 && shot.blue(100, 20) < 0x40);
        }

        function test_a_new_accent_draws_the_record_again() {
            tryVerify(function() { return disc.paints > 0; }, 5000);
            var before = disc.paints;
            disc.tintA = "#ff8800";
            tryVerify(function() { return disc.paints > before; }, 5000);
            before = disc.paints;
            disc.tintB = "#0088ff";
            tryVerify(function() { return disc.paints > before; }, 5000);
        }
    }
}
