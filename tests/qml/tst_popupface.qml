// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The popup's seat. Plasma's popup takes its size from the four Layout hints
// of whatever stands as the full representation and hands that item the
// keyboard, so the seat has to pass both on to the face sitting in it.
import QtQuick
import QtQuick.Layouts
import QtTest

import "../../package/contents/ui" as Ui

Item {
    id: shell
    width: 400
    height: 600

    // The seat's placeholder calls i18n(); qmltestrunner has no KLocalizedContext.
    function i18n(s) { return s }

    // What the shell does with a key the representation leaves alone.
    property int escapes: 0
    Keys.onEscapePressed: escapes++

    Component {
        id: seatMaker
        Ui.PopupFace { anchors.fill: parent }
    }

    // A face the size of the real one's contract: four hints, a focus scope,
    // Space taken, Esc left for whoever stands above.
    Component {
        id: faceMaker
        FocusScope {
            property var keys: []
            anchors.fill: parent
            focus: true
            Layout.minimumWidth: 256
            Layout.minimumHeight: 320
            Layout.preferredWidth: 336
            Layout.preferredHeight: 512
            Keys.onPressed: (event) => {
                keys.push(event.key)
                if (event.key === Qt.Key_Space) event.accepted = true
            }
            TextInput {
                objectName: "field"
                width: 100
                height: 20
            }
        }
    }

    Component {
        id: bareMaker
        Item { }
    }

    // A house that only counts: the face is in its window, and each call to
    // bring that window forward is one.
    Component {
        id: countingHouse
        QtObject {
            property Item faceItem: null
            property string seat: "window"
            property int asks: 0
            function wake() { return faceItem }
            function requestActivate() { asks++ }
        }
    }

    // The way main.qml writes it: the face is the seat's own property value
    // and arrives while the seat is still being built.
    Component {
        id: bornTogether
        Ui.PopupFace {
            anchors.fill: parent
            face: Item { anchors.fill: parent; Layout.minimumWidth: 123 }
        }
    }

    TestCase {
        name: "PopupFace"
        when: windowShown

        // A warning is a failure here: the seat is asked for focus with no
        // face in it, and a TypeError there would otherwise pass unseen.
        function init() {
            failOnWarning(/.?/)
            shell.escapes = 0
        }

        function seated() {
            var seat = createTemporaryObject(seatMaker, shell)
            var face = createTemporaryObject(faceMaker, shell)
            seat.face = face
            return seat
        }

        function hints(item) {
            return [item.Layout.minimumWidth, item.Layout.minimumHeight, item.Layout.preferredWidth, item.Layout.preferredHeight]
        }

        function test_the_face_sits_in_the_seat_and_fills_it() {
            var seat = seated()
            compare(seat.face.parent, seat.seat)
            compare(seat.face.width, 400)
            compare(seat.face.height, 600)
            shell.width = 300
            compare(seat.face.width, 300)
            shell.width = 400
        }

        function test_a_face_declared_with_its_seat_is_seated_at_birth() {
            var seat = createTemporaryObject(bornTogether, shell)
            compare(seat.face.parent, seat.seat)
            compare(seat.face.width, 400)
            compare(seat.Layout.minimumWidth, 123)
        }

        function test_the_popup_reads_the_faces_four_hints_off_the_seat() {
            var seat = seated()
            compare(hints(seat), [256, 320, 336, 512])
        }

        // The real floor is measured after the tab bar has built and moves
        // when a tab is switched off: a hint copied once would go stale.
        function test_a_hint_that_moves_later_moves_the_seats() {
            var seat = seated()
            seat.face.Layout.minimumWidth = 310
            seat.face.Layout.preferredHeight = 700
            compare(hints(seat), [310, 320, 336, 700])
        }

        function test_an_empty_seat_asks_for_nothing() {
            var seat = createTemporaryObject(seatMaker, shell)
            compare(hints(seat), [0, 0, -1, -1])
            seat.forceActiveFocus()
            verify(seat.activeFocus)
        }

        function test_a_face_without_hints_reads_as_the_layouts_own_defaults() {
            var seat = createTemporaryObject(seatMaker, shell)
            seat.face = createTemporaryObject(bareMaker, shell)
            compare(seat.face.parent, seat.seat)
            compare(hints(seat), [0, 0, -1, -1])
        }

        function test_a_hint_far_past_any_screen_is_passed_on_as_it_is() {
            var seat = seated()
            seat.face.Layout.minimumWidth = 1000000
            compare(seat.Layout.minimumWidth, 1000000)
        }

        function test_a_face_taken_away_leaves_the_seat_asking_for_nothing() {
            var seat = seated()
            var face = seat.face
            seat.face = null
            compare(hints(seat), [0, 0, -1, -1])
            face.Layout.minimumWidth = 999
            compare(seat.Layout.minimumWidth, 0)
        }

        // The shell calls forceActiveFocus() on the full representation when
        // the popup opens. With the focus left on the seat, Space and the
        // letters went nowhere.
        function test_the_keyboard_handed_to_the_seat_reaches_the_face() {
            var seat = seated()
            seat.forceActiveFocus()
            verify(seat.face.activeFocus)
            keyClick(Qt.Key_Space)
            compare(seat.face.keys, [Qt.Key_Space])
        }

        function test_a_face_seated_under_a_seat_that_has_the_keyboard_gets_it_at_once() {
            var seat = createTemporaryObject(seatMaker, shell)
            seat.forceActiveFocus()
            seat.face = createTemporaryObject(faceMaker, shell)
            verify(seat.face.activeFocus)
        }

        // Something else in the seat held the keyboard last, or the face came
        // back without its focus flag: the next opening still lands on the face.
        function test_a_face_that_lost_the_seats_focus_gets_the_keyboard_all_the_same() {
            var seat = seated()
            seat.face.focus = false
            shell.forceActiveFocus()
            seat.forceActiveFocus()
            verify(seat.face.activeFocus)
            keyClick(Qt.Key_Space)
            compare(seat.face.keys, [Qt.Key_Space])
        }

        // A field the listener was typing in keeps the cursor when the popup
        // is opened again: the seat focuses the face, not the face's top.
        function test_the_field_that_had_the_cursor_inside_the_face_keeps_it() {
            var seat = seated()
            var field = findChild(seat.face, "field")
            field.focus = true
            shell.forceActiveFocus()
            verify(!field.activeFocus)
            seat.forceActiveFocus()
            verify(field.activeFocus)
        }

        // Once, when the popup gets the keyboard. Asked again as it loses it,
        // a pinned popup would call the window back over whatever the
        // listener had just clicked on instead.
        function test_the_window_is_asked_forward_as_the_popup_gets_the_keyboard_and_not_as_it_loses_it() {
            var house = createTemporaryObject(countingHouse, shell)
            var seat = createTemporaryObject(seatMaker, shell, { house: house })
            compare(seat.away, true)
            compare(house.asks, 0)
            seat.forceActiveFocus()
            compare(house.asks, 1)
            shell.forceActiveFocus()
            verify(!seat.activeFocus)
            compare(house.asks, 1)
            seat.forceActiveFocus()
            compare(house.asks, 2)
            house.seat = "popup"
            shell.forceActiveFocus()
            seat.forceActiveFocus()
            compare(house.asks, 2)
        }

        function test_esc_the_face_leaves_alone_goes_on_to_the_shell() {
            var seat = seated()
            seat.forceActiveFocus()
            keyClick(Qt.Key_Escape)
            compare(seat.face.keys, [Qt.Key_Escape])
            compare(shell.escapes, 1)
        }
    }
}
