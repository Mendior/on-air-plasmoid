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
