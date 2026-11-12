/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

import "WindowLogic.js" as WindowLogic

// The player in a window of its own: the face's second seat, and the house
// that owns the face. There is one face for the applet's whole life and it is
// moved, never rebuilt. Built again on each move it started the list from the
// top, closed an open menu, asked the directory everything once more and
// left 114 errors in the log over ten round trips; moved, it did none of that.
Window {
    id: playerWindow

    // From main.qml: the face to build, the applet's config, whether Plasma's
    // popup is open, whether the widget stands on the desktop and whether
    // the pointer is on the face.
    property Component face: null
    property var cfg: null
    property bool popupOpen: false
    property bool planar: false
    property bool hovered: false

    // The listener's wish: the face in this window instead of the popup.
    property bool detached: false
    property Item faceItem: null
    readonly property string seat: WindowLogic.seatOf(detached, planar)
    readonly property bool faceShown: WindowLogic.faceShown(popupOpen, visible)
    // Somebody is at the face, which is more than the face being on screen
    // where the seat never closes (WindowLogic.watched has the rule).
    readonly property bool faceWatched: WindowLogic.watched(seat, planar, popupOpen, hovered, active)
    // Somebody has just come to a face that is on screen all day: what was
    // read at the slow rate is up to half a minute old.
    signal arrived()
    readonly property alias windowSeat: seatItem
    readonly property alias backdrop: backdropItem

    // The face is built when a seat first asks for it, as late as Plasma used
    // to build it. This seat owns it, because this seat lives as long as the
    // applet does and the popup's seat is Plasma's to throw away.
    function wake() {
        if (!faceItem && face) faceItem = face.createObject(seatItem);
        return faceItem;
    }

    function _settle() {
        if (seat !== "window") {
            hide();
            return;
        }
        if (wake()) faceItem.parent = seatItem;
        // The size the listener left it at, else the size the face asks for,
        // which is the popup's. The place cannot be remembered: under Wayland
        // a window is never told where it stands.
        width = WindowLogic.sizeFor(cfg ? cfg.windowWidth : 0, minimumWidth, Screen.width,
                                    faceItem ? faceItem.Layout.preferredWidth : 0);
        height = WindowLogic.sizeFor(cfg ? cfg.windowHeight : 0, minimumHeight, Screen.height,
                                     faceItem ? faceItem.Layout.preferredHeight : 0);
        show();
        _focusFace();
    }

    // A face can arrive without its place in the focus order: while it sat
    // in the popup, the placeholder's button may have held the keyboard last.
    // The keyboard then stays on the window's root, where Space, M and typing
    // into the search go nowhere until the face is clicked. So the face is
    // given it at the move and each time the window comes to the front.
    function _focusFace() {
        if (faceItem) faceItem.forceActiveFocus();
    }

    // A Window declared inside an item is a child of that item's window,
    // which here is the panel: it would stay above it and leave with it.
    transientParent: null
    title: "On Air"
    minimumWidth: faceItem ? faceItem.Layout.minimumWidth : 0
    minimumHeight: faceItem ? faceItem.Layout.minimumHeight : 0

    onSeatChanged: _settle()
    onDetachedChanged: if (cfg) cfg.detached = detached
    onActiveChanged: if (active) _focusFace()
    onFaceWatchedChanged: if (faceWatched && WindowLogic.standing(seat, planar)) arrived()
    onWidthChanged: if (visible) sizeKeeper.restart()
    onHeightChanged: if (visible) sizeKeeper.restart()
    // The window is plasmashell's and goes down with it; the key is what
    // brings the face back here after a restart. It is read this once: bound
    // to the key, the wish and the key wrote each other in a loop.
    Component.onCompleted: detached = !!cfg && cfg.detached === true
    // The title bar's close button sends the face home. Nothing is stopped
    // and nothing is lost: the popup has it the next time it opens.
    onClosing: detached = false

    // A drag is dozens of sizes a second and every write of a config key goes
    // to disk, so the size is written once it has come to rest. A maximised
    // window is not remembered: the next plain window would open the size of
    // the screen.
    Timer {
        id: sizeKeeper
        interval: 400
        onTriggered: {
            if (!playerWindow.cfg || playerWindow.visibility !== Window.Windowed) return;
            playerWindow.cfg.windowWidth = playerWindow.width;
            playerWindow.cfg.windowHeight = playerWindow.height;
        }
    }

    // Plasma paints the popup's background and nobody paints a window's: bare,
    // it was white, with a dark scheme's white text on it.
    Rectangle {
        id: backdropItem
        anchors.fill: parent
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
        Kirigami.Theme.inherit: false
        color: Kirigami.Theme.backgroundColor
    }

    Item {
        id: seatItem
        anchors.fill: parent
    }
}
