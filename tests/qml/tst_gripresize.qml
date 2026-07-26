// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The output menu's resize grip. The menu opens UPWARD from a footer
// button, so its grip sits at the top and moves as the menu grows — a
// naive local-coordinate drag then feeds its own movement back and the
// size oscillates (the reported "size jumps up and down"). This pins the
// fix: track the cursor in SCREEN space so a steady drag resizes steadily.
import QtQuick
import QtTest

Item {
    id: root
    width: 240
    height: 640

    property real maxH: 520
    property real minH: 60
    property real userH: 120

    // A panel anchored to the BOTTOM: growing its height moves its top (and
    // the grip) upward — exactly the output menu's geometry.
    Rectangle {
        id: panel
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(root.minH, Math.min(root.maxH, root.userH))
        color: "#333"

        Item {
            id: grip
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 24

            MouseArea {
                id: gripArea
                anchors.fill: parent
                property real _startY: 0
                property real _startH: 0
                onPressed: (m) => {
                    _startY = mapToGlobal(m.x, m.y).y
                    _startH = panel.height
                }
                onPositionChanged: (m) => {
                    if (!pressed) return
                    var dy = mapToGlobal(m.x, m.y).y - _startY   // up = negative
                    root.userH = Math.max(root.minH, Math.min(root.maxH, _startH - dy))
                }
            }
        }
    }

    TestCase {
        name: "GripResize"
        when: windowShown

        function init() { root.userH = 120 }

        function test_a_steady_upward_drag_grows_steadily_never_reversing() {
            var gripTopScene = panel.y   // grip is at the panel's top
            mousePress(root, root.width / 2, gripTopScene + 12)
            var last = panel.height
            var grew = 0
            // Walk the cursor up the SCENE in even steps. Target root with
            // absolute scene y so the grip's own movement can't distort it;
            // the grabbing MouseArea still receives every move.
            for (var sceneY = gripTopScene + 12; sceneY > 120; sceneY -= 20) {
                mouseMove(root, root.width / 2, sceneY)
                // Height must never step DOWN during a pure upward drag —
                // the local-coordinate bug made it yo-yo here.
                verify(panel.height >= last - 0.5)
                if (panel.height > last + 0.5) grew++
                last = panel.height
            }
            mouseRelease(root, root.width / 2, 120)
            // And it actually grew a lot, not a jittery crawl.
            verify(grew >= 3)
            verify(panel.height > 240)
        }

        function test_downward_drag_shrinks_and_clamps_at_the_floor() {
            root.userH = 400
            var gripTopScene = panel.y
            mousePress(root, root.width / 2, gripTopScene + 12)
            for (var sceneY = gripTopScene + 12; sceneY < 620; sceneY += 20)
                mouseMove(root, root.width / 2, sceneY)
            mouseRelease(root, root.width / 2, 619)
            // Dragging down past the bottom clamps at the floor, never below.
            compare(panel.height, root.minH)
        }

        function test_a_still_cursor_holds_the_size_no_oscillation() {
            // The purest reproduction: press, then hold the cursor at ONE
            // fixed scene position across several move events. The menu must
            // not budge. With a local-coordinate drag the grip moving under a
            // still cursor changed its local y and the size crept/yo-yoed.
            root.userH = 200
            var gripTopScene = panel.y
            var holdY = gripTopScene + 12
            mousePress(root, root.width / 2, holdY)
            var h0 = panel.height
            for (var i = 0; i < 6; i++) {
                mouseMove(root, root.width / 2, holdY)
                verify(Math.abs(panel.height - h0) < 1.0)
            }
            mouseRelease(root, root.width / 2, holdY)
        }

        function test_it_never_exceeds_the_ceiling() {
            root.userH = 500
            var gripTopScene = panel.y
            mousePress(root, root.width / 2, gripTopScene + 12)
            // Yank far above the top of the window.
            mouseMove(root, root.width / 2, -400)
            mouseRelease(root, root.width / 2, -400)
            compare(panel.height, root.maxH)
        }
    }
}
