// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Regression: the popup's navigation tabs must be reachable by Tab yet
// NOT grab keyboard focus on a MOUSE click — otherwise the focused tab
// swallows the global Space play/stop shortcut. The nav bar sets
// focusPolicy: Qt.TabFocus on every TabButton for exactly this reason.
import QtQuick
import QtQuick.Controls as QQC2
import QtTest

FocusScope {
    id: root
    width: 300
    height: 200
    focus: true
    property int spaceCount: 0
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Space) { root.spaceCount++; e.accepted = true }
    }

    QQC2.TabBar {
        id: bar
        QQC2.TabButton { text: "A"; focusPolicy: Qt.TabFocus }
        QQC2.TabButton { text: "B"; focusPolicy: Qt.TabFocus }
    }

    TestCase {
        name: "TabFocus"
        when: windowShown

        function test_a_mouse_click_switches_the_tab_without_stealing_focus() {
            root.forceActiveFocus()
            mouseClick(bar.itemAt(1), 5, 5)
            compare(bar.currentIndex, 1)          // the tab did switch
            verify(!bar.itemAt(1).activeFocus)    // but did not grab focus
            keyClick(Qt.Key_Space)
            compare(root.spaceCount, 1)           // Space reached the ancestor
        }
    }
}
