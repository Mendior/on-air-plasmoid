/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Which episodes are heard, half-heard, or fresh — pure decisions over the
// played set and the resume-position map, under qmltestrunner. The engine
// keeps a played map (episodeKey -> timestamp) and a positions map
// (episodeKey -> {sec,dur,at}); this file turns the two into one state per
// episode and the filter that hides what you have already heard. No I/O.
.pragma library

// The three states an episode can be in. "played" wins over a leftover
// position (finishing marks played AND clears the bookmark, but a manual
// mark-played on a half-listened episode must still read as played).
function stateOf(playedMap, posMap, key) {
    if (playedMap && playedMap[key] !== undefined) return "played"
    var p = posMap && posMap[key]
    if (p && p.sec > 0) return "in-progress"
    return "unplayed"
}

// Does an episode in `state` pass the filter? mode: 0 = all, 1 = unplayed
// (anything not fully played — fresh OR in-progress, so a half-heard
// episode stays visible to finish), 2 = in-progress only.
function matchesFilter(state, mode) {
    if (mode === 1) return state !== "played"
    if (mode === 2) return state === "in-progress"
    return true
}

// Mark an episode played, stamped now (the timestamp drives the LRU prune).
// Returns the SAME map, mutated — the caller owns persistence and the
// change tick.
function markPlayed(playedMap, key, nowMs) {
    if (key) playedMap[key] = nowMs || 0
    return playedMap
}

// Un-mark: back to unplayed (or in-progress if a position survives).
function markUnplayed(playedMap, key) {
    if (key) delete playedMap[key]
    return playedMap
}

// The played map, capped: the newest `cap` keys survive so a heavy
// listener's config blob cannot grow without bound. Returns a NEW map.
function prunePlayed(playedMap, cap) {
    var keys = Object.keys(playedMap || {})
    if (keys.length <= cap) return playedMap || {}
    keys.sort(function(a, b) { return (playedMap[b] || 0) - (playedMap[a] || 0) })
    var out = {}
    for (var i = 0; i < cap; i++) out[keys[i]] = playedMap[keys[i]]
    return out
}

// True a few seconds before the true end — the point where an episode is
// "done" enough to auto-mark played and drop its resume bookmark, so it
// does not offer to resume at the credits. dur/pos in seconds.
function isNearEnd(posSec, durSec) {
    return durSec > 0 && posSec >= durSec - 10
}
