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
// local file). count: rows in the list. pausedFile: a pause is holding an
// episode or a My Music file (filePause).
// Returns { what: "paused" | "audition" | "station" | "nothing", index }.
//
// The paused file goes first. It is the one thing the listener set down and
// has not let go of: a stop drops it, and so does every start of anything
// else, so while it stands nothing has been chosen after it.
//
// The audition is asked before lastPlay, because lastPlay cannot be
// trusted to mean "chosen" once an audition started: deleting a row sets it
// to 0 behind the listener's back. Row 0 stays the answer when the row that
// played is gone, as it always was.
function bareplay(hasAudition, lastPlay, count, pausedFile) {
    if (pausedFile === true) return { "what": "paused", "index": -1 };
    if (hasAudition === true) return { "what": "audition", "index": -1 };
    var n = count | 0;
    if (n <= 0) return { "what": "nothing", "index": -1 };
    var i = (lastPlay >= 0 && lastPlay < n) ? lastPlay : 0;
    return { "what": "station", "index": i };
}

// Can Play do anything? The desk's media controls light their button on
// this, and the Playing tab's own button asks the same question.
//
// playing/casting: something is on, so there is a track to speak of.
// parked/shifted: a seat in the timeshift buffer waits for its resume.
// hasAudition, lastPlay, count, pausedFile: what bareplay is asked.
//
// The desk used to be told "the list has a row", a rule written apart from
// the action. With no station saved, a search result that was playing was
// announced as unplayable, and after its stop the desk's Play stayed dark
// while the widget's own button brought the audition back. Stopped and out
// of the buffer, a Play does what bareplay answers, so bareplay is asked.
function canPlay(playing, casting, parked, shifted, hasAudition, lastPlay, count, pausedFile) {
    if (playing === true || casting === true || parked === true || shifted === true) return true;
    return bareplay(hasAudition, lastPlay, count, pausedFile).what !== "nothing";
}

// What one of the four transport words does. Stop, Pause, PlayPause and Play
// come from the media keys and the desk's controls; the widget's own button,
// Space and the panel's middle click are a PlayPause.
//
// playing: the local player is audible. casting: a device carries the
// stream. wantsPlaying: a standing order holds. parked/shifted: a seat in
// the timeshift buffer. ownFile: what plays here is an episode or a My Music
// file a pause can keep (ownFile). pausedFile: a pause is holding one now.
// inPlace: and the player still sits paused on it, on disk (inPlace).
// audition: a search result plays or is on its way (auditionComing).
//
// The answers, and what main.qml's transport() does with each:
//   "stop"     stopWithFade
//   "pause"    the timeshift pause, and a stop where there is no buffer
//   "keep"     the file pauses where it stands and is remembered
//   "resume"   the parked station comes back out of its buffer
//   "unpause"  a paused player plays on: the reader inside the buffer, or
//              the file a pause kept
//   "bare"     a Play that names nothing (bareplay), which starts a kept
//              file again when the player no longer holds it
//   "none"
//
// Stop never starts anything, and it ends whatever is held: sound, a cast, a
// standing order between two knocks of its retry (the ladder waits up to ten
// minutes and would restart what the key just refused), a seat in the
// buffer, a paused file.
//
// Pause was a stop for everything without a buffer. For a station that is
// honest, there is nothing to come back to but the broadcast. An episode or
// a file has a place. The stop threw the episode away, lastPlay stood at -1,
// and the next Play put the first station of the list on. Measured
// 2026-11-11 on main.qml's own functions around a counting player: Pause
// left the source and the episode key empty, and two presses of the
// widget's button ended in "radio:0". MPRIS says a Play after a Pause goes
// on from the same place.
//
// An audition is nobody's standing order, and on the relay road its player
// is started only when the tap is up, one to four seconds after the click.
// In that window nothing was playing, cast, ordered, parked or kept, so
// Stop answered "none" and the audition came up and played: on the bench a
// Stop half a second after the Play left the sink at -9.9 dBFS. An audition
// on its way counts as a standing order does. The button over it is a Stop,
// since a press takes down what is coming, and Play leaves it alone: either
// used to start it a second time. One that has a seat in its buffer is not
// on its way: it sounded, a pause parked it, and it comes back out of the
// buffer as any parked station does.
//
// Anything that is not exactly true counts as false, and a word nobody
// knows does nothing.
function mediaKey(cmd, playing, casting, wantsPlaying, parked, shifted, ownFile, pausedFile, inPlace, audition) {
    var here = playing === true, away = casting === true;
    // Asked only where nothing sounds here or on a device: those are answered before it.
    var coming = audition === true && parked !== true && shifted !== true;
    var lifts = shifted === true || (pausedFile === true && inPlace === true);
    if (cmd === "Stop")
        return (here || away || wantsPlaying === true || parked === true || shifted === true
                || pausedFile === true || audition === true) ? "stop" : "none";
    if (cmd === "Pause") {
        if (here) return ownFile === true ? "keep" : "pause";
        return (away || wantsPlaying === true || coming) ? "stop" : "none";
    }
    if (cmd === "PlayPause") {
        if (here || away) return (here && ownFile === true) ? "keep" : "pause";
        if (coming) return "stop";
        if (parked === true) return "resume";
        return lifts ? "unpause" : "bare";
    }
    if (cmd === "Play") {
        if (coming) return "none";
        if (parked === true) return "resume";
        if (lifts && !here) return "unpause";
        return (!here && !away) ? "bare" : "none";
    }
    return "none";
}

