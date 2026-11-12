/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The record that turns on the Playing page while a station has no cover:
// the disc, its grooves, a glint in the two accent colours and the hole.
// Only the drawing. The page turns it and lays the station's logo over the
// label.

import QtQuick

Canvas {
    // Canvas gradients want CSS colour strings, built from the live accent
    // so the glint follows the follow-system setting.
    function cssRgba(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255)
               + "," + Math.round(c.b * 255) + "," + a + ")"
    }
    property color tintA
    property color tintB
    onTintAChanged: requestPaint()
    onTintBChanged: requestPaint()
    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var c = width / 2
        // Record
        ctx.beginPath()
        ctx.arc(c, c, c - 1, 0, Math.PI * 2)
        ctx.fillStyle = "#151515"
        ctx.fill()
        // Grooves
        ctx.strokeStyle = "rgba(255,255,255,0.07)"
        ctx.lineWidth = 1
        for (var r = c * 0.45; r < c * 0.94; r += c * 0.055) {
            ctx.beginPath()
            ctx.arc(c, c, r, 0, Math.PI * 2)
            ctx.stroke()
        }
        // Light glint
        var g = ctx.createLinearGradient(0, 0, width, height)
        g.addColorStop(0, cssRgba(tintA, 0.14))
        g.addColorStop(0.5, cssRgba(tintA, 0))
        g.addColorStop(1, cssRgba(tintB, 0.10))
        ctx.beginPath()
        ctx.arc(c, c, c - 1, 0, Math.PI * 2)
        ctx.fillStyle = g
        ctx.fill()
        // Center hole
        ctx.beginPath()
        ctx.arc(c, c, c * 0.3, 0, Math.PI * 2)
        ctx.fillStyle = "#1f1f1f"
        ctx.fill()
        ctx.beginPath()
        ctx.arc(c, c, c * 0.045, 0, Math.PI * 2)
        ctx.fillStyle = "#0a0a0a"
        ctx.fill()
    }
}
