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

// Is anything on at all? playing/casting: audible now. wantsPlaying: a
// standing order holds, audible or not. tsPaused/tsShifted: parked in or
// moved inside the buffer.
//
// This is the sentence stopOffered opens with, for a caller that asks
// nothing more. The panel text is one: between two knocks of a reconnect
// nothing is audible for half a minute, and text that left and came back
// with the sound would shove every neighbour on the panel twice.
function held(playing, casting, wantsPlaying, tsPaused, tsShifted) {
    return (playing === true) || (casting === true) || (wantsPlaying === true)
        || (tsPaused === true) || (tsShifted === true);
}

// The level one notch of the wheel asks for, 0..1.
//
// shown: what the output plays right now. fadeFrom: the level the sleep
// timer's fade started from, below zero while no fade runs. pendingPct: the
// listener's last gesture still waiting to be saved, in percent, below zero
// when there is none. notch: the step, up or down.
//
// The step used to be counted from shown alone, and for its last thirty
// seconds the sleep timer is what moves shown. A notch at a level faded from
// 60 % to 30 % asked for 35 %, the wheel's gesture is saved as the default
// volume, and the radio came on at 35 % in the morning. During a fade the
// notch counts from the level the fade started at, and a second notch of the
// same burst from the one before it, which is still pending for a second.
// What is heard does not change: the fade writes its own level again on its
// next frame, as it did before.
//
// Anything that is not a finite number counts as absent, and the answer
// never leaves 0..1.
function wheelLevel(shown, fadeFrom, pendingPct, notch) {
    var base = Number.isFinite(shown) ? shown : 0;
    if (Number.isFinite(fadeFrom) && fadeFrom >= 0)
        base = (Number.isFinite(pendingPct) && pendingPct >= 0) ? pendingPct / 100 : fadeFrom;
    return Math.max(0, Math.min(1, base + (Number.isFinite(notch) ? notch : 0)));
}

// Does a list write made by the star or the trash leave the sound alone?
//
// The write stops the player, and what was a row of the list or an audition
// is started again by whoever wrote. A My Music file or a podcast episode is
// neither. It was cut off by a change to a list it is not in, and nothing
// brought it back. Those two play on through the write; everything else
// keeps the road it had.
//
// p.audible   the local player is playing
// p.preview   a search result is being auditioned
// p.source    the address the player holds
// p.episode   the playing episode's address, "" when none plays; an episode
//             can be a stream, so the address alone does not say
// p.tone      the wake-up tone's address: a file too, and the alarm's own
// p.bufferPath  the timeshift buffer's path on disk, "" while there is none
// p.shifted   the listener is inside that buffer, which is a station's
//
// Every fact has to be readable for the answer to be yes: audible exactly
// true, preview and shifted exactly false, the source a string. A state
// nobody can read stops the sound as it always did.
function listWriteKeepsSound(p) {
    if (!p || p.audible !== true || p.preview !== false || p.shifted !== false) return false;
    var src = p.source;
    if (typeof src !== "string" || src === "") return false;
    if (src === p.tone) return false;
    if (typeof p.bufferPath === "string" && p.bufferPath !== "" && src === "file://" + p.bufferPath) return false;
    if (typeof p.episode === "string" && p.episode !== "" && src === p.episode) return true;
    return src.indexOf("file://") === 0;
}
