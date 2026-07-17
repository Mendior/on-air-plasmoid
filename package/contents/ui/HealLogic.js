/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Choosing WHICH directory entries deserve an audition when a station's
// saved address is dead — pure decisions, no network, under qmltestrunner.
// main.qml fetches and auditions; this file ranks the ladder.
.pragma library

// The normalized name form both sides of every comparison use.
function normName(s) {
    return (s || "").replace(/\s+/g, " ").trim().toLowerCase();
}

// One directory row's score, or -1 when it earns no audition. Exact
// normalized name beats contains-match; the station's own base domain
// (it merely changed port/mount) beats everything — and is the only
// evidence strong enough to overwrite the saved address later.
function scoreRow(rowNorm, norm, sameBase) {
    var score = -1;
    if (norm !== "" && rowNorm === norm) score = 2;
    else if (norm !== "" && rowNorm.indexOf(norm) !== -1) score = 1;
    if (score < 0) return -1;
    return sameBase ? score + 2 : score;
}

// Order scored candidates into the audition ladder. Real streams first —
// HLS sinks to the bottom but is NOT dropped: the FFmpeg backend speaks
// HLS, and a station whose only live door is HLS deserves that door.
// Higher score first; inside a score level the higher bitrate — healing
// through the directory should come back BETTER, not merely alive.
// Duplicate addresses keep their best position.
function rank(cands) {
    var sorted = cands.slice();
    sorted.sort(function(a, b) {
        if ((a.hls === true) !== (b.hls === true)) return a.hls ? 1 : -1;
        if (b.score !== a.score) return b.score - a.score;
        return (b.bitrate || 0) - (a.bitrate || 0);
    });
    var seen = {}, out = [];
    for (var i = 0; i < sorted.length; i++) {
        if (seen[sorted[i].url]) continue;
        seen[sorted[i].url] = true;
        out.push(sorted[i].url);
    }
    return out;
}
