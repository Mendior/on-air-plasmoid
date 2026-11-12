/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// A live stream that has died while the player goes on saying it plays.
//
// Measured 2026-11-12 on Qt 6.12 with FFmpeg 9, three ways: a station that
// closed the connection, one that held it and sent nothing for forty
// seconds, and one that held it and never sent again. Each time the player
// stayed in PlayingState with its status at Buffering, the position stood
// at 29976 ms for as long as it was watched (170 s) and no EndOfMedia came.
// The player does report an error (-5 at once for the close, -110 after
// twenty seconds of nothing), and the heal that error arms turns back at its
// own door, because the player says it plays. The position is the one
// witness left, so it is looked at every few seconds while a live stream
// plays.
//
// It is a witness only once it has been seen to move: an Ogg FLAC stream
// taken straight off the socket stands at 278 ms from its first second, and
// that one belongs to the relay's rescue. And a standing position is not
// always the stream's doing. With the sound server frozen, and with the
// session manager gone and the stream left unlinked, the position stood the
// same way for two and three minutes, with no error at all. Opening the
// station again cannot cure that. It is opened once all the same, since
// from here the two cannot be told apart; the new connection's position
// then moved 72 ms and stood, which arms nothing, and nothing was opened a
// second time. For an output that takes sound for a few seconds and stops
// again, every verdict doubles the wait before the next.
//
// An alarm that rings is another matter. Its station gave every connection
// 8 s of sound and then held it open (bench, the same day): the verdicts
// came 5, 10 and 20 s after the player's error, and the silences between
// the 8 s of station grew from 31 s to 66 s and past 85 s. While the alarm
// rings (AlarmLogic.wakeRings) no verdict lengthens the wait.
//
// The wait itself is not ours to shorten. Tried for the alarm at five
// seconds: the verdict came 7 s into the silence, and the player, stopped
// while its connection still hung, held the widget's own thread for 12 and
// 13 s, until FFmpeg's read gave up at its twenty. On a panel that is the
// whole shell standing still. After the player's own error the same stop
// returns at once.
//
// Pure functions; StandWatch.qml asks.
.pragma library

// One look every five seconds while a live stream plays.
var TICK_MS = 5000;
// The position has to be seen this much further on before it is a witness.
var ARM_MS = 3000;
// Standing this long ends the stream; this long once the player itself has
// reported an error since the position last moved.
var STAND_MS = 20000;
var ERRED_STAND_MS = 5000;
// What the doubling stops at, and the run of sound that forgives what
// came before it.
var STAND_CAP_MS = 300000;
var HEALTHY_MS = 600000;
// A timer's five seconds are now and then a millisecond short, and a
// stand of 4999 ms waited one more look for its verdict (seen on the
// bench: "stood still for 10 s" where the look before had the answer).
var EARLY_MS = 500;

// Is the player on a live stream this watch is for? f holds what main.qml
// and the engine know:
//   playing   the player is in PlayingState
//   source    what it plays, as text
//   relayUrl  the relay tap's address, "" when there is none
//   relay     the engine's arm is a relay
//   shifted   the listener is in the buffer
//   parked    a pause holds the station
//   casting   the sound is on a device
//   episode   a podcast episode is on
//   audition  a search result is being tried
// The buffer, a file and the tap are not the broadcast, and each has a road
// of its own when it ends. An audition is nobody's standing order: put on
// again by itself it would be sound nobody asked for.
// Contract: true only when playing is true, source is an http or https
// address that is not relayUrl, and every one of the other six is false.
// Anything missing or of another kind is false. Never throws.
function watched(f) {
    if (!f || typeof f.source !== "string" || typeof f.relayUrl !== "string") return false;
    if (f.playing !== true || !/^https?:\/\/./i.test(f.source) || f.source === f.relayUrl) return false;
    return f.relay === false && f.shifted === false && f.parked === false && f.casting === false
           && f.episode === false && f.audition === false;
}

