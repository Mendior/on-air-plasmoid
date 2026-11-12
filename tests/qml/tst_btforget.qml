// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// A paired Bluetooth speaker's row in the output menu, walked with Tab. The
// Forget button showed under the pointer only, and a button that is not
// shown is no Tab stop; the speaker's own tick is a check delegate, which
// takes no focus by itself either (focusPolicy 0, measured), so Tab went
// past the whole row and nothing in it could be reached without a mouse.
// This hosts the row the way FullRepresentation.qml wires it, with the real
// CircleButton, inside a popup that closes on Escape like the menu does.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtTest
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "../../package/contents/ui" as Ui

FocusScope {
    // CircleButton reads root.accent and root.accentTextOn.
    id: root
    width: 420
    height: 480
    focus: true

    property color accent: "#6FCF97"
    property color accentTextOn: "#04140B"

    property string _btConnectingMac: ""
    property string _btPairingMac: ""
    property var forgot: []
    property var linked: []
    function btForget(mac) { forgot = forgot.concat([mac]) }
    function btConnect(mac, name) { linked = linked.concat(["+" + mac]) }
    function btDisconnect(mac) { linked = linked.concat(["-" + mac]) }

    ListModel { id: btDevicesModel }

    QQC2.Popup {
        id: castMenu
        x: 10
        y: 10
        width: 380
        modal: false
        closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutsideParent
        focus: true

        contentItem: ColumnLayout {
            QQC2.CheckBox {
                id: above
                text: "above"
            }

            Repeater {
                id: rows
                model: btDevicesModel
                delegate: RowLayout {
                    id: btRow
                    required property string mac
                    required property string name
                    required property bool connected
                    property alias forget: btForgetBtn
                    property alias tick: btRowDelegate
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    // The speaker before its Forget for Tab; laid out from the
                    // right, so Forget still stands at the far left.
                    layoutDirection: Qt.RightToLeft

                    HoverHandler { id: btRowHover }

                    PlasmaComponents3.CheckDelegate {
                        id: btRowDelegate
                        Layout.fillWidth: true
                        focusPolicy: Qt.TabFocus
                        text: btRow.name
                        checked: btRow.connected
                        enabled: root._btConnectingMac === "" && root._btPairingMac === ""
                        onToggled: {
                            var wasConnected = btRow.connected
                            checked = Qt.binding(function() { return btRow.connected })
                            if (wasConnected) root.btDisconnect(btRow.mac)
                            else root.btConnect(btRow.mac, btRow.name)
                        }
                    }

                    Ui.CircleButton {
                        id: btForgetBtn
                        property bool armed: false
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
                        Layout.alignment: Qt.AlignVCenter
                        iconName: armed ? "dialog-warning" : "user-trash"
                        opacity: (btRowHover.hovered || armed || activeFocus || btRowDelegate.activeFocus) ? 0.75 : 0.0
                        visible: (opacity > 0.0 || activeFocus || btRowDelegate.activeFocus) && root._btConnectingMac === ""
                                 && root._btPairingMac === ""
                        onVisibleChanged: if (!visible) armed = false
                        Behavior on opacity {
                            NumberAnimation { duration: Kirigami.Units.shortDuration }
                        }
                        onClicked: {
                            if (!armed) { armed = visible; btForgetDisarm.restart(); return }
                            armed = false
                            root.btForget(btRow.mac)
                        }
                        Timer { id: btForgetDisarm; interval: 3000; onTriggered: btForgetBtn.armed = false }
                    }
                }
            }

            QQC2.CheckBox {
                id: below
                text: "below"
            }
        }
    }

    TestCase {
        name: "BtForget"
        when: windowShown

        readonly property string flip: "AA:BB:CC:00:00:01"
        readonly property string buds: "AA:BB:CC:00:00:02"

        function init() {
            root._btConnectingMac = ""
            root._btPairingMac = ""
            root.forgot = []
            root.linked = []
            btDevicesModel.clear()
            btDevicesModel.append({ "mac": flip, "name": "Flip 7", "connected": false })
            btDevicesModel.append({ "mac": buds, "name": "Buds", "connected": true })
            castMenu.open()
            tryCompare(castMenu, "opened", true)
            // Laid out: a row is as wide as the menu, not as its own text.
            tryVerify(function() { return row(0).width > castMenu.availableWidth - 1 })
            above.forceActiveFocus()
            // The pointer away from the rows: a hover is not what is tested.
            mouseMove(root, 5, root.height - 5)
        }
        function cleanup() {
            castMenu.close()
            tryCompare(castMenu, "visible", false)
        }

        function row(i) { return rows.itemAt(i) }
        function at() {
            var f = root.Window.activeFocusItem
            if (f === above) return "above"
            if (f === below) return "below"
            for (var i = 0; i < rows.count; i++) {
                if (f === row(i).forget) return "forget " + i
                if (f === row(i).tick) return "speaker " + i
            }
            return "elsewhere"
        }
        // A step is done when the button it left has faded out, or the walk
        // would depend on how far a 100 ms fade has come.
        function step(key) {
            keyClick(key)
            for (var i = 0; i < rows.count; i++) {
                var r = row(i)
                var wanted = r.forget.activeFocus || r.tick.activeFocus || r.forget.armed
                tryCompare(r.forget, "visible", wanted, 2000, "row " + i + " after " + at())
            }
            return at()
        }
        function walk(key, steps) {
            var seen = []
            for (var i = 0; i < steps; i++) seen.push(step(key))
            return seen.join(", ")
        }
        // The two walks below go the whole way from the top; the rest start
        // on the speaker, one Tab before its button.
        function tabToForget(i) {
            row(i).tick.forceActiveFocus(Qt.TabFocusReason)
            compare(step(Qt.Key_Tab), "forget " + i, "Tab from the speaker is not on its Forget button")
            return row(i).forget
        }

        function test_tab_stops_on_each_speaker_and_then_on_its_forget() {
            compare(walk(Qt.Key_Tab, 5), "speaker 0, forget 0, speaker 1, forget 1, below")
        }

        function test_shift_tab_comes_back_over_the_speakers() {
            below.forceActiveFocus()
            // A Forget button shows once its speaker has the focus, so on the
            // way back the speaker comes first and its button is one Tab on.
            compare(walk(Qt.Key_Backtab, 3), "speaker 1, speaker 0, above")
            compare(walk(Qt.Key_Tab, 2), "speaker 0, forget 0")
            compare(walk(Qt.Key_Backtab, 2), "speaker 0, above")
        }

        function test_a_quick_second_tab_does_not_run_past_forget() {
            // The button fades in, and one that is shown only once the fade
            // has begun is not there yet for a Tab that follows at once.
            keyClick(Qt.Key_Tab)
            keyClick(Qt.Key_Tab)
            compare(at(), "forget 0")
            // And it is there for a press that follows at once: between the
            // tick losing the focus and the fade's first frame, only the
            // button's own focus shows it.
            verify(row(0).forget.visible, "the button has the focus and is not shown")
            keyClick(Qt.Key_Return)
            compare(row(0).forget.armed, true)
            keyClick(Qt.Key_Tab)
            keyClick(Qt.Key_Tab)
            compare(at(), "forget 1")
            verify(row(1).forget.visible)
        }

        function test_forget_is_shown_for_the_speaker_under_the_focus_only() {
            verify(!row(0).forget.visible)
            verify(!row(1).forget.visible)
            step(Qt.Key_Tab)
            verify(row(0).forget.visible)
            tryCompare(row(0).forget, "opacity", 0.75)
            verify(!row(1).forget.visible)
            // At the far left, as under the pointer, and the tick beside it.
            // The row is laid out again a moment after the button appears.
            tryVerify(function() { return row(0).tick.x > row(0).forget.width })
            verify(row(0).forget.x < 1)
            compare(row(1).tick.x, 0)
            step(Qt.Key_Tab)
            verify(row(0).forget.visible, "the button went away under its own focus")
            step(Qt.Key_Tab)
            verify(!row(0).forget.visible)
            verify(row(1).forget.visible)
        }

        function test_two_presses_forget_and_one_only_asks() {
            var btn = tabToForget(0)
            keyClick(Qt.Key_Return)
            compare(btn.armed, true)
            compare(root.forgot.length, 0)
            keyClick(Qt.Key_Return)
            compare(JSON.stringify(root.forgot), JSON.stringify([flip]))
            compare(btn.armed, false)
            compare(root.linked.length, 0)
        }

        function test_space_and_enter_press_forget_too() {
            var btn = tabToForget(1)
            keyClick(Qt.Key_Space)
            compare(btn.armed, true)
            keyClick(Qt.Key_Enter)
            compare(JSON.stringify(root.forgot), JSON.stringify([buds]))
        }

        function test_a_question_nobody_answers_runs_out() {
            var btn = tabToForget(0)
            keyClick(Qt.Key_Return)
            compare(btn.armed, true)
            tryCompare(btn, "armed", false, 4000)
            verify(btn.visible, "the button left while it still had the focus")
            // The next press asks again.
            keyClick(Qt.Key_Return)
            compare(btn.armed, true)
            compare(root.forgot.length, 0)
        }

        function test_escape_takes_the_question_back() {
            var btn = tabToForget(0)
            keyClick(Qt.Key_Return)
            compare(btn.armed, true)
            keyClick(Qt.Key_Escape)
            tryCompare(castMenu, "visible", false)
            compare(btn.armed, false, "the menu closed on a question that still stands")
            // Opened again inside the three seconds, one press must not forget.
            castMenu.open()
            tryCompare(castMenu, "opened", true)
            btn.forceActiveFocus()
            keyClick(Qt.Key_Return)
            compare(root.forgot.length, 0)
            compare(btn.armed, true)
        }

        function test_a_button_that_is_not_shown_takes_no_press() {
            var btn = tabToForget(0)
            // A speaker starts connecting, from a click elsewhere: every Forget
            // goes, and this one still has the focus (measured on Qt 6.12).
            root._btConnectingMac = buds
            tryCompare(btn, "visible", false)
            verify(btn.activeFocus)
            keyClick(Qt.Key_Return)
            compare(btn.armed, false)
            keyClick(Qt.Key_Return)
            compare(root.forgot.length, 0)
            root._btConnectingMac = ""
            tryCompare(btn, "visible", true)
            compare(btn.armed, false)
        }

        function test_a_question_is_dropped_when_a_speaker_starts_connecting() {
            var btn = tabToForget(0)
            keyClick(Qt.Key_Return)
            compare(btn.armed, true)
            root._btPairingMac = buds
            tryCompare(btn, "visible", false)
            compare(btn.armed, false)
            root._btPairingMac = ""
            tryCompare(btn, "visible", true)
            keyClick(Qt.Key_Return)
            compare(root.forgot.length, 0, "one press after the pause forgot the speaker")
        }

        function test_each_speaker_is_asked_about_by_itself() {
            tabToForget(0)
            keyClick(Qt.Key_Return)
            compare(row(0).forget.armed, true)
            var second = tabToForget(1)
            compare(second.armed, false)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Return)
            compare(JSON.stringify(root.forgot), JSON.stringify([buds]))
        }

        function test_a_speaker_that_drops_its_link_keeps_its_button() {
            var btn = tabToForget(1)
            btDevicesModel.setProperty(1, "connected", false)
            verify(btn.activeFocus)
            verify(btn.visible)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Return)
            compare(JSON.stringify(root.forgot), JSON.stringify([buds]))
        }

        function test_a_speaker_unpaired_elsewhere_takes_its_button_along() {
            tabToForget(1)
            keyClick(Qt.Key_Return)
            btDevicesModel.remove(1)
            compare(rows.count, 1)
            keyClick(Qt.Key_Return)
            compare(root.forgot.length, 0)
            // And the walk goes on over what is left.
            above.forceActiveFocus()
            compare(walk(Qt.Key_Tab, 3), "speaker 0, forget 0, below")
        }

        function test_space_on_the_speaker_connects_it_and_forgets_nothing() {
            step(Qt.Key_Tab)
            compare(at(), "speaker 0")
            keyClick(Qt.Key_Space)
            compare(JSON.stringify(root.linked), JSON.stringify(["+" + flip]))
            compare(root.forgot.length, 0)
            compare(row(0).forget.armed, false)
        }

        function test_other_keys_on_forget_do_nothing() {
            var btn = tabToForget(0)
            keyClick(Qt.Key_M)
            keyClick(Qt.Key_Delete)
            keyClick(Qt.Key_Down)
            compare(btn.armed, false)
            compare(root.forgot.length, 0)
        }

        function test_the_pointer_still_shows_it_and_two_clicks_forget() {
            var r = row(0)
            // Two moves: the first one after a still pointer is not a hover yet.
            mouseMove(r.tick, 40, 10)
            mouseMove(r.tick, 42, 12)
            tryCompare(r.forget, "visible", true)
            tryCompare(r.forget, "opacity", 0.75)
            mouseClick(r.forget, 10, 10)
            compare(r.forget.armed, true)
            compare(root.forgot.length, 0)
            mouseClick(r.forget, 10, 10)
            compare(JSON.stringify(root.forgot), JSON.stringify([flip]))
            compare(root.linked.length, 0, "a click on Forget ticked the speaker too")
        }

        function test_no_paired_speaker_is_nothing_to_stop_on() {
            btDevicesModel.clear()
            compare(walk(Qt.Key_Tab, 1), "below")
            compare(root.forgot.length, 0)
        }

        function test_a_long_name_and_many_speakers_keep_the_button_in_reach() {
            btDevicesModel.clear()
            for (var i = 0; i < 12; i++)
                btDevicesModel.append({ "mac": "AA:BB:CC:00:01:" + (10 + i), "connected": false,
                                        "name": new Array(40).join("Speaker with a long name ") })
            var btn = tabToForget(11)
            tryVerify(function() { return row(11).tick.x > btn.width })
            verify(btn.x < 1)
            compare(btn.width, Kirigami.Units.gridUnit * 1.8)
            verify(row(11).width <= castMenu.availableWidth, "the row grew out of the menu")
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Return)
            compare(JSON.stringify(root.forgot), JSON.stringify(["AA:BB:CC:00:01:21"]))
        }
    }
}