// mediaKey's ninth fact: a search result is on its way to sound, or sounds.
//
// address: the address of the result being tried, "" for none. lastWord:
// the sentence its retry ladder ends in when nothing is left to try, ""
// while it has not been said.
//
// The address alone is not that fact. The ladder's last word leaves it
// standing, for the row's mark and the Playing page's star, so a result
// that was dead for good went on counting as coming: the big button read
// Stop over a silent widget, the desk's Play did nothing, and the radio
// took two presses to come back. On its way is from the click until the
// result sounds or its ladder has spoken. The sentence goes with the next
// start, with a stop and with the next result's click, and the fact with it.
function auditionComing(address, lastWord) {
    return typeof address === "string" && address !== "" && !(typeof lastWord === "string" && lastWord !== "");
}

// mediaKey for the facts as main.qml keeps them, one array in mediaKey's own
// order. The transport and the face of its button both read that array, so
// what the button shows and what a press does are answered from one place.
function keyFor(cmd, facts) {
    var f = Array.isArray(facts) ? facts : [];
    return mediaKey(cmd, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8]);
}

// The face of the Playing page's big button: "pause", "stop" or "play".
//
// facts: what keyFor is given. pauseAvailable: a timeshift buffer is ready.
//
// The face is what a press does. A press that sets something down for later
// is a Pause: an episode or a file, a station with a buffer behind it, a
// listen inside that buffer. A press that ends the sound for good is a Stop:
// live radio with no buffer, a cast, whose place the widget does not know.
// Every press that starts something is a Play.
//
// The button read Stop on an episode because it asked only about the
// timeshift buffer, and since 2026.44 its press keeps the episode's place:
// it said Stop and paused.
function face(facts, pauseAvailable) {
    var f = Array.isArray(facts) ? facts : [], act = keyFor("PlayPause", f);
    if (act === "keep") return "pause";
    if (act === "pause") return (pauseAvailable === true || f[4] === true) ? "pause" : "stop";
    return act === "stop" ? "stop" : "play";
}

