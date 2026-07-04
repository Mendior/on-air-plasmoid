/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore

Item {
    id: circleRoot

    property string iconName: ""
    property color baseColor: "transparent"
    property color hoverColor: Qt.alpha(Kirigami.Theme.textColor, 0.12)
    property color iconColor: Kirigami.Theme.textColor
    property real iconScale: 0.5
    property bool primary: false
    property bool enabledState: true
    property bool checked: false
    property color checkedColor: root.accent
    property color checkedIconColor: root.accentTextOn
    property string tooltipText: ""
    // 2026: pehme pulseeriv rõngas (nt play-nupp mängimise ajal)
    property bool glowPulse: false

    signal clicked()

    opacity: enabledState ? 1.0 : 0.4
    scale: pressArea.pressed && enabledState ? 0.92 : (pressArea.containsMouse && enabledState ? 1.04 : 1.0)

    Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }

    implicitWidth: Kirigami.Units.gridUnit * 2.2
    implicitHeight: implicitWidth

    // Pulseeriv "hingamise" rõngas — käivitub glowPulse'iga
    Rectangle {
        id: pulseRing
        anchors.centerIn: parent
        width: parent.width
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 2
        border.color: Qt.alpha(circleRoot.checkedColor, 0.75)
        visible: circleRoot.glowPulse
        opacity: 0

        ParallelAnimation {
            running: circleRoot.glowPulse
            loops: Animation.Infinite
            NumberAnimation { target: pulseRing; property: "scale"; from: 1.0; to: 1.38; duration: 1900; easing.type: Easing.OutQuad }
            NumberAnimation { target: pulseRing; property: "opacity"; from: 0.6; to: 0; duration: 1900; easing.type: Easing.OutQuad }
        }
    }

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: width / 2
        color: {
            if (circleRoot.primary) return circleRoot.checkedColor
            if (circleRoot.checked) return circleRoot.checkedColor
            if (pressArea.containsMouse) return circleRoot.hoverColor
            return circleRoot.baseColor
        }

        Behavior on color {
            ColorAnimation { duration: Kirigami.Units.shortDuration }
        }
    }

    Rectangle {
        anchors.fill: bg
        radius: bg.radius
        color: pressArea.containsMouse && (circleRoot.primary || circleRoot.checked)
               ? Qt.alpha("white", 0.12)
               : "transparent"
        Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
    }

    // Ripple-efekt klikil
    Rectangle {
        id: ripple
        anchors.centerIn: parent
        width: 0
        height: width
        radius: width / 2
        color: circleRoot.primary || circleRoot.checked
               ? Qt.alpha("white", 0.35)
               : Qt.alpha(Kirigami.Theme.highlightColor, 0.3)
        opacity: 0
    }

    ParallelAnimation {
        id: rippleAnim
        NumberAnimation { target: ripple; property: "width"; from: circleRoot.width * 0.35; to: circleRoot.width * 1.05; duration: 340; easing.type: Easing.OutQuad }
        NumberAnimation { target: ripple; property: "opacity"; from: 0.85; to: 0; duration: 340; easing.type: Easing.OutQuad }
    }

    Kirigami.Icon {
        anchors.centerIn: parent
        width: parent.width * circleRoot.iconScale
        height: width
        source: circleRoot.iconName
        color: {
            if (circleRoot.primary) return circleRoot.checkedIconColor
            if (circleRoot.checked) return circleRoot.checkedIconColor
            return circleRoot.iconColor
        }
        smooth: true
    }

    MouseArea {
        id: pressArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: circleRoot.enabledState
        onClicked: {
            rippleAnim.restart()
            circleRoot.clicked()
        }
    }

    PlasmaCore.ToolTipArea {
        anchors.fill: parent
        active: tooltipText !== ""
        mainText: tooltipText
    }
}
