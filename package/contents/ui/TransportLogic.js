/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What the transport means when it names nothing.
//
// Play on the Playing tab, Space, the panel's middle click and the media
// keys all arrive without a station attached. Five roads used to answer
// that question with the same line copied five times, and the copy had no
// idea a search result could have been the last thing heard.
.pragma library

// A Play that names no station: what goes on?
//
// hasAudition: a search result was auditioned and nothing else has started
// since. lastPlay: the list row that played last (-1 during an audition or a
// local file). count: rows in the list.
// Returns { what: "audition" | "station" | "nothing", index }.
//
// The audition is asked first, before lastPlay, because lastPlay cannot be
// trusted to mean "chosen" once an audition started: deleting a row sets it
// to 0 behind the listener's back. Row 0 stays the answer when the row that
// played is gone, as it always was.
function bareplay(hasAudition, lastPlay, count) {
    if (hasAudition === true) return { "what": "audition", "index": -1 };
    var n = count | 0;
    if (n <= 0) return { "what": "nothing", "index": -1 };
    var i = (lastPlay >= 0 && lastPlay < n) ? lastPlay : 0;
    return { "what": "station", "index": i };
}

// Is there a stop to offer, and does it need a control of its own?
//
// The big button carries two meanings already: it is a Stop on a station that
// cannot timeshift, and a Pause on one that can. That leaves two states with
// nothing to press:
//
//   - a timeshift station playing. The only button pauses, and a pause holds
//     the connection open and keeps filling the buffer — at the 191 kb/s a
//     listener sees on a typical station that is about 86 MB an hour, while
//     they believe the radio is off.
//   - a quiet station between two knocks. The footer says Reconnecting, the
//     button says Play, and there is no way to say "stop trying". This is the
//     half of issue #13 that the retry budget never covered.
//
// Both are the same sentence: the widget holds something, and the person has
// no way to let go of it. `stopWithFade` already tears all of it down (the
// standing order, the ladder's timer, the network resume) — it was only ever
// missing a door.
//
// playing/casting: audible now. wantsPlaying: a standing order holds, whether
// or not anything is audible. tsPaused/tsShifted: parked in or moved inside
// the buffer. pauseAvailable: a buffer is ready, so the big button is a Pause.
//
// Anything that is not exactly true counts as false, so an undefined property
// during load cannot conjure a control out of nothing.
function stopOffered(playing, casting, wantsPlaying, tsPaused, tsShifted, pauseAvailable) {
    var audible = (playing === true) || (casting === true);
    var held = audible || (wantsPlaying === true) || (tsPaused === true) || (tsShifted === true);
    if (!held) return false;
    // The big button is already a Stop whenever something is audible with no
    // buffer behind it, and two stops side by side help nobody.
    var bigIsStop = audible && !((pauseAvailable === true) || (tsShifted === true));
    return !bigIsStop;
}
