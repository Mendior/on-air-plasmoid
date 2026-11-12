/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The line on a picture that is not the cover of the song on air: it says
// what the picture is, on the picture itself, so the two are seen together
// or not at all.
//
// Light letters on a dark ground of their own, not the desktop's colours:
// what is under it is a picture of any colour. The ground lets a little of
// the picture through, and a white sleeve is the worst there is; with 0.72
// of black over white the letters still stand at 9.3 to 1.
//
// Three lines at most. A cover with room shows one. The smallest cover the
// Playing page draws leaves the words 69 pixels beside its level bars, and
// "From another release" needs all three there in a wide font (measured in
// DejaVu Sans at 12 pixels: "From another" alone is 80 wide). Cut short it
// would say less than it has to, and the picture under it is a stand-in.
// A longer translation is cut with an ellipsis after the third line, a word
// no line can hold is broken, and whoever places the line gives a screen
// reader the whole text.

import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

Rectangle {
    id: note

    // What to say. "" draws nothing.
    property string text: ""
    // The widest it may be: the picture's width less the margins and
    // whatever else sits on that edge.
    property real room: 0

    readonly property real pad: Kirigami.Units.smallSpacing
    // The tests' way to the words.
    readonly property alias _label: label

    visible: text !== "" && room > pad * 2 + Kirigami.Units.gridUnit
    width: Math.min(room, Math.ceil(label.implicitWidth) + pad * 2)
    height: label.height + pad
    radius: Kirigami.Units.smallSpacing
    color: Qt.rgba(0, 0, 0, 0.72)

    Accessible.role: Accessible.StaticText
    Accessible.name: text

    PlasmaComponents3.Label {
        id: label
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: note.pad
        anchors.rightMargin: note.pad
        text: note.text
        textFormat: Text.PlainText
        color: "white"
        font: Kirigami.Theme.smallFont
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
    }
}
