// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The bars a row wears while it sounds. Paused, they are the pause sign:
// two bars standing still and the third gone, on every row alike.
import QtQuick
import QtTest

import "../../package/contents/ui" as Ui

Item {
    id: root
    width: 100
    height: 100

    Ui.EqBars {
        id: bars
        bars: 3
        barWidth: 3
        minHeight: 4
        maxHeight: 20
        animating: true
    }

    TestCase {
        name: "EqBars"
        when: windowShown

        // The height each bar is drawn at, left to right.
        function heights() {
            var out = [];
            for (var i = 0; i < bars.children.length; i++) {
                var slot = bars.children[i];
                if (slot.children && slot.children.length === 1 && slot.width === bars.barWidth)
                    out.push(slot.children[0].height);
            }
            return out;
        }

        function init() { bars.paused = false; bars.animating = true; bars.bars = 3 }

        function test_paused_they_are_two_bars_standing_and_one_gone() {
            bars.paused = true
            compare(heights(), [14, 14, 0])
            bars.bars = 4
            compare(heights(), [14, 14, 0, 0])
        }

        function test_paused_bars_do_not_move() {
            bars.paused = true
            var before = bars._t
            wait(300)
            compare(bars._t, before)
            compare(bars._moving, false)
        }

        function test_at_rest_and_not_paused_they_are_the_dots_they_were() {
            bars.animating = false
            compare(heights(), [4, 4, 4])
        }

        function test_playing_they_move_between_their_limits() {
            wait(300)
            verify(bars._t > 0)
            var h = heights()
            compare(h.length, 3)
            for (var i = 0; i < h.length; i++) verify(h[i] >= 4 && h[i] <= 20, "bar " + i + " at " + h[i])
        }

        function test_a_pause_wins_over_a_row_that_says_animate() {
            bars.animating = true; bars.paused = true
            compare(bars._moving, false)
            compare(heights(), [14, 14, 0])
        }

        function test_what_is_not_a_bar_rests() {
            compare(bars.restOf(0), 4)
            bars.paused = true
            compare(bars.restOf(1), 14)
            compare(bars.restOf(2), 0)
            compare(bars.restOf(99999), 0)
            compare(bars.restOf(-1), 14)
            compare(bars.restOf(undefined), 0)
        }
    }
}