// The word the desk is told: "Playing", "Paused" or "Stopped".
//
// A cast counts as playing: the local player is idle by design while a
// device carries the stream, but to the desk's media keys the music is on.
// A seat in the buffer and a paused file read as Paused, so the desk offers
// a resume and not a dead play button.
function playbackStatus(playing, casting, parked, shifted, pausedFile) {
    if (playing === true || casting === true) return "Playing";
    return (parked === true || shifted === true || pausedFile === true) ? "Paused" : "Stopped";
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
// the buffer. pauseAvailable: the big button is a Pause (face), over a ready
// buffer or over an episode or a file. pausedFile: a pause keeps one.
//
// Anything that is not exactly true counts as false, so an undefined property
// during load cannot conjure a control out of nothing.
function stopOffered(playing, casting, wantsPlaying, tsPaused, tsShifted, pauseAvailable, pausedFile) {
    var audible = (playing === true) || (casting === true);
    var held = audible || (wantsPlaying === true) || (tsPaused === true) || (tsShifted === true);
    if (!held && pausedFile !== true) return false;
    // The big button is already a Stop whenever something is audible with no
    // buffer behind it, and two stops side by side help nobody.
    var bigIsStop = audible && !((pauseAvailable === true) || (tsShifted === true));
    return !bigIsStop;
}

// Is anything on at all? playing/casting: audible now. wantsPlaying: a
// standing order holds, audible or not. tsPaused/tsShifted: parked in or
// moved inside the buffer. pausedFile: a pause keeps an episode or a file.
//
// This is the sentence stopOffered opens with, for a caller that asks
// nothing more. The panel text is one: between two knocks of a reconnect
// nothing is audible for half a minute, and text that left and came back
// with the sound would shove every neighbour on the panel twice.
function held(playing, casting, wantsPlaying, tsPaused, tsShifted, pausedFile) {
    return (playing === true) || (casting === true) || (wantsPlaying === true)
        || (tsPaused === true) || (tsShifted === true) || (pausedFile === true);
}

// The listener's own level now, 0..1: the one source for everything that
// works out what a device is told, and for the wheel where the output here
// is not what is heard.
//
// pendingPct: the last gesture's level, still waiting to be saved, below
// zero when there is none. overridePct: the wake-up alarm's own level while
// it stands, below zero otherwise. defaultPct: the saved level.
//
// The save waits a second after a gesture, and for that second the saved
// level is the one before it: the wheel took a widget from 80 % to 20 %, a
// move of the room's slider inside the second worked the device's level out
// of the 80, and a device at 0.060 was sent 0.200. A gesture counts at
// once. A mute is not a level: zero waiting to be saved means the level
// under it, which is what an unmute comes back to. The stream is never
// asked: it stands at whatever a fade or a calibration has it at.
function ownLevel(pendingPct, overridePct, defaultPct) {
    var pct = (Number.isFinite(pendingPct) && pendingPct > 0) ? pendingPct
              : ((Number.isFinite(overridePct) && overridePct >= 0) ? overridePct : defaultPct);
    return Number.isFinite(pct) ? Math.max(0, Math.min(1, pct / 100)) : 0;
}

// The level one notch of the wheel asks for, 0..1.
//
// shown: what the output plays right now. fadeFrom: the level the sleep
// timer's fade started from, below zero while no fade runs. pendingPct: the
// listener's last gesture still waiting to be saved, in percent, below zero
// when there is none. notch: the step, up or down. away: a device plays
// alone, so what the output here stands at is heard by nobody. own: the
// listener's level (ownLevel).
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
// Where a device plays alone the output here is not touched by what starts
// there. The wake-up alarm told a device 40 % while the output stood at last
// night's 80 %, and one notch down counted from the 80: the device went
// from 0.200 to 0.375. There a notch counts from the listener's level, which
// holds the notch before it too.
//
// Anything that is not a finite number counts as absent, and the answer
// never leaves 0..1.
function wheelLevel(shown, fadeFrom, pendingPct, notch, away, own) {
    var base = Number.isFinite(shown) ? shown : 0;
    if (away === true && Number.isFinite(own)) base = own;
    else if (Number.isFinite(fadeFrom) && fadeFrom >= 0)
        base = (Number.isFinite(pendingPct) && pendingPct >= 0) ? pendingPct / 100 : fadeFrom;
    return Math.max(0, Math.min(1, base + (Number.isFinite(notch) ? notch : 0)));
}

// Which knob the output menu's volume row turns, its slider and its mute
// alike.
//
// casting: a device carries the stream now. One that is only ticked is not
// what this asks about, and nothing here reaches it.
// localAlong: this computer plays along with the devices.
// combine: the sync group is up or being built. followsDefault: no local
// output is pinned, the sound goes to the system's default sink.
// dragRoad: the answer the drag in progress began with, "" outside a drag.
//
//   "sink"    the room's volume, the one the keyboard's keys turn
//             (setSinkMaster, toggleSinkMasterMute)
//   "player"  the widget's own volume (setUserVolume): the stream follows
//             it, and while a device carries the stream so does the device
//
// The row asked only how the local sound is routed. With the system default
// selected and a television carrying the stream, this computer silent, the
// slider and the mute turned this computer's master and the television
// heard nothing of it. Measured 2026-11-11 on the row's own lines around
// counting roads: slider local=1 cast=0, mute local=1 cast=0, and with an
// output pinned the same slider reached the device.
//
// A device playing alone is all there is to hear, so the row is the
// widget's own volume there, whatever the local routing says. Beside this
// computer the row stays the knob it was, and what it sends is for both
// (masterGesture).
//
// A drag keeps the knob it started on. A cast that ends under the pointer
// would hand the rest of the gesture to the room's master, at a level that
// was being chosen for a television.
function volumeRoad(casting, localAlong, combine, followsDefault, dragRoad) {
    if (dragRoad === "sink" || dragRoad === "player") return dragRoad;
    if (casting === true && localAlong !== true) return "player";
    return (combine === true || followsDefault === true) ? "sink" : "player";
}

// The level a device is sent: the master it follows, times its balance.
//
// master: 0..1 (castMaster). balance: the device's own, 0.001..1, the number
// its row in the menu sets and a device joining with none is given once,
// from the level it then has. Anything else counts as 1, full level.
//
// The balance is a stored number and is never worked out of two levels, so
// it survives a master at zero, and a device is back where it was when the
// master comes up again. It cannot be above 1: a device is never sent more
// than the master.
function deviceLevel(master, balance) {
    var m = Number.isFinite(master) ? Math.max(0, Math.min(1, master)) : 0;
    var b = (typeof balance === "number" && balance >= 0.001 && balance <= 1) ? balance : 1;
    return m * b;
}

// The master the devices follow, 0..1.
//
// road: volumeRoad's answer, which knob the menu's master row is.
// sinkPct, sinkMuted: this computer's master, below zero while unknown.
// ownMuted: the listener's own mute stands (ownMute). target: the level the
// widget's volume has for the listener, the one it goes back to after a mute.
//
// Everything the widget plays follows the widget's own volume, so a device
// does. Where the row is the room's knob, this computer playing along on
// the default sink or in a sync group, what is heard here is that volume
// times the room's master, and a device beside it follows the same product:
// the slider, the mute and the wheel then each move both by the same
// factor, and the balance between them stays what the device's row set.
// Silent is silent for both, whichever of the two was muted.
//
// What the stream itself stands at is not asked. This used to read a stream
// at zero as a mute, and the widget writes zero by itself: for the length of
// a calibration, for the 10 to 20 ms before a start's fade moves, and when
// the sleep timer's fade has run out, until the stop puts the level back. A
// click on the slider, a touch of the device's row or an unmute's answer in
// such a moment silenced the device, and nothing brought it back before the
// next gesture.
function castMaster(road, sinkPct, sinkMuted, ownMuted, target) {
    var own = Number.isFinite(target) ? Math.max(0, Math.min(1, target)) : 0;
    if (ownMuted === true) return 0;
    if (road !== "sink") return own;
    if (sinkMuted === true) return 0;
    return (typeof sinkPct === "number" && sinkPct >= 0) ? own * Math.min(1, sinkPct / 100) : own;
}

// The balance to store for one the widget worked out by itself: a joining
// device's share, or a balance read against another master at a tick. The
// exact one, cut off at its sixth decimal and never rounded up, and never
// under 0.001, which is the smallest step a device is told.
//
// The row's slider starts at 5 %, and what was worked out used to be held
// to that and rounded to whole per cent. Room 10 %, widget 80 %, balance
// 0.1: the device stands at 0.008, the exact balance without this computer
// is 0.01, the store made it 0.05, and one notch DOWN sent the device 0.038.
// What the widget works out may lie below what the slider offers, and it
// must not raise a level. Six decimals, not the three a device is told:
// cut at three, a tick and its untick in a room at 10 % took a balance of
// 0.555 to 0.55. A hair under a decimal, as division leaves it, is that
// decimal.
function balanceBelow(exact) {
    if (!Number.isFinite(exact)) return 1;
    return Math.max(0.001, Math.min(1, Math.floor(exact * 1e6 + 1e-3) / 1e6));
}

// The balance that keeps a device at the level it stands at when the master
// it follows changes under it.
//
// balance: what it has. wasRoad: the row's knob before "This computer" was
// ticked or unticked beside a playing device; the other one is the knob
// now. sinkPct, target: as in castMaster.
//
// On the default sink a device alone follows the widget's own volume, and
// beside this computer that volume times the room's master. The two can be
// far apart, the room at 40 % under a widget at 75 %, and a balance read
// against the one sent the device to less than half, or to more than twice
// its level, at the first gesture after the box was ticked. The second is a
// television jumping up when somebody turns the volume down.
//
// A balance cannot be above 1, so a device that stands above the new master
// comes down to it; it never goes up.
function rebalance(balance, wasRoad, sinkPct, target) {
    var b = (typeof balance === "number" && balance >= 0.001 && balance <= 1) ? balance : 1;
    if (wasRoad !== "sink" && wasRoad !== "player") return b;
    var was = castMaster(wasRoad, sinkPct, false, false, target);
    var now = castMaster(wasRoad === "sink" ? "player" : "sink", sinkPct, false, false, target);
    if (!(was > 0) || !(now > 0)) return b;
    return balanceBelow(b * was / now);
}

// Whether the listener's own mute stands after the widget's volume was
// written.
//
// stood: whether it stood before. byHand: the write is a gesture's, which
// all come through one door: the slider and the speaker button on the
// widget's own knob, the M key, the panel's wheel, an MPRIS volume.
// level: what was written.
//
// A gesture at zero is a mute, and any other gesture ends one. Everything
// else that writes the volume can only end one, by lifting the stream: a
// start brings this computer's sound back by itself, and so does a stop's
// restore. A zero written by anything else makes none.
function ownMute(stood, byHand, level) {
    if (byHand === true) return typeof level === "number" && level <= 0;
    return stood === true && !(typeof level === "number" && level > 0);
}

// Whether a device that plays follows this computer's master as the widget
// last read it: beside this computer on the room's knob. The reading is
// then kept fresh also while nobody looks at the widget.
function roomFollowed(casting, road) {
    return casting === true && road === "sink";
}

// What a gesture on the output menu's master row sends, and where.
//
// gesture: "move", the slider taken to `level`, or "mute", the speaker
// button. road: volumeRoad's answer for the row, the road of its drag while
// one runs. casting, localAlong: as in volumeRoad. stream: the widget's own
// volume as it stands, which is what the speaker button shows and switches.
// target, ownMuted: as in castMaster.
//
// Returns { sink, sinkMute, player, cast, castFollows }:
//   sink         percent for this computer's master, -1 for none
//   sinkMute     switch this computer's mute; pactl says which way it went
//   castFollows  and the devices are then told what it answered
//   player       level for the widget's own volume, -1 for none; a device
//                that plays follows it by setUserVolume's own line
//   cast         master for the devices, -1 for none
//
// With this computer and a device playing together, the row on the default
// sink moved this computer's master and left the device where it stood,
// while with an output pinned the same slider moved both. A listener who
// hears two things and turns the one volume expects both to follow.
function masterGesture(gesture, road, casting, localAlong, level, stream, target, ownMuted) {
    var to = { "sink": -1, "sinkMute": false, "castFollows": false, "player": -1, "cast": -1 };
    var lv = Number.isFinite(level) ? Math.max(0, Math.min(1, level)) : -1;
    var both = casting === true && localAlong === true;
    if (gesture === "move" && lv >= 0) {
        if (road !== "sink") to.player = lv;
        else {
            to.sink = Math.round(lv * 100);
            if (both) to.cast = castMaster("sink", to.sink, false, ownMuted, target);
        }
    } else if (gesture === "mute") {
        if (road === "sink") { to.sinkMute = true; to.castFollows = both; }
        else if (Number.isFinite(target)) to.player = stream > 0 ? 0 : Math.max(0, Math.min(1, target));
    }
    return to;
}

// Is a mute about to take the place of a level that still waits to be saved?
//
// pendingPct: a level the listener chose that has not been saved yet, in
// percent, below zero when none waits. The save runs a second behind the
// gesture. level: what is asked for now, 0..1.
//
// A mute is the level 0, and 0 is never saved, so that the unmute finds the
// last audible level. A level chosen less than a second before the mute was
// still waiting, the mute took its place, and the unmute went back to the
// level before it. Measured 2026-11-11 on main.qml's own volume functions:
// 80 % saved, the slider to 20 %, a mute inside that second, and the unmute
// sent 80 % to the stream and to the device. main.qml saves the waiting
// level first when this says yes.
function muteDisplaces(pendingPct, level) {
    return typeof level === "number" && level <= 0 && Number.isFinite(pendingPct) && pendingPct > 0;
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
// p.paused    a pause keeps the file the player holds (optional): it does
//             not sound, and a stop under it would put its needle back at
//             zero on the page
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
    if (!p || (p.audible !== true && p.paused !== true) || p.preview !== false || p.shifted !== false) return false;
    var src = p.source;
    if (typeof src !== "string" || src === "") return false;
    if (src === p.tone) return false;
    if (typeof p.bufferPath === "string" && p.bufferPath !== "" && src === "file://" + p.bufferPath) return false;
    if (typeof p.episode === "string" && p.episode !== "" && src === p.episode) return true;
    return src.indexOf("file://") === 0;
}

// Is what plays here an episode or a My Music file that a pause can keep?
//
// The facts are listWriteKeepsSound's, and so is the rule for what counts
// as the listener's own file. On top of them:
//
// p.casting   a device carries the stream; nothing is kept there, the
//             widget does not know where a device's needle stands
// p.stopping  a stop is fading the sound out; what is being stopped is not
//             kept by a second press
function ownFile(p) {
    return listWriteKeepsSound(p) && p.audible === true && p.casting === false && p.stopping === false;
}

// What a pause keeps of an episode or a My Music file: the call that plays
// it again, and the second it stood at. null for everything else, which
// pauses as it always did.
//
// ownFile's facts, and:
// p.raw         the address the episode was started with, "" for a file
// p.title, p.key, p.show, p.art, p.feed   what its start was told
// p.positionMs  the player's needle
// p.seekSec     a seek still waiting for the media to load, below zero when
//               there is none; the needle reads 0 until it lands
//
// Returns { episode, local, url, title, key, show, art, feed, sec }.
//
// The player pauses where it stands, so the page goes on showing the file,
// its cover and its place. What is kept here is for the roads where the
// player cannot simply go on: an episode that streams is opened again at its
// second, since the server drops a connection nobody reads from, and so is
// a file whose pause something else took out of the player.
function filePause(p) {
    if (!ownFile(p)) return null;
    var text = function(v) { return typeof v === "string" ? v : ""; };
    var episode = text(p.episode) !== "" && p.source === p.episode;
    var sec = (Number.isFinite(p.seekSec) && p.seekSec >= 0) ? p.seekSec
              : (Number.isFinite(p.positionMs) ? p.positionMs / 1000 : 0);
    return { "episode": episode, "local": p.source.indexOf("file://") === 0,
             "url": (episode && text(p.raw) !== "") ? p.raw : p.source,
             "title": text(p.title), "key": text(p.key), "show": text(p.show), "art": text(p.art),
             "feed": text(p.feed), "sec": Math.max(0, Math.min(2147483647, Math.floor(sec))) };
}

// Does the player still hold the kept file, paused, so that Play can simply
// go on? kept: what filePause returned. playerPaused: the player is in its
// paused state.
function inPlace(kept, playerPaused) {
    return playerPaused === true && kept !== null && typeof kept === "object" && kept.local === true;
}

// The second a kept file is opened again at, below zero when nothing is
// known and its own bookmark should speak.
//
// keptSec: the second filePause kept. playerPaused, positionMs: the player
// still sits paused, and where its needle stands now. seekWaits: a seek is
// still waiting for the file to load, so the needle reads zero and means
// nothing yet.
//
// Where the player holds the file paused its needle is the listener's own,
// zero included. A needle under one second used to count as one nobody
// knows: an episode paused at 120 s and dragged to its start came back at
// 120. Not knowing is a fact about the player, that it lost the source or
// has not loaded it, and never a small number.
function needle(keptSec, playerPaused, positionMs, seekWaits) {
    if (playerPaused === true && seekWaits !== true && Number.isFinite(positionMs) && positionMs >= 0)
        return Math.min(2147483647, Math.floor(positionMs / 1000));
    return (Number.isFinite(keptSec) && keptSec >= 1) ? Math.min(2147483647, Math.floor(keptSec)) : -1;
}

// Where Next, Previous, Seek and SetPosition from the desk's controls go:
// "skip" inside the episode that is held, "station" to the list, or "none".
//
// p: listWriteKeepsSound's facts of what plays. kept: what a pause keeps
// (filePause), null for none. playerPaused: the player sits paused, which
// under a pause means it still holds the kept source. seekable: the player
// can move its needle.
//
// An episode is held while it plays, here or on a device, and while a pause
// keeps it, whether the player still holds it or only the record does. The
// branches asked "an episode's key stands and the player plays", so over an
// episode paused in place a headset's Next put a radio station on, and Seek
// and SetPosition did nothing while CanSeek said they would.
//
// Inside is where the needle can be moved: the player has the episode,
// playing or paused, and can seek. An episode a device carries alone, one
// only the record holds and one that cannot be sought are left where they
// stand, and the desk is told so: no station starts over any of them.
//
// A My Music file and a seat in a station's buffer are not episodes. Next
// over them goes to the next station while they play, and so it does while
// they are paused.
function skipRoad(p, kept, playerPaused, seekable) {
    var f = (p !== null && typeof p === "object") ? p : {};
    var keptEpisode = kept !== null && typeof kept === "object" && kept.episode === true;
    var on = typeof f.episode === "string" && f.episode !== "";
    var plays = on && f.audible === true && f.source === f.episode;
    if (!plays && !keptEpisode && !(on && f.casting === true)) return "station";
    return ((plays || (keptEpisode && playerPaused === true)) && seekable === true) ? "skip" : "none";
}

// Where one of those four puts the needle, in ms; below zero for a word
// that is none of them, a number nobody can read, or a position below zero.
//
// cmd: "Next", "Previous", "Seek <microseconds, relative>" or
// "SetPos <microseconds, absolute>", as the bridge writes them.
//
// Next and Previous are the on-screen skip buttons, +30 s and -15 s. A
// needle sent past either end parks at that end, as PodcastLogic.skipTarget
// has it; a length nobody knows yet is no end.
function deskNeedle(cmd, positionMs, durationMs) {
    var word = typeof cmd === "string" ? cmd : "";
    var at = (Number.isFinite(positionMs) && positionMs >= 0) ? positionMs : 0;
    var us = /^(Seek|SetPos) -?[0-9]+(\.[0-9]+)?$/.test(word) ? parseFloat(word.substring(word.indexOf(" ") + 1)) : NaN;
    var to = word === "Next" ? at + 30000 : (word === "Previous" ? at - 15000
             : (word.indexOf("Seek ") === 0 ? at + us / 1000 : (word.indexOf("SetPos ") === 0 && us >= 0 ? us / 1000 : NaN)));
    if (!Number.isFinite(to)) return -1;
    var end = (Number.isFinite(durationMs) && durationMs > 0) ? durationMs : to;
    return Math.max(0, Math.min(end, to));
}

// The row of the list Next and Previous go to, below zero for none.
// lastPlay: the row that played last, -1 for none. count: rows in the list.
function stationStep(cmd, lastPlay, count) {
    if (!Number.isFinite(count) || count < 1 || (cmd !== "Next" && cmd !== "Previous")) return -1;
    var at = Number.isFinite(lastPlay) ? Math.max(-1, Math.floor(lastPlay)) : -1;
    if (cmd === "Next") return (at + 1) % count;
    return at - 1 < 0 ? count - 1 : Math.min(at - 1, count - 1);
}

// What a pause keeps, after the needle was moved under it: the same record
// at the needle's second. A pause taken out of the player later is opened
// again at what was kept, and that must not be where the pause was made.
function keptAt(kept, positionMs) {
    if (kept === null || typeof kept !== "object") return null;
    if (!Number.isFinite(positionMs) || positionMs < 0) return kept;
    return Object.assign({}, kept, { "sec": Math.min(2147483647, Math.floor(positionMs / 1000)) });
}

// Is a tap on a row the transport's own toggle? same: the row is what the
// player holds. playing: it sounds. pausedFile: a pause keeps it.
// alarmFiring: the tap is the wake-up starting its episode.
function rowTap(same, playing, pausedFile, alarmFiring) {
    return same === true && (playing === true || (pausedFile === true && alarmFiring !== true));
}

// What one entry of the panel icon's right-click menu shows.
//
// kind: "key" (the big button's press), "next" (the next station), "mute",
// "sleep" (the sleep timer, thirty minutes or its cancelling).
// f: { face, canPlay, episode, stations, muted, sleeping, sounding }
//   face      what the big button shows: "play", "pause" or "stop"
//   canPlay   Play has something to play
//   episode   an episode is held, so Next would move inside it
//   stations  rows in the list
//   muted     the listener's own mute stands
//   sleeping  the sleep timer runs
//   sounding  something plays, here or on a device
//
// Returns { word, icon, enabled, shown }. word names the text the caller
// translates: "play", "pause", "stop", "next", "mute", "unmute", "sleep",
// "wake"; "" for a kind nobody knows, which is not shown.
//
// The entry at the top does what the big button does and says what it
// says, so the two cannot disagree. The rest keep the menu short: an entry
// is there when it can do something now. Mute and the timer are for what
// sounds; a mute that stands and a timer that runs keep their way back.
function panelAction(kind, f) {
    var a = (f !== null && typeof f === "object" && !Array.isArray(f)) ? f : {};
    var on = a.sounding === true;
    if (kind === "key") {
        var face = (a.face === "pause" || a.face === "stop") ? a.face : "play";
        return { "word": face, "icon": "media-playback-" + (face === "play" ? "start" : face),
                 "enabled": face !== "play" || a.canPlay === true, "shown": true };
    }
    if (kind === "next")
        return { "word": "next", "icon": "media-skip-forward", "enabled": true,
                 "shown": a.episode !== true && typeof a.stations === "number" && a.stations > 1 };
    if (kind === "mute") {
        var muted = a.muted === true;
        return { "word": muted ? "unmute" : "mute", "icon": muted ? "audio-volume-high" : "audio-volume-muted",
                 "enabled": true, "shown": on || muted };
    }
    if (kind === "sleep") {
        var runs = a.sleeping === true;
        return { "word": runs ? "wake" : "sleep", "icon": runs ? "dialog-cancel" : "chronometer",
                 "enabled": true, "shown": on || runs };
    }
    return { "word": "", "icon": "", "enabled": false, "shown": false };
}

// The name of what the output menu's volume row turns: "system", "device"
// or "own".
//
// road: volumeRoad's answer. casting, localAlong: as in volumeRoad.
//
// The row said "Volume" and nothing else, and on the default output it is
// the system's volume: a listener who turned the radio down found every
// other application quieter and had no word on the screen to say why.
// "system" is this computer's master, which moves everything it plays and
// the devices that play along; "device" is a device playing alone, which
// follows the widget's own level; "own" is the widget's stream on an
// output of its own, which moves nothing else.
function volumeName(road, casting, localAlong) {
    if (road === "sink") return "system";
    return (road === "player" && casting === true && localAlong !== true) ? "device" : "own";
}
