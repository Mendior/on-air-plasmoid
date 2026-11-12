/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The player's face has two seats, Plasma's popup and a window of its own,
// and sits in one of them at a time. The questions that decide which, and
// what follows from it, are asked here.
.pragma library

// Which seat holds the face: "window" or "popup".
//
// detached: the listener sent the face to its own window (the config key).
// planar: the widget stands on the desktop, where the face is shown inline.
//
// A desktop widget is offered no window, and a wish left in the config from
// the widget's days in a panel does not open one. Measured: the
// window cut six pixels off each side of a desktop widget's face.
function seatOf(detached, planar) {
    return detached === true && planar !== true ? "window" : "popup";
}

// The face is on screen, which is what its animations and timers price
// themselves by: the popup is open, or the window is up. The window counts
// focused or not, because a player standing beside other work has to keep
// its titles and its clock moving.
//
// Either, not "the seat that holds the face": the two facts change one after
// the other during a move, and a rule that followed the seat would read
// false for that instant and run the popup's closing work on every move.
function faceShown(popupOpen, windowUp) {
    return popupOpen === true || windowUp === true;
}

// One side of the window, width or height, in pixels.
//
// stored: what the config remembers, 0 while nothing has been remembered.
// floor: the least the face needs. ceiling: the screen's side.
// fallback: the size the face asks for, the popup's own default.
//
// The answer always lies between the floor and the ceiling. A config can be
// edited by hand and a screen can be swapped for a smaller one, and a window
// taller than its screen has its lower edge, and the transport with it,
// where nobody can reach. Without a screen to ask it ends at 8192, more than
// any one screen has. A screen smaller than the face needs loses to the face.
function sizeFor(stored, floor, ceiling, fallback) {
    var least = _size(floor) ? floor : 1;
    var most = Math.max(least, _size(ceiling) ? ceiling : 8192);
    var want = _size(stored) ? stored : (_size(fallback) ? fallback : least);
    return Math.round(Math.min(most, Math.max(least, want)));
}

function _size(v) {
    return typeof v === "number" && isFinite(v) && v > 0;
}

// Somebody is at the face. The level poll runs at its full rate only then:
// every tick is a shell asking the sound server, and the seconds it costs
// are worth it while a listener is looking at the slider it feeds.
//
// In the popup an open popup is somebody looking. A desktop face and a
// window are on screen all day whether anybody looks or not, so there it
// takes more: the pointer on a desktop face, and in a window the pointer on
// the face together with the keyboard in the window.
//
// Why both in a window. The pointer alone leaves the poll at full rate under
// a parked pointer: a listener clicks a station and goes back to typing in
// another window. And a window minimised from the keyboard kept its last
// "the pointer is here" for as long as it stayed down (measured under KWin
// 6.8; so did a pointer that left onto bare screen). The keyboard alone
// calls a radio that was started and left "watched" all night. A click on
// the face gives both at once.
function watched(seat, planar, popupOpen, hovered, active) {
    if (seat === "window") return hovered === true && active === true;
    return planar === true ? hovered === true : popupOpen === true;
}

// A seat that is on screen whether or not anybody looks: the player's own
// window, and the desktop, where the face is shown inline.
function standing(seat, planar) {
    return seat === "window" || planar === true;
}
