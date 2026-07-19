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

// Inflected queries find nothing in a substring-only directory: an
// Estonian listener types "Elmari" hunting "Raadio Elmar", and "Elmar"
// does not contain "Elmari". The fallback stems shave one, then two
// trailing letters — never below four left — and each runs only when
// everything longer came back empty.
function stems(q) {
    var t = (q || "").trim();
    var out = [];
    for (var cut = 1; cut <= 2; cut++) {
        if (t.length - cut < 4) break;
        out.push(t.substring(0, t.length - cut));
    }
    return out;
}

// Whether the liveness probe may knock on this URL's host at all. The
// directory is publicly writable, and a crafted entry pointing the
// probe's GET at 127.0.0.1 or 192.168.x would turn every search into a
// scan of the user's own machine and network. Literal addresses only:
// QML has no resolver, so a DNS name that resolves privately (rebinding)
// is out of scope here — every plain hostname passes.
function isProbeSafeHost(url) {
    var m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@\/]*@)?(\[[^\]]*\]|[^:\/?#]*)/i
            .exec(url || "");
    if (!m || m[1] === "") return false;
    var host = m[1].toLowerCase();
    if (host.charAt(0) === "[") {
        var h6 = host.slice(1, -1);
        if (h6 === "::1") return false;               // loopback
        if (/^f[cd]/.test(h6)) return false;          // fc00::/7 unique-local
        if (/^fe[89ab]/.test(h6)) return false;       // fe80::/10 link-local
        return true;
    }
    if (host === "localhost") return false;
    var ip4 = /^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/.exec(host);
    if (ip4) {
        var a = +ip4[1], b = +ip4[2];
        if (a === 127 || a === 10) return false;
        if (a === 172 && b >= 16 && b <= 31) return false;
        if (a === 192 && b === 168) return false;
        if (a === 169 && b === 254) return false;
    }
    return true;
}

// One probe answer, read at the response headers. Dead is ONLY what
// stream hosts actually say about a mount that is gone: not found,
// forbidden (geo-blocks read this way), gone. Everything else stays
// unknown — 5xx hiccups, 429, timeouts, ICY status lines Qt cannot
// parse, and the non-standard codes CDNs throttle with (a living
// national station answered 460 to every fresh connection the moment
// a rate limiter woke up; a throttle is not a death certificate).
function probeVerdict(status) {
    if (status >= 200 && status < 400) return 1;
    if (status === 403 || status === 404 || status === 410) return 0;
    return -1;
}
