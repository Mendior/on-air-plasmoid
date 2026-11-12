// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The pill that says how far behind the broadcast the listener is, and the
// two steps beside it: what is shown when, what a press sends, and that the
// keyboard and a screen reader reach both steps.
import QtQuick
import QtTest

import "../../package/contents/ui"

FocusScope {
    id: root
    width: 420
    height: 80
    focus: true

    // What CircleButton reads off the widget's root.
    property color accent: "#3BEE96"
    property color accentTextOn: "#000000"

    function i18n(s) {
        var out = s;
        for (var i = 1; i < arguments.length; i++)
            out = out.replace("%" + i, arguments[i]);
        return out;
    }

    property var steps: []
    property int lives: 0
    // How often the label asked. Kept in an object: a property counted up
    // inside the label's own binding would be a loop.
    property var asked: ({ n: 0 })
    property string behind: "0:42"

    // Where the focus rests between two tests, one Tab before the pill.
    Item {
        id: rest
        activeFocusOnTab: true
    }

    ShiftPill {
        id: pill
        anchors.centerIn: parent
        behindOf: function() { root.asked.n++; return root.behind }
        onLive: root.lives++
        onStep: (ms) => { var s = root.steps.slice(); s.push(ms); root.steps = s }
    }

    TestCase {
        name: "ShiftPill"
        when: windowShown

        function part(name) {
            var found = findChild(pill, name);
            verify(found !== null, name);
            return found;
        }

        // A click lands where the layout has put a button, so the layout is
        // let finish first.
        function shown(shifted, parked, stepReady) {
            pill.shifted = shifted;
            pill.parked = parked;
            pill.stepReady = stepReady;
            waitForRendering(root, 200);
            wait(30);
        }

        function init() {
            // The focus leaves a step before the step is taken away.
            rest.forceActiveFocus();
            pill.open = false;
            root.steps = [];
            root.lives = 0;
            root.behind = "0:42";
            shown(false, false, false);
        }

        function test_nothing_is_shown_without_a_buffer_to_be_behind_in() {
            verify(!pill.visible);
            verify(!part("shiftBack").visible);
            verify(!part("shiftPillBody").visible);
            verify(!part("shiftForward").visible);
        }

        function test_a_live_listener_on_a_sliding_buffer_is_offered_the_step_back_alone() {
            shown(false, false, true);
            verify(pill.visible);
            verify(part("shiftBack").visible);
            verify(!part("shiftPillBody").visible);
            verify(!part("shiftForward").visible);
        }

        function test_a_listener_behind_live_has_the_pill_between_both_steps() {
            shown(true, false, true);
            verify(part("shiftBack").visible);
            verify(part("shiftPillBody").visible);
            verify(part("shiftForward").visible);
            compare(part("shiftPillLabel").text, "0:42 behind live — tap to catch up");
            verify(part("shiftBack").x < part("shiftPillBody").x);
            verify(part("shiftPillBody").x < part("shiftForward").x);
            shown(false, true, true);
            verify(part("shiftForward").visible);
            compare(part("shiftPillLabel").text, "Paused · 0:42 behind live");
        }

        function test_the_single_file_keeps_its_pill_and_has_no_steps() {
            shown(true, false, false);
            verify(pill.visible);
            verify(part("shiftPillBody").visible);
            verify(!part("shiftBack").visible);
            verify(!part("shiftForward").visible);
            shown(false, true, false);
            verify(part("shiftPillBody").visible);
            verify(!part("shiftBack").visible);
        }

        function test_a_press_sends_thirty_seconds_one_way_or_the_other() {
            shown(true, false, true);
            mouseClick(part("shiftBack"));
            compare(root.steps, [-30000]);
            mouseClick(part("shiftForward"));
            compare(root.steps, [-30000, 30000]);
            compare(root.lives, 0);
            mouseClick(part("shiftPillBody"));
            compare(root.lives, 1);
            compare(root.steps.length, 2);
        }

        function test_tab_reaches_back_and_then_forward_and_the_keys_press() {
            shown(true, false, true);
            keyClick(Qt.Key_Tab);
            verify(part("shiftBack").activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.steps, [-30000]);
            keyClick(Qt.Key_Return);
            compare(root.steps, [-30000, -30000]);
            keyClick(Qt.Key_Tab);
            verify(part("shiftForward").activeFocus);
            keyClick(Qt.Key_Enter);
            compare(root.steps, [-30000, -30000, 30000]);
            // A key that is nobody's presses nothing.
            keyClick(Qt.Key_A);
            compare(root.steps.length, 3);
        }

        function test_a_step_that_is_not_shown_takes_no_focus_and_no_press() {
            shown(false, false, true);
            verify(part("shiftBack").activeFocusOnTab);
            verify(!part("shiftForward").activeFocusOnTab);
            keyClick(Qt.Key_Tab);
            verify(part("shiftBack").activeFocus);
            keyClick(Qt.Key_Tab);
            verify(!part("shiftForward").activeFocus);
            shown(true, false, false);
            verify(!part("shiftBack").activeFocusOnTab);
            verify(!part("shiftForward").activeFocusOnTab);
        }

        function test_a_screen_reader_is_told_what_each_step_does() {
            shown(true, false, true);
            compare(part("shiftBack").Accessible.name, "Back 30 seconds");
            compare(part("shiftForward").Accessible.name, "Forward 30 seconds");
            compare(part("shiftBack").Accessible.role, Accessible.Button);
            compare(part("shiftForward").Accessible.role, Accessible.Button);
        }

        function test_the_label_counts_on_while_the_page_is_open() {
            shown(false, true, true);
            pill.open = true;
            compare(part("shiftPillLabel").text, "Paused · 0:42 behind live");
            // Nothing the label is bound to changes here but its own tick.
            root.behind = "0:43";
            tryCompare(part("shiftPillLabel"), "text", "Paused · 0:43 behind live", 3000);
        }

        function test_a_closed_page_asks_for_nothing() {
            shown(false, true, true);
            compare(part("shiftPillLabel").text, "Paused · 0:42 behind live");
            var before = root.asked.n;
            wait(1300);
            compare(root.asked.n, before);
        }

        function test_a_pill_without_a_clock_reads_nought() {
            var bare = Qt.createQmlObject('import "../../package/contents/ui"; ShiftPill { shifted: true }', root);
            compare(findChild(bare, "shiftPillLabel").text, "0:00 behind live — tap to catch up");
            bare.destroy();
        }
    }
}
