/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtMultimedia
import QtQuick
import QtQuick.Controls as QQC2
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
    required property double sizeBytes
    required property string notes
    required property string image

    // Supplied by the page: file URL under Podcasts/ when downloaded.
    property string localUrl: ""
    // The page owns which row is expanded (one at a time); the row asks it
    // to toggle through this signal.
    property bool expanded: false
    signal detailsToggled()

    readonly property bool hasDetails: notes !== ""
    // The tappable timestamps and links pulled from the sanitized notes —
    // computed only for the open row, so the closed list stays cheap.
    readonly property var noteStamps: expanded ? PodcastLogic.extractTimestamps(notes) : []
    readonly property var noteLinks: expanded ? PodcastLogic.extractLinks(notes) : []

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
        // The download size, but only while it is still a download — once the
        // file is here the size is spent information.
        if (!epItem.downloaded && sizeBytes > 0) parts.push(PodcastLogic.fmtSize(sizeBytes))
        if (resumeSec > 0) parts.push(i18n("%1 left", PodcastLogic.fmtTime(Math.max(0,
            (durationSec > 0 ? durationSec : resumeSec) - resumeSec))))
        return parts.join(" · ")
    }

    width: ListView.view
           ? ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin
           : 0
    readonly property real rowHeight: Kirigami.Units.gridUnit * 3
    height: rowHeight + (expanded && hasDetails
                         ? detailsCol.implicitHeight + Kirigami.Units.smallSpacing : 0)
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

    contentItem: Item {

    RowLayout {
        id: epMainRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: epItem.rowHeight
        spacing: Kirigami.Units.smallSpacing * 1.5
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

        // Show notes toggle — only when the feed carried any.
        CircleButton {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
            Layout.alignment: Qt.AlignVCenter
            visible: epItem.hasDetails && !epItem.isDownloading
            iconName: "documentinfo"
            iconScale: 0.5
            checked: epItem.expanded
            opacity: (epItem.expanded || epItem.hovered || epItem.activeFocus
                      || Kirigami.Settings.tabletMode) ? 0.7 : 0.0
            enabledState: opacity > 0
            tooltipText: epItem.expanded ? i18n("Hide episode notes")
                                         : i18n("Show episode notes")
            onClicked: epItem.detailsToggled()
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

        // Tapping the main row plays/downloads; the details area below has
        // its own taps, so the row's own tap lives here, not on the whole
        // (taller-when-expanded) delegate.
        TapHandler {
            onTapped: epItem.primaryAction()
        }
    }

    // ── Episode notes (expanded) ─────────────────────────────────────────
    // Sanitized plain text, with the timestamps and links pulled out as
    // tappable chips. Feed content never reaches a rich-text sink.
    ColumnLayout {
        id: detailsCol
        anchors.top: epMainRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Kirigami.Units.gridUnit * 2.5
        anchors.rightMargin: Kirigami.Units.smallSpacing * 2
        anchors.topMargin: Kirigami.Units.smallSpacing / 2
        visible: epItem.expanded && epItem.hasDetails
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: epItem.notes
            // Untrusted feed content — PLAIN TEXT ONLY, never rich/styled.
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            opacity: 0.8
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }

        // Tappable chapter timestamps — seek straight into the episode.
        Flow {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: epItem.downloaded && epItem.noteStamps.length > 0
            Repeater {
                model: epItem.noteStamps
                QQC2.Button {
                    required property var modelData
                    text: modelData.label
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    onClicked: {
                        if (!epItem.isThisPlaying)
                            root.playPodcastEpisode(epItem.localUrl, epItem.shownTitle, epItem.epKey)
                        playMusic.position = modelData.sec * 1000
                    }
                }
            }
        }

        // Links from the notes — each opens externally, gated by HostGuard.
        Repeater {
            model: epItem.noteLinks
            PlasmaComponents3.Label {
                required property var modelData
                Layout.fillWidth: true
                text: modelData
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 1
                color: root.accentBright
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openExternalLink(parent.text)
                }
            }
        }
    }
    }
}
