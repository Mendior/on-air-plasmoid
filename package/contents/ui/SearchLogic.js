/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What a search query MEANS against a station name — pure string
// decisions, no network, under qmltestrunner. FullRepresentation.qml
// fetches and renders; this file matches, ranks and reads probe answers.
.pragma library
.import "HostGuard.js" as HostGuard

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
    // The cut must not land between a surrogate pair: shaving one UTF-16
    // unit off a name ending in an emoji leaves a lone high surrogate and
    // encodeURIComponent throws URIError on it — inside an XHR handler,
    // which froze the search spinner for good. (Array.from(str) was no
    // help: measured in Qt's V4 engine it walks units, not code points.)
    var t = (q || "").trim();
    var out = [];
    for (var cut = 1; cut <= 2; cut++) {
        var end = t.length - cut;
        if (end < 4) break;
        var c = t.charCodeAt(end - 1);
        if (c >= 0xD800 && c <= 0xDBFF) end--;
        if (end < 4) break;
        // A shaved stem must not end in space: "Elmar 😀" cut back to
        // "Elmar " asks the directory for a name with a trailing blank,
        // which matches nothing the catalogue holds.
        var s = t.substring(0, end).replace(/\s+$/, "");
        if (s.length >= 4 && out.indexOf(s) === -1) out.push(s);
    }
    return out;
}

