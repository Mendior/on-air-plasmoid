/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Can it be read? The one question the accent colours never asked.
//
// The emerald was chosen against a dark panel. On Breeze Light the brighter
// green that names the playing station measures 1.33:1 against the popup and
// 1.23:1 on the row's own wash, where body text wants 4.5:1. A fixed
// darkening factor mended the emerald and nothing else: with the system
// accent it left a yellow (#e8cb2d) at 4.05:1 on a light scheme, and on a
// dark one it never looked at all (a grey accent sat at 2.56:1).
//
// So the colour is measured instead of assumed. Everything here takes
// "#rrggbb" or anything carrying r/g/b between 0 and 1, which a QML color
// does, and answers in "#rrggbb". No QML types, no I/O.
.pragma library

// WCAG 2.x AA for body text.
var MIN_TEXT = 4.5;
// The heaviest accent wash any of these labels sits on: the playing row
// (MediaListItem, EpisodeListItem, My Music) lays the accent over the popup
// at 0.15. The pills use 0.14 and less.
var ROW_WASH = 0.15;
// A colour that has to move lands this far past the line. The popup is
// translucent and blurred, so the surface on screen is never quite the
// nominal one; a colour that already reads is still left exactly alone.
var HEADROOM = 0.5;
// Forty shades between a colour and its pole: fine enough that the first
// one to pass lands within half a point of where it aims.
var STEPS = 40;

function channels(c) {
    if (typeof c === "string") {
        var m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(c.trim());
        return m ? { r: parseInt(m[1], 16) / 255, g: parseInt(m[2], 16) / 255,
                     b: parseInt(m[3], 16) / 255 } : null;
    }
    if (c && isFinite(c.r) && isFinite(c.g) && isFinite(c.b))
        return { r: Number(c.r), g: Number(c.g), b: Number(c.b) };
    return null;
}

function _lin(v) {
    return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

// WCAG relative luminance, 0..1; -1 for something that is not a colour.
function luminance(c) {
    var p = channels(c);
    if (!p) return -1;
    return 0.2126 * _lin(p.r) + 0.7152 * _lin(p.g) + 0.0722 * _lin(p.b);
}

// 1..21, order-blind; 0 when either side is not a colour.
function contrast(a, b) {
    var la = luminance(a), lb = luminance(b);
    if (la < 0 || lb < 0) return 0;
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function _mix(from, to, t) {
    return { r: from.r + (to.r - from.r) * t,
             g: from.g + (to.g - from.g) * t,
             b: from.b + (to.b - from.b) * t };
}

function hex(c) {
    var p = channels(c);
    if (!p) return "";
    function h(v) {
        var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16);
        return s.length < 2 ? "0" + s : s;
    }
    return "#" + h(p.r) + h(p.g) + h(p.b);
}

// What a tinted row really is: `wash` laid over `bg` at `alpha`.
function washed(bg, wash, alpha) {
    var b = channels(bg), w = channels(wash);
    if (!b) return "";
    return w ? hex(_mix(b, w, alpha)) : hex(b);
}

// The lower of the two readings: the bare popup and the playing row's wash.
function worstContrast(fg, bg, wash) {
    var bare = contrast(fg, bg);
    if (!channels(wash)) return bare;
    return Math.min(bare, contrast(fg, washed(bg, wash, ROW_WASH)));
}

// `fg` as it may be written on `bg`. A colour that already reads comes back
// untouched, the very value that went in, so a scheme it was drawn for
// keeps it exactly. Otherwise it walks toward whichever of black and white
// the surface leaves more room for. Walking to black scales the channels,
// which is what Qt.darker does: the hue and the saturation stay.
function readable(fg, bg, wash, min) {
    var f = channels(fg);
    if (!f || !channels(bg)) return fg;
    var want = min > 0 ? min : MIN_TEXT;
    if (worstContrast(fg, bg, wash) >= want) return fg;
    var black = { r: 0, g: 0, b: 0 }, white = { r: 1, g: 1, b: 1 };
    var pole = worstContrast(black, bg, wash) >= worstContrast(white, bg, wash) ? black : white;
    for (var i = 1; i <= STEPS; i++) {
        var shade = hex(_mix(f, pole, i / STEPS));
        if (worstContrast(shade, bg, wash) >= want + HEADROOM) return shade;
    }
    return hex(pole);
}

// The LIVE pill: its own colour washed over the popup at PILL_WASH.
// It was the theme's negative red at 0.16 over whatever lay behind it, with
// the letters in the same red: measured on the bench 3.03:1 on Breeze Light
// and 2.83:1 on Breeze Dark, where the aurora under it lifts the surface.
// On the Playing page a blurred cover can sit under it too, so a surface
// that shows through can never be measured once for all. The pill is
// painted opaque in its old colour instead, and the letters are measured
// against exactly that.
var PILL_WASH = 0.16;

// The pill's surface, opaque, for `fg` on a popup of `bg`.
function pillSurface(fg, bg) {
    return washed(bg, fg, PILL_WASH);
}

// The pill's letters: `fg`, or the nearest shade of it that reads on
// pillSurface(fg, bg).
function pillText(fg, bg) {
    var surface = pillSurface(fg, bg);
    return surface === "" ? fg : readable(fg, surface, "", MIN_TEXT);
}
