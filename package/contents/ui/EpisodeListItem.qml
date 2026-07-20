/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtMultimedia
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid

import "PodcastLogic.js" as PodcastLogic

// One podcast episode row: title, date · duration · resume badge, and a
// single honest primary action — play/stop when the file is here,
// download when it is not. Modeled on MediaListItem, without the parts
// an episode has no use for (reorder, favorites, liveness).
PlasmaComponents3.ItemDelegate {
    id: epItem

    // Explicit per-role declarations — a `required property var model`
    // (or a role named "model") shadows the delegate's model object and
    // rows render blank; the 2026.8 cast menu paid for that lesson.
    required property int index
    required property string title
    required property string url
    required property string guid
    required property double pubMs
    required property int durationSec

    // Supplied by the page: file URL under Podcasts/ when downloaded.
    property string localUrl: ""

    readonly property string epKey: PodcastLogic.episodeKey(guid, url)
    readonly property bool downloaded: localUrl !== ""
    readonly property bool isThisPlaying: downloaded && isPlaying()
                                          && playMusic.source.toString() === localUrl
    readonly property bool isDownloading: root._podDownloadKey === epItem.epKey
    // The maps are mutated in place; the rev ticks are their change signals.
    readonly property int resumeSec: { root._podPosRev; return root.podcastPositionSec(epKey) }
    readonly property bool played: { root._podPlayedRev; return root.isEpisodePlayed(epKey) }
    readonly property string shownTitle: title !== "" ? title : i18n("Episode")

    readonly property string metaLine: {
        var parts = []
        if (pubMs > 0) {
            var d = new Date(pubMs)
            parts.push(d.getDate() + "." + (d.getMonth() + 1) + "." + d.getFullYear())
        }
        if (durationSec > 0) parts.push(PodcastLogic.fmtTime(durationSec))
        if (resumeSec > 0) parts.push(i18n("%1 left", PodcastLogic.fmtTime(Math.max(0,
            (durationSec > 0 ? durationSec : resumeSec) - resumeSec))))
        return parts.join(" · ")
    }

    width: ListView.view
           ? ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin
           : 0
    height: Kirigami.Units.gridUnit * 3
    padding: 0
    hoverEnabled: true
    Accessible.name: shownTitle
    Accessible.role: Accessible.Button

    function primaryAction() {
        if (epItem.downloaded)
            root.playPodcastEpisode(epItem.localUrl, epItem.shownTitle, epItem.epKey)
        else if (!epItem.isDownloading)
            root.downloadEpisode(epItem.shownTitle, epItem.url, epItem.guid)
    }

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space) {
            epItem.primaryAction()
            event.accepted = true
        }
    }
    Accessible.onPressAction: epItem.primaryAction()

    background: Item {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing / 2

        Rectangle {
            anchors.fill: parent
            radius: Kirigami.Units.smallSpacing * 1.5
            color: {
                if (epItem.isThisPlaying) return Qt.alpha(root.accent, 0.15)
                if (epItem.hovered) return Qt.alpha(root.accent, 0.07)
                return Qt.alpha(Kirigami.Theme.textColor, 0.045)
            }
            border.width: 1
            border.color: epItem.isThisPlaying
                          ? Qt.alpha(root.accent, 0.55)
                          : epItem.hovered ? Qt.alpha(root.accent, 0.25)
                                           : Qt.alpha(Kirigami.Theme.textColor, 0.06)
            Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
        }
    }

    contentItem: RowLayout {
        spacing: Kirigami.Units.smallSpacing * 1.5
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
        anchors.rightMargin: Kirigami.Units.smallSpacing

        Item {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter

            EqBars {
                anchors.centerIn: parent
                visible: epItem.isThisPlaying
                animating: visible && root.expanded
                bars: 3
                barWidth: 3
                minHeight: 4
                maxHeight: parent.height * 0.6
                barColor: root.accent
            }
            Kirigami.Icon {
                anchors.fill: parent
                anchors.margins: 2
                visible: !epItem.isThisPlaying
                source: epItem.downloaded ? "media-playback-start"
                                          : "application-rss+xml"
                opacity: epItem.downloaded ? 0.85 : 0.45
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: epItem.shownTitle
                // Untrusted (feed content) — never interpret as HTML
                textFormat: Text.PlainText
                font.weight: epItem.isThisPlaying ? Font.DemiBold : Font.Normal
                // A played episode dims, so the unheard ones stand out.
                color: epItem.isThisPlaying ? root.accentBright : Kirigami.Theme.textColor
                opacity: epItem.played && !epItem.isThisPlaying ? 0.55 : 1.0
                elide: Text.ElideRight
                maximumLineCount: 1
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: epItem.metaLine
                textFormat: Text.PlainText
                visible: text !== ""
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }

        // A quiet status mark before the meta is read: a check when heard,
        // a dot when half-listened.
        Kirigami.Icon {
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            Layout.alignment: Qt.AlignVCenter
            source: "checkmark"
            color: Kirigami.Theme.textColor
            opacity: 0.45
            visible: epItem.played && !epItem.isThisPlaying
        }
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: Kirigami.Units.smallSpacing * 1.5
            height: width
            radius: width / 2
            color: root.accent
            visible: epItem.resumeSec > 0 && !epItem.played && !epItem.isThisPlaying
            opacity: 0.8
        }

        // Mark heard / unheard — a hover toggle so catching up needs no menu.
        CircleButton {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter
            iconName: epItem.played ? "edit-undo" : "checkmark"
            iconScale: 0.5
            opacity: (epItem.hovered || epItem.activeFocus
                      || Kirigami.Settings.tabletMode) ? 0.7 : 0.0
            enabledState: opacity > 0
            visible: !epItem.isDownloading
            tooltipText: epItem.played ? i18n("Mark as unplayed")
                                       : i18n("Mark as played")
            onClicked: root.toggleEpisodePlayed(epItem.epKey)
        }

        PlasmaComponents3.BusyIndicator {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter
            running: visible
            visible: epItem.isDownloading
        }

        CircleButton {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter
            visible: !epItem.isDownloading
            iconName: {
                if (epItem.isThisPlaying) return "media-playback-stop"
                if (epItem.downloaded) return "media-playback-start"
                return "download"
            }
            iconScale: 0.55
            opacity: (epItem.downloaded || epItem.hovered || epItem.activeFocus
                      || Kirigami.Settings.tabletMode) ? 0.85 : 0.4
            tooltipText: {
                if (epItem.isThisPlaying) return i18n("Stop")
                if (epItem.downloaded)
                    return epItem.resumeSec > 0
                           ? i18n("Resume from %1", PodcastLogic.fmtTime(epItem.resumeSec))
                           : i18n("Play episode")
                return i18n("Download episode for offline listening")
            }
            onClicked: epItem.primaryAction()
        }
    }

    TapHandler {
        onTapped: epItem.primaryAction()
    }
}