// Whether the liveness probe may knock on this URL's host at all. The
// directory is publicly writable, and a crafted entry pointing the
// probe's GET at 127.0.0.1 or 192.168.x would turn every search into a
// scan of the user's own machine and network. The actual address
// judgement lives in HostGuard.js, shared with the settings pages'
// logo fetcher — one gate, every spelling.
function isProbeSafeHost(url) {
    var host = HostGuard.hostOf(url);
    return host !== "" && !HostGuard.isPrivateHost(host);
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

// "70s in UK" — what a scoped query MEANS. Every " in " / " from "
// separator offers its tail to the resolver (the country map), longest
// tail first; only a tail the resolver recognizes splits the query into
// {text, cc, country}. "alice in chains" stays one query — "chains" is
// no country — and the resolver decides, never this parser, so the
// country vocabulary lives in exactly one place.
function scopedQuery(q, resolve) {
    var s = (q || "").trim()
    var sep = /\s+(?:in|from)\s+/gi
    var m
    while ((m = sep.exec(s)) !== null) {
        var text = s.substring(0, m.index).trim()
        var tail = s.substring(m.index + m[0].length).trim()
        if (text === "" || tail === "") continue
        var cc = resolve(tail)
        if (cc !== "") return { text: text, cc: cc, country: tail }
    }
    return null
}

// Catalogue text bound for a chip or label: the mirrors are only
// semi-trusted and some sinks render styled text, so markup characters
// become spaces and the length is capped — a multi-megabyte "name" from
// a hostile mirror must not reach the text shaper or the config file.
function cleanLabel(s, maxLen) {
    return String(s || "").replace(/[<>&]/g, " ")
        .replace(/\s+/g, " ").trim().substring(0, maxLen || 60);
}

// Vote counts read as a badge: past a thousand the exact number is noise,
// "12k" is the signal. The directory ships them as strings sometimes.
function formatVotes(v) {
    var n = parseInt(v, 10) || 0;
    if (n <= 0) return "";
    if (n < 1000) return String(n);
    // The rounding has to stop before it lies: 999,500 rounds to 1000 and
    // the badge read "1000k" instead of moving up a unit.
    if (n < 999500) {
        var k = n / 1000;
        return (k >= 10 ? Math.round(k) : Math.round(k * 10) / 10) + "k";
    }
    var m = n / 1000000;
    return (m >= 10 ? Math.round(m) : Math.round(m * 10) / 10) + "M";
}

// ISO-3166 alpha-2 → the flag emoji, built from regional-indicator
// letters — no image assets, every platform font carries them. Anything
// that is not exactly two ASCII letters yields "" (an unknown code must
// not render as a broken glyph pair).
function countryFlag(cc) {
    var c = (cc || "").toUpperCase()
    if (!/^[A-Z]{2}$/.test(c)) return ""
    return String.fromCodePoint(0x1F1E6 + c.charCodeAt(0) - 65,
                                0x1F1E6 + c.charCodeAt(1) - 65)
}

// Which of the found titles is the track the query asked for — or none.
// Numbers are identity, not flavor: an episode or mix number that differs
// is a DIFFERENT show however similar the words read (measured live: the
// stream said "Uplifting Only Episode 659", YouTube's #1 was the more
// famous "Uplifting Only 600 Special", and two hours of the wrong episode
// arrived). Every number in the query must appear in the title as its own
// token; among the qualifiers the most query words wins, and the search
// engine's own order breaks ties. -1 means nothing qualifies — refusing
// beats delivering the wrong show.
function downloadPick(query, titles) {
    var qf = fold(query)
    var qNums = qf.match(/\d+/g) || []
    var qWords = words(query).filter(function(w) {
        return w.length >= 3 && !/^\d+$/.test(w)
    })
    var best = -1, bestScore = -1
    for (var i = 0; i < titles.length; i++) {
        var tf = fold(titles[i])
        var tNums = tf.match(/\d+/g) || []
        var ok = true
        for (var n = 0; n < qNums.length; n++)
            if (tNums.indexOf(qNums[n]) === -1) { ok = false; break }
        if (!ok) continue
        var score = 0
        for (var w = 0; w < qWords.length; w++)
            if (tf.indexOf(qWords[w]) !== -1) score++
        if (qWords.length > 0 && score === 0) continue
        if (score > bestScore) { bestScore = score; best = i }
    }
    return best
}

// Two names for the same act. "Anaconda" and "Anaconda feat. Someone" are
// one artist; containment says so, but only once the shorter name is long
// enough that containing it means anything — "AC" inside "AC/DC" would
// otherwise make every two-letter name match half the catalogue.
function nameAkin(a, b) {
    if (a === "" || b === "") return false;
    if (a === b) return true;
    if (a.length >= 4 && b.length >= 4)
        return a.indexOf(b) !== -1 || b.indexOf(a) !== -1;
    // A short name still names the artist when the longer string is the
    // same artist plus company. Measured against this rule as it stood:
    // "Nas & Damian Marley" vs the record filed under "Nas", "Sia" vs
    // "Sia feat. Sean Paul", "Eve" vs "Eve feat. Gwen Stefani" — all three
    // returned no cover at all, because a name under four characters could
    // only ever match by being identical. Anchored at the START and at a
    // word boundary: that keeps the case the old rule was written against
    // ("AC" must not match its way through the middle of half the
    // catalogue) while letting the featuring line through.
    // What separates the two cases is the punctuation that follows. A
    // collaboration line NAMES its members — "Nas & Damian Marley", "Sia
    // feat. Sean Paul" — and the first of them is the artist the record is
    // filed under. "AC/DC" is not a list: the slash belongs to the name, and
    // "AC" alone does not identify it. So the short name must be followed by
    // a word that joins performers, not by any old non-letter.
    var shorter = a.length <= b.length ? a : b;
    var longer = a.length <= b.length ? b : a;
    if (shorter.length < 2) return false;
    if (longer.indexOf(shorter) !== 0) return false;
    var rest = longer.substring(shorter.length);
    return /^\s*(?:&|,|\+|feat\.?|ft\.?|featuring|with|and|vs\.?|x)\s/.test(rest);
}

// Which of the covers a music service offered actually belongs to this
// track — or none. The lookup used to take the search engine's first hit
// on faith, and a title that exists in more than one language is all it
// takes to hand the listener somebody else's record: measured live, an
// Estonian dance remix called "Veel veel veel" was illustrated with a
// Tamil devotional album of the same name, artist and all.
//
// The ARTIST is the identity. A cover filed under a different name is the
// wrong cover, and no cover beats a wrong one — the same rule the track
// download follows. Only when the stream gives no artist at all does the
// title have to carry the decision alone.
// What a music service sells INSTEAD of the record when it does not have
// the record. Measured on "Bodies Without Organs — Sunshine In The Rain":
// the top three answers were all karaoke labels, and the old lookup would
// have hung a karaoke sleeve on the song.
var _ART_JUNK = /karaoke|tribute|made popular by|in the style of|originally performed|instrumental version|cover version|backing track|as made famous/i;

// A title without its bracketed tail: "(Radio Edit)", "[Remastered 2021]".
// Both sides get this, or a station's "(Radio Edit)" would never match a
// catalogue's plain title and vice versa.
function artCoreTitle(t) {
    return fold(String(t || "").replace(/\s*[\(\[][^\)\]]*[\)\]]/g, " "));
}

