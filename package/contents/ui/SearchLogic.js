/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What a search query MEANS against a station name — pure string
// decisions, no network, under qmltestrunner. FullRepresentation.qml
// fetches and renders; this file matches, ranks and reads probe answers.
.pragma library

// The case- and accent-blind form both sides of every comparison use:
// "Järviradio" and "jarviradio" are the same station to a searcher.
function fold(s) {
    return (s || "").toLowerCase().normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "").replace(/\s+/g, " ").trim();
}

// The query as folded words — the unit of the any-order match.
function words(q) {
    var f = fold(q);
    return f === "" ? [] : f.split(" ");
}

// The single word worth asking the directory about — its search only does
// substring matches, so the longest word culls the flood best. Returned
// UNFOLDED: the server compares accents literally.
function longestWord(q) {
    var parts = (q || "").split(/\s+/), best = "";
    for (var i = 0; i < parts.length; i++)
        if (parts[i].length > best.length) best = parts[i];
    return best;
}

// Any-order containment: every query word appears somewhere in the name.
function matchesAllWords(name, ws) {
    if (!ws || ws.length === 0) return false;
    var n = fold(name);
    for (var i = 0; i < ws.length; i++)
        if (n.indexOf(ws[i]) === -1) return false;
    return true;
}

// 0 = the name IS the query, 1 = the name starts with it, 2 = the rest.
// Drives the float-to-top: the directory ranks by fame alone, and fame
// buries the exact station the user just typed out in full.
function relevance(name, q) {
    var n = fold(name), f = fold(q);
    if (f === "") return 2;
    if (n === f) return 0;
    if (n.indexOf(f) === 0) return 1;
    return 2;
}

// One probe answer, read at the response headers: a definite HTTP error is
// a dead mount, a 2xx is a live one, anything else (timeouts, transport
// errors, ICY status lines Qt cannot parse) stays unknown — a slow or odd
// server is not a dead station.
function probeVerdict(status) {
    if (status >= 200 && status < 400) return 1;
    if (status >= 400) return 0;
    return -1;
}
