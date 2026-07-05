/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 *
 *  Reusable equalizer animation. Pulsing bars whose phases are
 *  offset so the motion feels organic rather than mechanical.
 */

import QtQuick

Row {
    id: eqRoot

    property int bars: 4
    property color barColor: "white"
    property real barWidth: 4
    property real minHeight: 5
    property real maxHeight: 24
    property int baseDuration: 260
    property bool animating: visible

    spacing: Math.max(2, Math.round(barWidth * 0.75))
    height: maxHeight

    Repeater {
        model: eqRoot.bars

        delegate: Item {
            id: barSlot
            required property int index
            width: eqRoot.barWidth
            height: eqRoot.maxHeight

            Rectangle {
                id: bar
                anchors.bottom: parent.bottom
                width: parent.width
                radius: width / 2
                color: eqRoot.barColor
                height: eqRoot.minHeight

                SequentialAnimation on height {
                    loops: Animation.Infinite
                    running: eqRoot.animating
                    NumberAnimation {
                        from: eqRoot.minHeight
                        to: eqRoot.maxHeight * (0.72 + 0.28 * Math.sin(barSlot.index * 2.1))
                        duration: eqRoot.baseDuration + barSlot.index * 67
                        easing.type: Easing.InOutSine
                    }
                    NumberAnimation {
                        to: eqRoot.minHeight * (1 + (barSlot.index % 2))
                        duration: eqRoot.baseDuration + ((barSlot.index * 41) % 130)
                        easing.type: Easing.InOutSine
                    }
                }
            }
        }
    }
}
