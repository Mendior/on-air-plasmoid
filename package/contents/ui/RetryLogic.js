/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// How long to keep knocking at a station that went quiet.
//
// The widget cannot tell "the connection dropped" from "this station is
// gone" — three of the four ways a stream dies arrive with no error at
// all, just silence. Time tells them apart without needing to know:
// something that really dropped answers again within seconds to a couple
// of minutes, and something that is gone never answers. So the ladder is
// given a budget instead of a diagnosis.
//
// Counted in knocks, not minutes, deliberately — the interval sequence is
// fixed, so a knock count IS a duration, and it needs no clock to compare
// against. Wall-clock arithmetic has been the source of two separate bugs
// in this file's neighbourhood.
.pragma library

// The ladder itself: 30 s, 1, 2, 4, 8 minutes, then flat at 10. An outage
// that ends early is caught by the close knocks; a long one is not worth
// hammering. Widening rather than fixed so a station coming back up gets
// found fast without the widget behaving like a retry storm.
function nextRetryMs(attempts) {
    var n = attempts | 0;
    if (n < 0) n = 0;
    if (n > 5) n = 5;
    return Math.min(600000, 30000 * Math.pow(2, n));
}

// May the ladder arm for another round?
//
// `exempt` is the alarm's standing order and it wins over everything: a
// wake-up was promised in advance and must not end in silence because of
// a setting about ordinary listening. `cap` of 0 means knock until it
// comes back — the behaviour before the budget existed, kept reachable.
function shouldKnock(enabled, exempt, attempts, cap) {
    if (exempt === true) return true;
    if (enabled !== true) return false;
    var c = cap | 0;
    if (c <= 0) return true;
    return (attempts | 0) < c;
}

// What the chosen cap costs in wall time, for the one message the user
// actually sees. Derived from the ladder rather than written down beside
// it, so the two can never drift apart.
function budgetMs(cap) {
    var c = cap | 0;
    if (c <= 0) return 0;
    var total = 0;
    for (var i = 0; i < c; i++) total += nextRetryMs(i);
    return total;
}

// Is the standing order older than it is allowed to get?
//
// The budget above is counted in knocks, and the knocks ride timers that
// stand still while the machine sleeps: a station that goes quiet at eleven
// with the lid closed a minute later still has knocks left at eight the next
// morning, and the network coming back hands it one. So the order also
// carries the wall-clock moment it went quiet. Twice the budget and five
// minutes, because the knocks and the connects between them take longer than
// the sum of the waits (3.7 to 7 minutes for the default three), and the
// point is to end an order hours old, not to race the ladder to its last
// knock. An alarm never expires, and neither does a listener's own choice of
// knocking until it comes back.
function orderExpired(sinceMs, nowMs, exempt, cap) {
    if (exempt === true) return false;
    var c = cap | 0;
    if (c <= 0 || !(sinceMs > 0)) return false;
    return nowMs - sinceMs > budgetMs(c) * 2 + 300000;
}

// Is a quiet station waiting for its next knock?
//
// wantsPlaying: the standing order holds. attempts: knocks armed since the
// last time data flowed (the counter the ladder keeps; buffering, a stop and
// a spent budget all put it back to 0).
function betweenKnocks(wantsPlaying, attempts) {
    return wantsPlaying === true && (attempts | 0) > 0;
}

// Which moment does the deadline above measure from?
//
// `orderExpired` needs a moment to subtract, and until now `_replayOrder`
// handed it `Date.now()` whenever the order carried no quiet stamp — which
// always passes, since nothing is older than the instant it is asked about.
// That was not a corner: main.qml clears the quiet stamp every time audio
// buffers, so a station playing normally carries no stamp at all. Radio on at
// eleven, lid closed, network back at eight: no stamp, stamped "now", deadline
// cleared, and the station plays nine hours late — the very report the
// deadline was added for.
//
// quietSince: when the ladder armed, 0 while audio flows. heardAt: the last
// moment the widget was alive with this order and audio running, which a timer
// keeps — and that timer stands still with the machine, so after a night it
// still reads last night. nowMs: only for an order that has neither, where the
// first try has to be allowed.
function orderSince(quietSince, heardAt, nowMs) {
    if (quietSince > 0) return quietSince;
    if (heardAt > 0) return heardAt;
    return nowMs;
}
