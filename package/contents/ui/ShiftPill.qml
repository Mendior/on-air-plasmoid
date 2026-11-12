/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

// The Playing page's word for a listener who is behind the broadcast, and
// the two steps of thirty seconds beside it.
//
// The pill is what it always was: how far behind, and one tap back to live.
// The steps are there only where the pause buffer slides (MP3 and AAC since
// 2026.44), because only there is an earlier place something a new open can
// land in. Back is offered from live too, since "what did he just say" is
// asked by somebody who has not paused; forward only where there is
// something ahead, which a listener on the broadcast has not.
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "SlideLogic.js" as SlideLogic

RowLayout {
    id: shiftPill

    // The player is on the buffer.
    property bool shifted: false
    // The listener is parked in it, in silence.
    property bool parked: false
    // The buffer slides and holds enough for a step to land in.
    property bool stepReady: false
    // The page is on screen: the label counts only then.
    property bool open: false
    // How far behind, as m:ss. A function, because the answer moves with
    // the clock and not with any property a binding could follow.
    property var behindOf: function() { return "0:00" }
    property color accent: Kirigami.Theme.highlightColor
    property color accentText: Kirigami.Theme.textColor

    signal live()
    signal step(int ms)

    readonly property bool behind: shifted || parked

    visible: behind || stepReady
    spacing: Kirigami.Units.smallSpacing

    CircleButton {
        objectName: "shiftBack"
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Kirigami.Units.gridUnit * 1.5
        implicitHeight: implicitWidth
        visible: shiftPill.stepReady
        enabledState: visible
        iconName: "media-seek-backward"
        iconScale: 0.6
        tooltipText: i18n("Back 30 seconds")
        onClicked: shiftPill.step(-SlideLogic.STEP_MS)
    }

    Rectangle {
        id: pill
        objectName: "shiftPillBody"
        visible: shiftPill.behind
        implicitHeight: pillLabel.implicitHeight + Kirigami.Units.smallSpacing
        implicitWidth: pillLabel.implicitWidth + Kirigami.Units.largeSpacing
        radius: height / 2
        color: Qt.alpha(shiftPill.accent, 0.14)
        border.width: 1
        border.color: Qt.alpha(shiftPill.accent, 0.4)

        // Behind-live counts on a clock, so the label must tick even while
        // the player is silent and no position events re-run the binding.
        property int tick: 0
        Timer {
            interval: 1000
            repeat: true
            running: pill.visible && shiftPill.open
            onTriggered: pill.tick++
        }

        PlasmaComponents3.Label {
            id: pillLabel
            objectName: "shiftPillLabel"
            anchors.centerIn: parent
            text: {
                void pill.tick;
                return shiftPill.parked ? i18n("Paused · %1 behind live", shiftPill.behindOf())
                                        : i18n("%1 behind live — tap to catch up", shiftPill.behindOf());
            }
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.weight: Font.Bold
            color: shiftPill.accentText
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            Accessible.name: i18n("Back to live")
            onClicked: shiftPill.live()
        }
    }

    CircleButton {
        objectName: "shiftForward"
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Kirigami.Units.gridUnit * 1.5
        implicitHeight: implicitWidth
        visible: shiftPill.stepReady && shiftPill.behind
        enabledState: visible
        iconName: "media-seek-forward"
        iconScale: 0.6
        tooltipText: i18n("Forward 30 seconds")
        onClicked: shiftPill.step(SlideLogic.STEP_MS)
    }
}
