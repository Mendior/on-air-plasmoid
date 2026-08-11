/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The one door every device- and feed-supplied display name goes through.
// Names arrive from radio-browser, from podcast feeds and from whatever a
// box on the LAN calls itself, and they end up in the UI, in filenames and
// on shell command lines. Stripping happens once, here, so that no later
// caller has to remember — and main.qml keeps a thin _sanitizeDeviceName
// wrapper so its eight call sites read the same as they always did.
//
// It lives in its own file for a reason that was measured rather than
// guessed: while the body sat inside main.qml the only guard on it was a
// test that grepped the source for the character class, and two separate
// mutations walked straight past it — one renamed the function and kept
// the class, one returned before ever reaching it. A guard that reads text
// cannot tell whether the code runs. This file can be called, so
// tst_nameguard.qml calls it.
.pragma library

// What the class covers, and why each part is in it:
//   <>&                    markup, so a crafted name cannot become rich text
//   \u0000-\u001f          C0 controls, including tab and the newlines that
//                          would otherwise split a line of shell or a label
//   \u007f-\u009f          DEL and the C1 controls
//   \u200e \u200f          LRM/RLM
//   \u202a-\u202e          the bidi embedding and OVERRIDE codes — this is
//                          the group that lets a name display as something
//                          other than what it is
//   \u2066-\u2069          the isolates, same trick in newer clothes
// The 120-character cap is a display bound, not a security one; it is here
// so a very long name cannot push a row off the screen.
//
// Precondition, measured 2026-08-09: s must be a string or null/undefined.
// A TRUTHY non-string (5, an object) reaches .replace and throws TypeError;
// a falsy one (0, NaN) short-circuits at `(s || "")` and comes back as "".
// All eight callers pass strings today. Written down rather than fixed so
// the move out of main.qml changed nothing at all — see scripts/movecheck.py.
function sanitize(s) {
    return (s || "").replace(/[<>&\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
                    .substring(0, 120);
}
