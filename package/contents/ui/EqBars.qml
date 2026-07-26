/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 *
 *  Reusable equalizer animation. Pulsing bars whose phases are
 *  offset so the motion feels organic rather than mechanical.
 *
 *  Driven by a ~8 Hz Timer sampling per-bar sine waves instead of
 *  continuous NumberAnimations: the panel-icon instance runs for the
 *  WHOLE playback session, and a continuous animation forced the window
 *  to repaint at full display refresh rate the entire time (reported as
 *  high plasmashell CPU, issue #2). Discrete steps look like a real
 *  spectrum meter and cost a fraction of the render work.
 */

import QtQuick

Row {
    id: eqRoot

    property int bars: 4
    property color barColor: "white"
    property real barWidth: 4
    property real minHeight: 5
    property real maxHeight: 24
    // Kept name/meaning from the animation version: roughly the time of one
    // upswing, so existing callers keep their old feel.
    property int baseDuration: 260
    property bool animating: visible

    // Sampling clock (seconds). Bar heights are pure functions of this.
    property real _t: 0

    spacing: Math.max(2, Math.round(barWidth * 0.75))
    height: maxHeight

    Timer {
        interval: 120
        repeat: true
        running: eqRoot.animating
        onTriggered: eqRoot._t += 0.12
    }

    Repeater {
        model: eqRoot.bars

        delegate: Item {
            id: barSlot
            required property int index
            width: eqRoot.barWidth
            height: eqRoot.maxHeight

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                radius: width / 2
                color: eqRoot.barColor
                height: {
                    if (!eqRoot.animating) return eqRoot.minHeight;
                    // Full cycle ≈ 2 × baseDuration (like the old up+down pair),
                    // slightly detuned per bar so they never move in lockstep.
                    var freq = 1000 / (2 * (eqRoot.baseDuration + barSlot.index * 67));
                    var phase = barSlot.index * 2.1;
                    var v = 0.5 + 0.5 * Math.sin(eqRoot._t * freq * 2 * Math.PI + phase);
                    // A quieter second harmonic keeps the motion organic.
                    v = 0.7 * v + 0.3 * (0.5 + 0.5 * Math.sin(eqRoot._t * freq * 4.6 * Math.PI + phase * 1.7));
                    return eqRoot.minHeight + (eqRoot.maxHeight - eqRoot.minHeight) * v;
                }
            }
        }
    }
}
