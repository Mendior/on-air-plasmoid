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
.import "HostGuard.js" as HostGuard

// The normalized name form both sides of every comparison use.
function normName(s) {
    // String(): the directory is publicly writable, and one row whose name
    // arrived as a number used to throw here and take the other twenty-nine
    // rows of the answer down with it.
    return (s === undefined || s === null ? "" : String(s)).replace(/\s+/g, " ").trim().toLowerCase();
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
    "fluidstream.net": true, "mixlr.com": true, "yesstreaming.net": true,
    // Rent-a-stream hosts met in a listener's own list and in the shipped
    // one (2026-11-10); each rents a port or a subdomain to anybody.
    "fast-serv.com": true, "asurahosting.com": true, "streamerr.co": true,
    "streemlion.com": true, "listen2myradio.com": true,
    // Free dynamic-DNS names: anyone can take a.ddns.net next to yours, so
    // the base proves nothing about who runs the stream.
    "ddns.net": true, "duckdns.org": true, "no-ip.org": true, "no-ip.biz": true,
    "no-ip.info": true, "noip.me": true, "hopto.org": true, "zapto.org": true,
    "sytes.net": true, "myftp.org": true, "myftp.biz": true, "serveftp.com": true,
    "servegame.com": true, "redirectme.net": true, "dynu.net": true,
    "freeddns.org": true, "mooo.com": true, "dyndns.org": true, "homeip.net": true
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
// shared landlord lets it go; the address typed in then stays the one
// thing the directory cannot overrule.
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
        // http(s) only (frontDoor). This address is auditioned straight into
        // the player, and a file: or data: row must never become its source.
        var cand = frontDoor(r).filter(function(d) { return !sameDoor(d, saved); })[0] || "";
        if (cand === "") continue;
        var fmt = StreamLogic.streamFormat(cand);
        if (fmt === "playlist") continue;
        var rowNorm = normName(r.name);
        var rowBase = StreamLogic.baseDomain(StreamLogic.hostOf(cand));
        // A bare address has no name to share: another port on the same
        // number is another server, rented to anyone.
        var home = roof && rowBase === base && (!_bareAddr(base) || _port(cand) === _port(saved));
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

// A directory row's doors in the order worth trying. url_resolved is where
// the checker ended up last time, url the address the station handed in.
// The handed-in one leads when it is a stream of the same family, which is
// what a CDN's router looks like: router.euddn.net kept one token for every
// station from January to November 2026 while the edges it hands out
// rotated and the old ones' certificate expired. A playlist or HLS list
// stays second, because the alarm and the recorder play an address as it is.
// Contract: up to two http(s) addresses, no repeats; [] for nothing usable.
function frontDoor(row) {
    var r = row || {};
    // http(s) on a public host. The catalogue is publicly writable and no
    // one clicked, so a row may not send the player knocking on the router.
    var web = function(u) {
        var t = (u || "").toString();
        if (!/^https?:\/\//i.test(t)) return "";
        var host = HostGuard.hostOf(t);
        return host !== "" && !HostGuard.isPrivateHost(host) ? t : "";
    };
    var url = web(r.url), res = web(r.url_resolved);
    var fmt = url === "" ? "" : StreamLogic.streamFormat(url);
    var kin = url !== "" && res !== "" && fmt !== "playlist" && fmt !== "hls"
              && StreamLogic.baseDomain(StreamLogic.hostOf(url)) === StreamLogic.baseDomain(StreamLogic.hostOf(res));
    var doors = kin ? [url, res] : [res, url];
    // One door in two spellings is one audition, not two.
    if (sameDoor(doors[0], doors[1])) doors = [doors[0]];
    return doors.filter(function(d, i) { return d !== "" && doors.indexOf(d) === i; });
}

// The identity rung's doors. byuuid answers with the station's own row, and
// that row holds two addresses: url_resolved, where the directory's checker
// ended up the last time it looked, and url, the one the station handed in.
// They differ on one row in nine (59 of the 500 most-voted on 2026-09-21,
// 54 of them a .pls or .m3u), because url is the station's playlist or a
// redirector in front of several servers. A station added from the search
// saved url_resolved, so that is usually also the address that just died
// and drops out as the saved one; frontDoor puts a same-family redirector
// first anyway, so the next save is not another edge that rots.
// Contract: null when nobody answered (no reply, not a 200, not a JSON
// list); [] when the directory answered and has nothing to offer; else the
// doors worth an audition in frontDoor's order, all marked byUuid and
// carrying the gated logo. firstOnly is the wake-up's ladder: one door,
// the first one that is not the saved address.
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
    // http(s) only (frontDoor), as on the name rung: the catalogue is
    // publicly writable and this address goes straight into the player.
    var doors = frontDoor(row).filter(function(d) { return !sameDoor(d, orig); });
    if (firstOnly === true) doors = doors.slice(0, 1);
    return doors.map(function(d) { return { url: d, byUuid: true, favicon: fav }; });
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

// Two spellings of one door: the same scheme, host and path. The host's
// letter case, a trailing slash and blanks around a pasted address are
// noise. The scheme is not: a TLS port that closed leaves the plain one,
// and that is a move the list has to learn. Nor is the path's case, which
// an Icecast mount means. addrKey folds both, for the questions where a
// person retyped an address; this is the one for "did the station move".
// Contract: false for anything that is not an http(s) address, so two
// empty addresses are never the same door.
function sameDoor(a, b) {
    var key = function(u) {
        var m = (typeof u === "string" ? u.trim() : "").match(/^(https?:\/\/)([^\/?#]+)(.*)$/i);
        return m ? m[1].toLowerCase() + m[2].toLowerCase() + m[3].replace(/\/$/, "") : "";
    };
    var ka = key(a);
    return ka !== "" && ka === key(b);
}

function _bareAddr(host) {
    return host.charAt(0) === "[" || /^\d+(\.\d+){3}$/.test(host);
}

// An address in the parts the questions below ask about, null for anything
// that is not http(s). The port is "" where it is the scheme's own.
function _addr(u) {
    var m = (typeof u === "string" ? u.trim() : "")
            .match(/^(https?):\/\/(?:[^\/?#@]*@)?(\[[^\]]*\]|[^\/:?#]+)(?::(\d+))?([^?#]*)/i);
    if (!m) return null;
    var scheme = m[1].toLowerCase(), port = m[3] || "";
    if ((scheme === "http" && port === "80") || (scheme === "https" && port === "443")) port = "";
    return { scheme: scheme, host: m[2].toLowerCase(), port: port, path: m[4] === "" ? "/" : m[4] };
}

function _port(u) {
    var a = _addr(u);
    return a ? a.port : "";
}

function _origin(a) {
    return a.scheme + "://" + a.host + (a.port !== "" ? ":" + a.port : "");
}

// ── The same mount on another server ────────────────────────────────────
// A broadcaster's CDN moves a mount from one edge to another and the
// address a listener saved answers 404, while the station plays on. Sky
// Media did it to five mounts around 2026-10-22: seven rows of one home
// list went quiet, the directory had a usable row for two of them, and
// every one played from skymedia-live.bitflip.ee/<mount> (measured
// 2026-11-10). A mount's own name on the station's own domain is who the
// station is, whatever server carries it this month.

// Mount names every station uses say nothing about which station it is.
var _PLAIN_MOUNTS = {
    "stream": true, "streams": true, "live": true, "listen": true, "radio": true,
    "play": true, "player": true, "audio": true, "sound": true, "music": true,
    "mount": true, "relay": true, "proxy": true, "icecast": true, "shoutcast": true,
    "autodj": true, "index": true, "playlist": true, "master": true, "main": true,
    "default": true, "high": true, "medium": true, "mobile": true, "hifi": true,
    "best": true, "good": true, "normal": true, "standard": true, "source": true,
    "direct": true, "online": true, "onair": true, "webradio": true, "internet": true,
    "channel": true, "station": true, "broadcast": true, "listenlive": true,
    "livestream": true, "simulcast": true, "radiostream": true, "mpeg": true,
    "aacp": true, "aacplus": true, "flac": true, "opus": true
};

// The last piece of an address's path when it is a name of its own: "RETRO",
// "retro1.mp3", never "stream", "live.mp3", ";" or "128". Fewer than four
// letters name nothing either ("NRJ" could be anyone's).
// Contract: the piece as written, or "".
function mountOf(url) {
    var a = _addr(url);
    if (!a) return "";
    var piece = a.path.substring(a.path.lastIndexOf("/") + 1);
    var core = piece.toLowerCase().replace(/\.(mp3|aacp?|og[ga]|opus|flac|m3u8?|pls|ts)$/, "")
                    .replace(/[^a-zà-ɏЀ-ӿ]/g, "");
    return core.length >= 4 && _PLAIN_MOUNTS[core] !== true ? piece : "";
}

// Is otherUrl the saved mount on a sibling server? The station's own domain
// (no landlord), the same scheme, port and path, a mount with a name of its
// own, and two hosts that differ only in their numbers, as edge02 and
// edge43 do. A bare address has only itself for a domain, so it has no
// sibling to be mistaken for.
function mountTwin(savedUrl, otherUrl) {
    var a = _addr(savedUrl), b = _addr(otherUrl);
    if (!a || !b || mountOf(savedUrl) === "") return false;
    var base = StreamLogic.baseDomain(a.host);
    if (base === "" || sharedBase(base)) return false;
    if (StreamLogic.baseDomain(b.host) !== base) return false;
    if (a.scheme !== b.scheme || a.port !== b.port || a.path !== b.path) return false;
    return a.host.replace(/\d+/g, "#") === b.host.replace(/\d+/g, "#");
}

// Where the saved mount would be under a relative's roof: the lead's own
// server, the saved path. A lead is another address on the saved station's
// domain: a row of the same family in the listener's list, or where a
// directory row's door landed.
// Contract: "" when the lead is no relative (another domain, a landlord, a
// bare address), is the dead server itself, or the mount has no name.
function kinGuess(savedUrl, leadUrl) {
    var a = _addr(savedUrl), b = _addr(leadUrl);
    if (!a || !b || mountOf(savedUrl) === "") return "";
    var base = StreamLogic.baseDomain(a.host);
    if (base === "" || _bareAddr(a.host) || sharedBase(base)) return "";
    if (StreamLogic.baseDomain(b.host) !== base || _origin(a) === _origin(b)) return "";
    return _origin(b) + a.path;
}

// A stream answered: a 2xx that is not a page. An error page behind a
// polite 200 is the usual way a CDN says no. An old SHOUTcast names no
// type at all and still plays.
function aliveAnswer(status, contentType) {
    if (!(status >= 200 && status < 300)) return false;
    return !/^\s*(text\/|application\/(json|xml|xhtml))/i.test(contentType || "");
}

// May a guess that answered be taken for the saved station? Only when the
// answer came from the saved mount's twin: the guess itself where nothing
// redirected, else where Qt says it ended. A door that plays but does not
// say where from proves nothing about whose sound it is.
function kinAccepts(savedUrl, guessUrl, status, contentType, landedUrl) {
    if (!aliveAnswer(status, contentType)) return false;
    return mountTwin(savedUrl, (landedUrl || "") === "" ? guessUrl : landedUrl);
}

// Every address that may know where the saved mount went: the listener's
// own rows on the saved station's domain first (no question asked of
// anyone), then both addresses of each directory row, the resolved one
// first because it is the likelier relative.
function kinLeads(savedUrl, ownRows, dirRows) {
    var a = _addr(savedUrl), out = [], i;
    if (!a) return out;
    var base = StreamLogic.baseDomain(a.host);
    for (i = 0; i < (ownRows || []).length; i++) {
        var own = _addr((ownRows[i] || {}).hostname);
        if (own && StreamLogic.baseDomain(own.host) === base && !sameDoor(ownRows[i].hostname, savedUrl))
            out.push(ownRows[i].hostname);
    }
    for (i = 0; i < (dirRows || []).length; i++) {
        var r = dirRows[i] || {};
        if (_addr(r.url_resolved)) out.push(r.url_resolved);
        if (_addr(r.url)) out.push(r.url);
    }
    return out;
}

// What to ask, in order: guesses first (the saved mount under each
// relative's roof, a request to the station's own CDN), then at most three
// doors on other domains, asked only for where they land. Six guesses and
// three doors bound a hunt nobody clicked for.
// Contract: { guesses, doors }, both empty where a twin cannot exist.
function kinPlan(savedUrl, leads) {
    var plan = { "guesses": [], "doors": [] };
    var a = _addr(savedUrl);
    if (!a || mountOf(savedUrl) === "") return plan;
    var base = StreamLogic.baseDomain(a.host);
    if (base === "" || _bareAddr(a.host) || sharedBase(base)) return plan;
    for (var i = 0; i < (leads || []).length; i++) {
        var b = _addr(leads[i]);
        if (!b || HostGuard.isPrivateHost(b.host) || sameDoor(leads[i], savedUrl)) continue;
        if (StreamLogic.baseDomain(b.host) === base) {
            var g = kinGuess(savedUrl, leads[i]);
            if (g !== "" && plan.guesses.indexOf(g) === -1 && plan.guesses.length < 6) plan.guesses.push(g);
        } else {
            var door = _origin(b) + b.path;
            if (plan.doors.indexOf(door) === -1 && plan.doors.length < 3) plan.doors.push(door);
        }
    }
    return plan;
}

var _PLAIN_WORDS = { "radio": true, "raadio": true, "rádio": true, "radyo": true, "station": true,
                     "online": true, "live": true, "music": true, "hits": true, "plus": true,
                     "stream": true, "channel": true, "digital": true };

// The wider question, for a station the name search knows nothing about:
// the first word of its name that is not every station's word. "Raadio
// Relax International" asks for "relax", and the directory's "Relax FM
// Eesti" answers with the family's door.
// Contract: a word of four letters or more, lower case, or "".
function kinWord(name) {
    var words = normName(name).split(/[^a-z0-9à-ɏЀ-ӿ]+/);
    for (var i = 0; i < words.length; i++)
        if (words[i].length >= 4 && _PLAIN_WORDS[words[i]] !== true && !/^\d+$/.test(words[i]))
            return words[i];
    return "";
}

// Two-letter domains that are sold to anyone and name no country.
var _VANITY_TLDS = { "fm": true, "am": true, "tv": true, "io": true, "co": true, "me": true,
                     "ly": true, "to": true, "cc": true, "ws": true, "nu": true, "tk": true,
                     "ai": true, "gg": true, "im": true, "sh": true, "st": true, "la": true };

// The country a saved address's own domain names: bitflip.ee is Estonian,
// bbc.co.uk British. It narrows the wider question for a row that carries
// no country of its own, which is most rows added by hand.
// Contract: a two-letter code, or "" where the domain says nothing.
function tldCountry(savedUrl) {
    var a = _addr(savedUrl);
    if (!a || _bareAddr(a.host)) return "";
    var tld = a.host.substring(a.host.lastIndexOf(".") + 1);
    if (!/^[a-z]{2}$/.test(tld) || _VANITY_TLDS[tld] === true) return "";
    return tld === "uk" ? "GB" : tld.toUpperCase();
}

// The wider question as a directory path, "" when the name has no word
// worth asking for. The country narrows it when one is known: "relax"
// alone is answered by thirty stations from everywhere, "relax" in EE by
// the family whose doors lead home.
function kinSearchPath(name, cc) {
    var word = kinWord(name);
    if (word === "") return "";
    var code = (typeof cc === "string" ? cc : "").toUpperCase();
    return "/json/stations/search?name=" + encodeURIComponent(word)
           + (/^[A-Z]{2}$/.test(code) ? "&countrycode=" + code : "")
           + "&hidebroken=true&order=votes&reverse=true&limit=30";
}

// ── One failure is not a death ──────────────────────────────────────────
// An encoder restarts, a link drops for a second, a laptop wakes. The heal
// used to ask the directory two and a half seconds after any one error
// and, for a row with a uuid or its own domain, write the answer over the
// saved address at the first buffer: "Star FM" at 320 kb/s would have
// become its 96 kb/s mount for good (worked through on the directory's
// answers of 2026-11-10; no such move in fourteen days of this desk's log).

// Has the saved address had its second chance? One fresh open, at most
// once a minute, before anybody asks where the station went.
function knockFirst(lastKnockMs, nowMs) {
    var ago = nowMs - lastKnockMs;
    return !(ago >= 0 && ago < 60000);
}

var DEATH_PROOF_MS = 300000;

// When may a move that the identity gate allows be written? "now" over an
// address first seen dead five minutes ago or more, "later" before that,
// "never" for a stopgap. firstDeadMs: when this session first saw the
// saved address fail, 0 when it never did.
function moveWhen(verdict, firstDeadMs, nowMs) {
    if (verdict !== "permanent") return "never";
    var dead = nowMs - firstDeadMs;
    return firstDeadMs > 0 && dead >= DEATH_PROOF_MS ? "now" : "later";
}

// How long until the second look at an address that is "later".
function proofWaitMs(firstDeadMs, nowMs) {
    var dead = nowMs - firstDeadMs;
    if (!(firstDeadMs > 0) || !(dead >= 0)) return DEATH_PROOF_MS;
    return Math.max(1000, DEATH_PROOF_MS - dead);
}

// How many looks in a row, five minutes apart, an address may go unanswered
// before its silence counts.
var PROOF_LOOKS = 3;

// What the second look makes of the old address's answer. silent: how many
// looks in a row, this one included, nobody answered at all.
// Contract: "keep" when the address is a stream again; "move" when its
// server says it is gone, or when nobody has answered there on PROOF_LOOKS
// looks running; "again" while it is not known.
// Anything that was not a stream used to be a "move", a look that timed out
// included, and a slow three seconds rewrote the listener's list. Only two
// things are proof now. The server's own word: 403, 404 or 410. And silence
// that lasts, status 0 on look after look while the new address played on,
// which is what a host that is gone for good looks like. A server that says
// anything else is still there, and the caller starts the count again. -1
// is KinHunt's answer whose last hop Qt does not name: on a Qt that never
// names it, a living address gives nothing but those.
function proofVerdict(status, contentType, silent) {
    if (aliveAnswer(status, contentType)) return "keep";
    if (status === 403 || status === 404 || status === 410) return "move";
    return status === 0 && silent >= PROOF_LOOKS ? "move" : "again";
}

// Did the directory answer the question?
// Contract: true for a 200 whose body is a JSON list, the empty one
// included; false for anything else and for no reply at all.
// A page or an object behind a 200 is a directory that is unwell. Taken for
// an answer it stamped the ten-minute lock and the listener was told the
// station is nowhere.
function answered(reply) {
    if (!reply || reply.status !== 200) return false;
    try { return Array.isArray(JSON.parse(reply.responseText)); } catch (e) { return false; }
}

// A directory reply as its rows: [] for no reply, a status that is not 200,
// a body that is not a JSON list. The kin rung reads every rung's rows for
// doors, whatever the rung itself made of them.
function replyRows(reply) {
    if (!reply || reply.status !== 200) return [];
    var rows = null;
    try { rows = JSON.parse(reply.responseText); } catch (e) { return []; }
    return Array.isArray(rows) ? rows : [];
}

// Can this saved address have a twin at all? A mount with a name of its
// own on a domain that is the station's: no landlord, no bare address.
function kinPossible(savedUrl) {
    var a = _addr(savedUrl);
    if (!a || mountOf(savedUrl) === "") return false;
    var base = StreamLogic.baseDomain(a.host);
    return base !== "" && !_bareAddr(a.host) && !sharedBase(base);
}

// Which row of the list moves when a heal is written. Two rows can hold the
// same address: the one that carries the playing station's name and is
// switched on, else one that is switched on, else the first.
// Contract: an index into rows, -1 when no row holds oldUrl.
function movedRow(rows, oldUrl, playingName) {
    var want = normName(playingName), on = -1, any = -1;
    for (var i = 0; i < (rows || []).length; i++) {
        var r = rows[i] || {};
        if ((r.hostname || "") !== oldUrl) continue;
        if (any < 0) any = i;
        if (r.active === false) continue;
        if (on < 0) on = i;
        if (want !== "" && normName(r.name) === want) return i;
    }
    return on >= 0 ? on : any;
}
