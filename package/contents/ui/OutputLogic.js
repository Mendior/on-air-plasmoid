/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The output box: one row for the system's default output and one for each
// output the sound server lists. The list is not the box's to keep: outputs
// come and go under it, and the group of all outputs is itself one of them.
.pragma library

// The box's rows: the default first, then each output's description in the
// list's own order.
function rowNames(first, outs) {
    var names = [first];
    for (var i = 0; i < _count(outs); i++) names.push(_text(outs[i], "description"));
    return names;
}

// The row that shows for a configured output: its own, or the default's (0)
// while nothing is configured or the configured output is not in the list.
// An output that is away reads as the default because that is where the
// sound is until it comes back.
//
// Asked by id, never by description: two speakers of one model read alike.
function rowFor(outs, wanted) {
    if (wanted === "") return 0;
    for (var i = 0; i < _count(outs); i++)
        if (_text(outs[i], "id") === wanted) return i + 1;
    return 0;
}

// The output a chosen row stands for: "" for the default's row, and for a
// row the list no longer has, which it can lose between the drawing of the
// row and the click on it.
function idAt(outs, row) {
    if (typeof row !== "number" || !(row >= 1 && row <= _count(outs))) return "";
    return _text(outs[row - 1], "id");
}

// Qt hands the output list over as a sequence, for which Array.isArray()
// says no, so a list is whatever has a whole length.
function _count(outs) {
    if (outs === null || typeof outs !== "object") return 0;
    var n = outs.length;
    return typeof n === "number" && n % 1 === 0 && n > 0 ? n : 0;
}

// An output's id arrives as bytes, which only String() turns into the name.
function _text(out, key) {
    if (out === null || typeof out !== "object") return "";
    var v = out[key];
    return v === undefined || v === null ? "" : String(v);
}
