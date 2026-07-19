/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

RowLayout {
    id: headingRoot

    spacing: Kirigami.Units.smallSpacing

    readonly property bool hasStation: root.currentStation && root.currentStation.length > 0
    readonly property bool hasTrack: root.title && root.title !== Plasmoid.title && root.title.length > 0
    readonly property string primaryText: {
        if (root.view === 2 && !hasStation) return i18n("My Music")
        return hasStation ? root.currentStation : Plasmoid.title
    }
    readonly property string secondaryText: hasTrack ? root.title : ""

    CircleButton {
        id: backButton
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.2
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.2
        Layout.alignment: Qt.AlignVCenter
        iconName: "go-previous"
        iconScale: 0.55
        visible: root.view === 1
        tooltipText: i18n("Back to stations")
        onClicked: root.view = 0
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Kirigami.Units.smallSpacing / 2

        PlasmaComponents3.Label {
            id: primaryLabel
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: headingRoot.primaryText
            // Untrusted (station name / ICY title) — never interpret as HTML
            textFormat: Text.PlainText
            font.weight: Font.Bold
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 4
            font.letterSpacing: 0.4
            elide: Text.ElideRight
            maximumLineCount: 1
            color: Plasmoid.userBackgroundHints === PlasmaCore.Types.ShadowBackground
                   ? Kirigami.Theme.highlightedTextColor
                   : Kirigami.Theme.textColor
        }

        // 2026 signature: emerald-gradient strip below the title
        Rectangle {
            id: accentUnderline
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.min(primaryLabel.contentWidth * 0.7, headingRoot.width * 0.45)
            Layout.preferredHeight: 3
            radius: 1.5
            opacity: 0.95
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.alpha(root.accentTeal, 0.15) }
                GradientStop { position: 0.5; color: root.accentBright }
                GradientStop { position: 1.0; color: Qt.alpha(root.accentTeal, 0.15) }
            }

            // The strip "breathes" while music is playing
            SequentialAnimation on opacity {
                loops: Animation.Infinite
                // longDuration is 0 when animations are disabled system-wide
                running: isPlaying() && root.expanded && Kirigami.Units.longDuration > 0
                NumberAnimation { from: 0.95; to: 0.45; duration: 1400; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.45; to: 0.95; duration: 1400; easing.type: Easing.InOutSine }
                // Speed flipped to Instant mid-cycle: settle on the rest opacity, not mid-breath
                onStopped: accentUnderline.opacity = 0.95
            }
        }

        PlasmaComponents3.Label {
            id: secondaryLabel
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: headingRoot.secondaryText
            // Untrusted (ICY title) — never interpret as HTML
            textFormat: Text.PlainText
            visible: text !== ""
            opacity: 0.85
            font.italic: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
            elide: Text.ElideRight
            maximumLineCount: 1
            color: Plasmoid.userBackgroundHints === PlasmaCore.Types.ShadowBackground
                   ? Kirigami.Theme.highlightedTextColor
                   : Kirigami.Theme.textColor
            transform: Translate { id: secondaryShift; y: 0 }
            // Qualified on purpose: a bare `text` here resolves to the
            // INJECTED signal parameter (deprecated in Qt 6, removal
            // announced), not to this label's property.
            onTextChanged: if (secondaryLabel.text !== "") secondaryReveal.restart()

            // On track change, the new title slides in smoothly
            ParallelAnimation {
                id: secondaryReveal
                NumberAnimation { target: secondaryLabel; property: "opacity"; from: 0; to: 0.85; duration: 380; easing.type: Easing.OutCubic }
                NumberAnimation { target: secondaryShift; property: "y"; from: Kirigami.Units.smallSpacing; to: 0; duration: 380; easing.type: Easing.OutCubic }
            }
        }
    }

    CircleButton {
        id: infoButton
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.2
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.2
        Layout.alignment: Qt.AlignVCenter
        iconName: "view-media-lyrics"
        iconScale: 0.55
        visible: headingRoot.hasStation && root.view === 0
        tooltipText: i18n("Show now playing")
        onClicked: root.view = 1
    }
}
