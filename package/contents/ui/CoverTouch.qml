/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What the cover on the Playing page answers to: a small menu with links
// for the artist on air, and a click that shows the picture larger. It lies
// over the cover and draws nothing of the cover itself, except the line
// that says what a picture is when it is not the cover of the song on air.
//
// Neither asks the network for anything. A link is an address handed to the
// listener's browser on the listener's click, and the larger picture is the
// one the page already holds, enlarged to twice its own pixels at most.

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "CoverLogic.js" as CoverLogic
import "MusicLinks.js" as MusicLinks

Item {
    id: touch

    // What the title line parsed to and the station it came from. The
    // artist is what MusicLinks makes of the two; "" offers no menu.
    property string trackArtist: ""
    property string station: ""
    readonly property string artist: MusicLinks.artist(trackArtist, station)
    // The address of the picture the page shows; "" while it shows none.
    property string art: ""
    // What that picture is of, in the artwork engine's word. A picture of
    // the artist and the sleeve of another record of theirs say so on the
    // picture, here and in the larger view; the song's own cover ("track")
    // and whatever else the page shows (a logo, an episode's cover) do not.
    property string kind: ""
    readonly property string note: art === "" ? ""
        : kind === "artist" ? i18nc("on the cover picture: it is a picture of the artist, not the cover of the song", "Artist picture")
        : kind === "release" ? i18nc("on the cover picture: it is the cover of another record by the same artist", "From another release")
        : ""
    // The picture's own size in pixels, as the page's Image read it, and
    // the room the face leaves a larger one. The larger view is offered
    // while it would draw the picture larger than the cover already does
    // (CoverLogic.largerAdds): a station's logo of 32 pixels is not, and
    // then the cover is no button and a click on it does nothing.
    property size natural: Qt.size(0, 0)
    // How many of the screen's pixels one unit of the page is. The tests give their own.
    property real ratio: Screen.devicePixelRatio
    readonly property real roomW: face ? face.width - Kirigami.Units.largeSpacing * 2 : 0
    readonly property real roomH: face ? face.height - Kirigami.Units.largeSpacing * 2 : 0
    readonly property bool largerOffered: art !== ""
        && CoverLogic.largerAdds(natural.width, natural.height, width, height, roomW, roomH, ratio)
    // How much of the picture's lower edge the page keeps for itself on the
    // right (its level bars). The line stays clear of it.
    property real corner: 0
    // The face. The larger picture is laid over it, so it stays inside the
    // popup or the player's window whichever the page sits in.
    property Item face: null
    property color accent: Kirigami.Theme.highlightColor
    // How an address is opened. The tests put their own here.
    property var open: function(address) { Qt.openUrlExternally(address) }

    // The artist the open menu is about, "" while it is shut. Taken when it
    // opens: the next song must not change where an entry that is already
    // on screen leads.
    property string heldArtist: ""
    readonly property bool linksOpen: heldArtist !== ""
    // Whether the picture is shown larger. It follows the cover: no picture
    // on the page, or one the view has nothing to add to, and it shuts.
    property bool larger: false
    onLargerOfferedChanged: if (!largerOffered) larger = false

    // Where the keyboard was when the menu or the larger view opened, to go
    // back to when it shuts. Both take the focus while they are up, for
    // their own keys. They used to hand it to their button afterwards,
    // whoever had opened them: after a click on the menu's button and one
    // more to shut it, Space opened the menu again and the next Space a
    // link in the browser, where the listener had meant to pause (seen on
    // the panel, 2026-11-12). A click moves the keyboard nowhere, so the
    // focus returns to where it was; for someone who came with Tab that is
    // the button they pressed.
    property Item _focusBefore: null

    function _hold() {
        if (!linksOpen && !larger) _focusBefore = touch.Window.activeFocusItem
    }
    // from is what has just shut. While the other one is up it has taken
    // over and nothing goes back yet. A focus that walked on by itself
    // (Tab, a click elsewhere) stays where it went. Otherwise it returns,
    // and where the item it came from is gone or hidden by now, it goes to
    // the face, whose keys the page hears; left on the shut item, which
    // Qt allows, the next key would be spent on closing nothing.
    function _handBack(from) {
        if (linksOpen || larger || !from.activeFocus) return
        var to = _focusBefore
        if (to && to.visible && to.enabled) to.forceActiveFocus()
        else _toFace(from)
    }
    // A face that is a focus scope, as the widget's is, would hand the focus
    // straight back to the item that held it, so that item lets go first.
    function _toFace(from) {
        from.focus = false
        if (face) face.forceActiveFocus()
    }
    onLinksOpenChanged: if (!linksOpen) _handBack(linksPanel)
    onLargerChanged: if (!larger) _handBack(largerView)
    // A button of ours that goes while it holds the focus (the song ended,
    // the next picture is a small logo) hands it to the face the same way.
    function _leave(button) {
        if (!button.visible && button.activeFocus) _toFace(button)
    }

    function openLinks() {
        if (artist === "") return
        _hold()
        heldArtist = artist
        larger = false
        lastfmEntry.forceActiveFocus()
    }
    function closeLinks() {
        heldArtist = ""
    }
    function follow(address) {
        closeLinks()
        if (address !== "") touch.open(address)
    }
    function showLarger() {
        if (!largerOffered) return
        _hold()
        larger = true
        largerView.forceActiveFocus()
    }
    function closeLarger() {
        larger = false
    }

    // The tests' way to what is drawn here.
    readonly property alias _coverButton: coverButton
    readonly property alias _coverArea: coverArea
    readonly property alias _linksButton: linksButton
    readonly property alias _linksPanel: linksPanel
    readonly property alias _heldLabel: heldLabel
    readonly property alias _lastfmEntry: lastfmEntry
    readonly property alias _discogsEntry: discogsEntry
    readonly property alias _largerView: largerView
    readonly property alias _largerImage: largerImage
    readonly property alias _coverNote: coverNote
    readonly property alias _largerNote: largerNote

    // The page was left with something open: it does not wait there for the
    // next visit.
    onVisibleChanged: if (!visible) { heldArtist = ""; larger = false }

    // The cover as a button for the keyboard and a screen reader. It is
    // there while the picture can be shown larger and gone otherwise: a Tab
    // stop that does nothing is worse than none.
    Item {
        id: coverButton
        anchors.fill: parent
        visible: touch.largerOffered
        onVisibleChanged: touch._leave(coverButton)
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: i18n("Show the cover larger")
        Accessible.description: touch.note
        Accessible.onPressAction: touch.showLarger()
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                touch.showLarger()
                event.accepted = true
            } else if (event.key === Qt.Key_Menu && touch.artist !== "") {
                touch.openLinks()
                event.accepted = true
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            radius: Kirigami.Units.smallSpacing * 2 + 2
            color: "transparent"
            border.width: 2
            border.color: touch.accent
            visible: coverButton.activeFocus
        }
    }

    MouseArea {
        id: coverArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: touch.largerOffered && !touch.linksOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: (mouse) => {
            if (touch.linksOpen) touch.closeLinks()
            else if (mouse.button === Qt.RightButton) touch.openLinks()
            else touch.showLarger()
        }
    }

    CoverNote {
        id: coverNote
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Kirigami.Units.smallSpacing * 1.5
        text: touch.note
        room: touch.width - Kirigami.Units.smallSpacing * 3 - touch.corner
    }

    CircleButton {
        id: linksButton
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Kirigami.Units.smallSpacing
        width: Kirigami.Units.gridUnit * 1.6
        height: width
        visible: touch.artist !== "" || touch.linksOpen
        onVisibleChanged: touch._leave(linksButton)
        iconName: "overflow-menu"
        // The button sits on a picture of any colour.
        baseColor: Qt.alpha(Kirigami.Theme.backgroundColor, 0.8)
        hoverColor: Kirigami.Theme.backgroundColor
        tooltipText: i18n("About this music")
        onClicked: touch.linksOpen ? touch.closeLinks() : touch.openLinks()
    }

    FocusScope {
        id: linksPanel
        visible: touch.linksOpen
        anchors.top: linksButton.bottom
        anchors.topMargin: Kirigami.Units.smallSpacing
        anchors.right: parent.right
        anchors.rightMargin: Kirigami.Units.smallSpacing
        width: linksColumn.implicitWidth + Kirigami.Units.smallSpacing * 2
        height: linksColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
        Keys.onEscapePressed: (event) => { touch.closeLinks(); event.accepted = true }
        // Tab walked on, or something else took the focus: the menu shuts
        // and leaves the focus where it went.
        onActiveFocusChanged: if (!activeFocus) touch.heldArtist = ""

        Rectangle {
            anchors.fill: parent
            radius: Kirigami.Units.smallSpacing
            color: Kirigami.Theme.backgroundColor
            border.width: 1
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.2)
        }
        ColumnLayout {
            id: linksColumn
            anchors.centerIn: parent
            spacing: 0

            PlasmaComponents3.Label {
                id: heldLabel
                Layout.fillWidth: true
                Layout.maximumWidth: Kirigami.Units.gridUnit * 11
                Layout.margins: Kirigami.Units.smallSpacing
                text: touch.heldArtist
                font.bold: true
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            PlasmaComponents3.ToolButton {
                id: lastfmEntry
                Layout.fillWidth: true
                text: i18n("Search artist on Last.fm")
                KeyNavigation.down: discogsEntry
                KeyNavigation.up: discogsEntry
                onClicked: touch.follow(MusicLinks.lastfm(touch.heldArtist))
            }
            PlasmaComponents3.ToolButton {
                id: discogsEntry
                Layout.fillWidth: true
                text: i18n("Search artist on Discogs")
                KeyNavigation.down: lastfmEntry
                KeyNavigation.up: lastfmEntry
                onClicked: touch.follow(MusicLinks.discogs(touch.heldArtist))
            }
        }
    }

    // The picture again, and the very one the page holds: the same component
    // with the same address asks for it the same way, and Qt hands both the
    // one decoded copy (measured against a server that counts). The size it
    // is drawn at is CoverLogic.largerScale's, in the picture's own shape.
    Item {
        id: largerView
        parent: touch.face
        anchors.fill: parent
        z: 1000
        visible: touch.larger
        Accessible.role: Accessible.Button
        Accessible.name: i18n("Close the larger cover")
        Accessible.description: touch.note
        Accessible.onPressAction: touch.closeLarger()
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
                touch.closeLarger()
                event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                // The page behind the picture is not walked while it is up.
                event.accepted = true
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.alpha(Kirigami.Theme.backgroundColor, 0.94)
        }
        CoverImage {
            id: largerImage
            readonly property real by: CoverLogic.largerScale(touch.natural.width, touch.natural.height, touch.roomW, touch.roomH, touch.ratio)
            anchors.centerIn: parent
            width: touch.natural.width * by
            height: touch.natural.height * by
            source: touch.larger ? touch.art : ""
        }
        CoverNote {
            id: largerNote
            anchors.left: largerImage.left
            anchors.bottom: largerImage.bottom
            anchors.margins: Kirigami.Units.smallSpacing * 1.5
            text: touch.note
            room: largerImage.width - Kirigami.Units.smallSpacing * 3
        }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            cursorShape: Qt.PointingHandCursor
            onClicked: touch.closeLarger()
            onWheel: (wheel) => { wheel.accepted = true }
        }
    }
}