// The initials of a multi-word name: "Bodies Without Organs" → "bwo".
// Catalogues file bands under both spellings and neither contains the
// other, so containment alone loses the record.
function artInitials(name) {
    var ws = fold(name).split(" ");
    var out = "";
    for (var i = 0; i < ws.length; i++)
        if (ws[i].length > 1) out += ws[i].charAt(0);
    return out;
}

// How strongly a candidate's artist is OUR artist: 2 for the same name in
// any spelling, 0 for a stranger.
function artArtistScore(wantArtist, gotArtist) {
    var wa = fold(wantArtist), ga = fold(gotArtist);
    if (wa === "" || ga === "") return 0;
    if (nameAkin(wa, ga)) return 2;
    if (ga.length >= 2 && artInitials(wa) === ga) return 2;
    if (wa.length >= 2 && artInitials(ga) === wa) return 2;
    return 0;
}

// Which of the covers a music service offered actually belongs to this
// track — or none. The lookup used to take the first hit on faith, and a
// title that exists in more than one language is all it takes to hand the
// listener somebody else's record: measured live, an Estonian dance remix
// called "Veel veel veel" was illustrated with a Tamil devotional album.
//
// The ARTIST decides. Knowing who we are hearing, a candidate under
// another name is refused however well its title reads — that is what
// keeps the Tamil album out. The title then chooses between that artist's
// own records, so "Curly Strings — Kuu" stops wearing the sleeve of the
// first song of theirs the catalogue happened to list. Karaoke and tribute
// pressings are dropped before any of this. Only when the stream names no
// artist at all does the title have to carry the decision alone.
function artPick(wantArtist, wantTitle, cands) {
    if (!cands || cands.length === 0) return -1;
    var wa = fold(wantArtist);
    var best = -1, bestScore = 0;
    for (var i = 0; i < cands.length; i++) {
        var c = cands[i] || {};
        if (_ART_JUNK.test(String(c.title || "")) || _ART_JUNK.test(String(c.artist || "")))
            continue;
        // An EXACT core title outranks a mere containment. Both used to
        // score 2, and the strict > below then handed the tie to whichever
        // record the service happened to list first — so a played "Kiss"
        // could take the sleeve of "Kiss the Sky", and "Hello" that of
        // "Hello Goodbye", which is the very failure the paragraph above
        // claims to have fixed. Containment itself has to stay: it is what
        // matches "Radio Ga Ga" to "Radio Ga Ga - Remastered 2011". So the
        // cure is an order between the two, not a stricter nameAkin.
        // artArtistScore answers only 0 or 2, so with an artist known this
        // reads 5 / 4 / 2 and never ties.
        var wantCore = artCoreTitle(wantTitle);
        var candCore = artCoreTitle(c.title);
        var te = 0;
        if (wantCore !== "" && wantCore === candCore) te = 3;
        else if (nameAkin(wantCore, candCore)) te = 2;
        var score;
        if (wa !== "") {
            var ae = artArtistScore(wantArtist, c.artist);
            if (ae === 0) continue;
            score = ae + te;
        } else {
            if (te === 0) continue;
            score = te;
        }
        if (score > bestScore) { best = i; bestScore = score; }
    }
    return best;
}

// ISO code → a name a human can read on the chip. Qt's CLDR data has the
// answer offline, but Qt.locale() FALLS BACK SILENTLY on a pair it does not
// carry (measured: "et_FI" answers as et_EE with "Eesti", "en_ZZ" as en_US
// with "United States") — a wrong country served with full confidence. So a
// name is trusted only when the locale resolved to exactly what was asked.
// The listener's own language gets the first try, English the second, and
// the bare code is the honest last resort.
function countryDisplayName(cc, localeName) {
    var c = (cc || "").toUpperCase()
    if (!/^[A-Z]{2}$/.test(c)) return ""
    var langs = []
    var lp = String(localeName || "").split(/[_-]/)[0].toLowerCase()
    if (/^[a-z]{2,3}$/.test(lp)) langs.push(lp)
    if (langs.indexOf("en") === -1) langs.push("en")
    for (var i = 0; i < langs.length; i++) {
        var want = langs[i] + "_" + c
        var loc = Qt.locale(want)
        if (loc.name === want && loc.nativeTerritoryName !== "")
            return loc.nativeTerritoryName
    }
    return c
}
