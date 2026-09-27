/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Pure logic for station logos: the one http(s)-or-empty gate every road
// that persists a favicon must pass, the rule for whose logo a name search
// may lend a saved station (the runtime backfill and the settings page both
// ask it), and the monogram (initials + deterministic hue)
// that stands in when no logo can be obtained at all. No QML types, no
// I/O — everything here runs under qmltestrunner (tests/qml/).
.pragma library
.import "HostGuard.js" as HostGuard
.import "StreamLogic.js" as StreamLogic
.import "HealLogic.js" as HealLogic

// The single gate between untrusted favicon strings (publicly writable
// catalog rows, hand edits, .arp imports) and Image.source / the shell:
// only plain web URLs pass; file://, data:, "null", scheme-less and
// garbage all become "" — which the UI renders as a monogram and the
// backfill treats as "please find one".
//
// The host is judged too, by the same gate the liveness probe uses. A
// scheme test alone let a crafted catalogue row aim an Image.source (and
// syncFavicons' curl, at every widget start) at http://192.168.1.1 — a
// blind GET into the user's LAN with no click. Nothing is readable back,
// but reachability is not ours to hand out.
function webUrlOrEmpty(v) {
    var s = (v === undefined || v === null) ? "" : String(v).trim();
    if (s === "null") return "";
    if (!/^https?:\/\//i.test(s)) return "";
    var host = HostGuard.hostOf(s);
    return (host !== "" && !HostGuard.isPrivateHost(host)) ? s : "";
}

// Two spellings of one address: the scheme, a trailing slash and letter
// case are noise. The edit dialog's identity question and the bitrate
// upgrade fold a saved address the same way.
function _addrKey(u) {
    return (u === undefined || u === null ? "" : String(u)).trim()
           .replace(/^https?:\/\//i, "").replace(/\/$/, "").toLowerCase();
}

// The rows of a name search that may speak for a saved station: lend it a
// logo, or a homepage to look for one on. Best first.
// A name is not an identity, and what is taken here is SAVED to the list.
// "Rock FM" answered with four exact-name rows in its ten most voted, from
// three countries (RU 58 976 votes, ES, EE, ES; measured 2026-09-21), and
// the first of them put the Russian station's logo on a Spanish listener's
// row for good. "Radio Nova" had five from four countries.
//   rows      the directory's answer, votes order, publicly writable
//   wantNorm  the saved name through normFn (HealLogic.normName)
//   savedUrl  the saved stream address, "" when there is none to compare
//   asked     the limit the question carried; 0 or nothing when unknown
// Three roads, in this order:
//   1. the station's own record: a row whose address IS the saved one. Its
//      name may differ, the listener can have renamed the station;
//   2. the exact name under the saved address's own base domain, unless
//      that domain is a landlord (HealLogic.sharedBase);
//   3. the exact name alone, and only while the name means one station in
//      this answer: a single row, or every row on one non-shared base
//      domain, or every row in one country. Rows WITHOUT a logo vote too:
//      "Kiss FM" had two Spanish rows with none and a Ukrainian row with
//      one, and counting logos alone would have called that unanimous. The
//      own record votes even under another name, and a row without a
//      country agrees with nobody.
// A full page closes the third road. The ten most voted "Kiss FM" rows held
// one exact name, the thirty most voted held four from three countries, so
// one row on a full page says nothing about how many there are.
// Anything else is no donor at all, and the row keeps its initials.
function donorRows(rows, wantNorm, normFn, savedUrl, asked) {
    var out = [];
    if (!rows || !rows.length || !wantNorm || !normFn) return out;
    var want = _addrKey(savedUrl);
    var home = StreamLogic.baseDomain(StreamLogic.hostOf(want === "" ? "" : String(savedUrl).trim()));
    if (HealLogic.sharedBase(home)) home = "";
    var own = [], roof = [], named = [], votes = [];
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (!r) continue;
        var mine = want !== "" && (_addrKey(r.url) === want || _addrKey(r.url_resolved) === want);
        if (!mine && normFn((r.name || "").toString()) !== wantNorm) continue;
        var base = StreamLogic.baseDomain(StreamLogic.hostOf((r.url_resolved || r.url || "").toString()));
        var cc = (r.countrycode || "").toString().toUpperCase();
        votes.push({ base: HealLogic.sharedBase(base) ? "" : base,
                     cc: /^[A-Z]{2}$/.test(cc) ? cc : "" });
        if (mine) own.push(r);
        else if (home !== "" && base === home) roof.push(r);
        else named.push(r);
    }
    out = own.concat(roof);
    if (asked > 0 && rows.length >= asked) return out;
    var oneBase = true, oneCc = true;
    for (var v = 0; v < votes.length; v++) {
        if (votes[v].base === "" || votes[v].base !== votes[0].base) oneBase = false;
        if (votes[v].cc === "" || votes[v].cc !== votes[0].cc) oneCc = false;
    }
    return (votes.length === 1 || oneBase || oneCc) ? out.concat(named) : out;
}

// First usable favicon for a saved station from a radio-browser answer.
// With wantNorm given only donorRows may donate; without it (no caller in
// the widget asks that way) the first gated favicon of any row.
function pickFavicon(rows, wantNorm, normFn, savedUrl, asked) {
    if (!rows || !rows.length) return "";
    var from = wantNorm ? donorRows(rows, wantNorm, normFn, savedUrl, asked) : rows;
    for (var i = 0; i < from.length; i++) {
        var fav = webUrlOrEmpty((from[i] || {}).favicon);
        if (fav !== "") return fav;
    }
    return "";
}

// Initials for the monogram avatar. Two words give one code point from
// each ("Raadio Elmar" -> RE); one word gives its first two ("Elmar" ->
// EL, "R2" -> R2). Code points via Array.from so astral characters
// cannot be split; no diacritic folding — Õ stays Õ, it IS the identity.
// Leading punctuation is stripped per word; a name with nothing usable
// returns "" and the caller keeps its old empty-state.
function monogramText(name) {
    var s = (name === undefined || name === null) ? "" : String(name).trim();
    if (s === "") return "";
    var toks = s.split(/\s+/);
    var cleaned = [];
    for (var i = 0; i < toks.length; i++) {
        // Letters of the scripts station names actually come in: Latin
        // (with its extensions), Cyrillic, Greek, Hebrew, Arabic, kana,
        // CJK, Hangul — a Greek or Japanese station deserves its initials
        // exactly as much as an Estonian one.
        var t = toks[i].replace(/^[^0-9A-Za-zÀ-ɏЀ-ӿͰ-Ͽ֐-׿؀-ۿ぀-ヿ一-鿿가-힯]+/, "");
        if (t !== "") cleaned.push(t);
    }
    if (cleaned.length === 0) return "";
    if (cleaned.length >= 2)
        return (Array.from(cleaned[0])[0] + Array.from(cleaned[1])[0]).toUpperCase();
    var cp = Array.from(cleaned[0]);
    return (cp.length >= 2 ? cp[0] + cp[1] : cp[0]).toUpperCase();
}

// Deterministic hue for the monogram tint: djb2 over the folded name,
// constrained to 90–230° — greens through blues, so the widget's emerald
// identity stays coherent and red (= danger/recording) is never handed
// out as a station color. Same name, same color, every session.
function monogramHue(name) {
    var s = ((name === undefined || name === null) ? "" : String(name)).trim().toLowerCase();
    var h = 5381;
    for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
    return 90 + (Math.abs(h) % 141);
}
