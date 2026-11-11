/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What the panel writes next to its icon.
//
// The now-playing text arrived as a contribution (GitHub #14) with its rules
// written into the panel item, where nothing could test them. They are here
// instead: which two lines, when there is room for two, how wide, and what
// the widget asks of the panel while it has nothing to say.
.pragma library

// A field as a line of text. A property that is still undefined while the
// widget loads, or a title of nothing but spaces, is no line.
function _line(v) {
    return (typeof v === "string") ? v.trim() : "";
}

// Artist over title. A stream that sends only a title gets the title over
// the station; one that sends nothing gets the station alone.
// Returns { top, bottom }. bottom is "" when there is one thing to say.
function lines(artist, title, station) {
    var a = _line(artist), t = _line(title), st = _line(station);
    var top = a !== "" ? a : (t !== "" ? t : st);
    var bottom = a !== "" ? t : (t !== "" ? st : "");
    // Between songs some streams send the station's own name as the title.
    if (bottom.toLowerCase() === top.toLowerCase()) bottom = "";
    return { "top": top, "bottom": bottom };
}

// The same thing on one line, for a panel too thin for two. The station is
// left out when there is a song to name: one line holds one of them, and
// the tooltip says the other.
function single(artist, title, station) {
    var a = _line(artist), t = _line(title);
    if (a !== "" && t !== "") return a + " – " + t;
    if (t !== "") return t;
    return a !== "" ? a : _line(station);
}

// Is the text shown at all? enabled: the setting. horizontal: a horizontal
// panel, the only kind with width to give. held: the widget holds something
// (TransportLogic.held). top: the first line.
// Anything that is not exactly true is false, so nothing appears on a panel
// because a property was not ready yet.
function shown(enabled, horizontal, held, top) {
    return enabled === true && horizontal === true && held === true && _line(top) !== "";
}

// Do two lines fit? height: the panel item. lineHeight: one line of the
// panel's small font. bottom: the second line, "" when there is none.
// A panel thinner than two lines gets one line, not two that hang over its
// edge.
function stacked(height, lineHeight, bottom) {
    if (_line(bottom) === "") return false;
    var h = Number(height), l = Number(lineHeight);
    if (!(h > 0) || !(l > 0)) return false;
    return h >= 2 * l;
}

// How wide the text is, in whole pixels. capUnits: the setting, in grid
// units. gridUnit: one of them in pixels. widest: the longer line as drawn.
// Rounded up, because a width one fraction short elides the last letter.
function textWidth(capUnits, gridUnit, widest) {
    var cap = Number(capUnits) * Number(gridUnit);
    var w = Number(widest);
    if (!(cap > 0) || !(w > 0)) return 0;
    return Math.ceil(Math.min(cap, w));
}

// What the widget asks of the panel: { min, pref, max } for the three
// Layout width hints. iconSide: the square the glyph sits in.
//
// With nothing to show the answer is what an item has when it sets no hints
// at all (0, -1 and no upper bound; tst_panellogic reads them off a bare
// Item). The setting is off unless a listener turns it on, and until then
// the panel must get exactly the widget it always got.
function widthHints(shown, iconSide, gap, textWidth) {
    var nothing = { "min": 0, "pref": -1, "max": Number.POSITIVE_INFINITY };
    if (shown !== true) return nothing;
    var side = Number(iconSide), g = Number(gap), t = Number(textWidth);
    if (!(side > 0) || !(g >= 0) || !(t > 0)) return nothing;
    var w = Math.ceil(side + g + t);
    return { "min": w, "pref": w, "max": w };
}
