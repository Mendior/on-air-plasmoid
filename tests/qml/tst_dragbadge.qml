// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// While a station row is dragged its logo gives way to the row's number,
// "because that is the one moment position genuinely matters". The number
// came from targetIndex, which is the place the row had when the list was
// built: the row travelled down the list and went on saying where it had
// started. A drag moves the row in the model at every step, so the place
// it has now is model.index. This hosts the badge's text over a real
// ListView and moves a row the way the drag does.
import QtQuick
import QtTest

Item {
    id: root
    width: 200
    height: 400

    ListModel { id: rows }

    ListView {
        id: view
        anchors.fill: parent
        model: rows
        delegate: Item {
            id: listItem
            width: view.width
            height: 40
            readonly property int targetIndex: typeof model.originalIndex !== "undefined" ? model.originalIndex : model.index
            property alias badge: badgeLabel.text
            QtObject { id: avatar; readonly property string mono: model.mono }
            QtObject { id: dragArea; property bool pressed: false }
            property alias pressed: dragArea.pressed
            Text {
                id: badgeLabel
                readonly property bool reorderHover: dragArea.pressed
                text: reorderHover ? (model.index + 1)
                      : (avatar.mono === "" ? (listItem.targetIndex + 1) : avatar.mono)
            }
        }
    }

    TestCase {
        name: "DragBadge"
        when: windowShown

        function init() {
            rows.clear()
            var names = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]
            for (var i = 0; i < names.length; i++)
                rows.append({ "name": names[i], "originalIndex": i, "mono": names[i].charAt(0) })
            waitForRendering(view)
        }

        function row(name) {
            // A move is laid out a frame later; ask for it now.
            view.forceLayout()
            for (var i = 0; i < rows.count; i++)
                if (rows.get(i).name === name) return view.itemAtIndex(i)
            return null
        }

        function test_a_row_at_rest_shows_its_letter() {
            compare(row("Alpha").badge, "A")
            compare(row("Gamma").badge, "G")
        }

        function test_a_pressed_row_shows_the_place_it_has() {
            row("Gamma").pressed = true
            compare(row("Gamma").badge, "3")
        }

        function test_the_number_follows_the_row_down_the_list() {
            var alpha = row("Alpha")
            alpha.pressed = true
            compare(alpha.badge, "1")
            rows.move(0, 1, 1)
            compare(alpha.badge, "2")
            rows.move(1, 3, 1)
            compare(alpha.badge, "4")
            rows.move(3, 4, 1)
            compare(alpha.badge, "5")
        }

        function test_the_number_follows_the_row_up_to_the_first_place() {
            var eps = row("Epsilon")
            eps.pressed = true
            compare(eps.badge, "5")
            rows.move(4, 0, 1)
            compare(eps.badge, "1")
        }

        function test_a_row_without_a_letter_keeps_its_number_at_rest() {
            rows.setProperty(2, "mono", "")
            compare(row("Gamma").badge, "3")
        }

        function test_the_rows_pushed_aside_keep_their_letters() {
            row("Alpha").pressed = true
            rows.move(0, 2, 1)
            compare(row("Beta").badge, "B")
            compare(row("Gamma").badge, "G")
        }
    }
}