// What is remembered between two looks, from the moment a watch begins.
// Contract: { low, pos, since, armed, tickAt, bornAt, erredAt } with low and
// pos at posMs (0 for anything that is no number from 0 up), since, tickAt
// and bornAt at nowMs, armed false and erredAt 0.
function begin(posMs, nowMs) {
    var at = _num(posMs) && posMs > 0 ? posMs : 0;
    return { low: at, pos: at, since: nowMs, armed: false, tickAt: nowMs, bornAt: nowMs, erredAt: 0 };
}

// The player reported an error.
// Contract: a copy of mem with erredAt at nowMs; null stays null.
function erred(mem, nowMs) {
    if (!mem) return null;
    var m = _copy(mem);
    m.erredAt = nowMs;
    return m;
}

// How long the position may stand before the stream is taken for dead.
// Contract: STAND_MS, or ERRED_STAND_MS when erred is true, doubled for
// every strike and never more than STAND_CAP_MS. Strikes that are no whole
// number from 0 up count as none, and so do all of them when waking is
// exactly true.
function limitMs(strikes, erred, waking) {
    var n = (_num(strikes) && strikes > 0 && Math.floor(strikes) === strikes) ? Math.min(strikes, 16) : 0;
    if (waking === true) n = 0;
    return Math.min(STAND_CAP_MS, (erred === true ? ERRED_STAND_MS : STAND_MS) * Math.pow(2, n));
}

// One look at the position.
//   mem      what begin or the last look returned
//   posMs    the player's position
//   nowMs    the wall clock
//   full     the player's status is Buffered or Buffering
//   strikes  verdicts given since the last forgiven run
//   waking   an alarm rings
// Contract: { mem, stoodMs, forgiven }.
//   stoodMs   0, or how long the position has stood when that is a verdict:
//             the watch is armed, full is true and the position has stood
//             limitMs(strikes, an error since it last moved, waking) or
//             longer, less EARLY_MS
//   forgiven  true on a look that saw the position move HEALTHY_MS or more
//             after the watch began, armed
// The watch is armed by a look that sees the position ARM_MS or more past
// where it began. A position that went back began again there, unarmed: the
// same address was opened anew. A look that comes more than two ticks after
// the last one (the machine slept, the panel hung) starts the standing
// anew and forgets the error. An error is forgotten once the position has
// moved more than two ticks after it. A mem that is none or a position that
// is no number begins a watch and gives no verdict; a clock that is no
// number changes nothing. What was handed in is never changed. Never throws.
function look(mem, posMs, nowMs, full, strikes, waking) {
    var out = { mem: mem, stoodMs: 0, forgiven: false };
    if (!_num(nowMs)) return out;
    if (!mem || !_num(posMs) || posMs < mem.pos) {
        out.mem = begin(posMs, nowMs);
        return out;
    }
    var m = _copy(mem), late = nowMs - m.tickAt > 2 * TICK_MS || nowMs < m.tickAt;
    m.tickAt = nowMs;
    out.mem = m;
    if (posMs > m.pos) {
        m.pos = posMs;
        m.since = nowMs;
        if (posMs - m.low >= ARM_MS) m.armed = true;
        if (m.erredAt > 0 && nowMs - m.erredAt > 2 * TICK_MS) m.erredAt = 0;
        out.forgiven = m.armed && nowMs - m.bornAt >= HEALTHY_MS;
        return out;
    }
    if (late) {
        m.erredAt = 0;
        m.since = nowMs;
        return out;
    }
    if (m.armed && full === true && nowMs - m.since >= limitMs(strikes, m.erredAt > 0, waking) - EARLY_MS) out.stoodMs = nowMs - m.since;
    return out;
}

function _num(x) {
    return typeof x === "number" && isFinite(x);
}

function _copy(mem) {
    return { low: mem.low, pos: mem.pos, since: mem.since, armed: mem.armed, tickAt: mem.tickAt, bornAt: mem.bornAt, erredAt: mem.erredAt };
}
