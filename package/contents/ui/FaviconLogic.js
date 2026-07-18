/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Pure logic for station logos: the one http(s)-or-empty gate every road
// that persists a favicon must pass, the directory-row favicon picker the
// runtime backfill uses, and the monogram (initials + deterministic hue)
// that stands in when no logo can be obtained at all. No QML types, no
// I/O — everything here runs under qmltestrunner (tests/qml/).
.pragma library

// The single gate between untrusted favicon strings (publicly writable
// catalog rows, hand edits, .arp imports) and Image.source / the shell:
// only plain web URLs pass; file://, data:, "null", scheme-less and
// garbage all become "" — which the UI renders as a monogram and the
// backfill treats as "please find one".
function webUrlOrEmpty(v) {
    var s = (v === undefined || v === null) ? "" : String(v).trim();
    if (s === "null") return "";
    return /^https?:\/\//i.test(s) ? s : "";
}

// First usable favicon from a radio-browser result array. With wantNorm
// given, only rows whose normalized name is an EXACT match may donate —
// the catalog is publicly writable, and a famous near-namesake must not
// put its logo on the user's station. normFn is HealLogic.normName,
// passed in so this library stays dependency-free.
function pickFavicon(rows, wantNorm, normFn) {
    if (!rows || !rows.length) return "";
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i] || {};
        var fav = webUrlOrEmpty(r.favicon);
        if (fav === "") continue;
        if (wantNorm) {
            if (!normFn || normFn((r.name || "").toString()) !== wantNorm) continue;
        }
        return fav;
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
        var t = toks[i].replace(/^[^0-9A-Za-zÀ-ɏЀ-ӿ]+/, "");
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
