/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What the sync says in the journal about two things it used to pass over.
//
// The delay map has four writers. The calibration, the verify fold and the
// fold and settle corrections each leave a line with the map before and
// after. A hand on the fine-tune did not, and on 2026-11-11 the map went
// from 181 to 161 ninety seconds after a panel restart with nothing in the
// journal to say what had moved it. The room read 21, 27 and 20 ms out for
// ten minutes, and the only way to find the hand was to rule out the other
// three.
//
// The settle round after a rebuild has five reads to make a verdict of
// three. Two of the ways it can end empty-handed say so. The third did not:
// reads spent on probes that came back unreadable, or skipped, or never
// came back. The same evening a round ended that way at 18:28 and the room
// stayed 50 ms out until 21:50 with no line to show the round was over.
.pragma library

// The line for a delay set by hand, or "" when the map holds what it held.
// Compared entry by entry: the same speakers at the same numbers are the
// same map however the text happens to be laid out. The popup hands over a
// drag when it is released and a run of wheel notches once it has stopped,
// so this is one line for one gesture.
function handSet(before, after) {
    var was = _text(before), now = _text(after);
    if (_same(was, now)) return "";
    return "[ARP] sync: fine-tune set by hand (slider, wheel or ms field) — map " + was + " -> " + now;
}

// No map yet is an empty map.
function _text(m) {
    return m === undefined || m === null || m === "" ? "{}" : String(m);
}

// Two maps with the same entries. Text that cannot be taken apart is only
// the same as itself.
function _same(a, b) {
    if (a === b) return true;
    var x, y, k;
    try {
        x = JSON.parse(a);
        y = JSON.parse(b);
    } catch (e) {
        return false;
    }
    if (x === null || y === null || typeof x !== "object" || typeof y !== "object") return false;
    for (k in x) if (x[k] !== y[k]) return false;
    for (k in y) if (!(k in x)) return false;
    return true;
}

// The line for a settle round that is over without a verdict, with how many
// of the three readings it needed it had.
function settleOver(inHand) {
    var n = Math.floor(Number(inHand));
    if (!(n > 0)) n = 0;
    if (n > 3) n = 3;
    return "[ARP] sync: settle gave up its window — no reads left, " + n + " of three readings in hand";
}
