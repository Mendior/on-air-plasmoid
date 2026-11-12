/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.extras as PlasmaExtras

// The popup's seat for the player's face. Plasma owns the item it is given
// as the full representation: it parents it into its popup, sizes the popup
// by the item's four Layout hints and calls forceActiveFocus() on it when
// the popup opens. The seat takes that treatment and passes it on.
FocusScope {
    id: popupFace

    // The house (PlayerWindow) builds the face and says which seat has it.
    // Without one the seat holds whatever face it is handed.
    property var house: null
    property Item face: house ? house.faceItem : null
    readonly property bool away: !!house && house.seat === "window"
    readonly property alias seat: seatItem

    // No face reads as the Layout's own defaults, so an empty seat asks the
    // popup for nothing instead of for a size somebody made up here. They
    // follow the face while it is away too: the popup keeps its size.
    Layout.minimumWidth: face ? face.Layout.minimumWidth : 0
    Layout.minimumHeight: face ? face.Layout.minimumHeight : 0
    Layout.preferredWidth: face ? face.Layout.preferredWidth : -1
    Layout.preferredHeight: face ? face.Layout.preferredHeight : -1

    // The face is a focus scope of its own, so this lands on the field that
    // had the cursor inside it, not on its top. Left on the seat, the
    // keyboard reached nothing: Space, M and typing into the search were dead.
    function _handOver() {
        if (!face || away) return;
        face.parent = seatItem;
        if (activeFocus) face.forceActiveFocus();
    }
    onFaceChanged: _handOver()
    onAwayChanged: _handOver()
    // The popup cannot be told to stay shut: the panel icon and the shortcut
    // open it whatever the widget wants. So an opened popup that finds its
    // face away asks for the window, which makes the icon the way to a
    // window lost under other windows. It asks when the popup has the
    // keyboard and not when it opens: asked as the popup opened, the window
    // stayed behind under KWin 6.8; asked once the popup had the keyboard,
    // it came forward and an unpinned popup closed by itself.
    onActiveFocusChanged: {
        _handOver();
        if (activeFocus && away) house.requestActivate();
    }
    Component.onCompleted: if (house) house.wake()

    Item {
        id: seatItem
        anchors.fill: parent
    }

    // Where the window could not be brought forward, or the popup is pinned
    // open, the popup says where the face is and offers the way back. It
    // says where the player is and not what it does: this is shown on the
    // seat's word alone, over a player that may be paused or stopped.
    PlasmaExtras.PlaceholderMessage {
        objectName: "awayNote"
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 4
        visible: popupFace.away
        iconName: "window-duplicate"
        text: i18n("The player is open in its own window")
        helpfulAction: Kirigami.Action {
            icon.name: "window-minimize-pip"
            text: i18n("Bring it back")
            onTriggered: popupFace.house.detached = false
        }
    }
}
