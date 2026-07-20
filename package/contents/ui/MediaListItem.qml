/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtMultimedia
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

import "ReorderLogic.js" as ReorderLogic

PlasmaComponents3.ItemDelegate {
    id: listItem

    readonly property int targetIndex: typeof model.originalIndex !== "undefined" ? model.originalIndex : model.index
    // Reordering works on the list the user actually sees — with a search
    // filter active the visible neighbours aren't the real neighbours, so the
    // arrows hide themselves instead of doing something surprising.
    readonly property bool reorderable: root.searchFilter === ""
    readonly property bool isCurrent: lastPlay === listItem.targetIndex && (isPlaying() || root._casting)
    // Cast-only playback buffers on the device — the idle local player would
    // otherwise leave the current row on an eternal BusyIndicator.
    readonly property bool isBuffered: playMusic.mediaStatus === MediaPlayer.BufferedMedia
                                       || playMusic.mediaStatus === MediaPlayer.BufferingMedia
                                       || (root._casting && !root._castLocalPlay)
    readonly property bool isLoading: listItem.isCurrent && !listItem.isBuffered
    readonly property bool isFav: root.isFavorite(model.name)
    readonly property bool isKeyboardCurrent: ListView.isCurrentItem && ListView.view && ListView.view.activeFocus

    width: ListView.view
           ? ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin
           : 0
    height: Kirigami.Units.gridUnit * 3
    padding: 0
    clip: false
    hoverEnabled: true
    // NOT text: — AbstractButton would parse '&' in station names ("R&B FM")
    // into stray Alt-mnemonic shortcuts; Accessible.name has no side effects.
    Accessible.name: model.name
    Accessible.role: Accessible.Button

    // Play THIS row. The pointer reaches it through the TapHandler below;
    // the keyboard and screen readers reach it here — without this, Space
    // was swallowed by the button with no handler (so the global Space
    // toggle never fired either) and Return bubbled to the ListView, which
    // played currentIndex rather than the focused row.
    function _activate() {
        isError = false
        errorTimer.stop()
        lastPlay = listItem.targetIndex
        refreshServer(listItem.targetIndex)
    }
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space) {
            listItem._activate()
            event.accepted = true
        }
    }
    Accessible.onPressAction: listItem._activate()

    background: Item {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing / 2

        Rectangle {
            id: bgRect
            anchors.fill: parent
            radius: Kirigami.Units.smallSpacing * 1.5
            scale: listItem.hovered && !listItem.isCurrent ? 1.012 : 1.0
            color: {
                if (listItem.isCurrent && listItem.isBuffered)
                    return Qt.alpha(root.accent, 0.15)
                if (listItem.hovered)
                    return Qt.alpha(root.accent, 0.07)
                return Qt.alpha(Kirigami.Theme.textColor, 0.045)
            }
            border.width: 1
            border.color: {
                if (listItem.isCurrent)
                    return Qt.alpha(root.accent, 0.55)
                if (listItem.isKeyboardCurrent)
                    return Qt.alpha(Kirigami.Theme.textColor, 0.3)
                if (listItem.hovered)
                    return Qt.alpha(root.accent, 0.25)
                return Qt.alpha(Kirigami.Theme.textColor, 0.06)
            }

            Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
            Behavior on border.color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

            // Gradient accent strip on the left for the playing station
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: 4
                width: 3
                radius: 1.5
                visible: listItem.isCurrent && listItem.isBuffered
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.alpha(root.accentTeal, 0.3) }
                    GradientStop { position: 0.5; color: root.accentBright }
                    GradientStop { position: 1.0; color: Qt.alpha(root.accentTeal, 0.3) }
                }
            }
        }
    }

    contentItem: RowLayout {
        id: listItemLayout
        spacing: Kirigami.Units.smallSpacing * 1.5
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
        anchors.rightMargin: Kirigami.Units.smallSpacing

        Item {
            id: leadingArea
            Layout.preferredWidth: Kirigami.Units.gridUnit * 2
            Layout.preferredHeight: Kirigami.Units.gridUnit * 2
            Layout.alignment: Qt.AlignVCenter

            Rectangle {
                id: avatar
                anchors.fill: parent
                // 2026: squircle ring — not a full circle
                radius: width * 0.32
                readonly property bool darkTheme: Kirigami.Theme.backgroundColor.hslLightness < 0.5
                readonly property string mono: root.monogramText(model.name)
                // Monogram mode: no decoded logo to show and the name gave
                // usable initials — the avatar wears the station's own
                // deterministic tint instead of the neutral gray.
                readonly property bool monogrammed: !listItem.isCurrent && mono !== ""
                                                    && faviconImage.status !== Image.Ready
                color: listItem.isCurrent
                       ? root.accent
                       : avatar.monogrammed
                         ? Qt.hsla(root.monogramHue(model.name) / 360, 0.45,
                                   avatar.darkTheme ? 0.28 : 0.85, 1)
                         : Qt.alpha(Kirigami.Theme.textColor, 0.1)
                border.width: 1
                border.color: listItem.isCurrent
                              ? Qt.alpha(root.accentBright, 0.6)
                              : Qt.alpha(Kirigami.Theme.textColor, 0.12)
                clip: true
                scale: listItem.hovered ? 1.06 : 1.0

                Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

                Image {
                    id: faviconImage
                    anchors.fill: parent
                    anchors.margins: 1
                    // Decode at display size: a station's 512-pixel logo
                    // otherwise keeps a full-size texture per visible row.
                    sourceSize.width: 64
                    sourceSize.height: 64
                    // Disk-cached copy when available (instant, offline-proof)
                    source: root.faviconSrc(model.favicon)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                    visible: status === Image.Ready && !listItem.hovered && !listItem.isCurrent
                    // Self-healing, two rungs. A corrupted CACHE file goes
                    // through the central _favBroken map, which flips every
                    // faviconSrc binding to the remote URL — an imperative
                    // `source =` here would DESTROY the binding and pin this
                    // delegate off the disk cache for good. A REMOTE that
                    // errors too (dead host, moved file, a format nothing
                    // decodes) asks the directory for the station's current
                    // logo by identity, once per session.
                    onStatusChanged: {
                        if (status !== Image.Error) return
                        if (model.favicon
                            && source.toString().indexOf("file://") === 0) {
                            root.faviconCacheBroken(model.favicon)
                        } else if (source.toString().indexOf("http") === 0) {
                            root.faviconSelfHeal(model.hostname)
                        }
                    }
                }

                // The empty-state face: the station's initials in its own
                // deterministic tint. The row number this replaced only ever
                // appeared on logo-less rows and was already hidden on hover
                // — but while the row is being DRAGGED the number RESURFACES,
                // because that is the one moment position genuinely matters.
                PlasmaComponents3.Label {
                    anchors.centerIn: parent
                    readonly property bool reorderHover: dragArea.pressed
                    text: (reorderHover || avatar.mono === "")
                          ? (listItem.targetIndex + 1) : avatar.mono
                    // Monogram ink serves the number during a drag too —
                    // on-palette and higher-contrast than dimmed textColor
                    // over the tint. On the current row's accent flood the
                    // accent's own text color is the only honest choice.
                    color: listItem.isCurrent ? root.accentTextOn
                           : avatar.monogrammed
                             ? Qt.hsla(root.monogramHue(model.name) / 360,
                                       avatar.darkTheme ? 0.55 : 0.65,
                                       avatar.darkTheme ? 0.82 : 0.25, 1)
                             : Kirigami.Theme.textColor
                    opacity: (avatar.monogrammed || listItem.isCurrent) ? 1.0 : 0.7
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.5
                    // Only a single-letter MONOGRAM gets the big size — the
                    // position numbers stay one size across all rows.
                    font.pixelSize: avatar.height
                                    * (!reorderHover && avatar.mono.length === 1 ? 0.48 : 0.40)
                    visible: reorderHover
                             || (!listItem.isCurrent && !listItem.hovered
                                 && !faviconImage.visible)
                }

                EqBars {
                    anchors.centerIn: parent
                    visible: listItem.isCurrent && listItem.isBuffered && !listItem.hovered
                    animating: visible && root.expanded
                    bars: 3
                    barWidth: 3
                    minHeight: 4
                    maxHeight: avatar.height * 0.55
                    barColor: root.accentTextOn
                }

                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: parent.width * 0.55
                    height: parent.height * 0.55
                    source: {
                        if (listItem.isCurrent && listItem.hovered)
                            return "media-playback-stop"
                        return "media-playback-start"
                    }
                    color: listItem.isCurrent
                           ? root.accentTextOn
                           : Kirigami.Theme.textColor
                    visible: {
                        // While the row is being DRAGGED the position number
                        // takes this slot — not the play/stop affordance, on
                        // the current row included: the row being moved is the
                        // one whose position matters most.
                        if (dragArea.pressed) return false
                        if (listItem.isCurrent && listItem.hovered) return true
                        if (listItem.isCurrent) return false
                        return listItem.hovered && !listItem.isLoading
                    }
                    opacity: visible ? 1.0 : 0.0

                    Behavior on opacity {
                        NumberAnimation { duration: Kirigami.Units.shortDuration }
                    }
                }

                PlasmaComponents3.BusyIndicator {
                    anchors.centerIn: parent
                    width: parent.width * 0.7
                    height: parent.height * 0.7
                    running: visible
                    visible: listItem.isLoading && !listItem.hovered
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Item {
                id: trackRect
                Layout.fillWidth: true
                Layout.preferredHeight: trackName.implicitHeight
                clip: true

                PlasmaComponents3.Label {
                    id: trackName
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    text: model.name
                    // Untrusted (station name) — never interpret as HTML
                    textFormat: Text.PlainText
                    font.weight: listItem.isCurrent && listItem.isBuffered ? Font.DemiBold : Font.Normal
                    color: listItem.isCurrent && listItem.isBuffered
                           ? root.accentBright
                           : Kirigami.Theme.textColor
                    maximumLineCount: 1
                    elide: Text.ElideRight

                    Behavior on color {
                        ColorAnimation { duration: Kirigami.Units.shortDuration }
                    }

                    XAnimator {
                        target: trackName
                        from: 0
                        to: -trackName.contentWidth
                        // Clamped: a corrupt speedfactor must not yield a
                        // zero/negative duration
                        duration: Math.round(Math.abs(to - from) / Kirigami.Units.gridUnit * 300
                                             * Math.max(0.1, Math.min(8, (Plasmoid.configuration.speedfactor || 1))))
                        // longDuration is 0 when animations are disabled system-wide
                        running: listItem.hovered && trackName.contentWidth > trackRect.width
                                 && Kirigami.Units.longDuration > 0
                        loops: 1
                        onFinished: {
                            from = trackRect.width
                            if (listItem.hovered) start()
                        }
                        onStopped: {
                            from = 0
                            trackName.x = 0
                        }
                    }
                }
            }
        }

        // Drag handle: grab and drop the station anywhere in the list — one
        // config write per journey, where the arrows charged one per step.
        // The arrows stay right next to it: they are the keyboard's and the
        // screen reader's road, and some hands simply prefer them.
        Item {
            id: dragHandle
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.6
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.6
            Layout.alignment: Qt.AlignVCenter
            // Always in the layout while reorderable (opacity alone hides):
            // popping in and out of existence shifted the row's content the
            // moment the pointer arrived, so the target moved under it.
            // Tablet mode has no hover — the controls stay revealed there.
            // At rest the handle stays FAINTLY visible (the settings page
            // taught this): an affordance at opacity 0 is a feature nobody
            // finds.
            opacity: (dragArea.pressed || listItem.hovered || listItem.isKeyboardCurrent
                      || Kirigami.Settings.tabletMode) ? 0.75 : 0.3
            visible: listItem.reorderable
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }

            Kirigami.Icon {
                anchors.fill: parent
                anchors.margins: 4
                source: "handle-sort"
                fallback: "transform-move"
            }

            MouseArea {
                id: dragArea
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                // The Flickable must not steal the gesture mid-drag.
                preventStealing: true
                // Identity is captured at PRESS: the live move()s below
                // change model.index as the row travels, and the commit
                // functions verify name+hostname against the config, which
                // stays untouched until the drop.
                property string startName: ""
                property string startHostname: ""
                property int startVis: -1
                onPressed: {
                    const view = listItem.ListView.view
                    if (!view) return
                    startName = model.name
                    startHostname = model.hostname
                    startVis = model.index
                    view.dragActive = true
                }
                onPositionChanged: (mouse) => {
                    const view = listItem.ListView.view
                    if (!view || !view.dragActive) return
                    // Geometry-true targeting: ask the view which row is
                    // under the pointer (the x is this row's own center in
                    // content coordinates — always inside every row) and
                    // MOVE the row there live. The displaced transition
                    // slides the neighbours aside; the row itself rides
                    // its slot under the finger. One config write still
                    // happens only at the drop.
                    const pt = mapToItem(view.contentItem, mouse.x, mouse.y)
                    const target = ReorderLogic.dragTarget(
                        view.indexAt(listItem.x + listItem.width / 2, pt.y),
                        pt.y, view.contentHeight, listItem.height,
                        model.index, view.count)
                    if (target !== model.index && target >= 0 && target < view.count)
                        view.model.move(model.index, target, 1)
                    // Edge autoscroll, so a long list is one gesture too.
                    const vy = mapToItem(view, mouse.x, mouse.y).y
                    if (vy < listItem.height)
                        view.contentY = Math.max(0, view.contentY - Kirigami.Units.gridUnit)
                    else if (vy > view.height - listItem.height)
                        view.contentY = Math.min(Math.max(0, view.contentHeight - view.height),
                                                 view.contentY + Kirigami.Units.gridUnit)
                }
                onReleased: finishDrag(true)
                onCanceled: finishDrag(false)
                // The drop: the view already shows the final order, the
                // config does not know yet. Commit translates the journey
                // into the engine's insert-before contract; a cancelled
                // gesture — or a commit the engine refused because the
                // config changed underneath — walks the live moves back,
                // so the view never lies about what is stored.
                function finishDrag(commit) {
                    const view = listItem.ListView.view
                    if (!view || !view.dragActive) return
                    view.dragActive = false
                    const from = startVis
                    startVis = -1
                    const final = model.index
                    if (from < 0 || final === from) return
                    var ok = false
                    if (commit) {
                        ok = root.favoritesOnly
                             ? root.moveFavoriteTo(startName,
                                                   ReorderLogic.commitSlot(from, final))
                             : root.moveStationTo(from, startName, startHostname,
                                                  ReorderLogic.commitSlot(from, final))
                    }
                    if (!ok) view.model.move(final, from, 1)
                }
            }
        }

        // The reorder arrows retired: the live drag handle (and Ctrl+Up/Down
        // for the keyboard) do the job, and the two extra hover-slots were
        // exactly what knocked the row's controls out of column alignment.

        // Trash button: remove station — two-step confirmation (red = "are you sure?")
        CircleButton {
            id: removeButton
            property bool armed: false
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter
            iconName: "edit-delete"
            iconScale: 0.55
            // Not checkable: two-step confirm button; armed is a visual state,
            // not checkbox semantics.
            checked: armed
            checkedColor: "#E0463C"
            checkedIconColor: "#FFFFFF"
            // Keyboard-current row (or own focus) reveals the button too —
            // visible:false items are skipped by Tab and screen readers
            opacity: armed ? 1.0 : ((listItem.hovered || listItem.isKeyboardCurrent || activeFocus
                                     || Kirigami.Settings.tabletMode) ? 0.6 : 0.0)
            visible: true            // reserved slot — see the arrows above
            enabledState: opacity > 0
            tooltipText: armed
                         ? i18n("Click again to confirm removal")
                         : i18n("Remove station from list")
            onClicked: {
                if (!armed) {
                    armed = true
                    disarmTimer.restart()
                } else {
                    armed = false
                    // targetIndex (= originalIndex), NOT the delegate's filtered-list
                    // index — with a search filter active they point at different rows
                    root.removeStation(listItem.targetIndex, model.name, model.hostname)
                }
            }

            Timer {
                id: disarmTimer
                interval: 2500
                repeat: false
                onTriggered: removeButton.armed = false
            }

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }
        }

        CircleButton {
            id: favButton
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter
            iconName: listItem.isFav ? "favorite" : "non-starred-symbolic"
            iconScale: 0.55
            checkable: true
            checked: listItem.isFav
            opacity: listItem.isFav ? 1.0 : ((listItem.hovered || listItem.isKeyboardCurrent || activeFocus
                                              || Kirigami.Settings.tabletMode) ? 0.85 : 0.0)
            // Slot ALWAYS reserved (opacity hides, not visibility) — a
            // collapsing star column was what left the drag handle and the
            // buttons at different x on favourite vs plain rows.
            visible: true
            enabledState: opacity > 0
            tooltipText: listItem.isFav ? i18n("Remove from favorites") : i18n("Add to favorites")
            onClicked: root.toggleFavorite(model.name)

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }
        }

        // Grab the current track — only on the row that is actually playing,
        // where "the song that's on" exists. It saves a trip to the Playing
        // tab: hear something you like in the list, download it right here.
        // The slot is reserved on every row (opacity gates it) so the columns
        // stay aligned; it took the old always-collapsing speaker icon's place
        // (the avatar's bars already show which row is live).
        CircleButton {
            id: grabButton
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter
            readonly property bool hasTrack: root.trackTitle !== ""
                || (root.title !== Plasmoid.title && root.title !== "")
            iconName: root.downloading ? "view-refresh" : "download"
            iconScale: 0.55
            checked: root.downloading
            checkedColor: root.accent
            checkedIconColor: root.accentTextOn
            opacity: (listItem.isCurrent && listItem.isBuffered) ? 0.9 : 0.0
            visible: true
            enabledState: opacity > 0 && !root.downloading && grabButton.hasTrack
            tooltipText: root.downloading
                         ? i18n("Downloading…")
                         : grabButton.hasTrack
                           ? i18n("Download this track (for offline listening)")
                           : i18n("Waiting for track info…")
            onClicked: root.downloadCurrentTrack()

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }
        }
    }

    TapHandler {
        onTapped: listItem._activate()
    }

    // While dragged, the row rides its slot live under the finger — a
    // slight lift over the neighbours is all the indication needed; the
    // 2 px insertion line and the dimmed ghost this replaced asked the
    // eye to map an abstract marker to a future position.
    z: dragArea.pressed ? 2 : 0
    scale: dragArea.pressed ? 1.02 : 1.0
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
}
