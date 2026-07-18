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

PlasmaComponents3.ItemDelegate {
    id: listItem

    readonly property int targetIndex: typeof model.originalIndex !== "undefined" ? model.originalIndex : model.index
    // Reordering works on the list the user actually sees — with a search
    // filter active the visible neighbours aren't the real neighbours, so the
    // arrows hide themselves instead of doing something surprising.
    readonly property bool reorderable: root.searchFilter === ""
    readonly property bool isCurrent: lastPlay === listItem.targetIndex && (isPlaying() || root._casting)
    readonly property bool isBuffered: playMusic.mediaStatus === MediaPlayer.BufferedMedia
                                       || playMusic.mediaStatus === MediaPlayer.BufferingMedia
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
                color: listItem.isCurrent
                       ? root.accent
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
                    // Self-healing, two rungs: a corrupted cache file falls
                    // back to the remote URL once — and a REMOTE that errors
                    // too (dead host, moved file, a format nothing decodes)
                    // asks the directory for the station's current logo by
                    // identity, once per session, updating model and config.
                    onStatusChanged: {
                        if (status !== Image.Error) return
                        if (model.favicon
                            && source.toString().indexOf("file://") === 0) {
                            source = model.favicon
                        } else if (source.toString().indexOf("http") === 0) {
                            root.faviconSelfHeal(model.hostname)
                        }
                    }
                }

                PlasmaComponents3.Label {
                    anchors.centerIn: parent
                    text: listItem.targetIndex + 1
                    color: Kirigami.Theme.textColor
                    opacity: 0.7
                    font.pixelSize: Kirigami.Units.gridUnit * 0.75
                    visible: !listItem.hovered && !listItem.isCurrent && !faviconImage.visible
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
                        duration: Math.round(Math.abs(to - from) / Kirigami.Units.gridUnit
                                             * 300 * Plasmoid.configuration.speedfactor)
                        running: listItem.hovered && trackName.contentWidth > trackRect.width
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

        // Reorder arrows: move the station (or, in the favorites view, the
        // favorite) one step up/down. Ctrl+Up/Down does the same via keyboard.
        CircleButton {
            id: moveUpButton
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.6
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.6
            Layout.alignment: Qt.AlignVCenter
            iconName: "go-up"
            iconScale: 0.55
            opacity: (listItem.hovered || listItem.isKeyboardCurrent || activeFocus) ? 0.6 : 0.0
            visible: opacity > 0.0 && listItem.reorderable && model.index > 0
            tooltipText: i18n("Move up")
            onClicked: {
                if (root.favoritesOnly)
                    root.moveFavorite(model.name, -1)
                else
                    root.moveStation(listItem.targetIndex, model.name, model.hostname, -1)
            }

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }
        }

        CircleButton {
            id: moveDownButton
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.6
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.6
            Layout.alignment: Qt.AlignVCenter
            iconName: "go-down"
            iconScale: 0.55
            opacity: (listItem.hovered || listItem.isKeyboardCurrent || activeFocus) ? 0.6 : 0.0
            visible: opacity > 0.0 && listItem.reorderable
                     && listItem.ListView.view
                     && model.index < listItem.ListView.view.count - 1
            tooltipText: i18n("Move down")
            onClicked: {
                if (root.favoritesOnly)
                    root.moveFavorite(model.name, 1)
                else
                    root.moveStation(listItem.targetIndex, model.name, model.hostname, 1)
            }

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }
        }

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
            opacity: armed ? 1.0 : ((listItem.hovered || listItem.isKeyboardCurrent || activeFocus) ? 0.6 : 0.0)
            visible: opacity > 0.0
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
            opacity: listItem.isFav ? 1.0 : ((listItem.hovered || listItem.isKeyboardCurrent || activeFocus) ? 0.85 : 0.0)
            visible: opacity > 0.0
            tooltipText: listItem.isFav ? i18n("Remove from favorites") : i18n("Add to favorites")
            onClicked: root.toggleFavorite(model.name)

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }
        }

        Kirigami.Icon {
            id: speakerIcon
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            Layout.alignment: Qt.AlignVCenter
            source: "audio-volume-high"
            color: root.accent
            visible: listItem.isCurrent && listItem.isBuffered
            opacity: visible ? 0.85 : 0.0

            Behavior on opacity {
                NumberAnimation { duration: Kirigami.Units.shortDuration }
            }
        }
    }

    TapHandler {
        onTapped: listItem._activate()
    }
}
