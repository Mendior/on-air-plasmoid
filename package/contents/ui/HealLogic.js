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

// Streaming hosts that rent one base domain to thousands of unrelated
// stations. A shared base is a landlord, not an identity: two tenants of
// zeno.fm have nothing in common, so "same domain" proves nothing there.
// Measured from the catalog's 3000 most-voted stations (2026-08-20):
// streamtheworld 171 distinct stations, zeno.fm 163, radiojar 45 — plus
// the CDNs and the well-known rent-a-stream providers below the cut.
var SHARED_STREAM_HOSTS = {
    "streamtheworld.com": true, "zeno.fm": true, "infomaniak.ch": true,
    "hostingradio.ru": true, "radiojar.com": true, "laut.fm": true,
    "cdnstream1.com": true, "cdnstream.com": true, "fastcast4u.com": true,
    "radio.co": true, "radioca.st": true, "cdnvideo.ru": true,
    "securenetsystems.net": true, "akamaized.net": true,
    "bitgravity.com": true, "play.cz": true, "live24.gr": true,
    "shoutca.st": true, "myradiostream.com": true, "caster.fm": true,
    "radioboss.fm": true, "airtime.pro": true, "live365.com": true,
    "cloudfront.net": true, "fastly.net": true, "zenolive.com": true,
    "radioking.com": true, "voscast.com": true, "torontocast.com": true,
    "fluidstream.net": true, "mixlr.com": true, "yesstreaming.net": true
};
// Left out on purpose: broadcaster-family CDNs (rndfnk.com is ARD's,
// bitgravity.com carries All India Radio) and closed B2B relays — a
// stranger cannot rent a mount there, so the shared-roof risk the list
// exists for does not apply, and their tenants keep the own-domain
// repair. Single-operator names (1.fm, somafm.com, qurango.net) are
// families too, however many stations they run.

function sharedBase(base) {
    return SHARED_STREAM_HOSTS[(base || "").toLowerCase()] === true;
}

// One directory row's score, or -1 when it earns no audition. Exact
// normalized name beats contains-match; the station's own base domain
// (it merely changed port/mount) beats everything — and is the only
// evidence strong enough to overwrite the saved address later. The
// caller feeds sameBase=false for a shared host: a landlord in common
// must not outrank an exact name on the station's real home.
function scoreRow(rowNorm, norm, sameBase) {
    var score = -1;
    if (norm !== "" && rowNorm === norm) score = 2;
    else if (norm !== "" && rowNorm.indexOf(norm) !== -1) score = 1;
    if (score < 0) return -1;
    return sameBase ? score + 2 : score;
}

// May this healed address overwrite the SAVED one? The catalog is
// publicly writable, so the bar is identity, not similarity: the
// directory's own uuid row, or the station's own (non-shared) domain
// carrying the exact saved name. A contains-match on a shared host
// once rewrote a user's station into a different tenant for good —
// that class plays as a session stopgap and never touches the list.
function commitVerdict(byUuid, oldBase, newBase, exactName) {
    if (byUuid) return "permanent";
    if (oldBase === "" || newBase !== oldBase) return "stopgap";
    if (sharedBase(oldBase)) return "stopgap";
    return exactName === true ? "permanent" : "stopgap";
}

// Order scored candidates into the audition ladder. Real streams first —
// HLS sinks to the bottom but is NOT dropped: the FFmpeg backend speaks
// HLS, and a station whose only live door is HLS deserves that door.
// Higher score first; inside a score level the higher bitrate — healing
// through the directory should come back BETTER, not merely alive.
// Duplicate addresses keep their best position. Returns the row
// objects, not bare urls — the commit gate needs each candidate's
// exact-name verdict to survive the ranking.
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
        out.push(sorted[i]);
    }
    return out;
}
