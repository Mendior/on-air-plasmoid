/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Choosing WHICH directory entries deserve an audition when a station's
// saved address is dead — pure decisions, no network, under qmltestrunner.
// main.qml fetches and auditions; this file says who may audition for a
// dead address, and in what order.
.pragma library
.import "StreamLogic.js" as StreamLogic

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

// Two spellings of one address. The scheme, a trailing slash, letter case
// and blanks around a pasted address are noise; the click and vote lookup
// folds an address the same way.
function addrKey(u) {
    return (u || "").toString().trim()
           .replace(/^https?:\/\//i, "").replace(/\/$/, "").toLowerCase();
}

// Does a row edited by hand in the settings still name the station its
// directory uuid names? The uuid outranks everything downstream: the heal
// writes whatever byuuid answers over the saved address without a second
// question, and logos and votes follow it. So an edit keeps it only where
// the row could have earned that write WITHOUT a uuid: the address left
// alone (a rename), or a move the commit gate above would itself call
// permanent — same own domain, same name. A new domain, a new name or a
// shared landlord lets it go; the typed address then stays the one thing
// the directory cannot overrule, and the next vote or click resolves a
// fresh uuid from the name and the new address.
// Contract: true = the uuid stays. Scheme, a trailing slash and letter
// case are not a move. null and undefined are answered, never thrown on.
function editKeepsIdentity(oldName, oldUrl, newName, newUrl) {
    if (addrKey(oldUrl) === addrKey(newUrl)) return true;
    var oldBase = StreamLogic.baseDomain(StreamLogic.hostOf((oldUrl || "").toString().trim()));
    var newBase = StreamLogic.baseDomain(StreamLogic.hostOf((newUrl || "").toString().trim()));
    var text = function(n) { return n === undefined || n === null ? "" : String(n); };
    return commitVerdict(false, oldBase, newBase,
                         normName(text(oldName)) === normName(text(newName))) === "permanent";
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

// A row's country as a two-letter code, "??" when the directory has none.
// One row in thirty on "Rock FM", four in thirty on "Kiss FM" (2026-09-21).
function rowCountry(r) {
    var c = ((r || {}).countrycode || "").toString().toUpperCase();
    return /^[A-Z]{2}$/.test(c) ? c : "??";
}

// The country the directory files the SAVED station under, "" when it
// cannot say. Two witnesses. First the station's own record: a row whose
// address is the saved one. It stays listed after the stream dies, marked
// broken. "Deep House Lounge" from the shipped list answered with exactly
// one row on 2026-09-21: its own, lastcheckok 0, filed under US. That is
// why an ordinary heal does not ask for hidebroken (searchTail). Then the
// rows under the station's own non-shared domain, when they all name one
// country. Witnesses that disagree prove nothing, and a row without a
// country says nothing either way.
// The saved logo is deliberately no witness: the favicon backfill fills an
// empty logo by NAME, so it can come from the very namesake this question
// exists to keep out.
function homeCountry(results, savedUrl) {
    var saved = (savedUrl || "").toString().trim();
    var want = addrKey(saved);
    var base = StreamLogic.baseDomain(StreamLogic.hostOf(saved));
    var roof = base !== "" && !sharedBase(base);
    var own = "", under = "";
    for (var i = 0; i < (results || []).length; i++) {
        var r = results[i] || {};
        var c = rowCountry(r);
        if (c === "??") continue;
        if (want !== "" && (addrKey(r.url) === want || addrKey(r.url_resolved) === want)) {
            if (own === "") own = c;
            else if (own !== c) own = "!";
        } else if (roof && StreamLogic.baseDomain(StreamLogic.hostOf((r.url_resolved || r.url || "").toString())) === base) {
            if (under === "") under = c;
            else if (under !== c) under = "!";
        }
    }
    if (own !== "") return own === "!" ? "" : own;
    return under === "!" ? "" : under;
}

// The name search's query tail. An ordinary heal asks for broken rows as
// well, because the saved station's own record is one of them and it is the
// witness to its country (homeCountry). Broken rows cost seats in the
// thirty: none on "Rock FM" on 2026-09-21, none or one on the four names
// tried. A wake-up asks exactly as it always has, so its ladder is the
// old one row for row.
function searchTail(anySound) {
    return (anySound === true ? "&hidebroken=true" : "") + "&order=votes&reverse=true&limit=30";
}

// The name rung, whole: which rows of a name search may audition for a dead
// saved address, in what order, and which may not.
// A name is not an identity. "Rock FM" answered with five exact-name rows
// from four countries (RU, ES, EE, ES, LT; measured 2026-09-21), and on
// name, domain and bitrate alone the Estonian 320 kb/s stream auditioned
// first for a Spanish listener's station, under their name and their logo.
// Inside one country the same exact name is nearly always one broadcaster's
// mounts, so the country is the question worth asking. Votes are not: they
// pick the Russian one (58 976).
//   results    the directory's answer, publicly writable rows
//   savedUrl   the dead address; savedName the listener's name for it
//   knownCc    the country from the station's uuid record, "" without one
//   anySound   a wake-up is ringing, or the caller has no way to ask about
//              a country yet (the search preview): nothing is refused and
//              the ladder is the old one, same rows in the same order
// Returns { cands: rows best first, refused: how many were left out }.
// Every row carries near (own domain, or the station's country) and kin
// (near, the exact name, and a country that came from a witness rather
// than from the rows agreeing among themselves). Only kin plays without
// the notice naming it. A row never carries a favicon: a name search's
// logo must not reach the saved station.
function ladder(results, savedUrl, savedName, knownCc, anySound) {
    var saved = (savedUrl || "").toString();
    var norm = normName(savedName === undefined || savedName === null ? "" : String(savedName));
    var base = StreamLogic.baseDomain(StreamLogic.hostOf(saved));
    // A shared streaming host is a landlord, not a home: its bonus would
    // rank a stranger's tenancy above the station's real name match.
    var roof = base !== "" && !sharedBase(base);
    var rows = [], i;
    for (i = 0; i < (results || []).length; i++) {
        var r = results[i] || {};
        // lastcheckok: the directory's own probe reached this address on
        // its latest sweep, which is the point of asking them.
        if (String(r.lastcheckok) !== "1") continue;
        var cand = (r.url_resolved || r.url || "").toString();
        // http(s) only. This address is auditioned straight into the
        // player, and a file: or data: row must never become its source.
        if (!/^https?:\/\//i.test(cand) || cand === saved) continue;
        var fmt = StreamLogic.streamFormat(cand);
        if (fmt === "playlist") continue;
        var rowNorm = normName(r.name);
        var rowBase = StreamLogic.baseDomain(StreamLogic.hostOf(cand));
        var home = roof && rowBase === base;
        var score = scoreRow(rowNorm, norm, home);
        if (score < 0) continue;
        var br = parseInt(r.bitrate) || 0;
        if (br >= 8000) br = Math.round(br / 1000);
        rows.push({ url: cand, score: score, bitrate: br, hls: fmt === "hls",
                    exact: rowNorm === norm, home: home, cc: rowCountry(r),
                    roof: sharedBase(rowBase) ? "" : rowBase,
                    name: (r.name || "").toString(), country: (r.country || "").toString() });
    }
    var cc = (knownCc || "").toString().toUpperCase();
    if (!/^[A-Z]{2}$/.test(cc)) cc = homeCountry(results, saved);
    var known = cc !== "";
    // What the best name tier present says about itself. A row without a
    // country abstains: it neither agrees nor objects. Alone in its tier it
    // stays, as the only answer there is; two of them prove nothing about
    // each other.
    var top = 0, agreed = "", blank = 0, roofs = "";
    for (i = 0; i < rows.length; i++)
        if (!rows[i].home && rows[i].score > top) top = rows[i].score;
    for (i = 0; i < rows.length; i++) {
        if (rows[i].home || rows[i].score !== top) continue;
        if (roofs === "") roofs = rows[i].roof === "" ? "!" : rows[i].roof;
        else if (roofs !== rows[i].roof) roofs = "!";
        if (rows[i].cc === "??") { blank++; continue; }
        if (agreed === "") agreed = rows[i].cc;
        else if (agreed !== rows[i].cc) agreed = "!";
    }
    // Nobody vouches for a country, but the tier may agree with itself.
    if (!known) cc = agreed === "!" ? "" : agreed !== "" ? agreed : blank === 1 ? "??" : "";
    // One station filed under many countries is not a crowd of namesakes.
    // "Dance Wave!" answered with 23 exact-name rows on 2026-09-21, every one
    // under dancewave.online, filed under HU, GR, US, AF, DE, CA, GB and no
    // country at all. Where the whole tier lives under one roof that is no
    // landlord, the filing is noise and the roof is the answer. With a known
    // country that only holds when the rows disagree among themselves: one
    // foreign broadcaster with two mounts is still a foreigner.
    var oneRoof = roofs !== "!" && roofs !== "" && (agreed === "!" || (!known && blank > 1)) ? roofs : "";
    var keep = [], refused = 0;
    for (i = 0; i < rows.length; i++) {
        var w = rows[i];
        w.near = w.home || (cc !== "" && w.cc === cc) || (oneRoof !== "" && w.roof === oneRoof);
        w.kin = w.exact && (w.home || (known && w.cc === cc));
        if (w.near || anySound === true) keep.push(w); else refused++;
    }
    return { cands: rank(keep), refused: refused };
}

// What the stopgap notice owes the listener about a candidate nothing
// vouches for: the directory's name for it and its country. "" for a row
// that is the station as far as the evidence goes. Catalogue text is only
// semi-trusted and a notification renders markup, hence the same scrub as
// SearchLogic.cleanLabel.
function strangerLabel(row, countryName) {
    if (!row || row.byUuid === true || row.kin === true) return "";
    var scrub = function(s) {
        return (s || "").toString().replace(/[<>&]/g, " ").replace(/\s+/g, " ").trim().substring(0, 60);
    };
    var n = scrub(row.name), c = scrub(countryName);
    if (n === "") return "";
    return c === "" ? n : n + " (" + c + ")";
}

// The identity rung's doors. byuuid answers with the station's own row, and
// that row holds two addresses: url_resolved, where the directory's checker
// ended up the last time it looked, and url, the one the station handed in.
// They differ on one row in nine (59 of the 500 most-voted on 2026-09-21,
// 54 of them a .pls or .m3u), because url is the station's playlist or a
// redirector in front of several servers. A station added from the search
// saves url_resolved, so that is usually also the address that just died:
// the resolved door then drops out as the saved one, and the front door is
// the only one left, and today nobody tries it.
// Contract: null when nobody answered (no reply, not a 200, not a JSON
// list); [] when the directory answered and has nothing to offer; else the
// doors worth an audition, both marked byUuid and carrying the gated logo.
// firstOnly is the wake-up's ladder: the single door it has always had.
// The logo gate arrives as a function because FaviconLogic asks this file
// about shared hosts, and two files cannot import each other.
function uuidRung(reply, orig, firstOnly, logoGate) {
    if (!reply || reply.status !== 200) return null;
    var rows = null;
    try { rows = JSON.parse(reply.responseText); } catch (e) { return null; }
    if (!Array.isArray(rows)) return null;
    var row = rows[0];
    if (!row || String(row.lastcheckok) !== "1") return [];
    var fav = logoGate(row.favicon);
    var doors = [(row.url_resolved || row.url || "").toString()];
    if (firstOnly !== true) doors.push((row.url || "").toString());
    var out = [];
    for (var i = 0; i < doors.length; i++) {
        // http(s) only, as on the name rung: the catalogue is publicly
        // writable and this address goes straight into the player.
        if (!/^https?:\/\//i.test(doors[i]) || doors[i] === orig) continue;
        if (out.length > 0 && out[0].url === doors[i]) continue;
        out.push({ url: doors[i], byUuid: true, favicon: fav });
    }
    return out;
}

// The country the uuid record files the station under, for the rung below.
// Contract: "" when there is no answer or no country in it.
function uuidCountry(reply) {
    try {
        return (((JSON.parse(reply.responseText) || [])[0] || {}).countrycode || "").toString();
    } catch (e) { return ""; }
}

// The ladder ran empty and no rung ever heard from the directory: every
// mirror down, or a login portal's page where the list should be. That is
// not the directory saying the station is gone, and the ten-minute lookup
// lock must not stand on it: with the default three knocks (30 + 60 + 120 s,
// all inside the lock) a play pressed before the Wi-Fi was up bounced every
// one off the lock and the order ended with the new address one question
// away. The lock was also the only thing holding the telling to one in ten
// minutes where a stream buffers and dies, because every buffer resets the
// backoff count. So the stamp remembers the telling instead: above zero a
// moment that holds the lock, below zero minus the moment the listener was
// told the directory is out of reach, zero asked in silence.
// Contract: null when the directory did answer (today's road), else
// { stamp, say }. Only the first give-up of an outage speaks.
function unheard(answered, attempts, prior, nowMs) {
    if (answered === true) return null;
    var first = (attempts | 0) === 0;
    var ago = prior < 0 ? nowMs + prior : -1;
    if (ago >= 0 && ago < 600000) return { stamp: first ? -prior : prior, say: false };
    return first ? { stamp: -nowMs, say: true } : { stamp: 0, say: false };
}

// One directory lookup per station per ten minutes, so a station that is
// simply offline is not hammered with searches. Stamps of zero and below
// hold nothing (see unheard).
function lockHolds(stamp, nowMs) {
    return stamp > 0 && nowMs - stamp < 600000;
}
