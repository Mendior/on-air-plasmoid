/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import org.kde.plasma.components as PlasmaComponents3

// The header's corner. Which of its two buttons stand there depends on where
// the face sits: the popup, a window of its own, or inline on the desktop.
// The heading keeps clear of the corner by its width, so a button that is
// not offered takes no room.
Row {
    id: seatButtons

    property bool planar: false
    property bool inWindow: false
    property bool pinned: false
    signal moveAsked()
    signal pinToggled(bool on)

    // To a window of its own and back. Not offered on the desktop, where the
    // face is always in sight and a window cut six pixels off each side of
    // it. A face that is in a window keeps the way back whatever else holds.
    PlasmaComponents3.ToolButton {
        objectName: "windowButton"
        visible: seatButtons.inWindow || !seatButtons.planar
        icon.name: seatButtons.inWindow ? "window-minimize-pip" : "window-new"
        focusPolicy: Qt.TabFocus
        Accessible.name: seatButtons.inWindow ? i18n("Back to the panel") : i18n("Open in its own window")
        onClicked: seatButtons.moveAsked()
        PlasmaComponents3.ToolTip { text: parent.Accessible.name }
    }

    // Pinned, the popup survives clicks elsewhere (the same pattern the
    // folder-view popup uses); the state lives in a config key, so a pinned
    // player is still pinned after a restart. There is no popup to hold open
    // on the desktop, and a window stays up by itself.
    PlasmaComponents3.ToolButton {
        objectName: "pinButton"
        visible: !seatButtons.planar && !seatButtons.inWindow
        icon.name: "window-pin"
        checkable: true
        checked: seatButtons.pinned
        onToggled: seatButtons.pinToggled(checked)
        focusPolicy: Qt.TabFocus
        Accessible.name: i18n("Keep open")
        PlasmaComponents3.ToolTip { text: i18n("Keep open") }
    }
}
