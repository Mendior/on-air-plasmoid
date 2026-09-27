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

// The word the word pass asks the directory for. Its search matches
// substrings and answers with the 50 most voted, so the word has to cull.
// Measured 2026-09-21: asked for "radio" the fifty ran from 825 222 votes down
// to 23 417 and one of them also held "nova"; asked for "nova", twenty-one
// did. Station words (NAME_WORDS) and words under three letters stand back
// for the longest word that is the listener's own. When nothing else was
// typed ("radio fm") the longest word is asked, as before. Unfolded, like
// longestWord: the server compares accents literally.
// Contract: askWord("nova radio") = "nova"; askWord("Rádio Nova") = "Nova";
//   askWord("radio fm") = "radio"; askWord("fm 4") = "fm"; askWord("") = "".
function askWord(q) {
    var parts = String(q === undefined || q === null ? "" : q).split(/\s+/), own = [];
    for (var i = 0; i < parts.length; i++)
        if (parts[i].length >= 3 && !NAME_WORDS.hasOwnProperty(fold(parts[i]))) own.push(parts[i]);
    return longestWord(own.length > 0 ? own.join(" ") : q);
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

// A decade the way a listener types it, as the fragment the directory's tag
// filter should be asked for — "" when the word is no decade. The filter is
// a substring match (measured: tagList=roc answers 162 British stations), so
// the bare "80" reaches "80s", "80's", "1980s" and "80er" in one question;
// asking for "80s" alone left a fifth of them out. The 2000s and 2010s keep
// their "s": a bare "00" is every "top 100" in the catalogue.
// Contract: decadeTag("80") = decadeTag("80s") = decadeTag("80's")
//   = decadeTag("1980s") = decadeTag("eighties") = "80";
//   decadeTag("2000s") = decadeTag("00s") = "00s"; decadeTag("10") = "".
var DECADE_WORDS = { "fifties": "50", "sixties": "60", "seventies": "70",
                     "eighties": "80", "nineties": "90" };

function decadeTag(word) {
    var w = fold(word).replace(/\u2019/g, "'");
    if (w === "") return "";
    if (DECADE_WORDS.hasOwnProperty(w)) return DECADE_WORDS[w];
    var m = w.match(/^(?:19)?([5-9])0(?:s|'s|er|ies)?$/);
    if (m) return m[1] + "0";
    m = w.match(/^20([01])0(?:s|'s|er)$/) || w.match(/^([01])0(?:s|'s)$/);
    return m ? m[1] + "0s" : "";
}

// The genres the idle rail may offer as a chip. The directory decides the
// ORDER and whether a genre is worth showing at all — its tag counts are
// real — but not the vocabulary: that namespace is user-typed slush, and a
// "shape and station count" filter alone put "entretenimiento" and "moi
// merino" on an English rail. These are genre words a listener recognizes,
// in the spelling the directory uses. Narrower than GENRES below on
// purpose: a chip is a recommendation, a typed word is the listener's own.
var CHIP_GENRES = (function() {
    var list = ["pop", "rock", "jazz", "classical", "news", "talk", "dance",
        "electronic", "house", "techno", "trance", "hits", "top 40", "oldies",
        "80s", "90s", "70s", "60s", "country", "folk", "blues", "soul", "funk",
        "disco", "metal", "punk", "indie", "alternative", "hip hop", "rap",
        "rnb", "reggae", "latin", "salsa", "chillout", "lounge", "ambient",
        "sport", "sports", "christian", "gospel", "culture", "comedy",
        "schlager", "chanson", "world", "instrumental", "soundtrack", "kids",
        "student"];
    var m = Object.create(null);
    for (var i = 0; i < list.length; i++) m[list[i]] = true;
    return m;
})();

function isChipGenre(name) {
    return CHIP_GENRES[String(name || "")] === true;
}

// Genre words a listener types, in the spelling the directory's tags use
// (its 260 biggest tags, read on 2026-09-21, minus everything that is a
// place, a company or Spanish for "music"). Longest phrase wins, so
// "classic rock" is one tag and not a classic and a rock.
var GENRES = (function() {
    var list = [
        "pop", "rock", "jazz", "classical", "news", "talk", "dance", "hits",
        "oldies", "electronic", "house", "techno", "trance", "top 40", "top40",
        "country", "folk", "blues", "soul", "funk", "disco", "metal", "punk",
        "indie", "alternative", "hip hop", "hiphop", "hip-hop", "rap", "rnb",
        "r&b", "reggae", "latin", "salsa", "chillout", "chill", "lounge",
        "ambient", "sport", "sports", "christian", "gospel", "culture",
        "comedy", "schlager", "chanson", "world", "world music",
        "instrumental", "soundtrack", "kids", "student", "pop rock",
        "classic rock", "classic hits", "adult contemporary", "easy listening",
        "retro", "religious", "alternative rock", "latin pop", "electro",
        "edm", "latino", "tropical", "smooth jazz", "hard rock", "cumbia",
        "deep house", "reggaeton", "heavy metal", "soft rock", "urban",
        "ska", "dubstep", "grunge", "new wave", "opera", "bluegrass",
        "americana", "celtic", "bollywood", "afrobeat", "psytrance",
        "hardstyle", "progressive", "downtempo", "swing", "big band",
        "acoustic", "piano", "meditation", "relax", "eurodance",
        "italo disco", "synthpop", "gothic", "industrial", "hardcore",
        "new age", "drum and bass", "lofi", "lo-fi", "kpop", "k-pop",
        "jpop", "j-pop", "anime", "garage", "love songs", "christmas"
    ];
    var m = Object.create(null);
    for (var i = 0; i < list.length; i++) m[list[i]] = true;
    return m;
})();

// Words that belong to station names. One of these anywhere and the query
// is a name: "virgin radio uk", "classic fm uk", "radio 80".
var NAME_WORDS = { "radio": 1, "fm": 1, "am": 1, "station": 1, "the": 1,
                   "live": 1, "tv": 1, "web": 1, "online": 1 };

// "rock 80 uk" — a wish spelled as facets, no "in" between them. Every word
// has to be accounted for: a country the resolver knows (one at most), a
// decade, a genre from GENRES, or — only beside a country or a decade — up
// to two unknown words read as one tag ("synthwave uk"). A word that smells
// like a station name (radio, fm, a frequency) sends the whole query back to
// the name roads untouched: "virgin radio uk" is a station, not a wish.
// Contract: null, or { text, tags, cc, country } where text is the query
// without its country words (what runs as the name inside the country),
// tags are tagList fragments in typed order, cc/country are "" when no
// country was named. A reading needs two facets, a lone decade excepted.
function facetQuery(q, resolve) {
    var typed = String(q === undefined || q === null ? "" : q).trim().split(/\s+/);
    var ws = words(q);
    if (ws.length === 0 || ws.length > 6 || typed.length !== ws.length) return null;
    var tags = [], unknown = [], kept = [];
    var cc = "", country = "", decades = 0;
    var flush = function() {
        if (unknown.length > 0) { tags.push(unknown.join(" ")); }
        var n = unknown.length;
        unknown = [];
        return n;
    };
    var runs = 0, loose = 0;
    for (var i = 0; i < ws.length; ) {
        var hit = 0;
        for (var len = Math.min(3, ws.length - i); len >= 1 && hit === 0; len--) {
            var phrase = ws.slice(i, i + len).join(" ");
            var code = typeof resolve === "function" ? resolve(phrase) : "";
            if (code) {
                if (cc !== "") return null;
                if (flush() > 0) runs++;
                cc = code; country = phrase; hit = len;
            } else if (GENRES[phrase]) {
                if (flush() > 0) runs++;
                tags.push(phrase); hit = len;
                for (var g = 0; g < len; g++) kept.push(typed[i + g]);
            }
        }
        if (hit === 0) {
            var w = ws[i];
            var d = decadeTag(w);
            if (d !== "") {
                if (flush() > 0) runs++;
                tags.push(d); decades++;
            } else {
                if (NAME_WORDS.hasOwnProperty(w) || /[0-9]/.test(w)) return null;
                unknown.push(w); loose++;
            }
            kept.push(typed[i]);
            hit = 1;
        }
        i += hit;
    }
    if (flush() > 0) runs++;
    // Unknown words are one tag of two words at most, and only a country or
    // a decade beside them says this is a wish and not a name.
    if (loose > 2 || runs > 1 || (loose > 0 && cc === "" && decades === 0)) return null;
    if (tags.length === 0) return null;
    var facets = tags.length + (cc !== "" ? 1 : 0);
    if (facets < 2 && !(decades === 1 && ws.length === 1)) return null;
    return { text: kept.join(" "), tags: tags, cc: cc, country: country };
}

// A genre word typed alone in the All mode: "rock", "smooth jazz", "80s".
// Measured 2026-09-21, votes order: name=rock answers 50 rows, the page's 30
// fill from them and the tag pass never ran, so 17 of the 30 biggest
// rock-tagged stations (Radio Caroline, 1LIVE, SWR3) were not on the page and
// "Show more" only paged more names. "jazz" lost 9 of 30 the same way, "80s"
// fills the page with names too. The idle rail's genre chips type these words.
// Contract: isGenreWord("Rock ") = isGenreWord("smooth jazz") = isGenreWord("80")
//   = isGenreWord("eighties") = true; "rock fm", "rock 80", "uk", "" are false.
function isGenreWord(q) {
    var f = fold(q);
    return GENRES[f] === true || decadeTag(f) !== "";
}

// A name as bare words: folded, apostrophes out ("80's" is one word), a
// frequency out whole, split on everything that is neither a letter nor a
// digit in ANY script. Measured on name=90: three of the four leads were a
// Greek news station on 90.1, a Thai one on 90.5 and "Radio 9090 90.9" —
// a cut at a-z0-9 made "90.1" two bare numbers and made the Greek and Thai
// words vanish, so what was left of each name was the decade alone.
function _nameTokens(s) {
    var raw = fold(String(s === undefined || s === null ? "" : s))
        .replace(/['\u2019]/g, "").replace(/[0-9]+[.,][0-9]+/g, " ")
        .split(/[^a-z0-9\u00c0-\u1fff\u2c00-\uffff]+/);
    var out = [];
    for (var i = 0; i < raw.length; i++)
        if (raw[i] !== "") out.push(raw[i]);
    return out;
}

// Whether a station is NAMED after the word: take the station words (radio,
// fm, live ...) and the bare numbers (a frequency, a channel) out of its name
// and what is left IS the word. "Rock FM", "Radio 1 Rock" and "Jazz FM 104.6"
// are; "Rock Antenne" and "Jazz Radio Blues" carry names of their own and
// stand in the genre list on their votes. A decade matches in any spelling.
// Measured in the top 50 names: six such stations for "rock" (the Spanish
// Rock FM, 24 000 votes, has no tags at all and is in no tag answer), two for
// "jazz", one for "80s".
function namedAfter(name, q) {
    var norm = function(t) { return decadeTag(t) || t; };
    var want = _nameTokens(q).map(norm);
    if (want.length === 0) return false;
    var got = _nameTokens(name), rest = [];
    for (var i = 0; i < got.length; i++) {
        var t = norm(got[i]);
        if (want.indexOf(t) === -1
            && (NAME_WORDS.hasOwnProperty(got[i]) || /^[0-9]+$/.test(got[i]))) continue;
        rest.push(t);
    }
    return rest.join("") === want.join("");
}

// How many named-after stations may stand ahead of the genre's own list:
// eight leaves the genre 22 of the page's 30 rows whatever the word is.
var LEAD_MAX = 8;

// The row filter for the NAME answer of a genre-word query, or null when the
// query is no genre word and the name answer is the list, as before.
// Contract: leadRows(q) = null | function(row) -> bool. The filter counts what
// it kept and stops at LEAD_MAX, so one filter serves one answer. The first
// row of the answer leads whatever it is called: it is the directory's own
// idea of the biggest station carrying the word, and under "world" that is
// BBC World Service, 163 397 votes, tagged news and talk and in no tag
// answer's first page. A twin entry (same name, same country) leads once.
function leadRows(q) {
    if (!isGenreWord(q)) return null;
    var left = LEAD_MAX, top = true, had = Object.create(null);
    return function(row) {
        var first = top, name = row ? row.name : "";
        top = false;
        var id = fold(String(name === undefined || name === null ? "" : name)) + "|"
                 + String((row && row.countrycode) || "").toUpperCase();
        if (left <= 0 || had[id] === true || !(first || namedAfter(name, q))) return false;
        had[id] = true;
        left--;
        return true;
    };
}

// The hand-written country words: the Estonian names the directory has never
// heard of, and the everyday names it files under something longer — it says
// "The United Kingdom Of Great Britain And Northern Ireland" and "The United
// States Of America", and nobody types either.
var COUNTRY_ALIASES = (function() {
    var src = {
        "soome": "FI", "finland": "FI", "suomi": "FI",
        "eesti": "EE", "estonia": "EE",
        "rootsi": "SE", "sweden": "SE", "sverige": "SE",
        "norra": "NO", "norway": "NO", "norge": "NO",
        "läti": "LV", "latvia": "LV",
        "leedu": "LT", "lithuania": "LT",
        "saksamaa": "DE", "germany": "DE", "deutschland": "DE",
        "inglismaa": "GB", "suurbritannia": "GB", "uk": "GB",
        "united kingdom": "GB", "great britain": "GB", "britain": "GB",
        "england": "GB", "scotland": "GB", "wales": "GB",
        "iirimaa": "IE", "ireland": "IE",
        "usa": "US", "ameerika": "US", "america": "US", "us": "US",
        "united states": "US",
        "venemaa": "RU", "russia": "RU",
        "prantsusmaa": "FR", "france": "FR",
        "hispaania": "ES", "spain": "ES", "españa": "ES",
        "itaalia": "IT", "italy": "IT", "italia": "IT",
        "taani": "DK", "denmark": "DK", "danmark": "DK",
        "poola": "PL", "poland": "PL", "polska": "PL",
        "holland": "NL", "madalmaad": "NL", "netherlands": "NL", "nederland": "NL",
        "ukraina": "UA", "ukraine": "UA",
        "ungari": "HU", "hungary": "HU",
        "šveits": "CH", "switzerland": "CH", "schweiz": "CH",
        "austria": "AT", "österreich": "AT",
        "jaapan": "JP", "japan": "JP",
        "hiina": "CN", "china": "CN",
        "kanada": "CA", "canada": "CA",
        "austraalia": "AU", "australia": "AU",
        "brasiilia": "BR", "brazil": "BR", "brasil": "BR",
        "türgi": "TR", "turkey": "TR",
        "korea": "KR", "south korea": "KR",
        "czech republic": "CZ", "uae": "AE", "emirates": "AE",
        "iran": "IR", "moldova": "MD", "north macedonia": "MK", "macedonia": "MK",
        "taiwan": "TW", "tanzania": "TZ", "venezuela": "VE", "bosnia": "BA",
        "philippines": "PH", "dominican republic": "DO"
    };
    var m = Object.create(null);
    for (var k in src) m[fold(k)] = src[k];
    return m;
})();

function countryAliases() {
    return COUNTRY_ALIASES;
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

// The form a typed country name must take on the wire. The directory's
// country filter is a CASE-SENSITIVE substring match (measured live:
// country=mexico answers nothing, country=Mexico and even country=Mexi
// answer plenty) — so every word gets its capital, hyphenated names
// included, and the substring match forgives the rest ("united arab
// emirates" finds "The United Arab Emirates").
function countryQueryForm(q) {
    return String(q || "").trim().replace(/(^|[\s-])(\S)/g, function(m, sep, ch) {
        return sep + ch.toUpperCase();
    });
}

// The directory's own country list ({name, iso_3166_1} rows) as a folded
// name → code map, the same shape the hand-written map feeds the scope
// parser. Only clean rows enter: a code that is not two ASCII letters or
// a name past any honest length is catalogue slush, not a country. Names
// with a leading article are keyed both ways — a searcher types "united
// arab emirates", the directory files "The United Arab Emirates".
function countryMapFromApi(rows) {
    var m = Object.create(null);
    if (!rows || !rows.length) return m;
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i] || {};
        var cc = String(r.iso_3166_1 || "").toUpperCase();
        if (!/^[A-Z]{2}$/.test(cc)) continue;
        var name = fold(String(r.name || "").substring(0, 80));
        if (name === "") continue;
        m[name] = cc;
        if (name.indexOf("the ") === 0) m[name.substring(4)] = cc;
    }
    return m;
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

// The country a result row shows. The directory's own names run to "The
// United Kingdom Of Great Britain And Northern Ireland", and on a row one
// line wide that pushed the bitrate and the codec off the end for every
// British and American station. The short CLDR name when Qt has one, the
// directory's name without its article when it does not.
// Contract: countryLabel("GB", <the long name>, "en_US") = "United Kingdom";
//   an unknown or missing code answers with the directory's name.
function countryLabel(cc, apiName, localeName) {
    var code = String(cc || "").toUpperCase();
    var shortName = countryDisplayName(code, localeName);
    if (shortName !== "" && shortName !== code) return shortName;
    return String(apiName || "").replace(/^The\s+/, "");
}

// What an empty answer tries next: "unscope", "stems" or "done".
// A country chip pinned by an EARLIER search keeps scoping what is typed
// after it — that is its job ("Popular in Finland", then "rock"). But when
// the new text finds nothing inside that country, the chip is yesterday's
// intent standing in front of today's: seen live, "jazz united states" and
// then "virgin radio uk" answered "No matching stations" with the American
// chip still up. The scope goes and the text runs again everywhere. A scope
// the text itself names ("80s in uk") is the listener's word and stays.
// Contract: s = { count, gotAnswer, mode, inheritedScope, countryQuery,
//   stemCount }. No answer from the network is never "no results".
function emptyNext(s) {
    if (!s || s.gotAnswer !== true || s.count > 0) return "done";
    if (s.inheritedScope === true) return "unscope";
    if (s.mode === "all" && s.countryQuery !== true && s.stemCount > 0) return "stems";
    return "done";
}

// The pinned country a run is fenced to, "" for none. The chip that shows the
// pin, and the ✕ that releases it, live on the discovery rail, and Appearance
// can switch the rail off. Then "jazz in uk" pinned GB unseen and every later
// search ran inside Britain: measured, name=elmar&countrycode=GB has no rows
// while Raadio Elmar is one search away without the fence. A fence nobody can
// see or take down is not inherited. The country the text itself names is
// the listener's word and fences that one run, rail or no rail.
// Contract: s = { released, textCc, countryRole, pinnedCc, railShown };
//   released -> "", then textCc, then "" under a country search or a hidden
//   rail, then pinnedCc. A caller that says nothing of the rail has one.
function scopeFor(s) {
    if (!s || s.released) return "";
    if (s.textCc) return String(s.textCc);
    if (s.countryRole || s.railShown === false) return "";
    return String(s.pinnedCc || "");
}

// A query part for a radio-browser URL. encodeURIComponent throws URIError
// on a lone surrogate, and station names arrive with those: a catalogue row
// truncated mid-emoji, or a config cap that cut a pair in half. One such
// name used to abort the whole favicon backfill and the uuid heal for that
// station, inside a timer handler where nothing caught it. The lone half
// carries no meaning, so it is dropped rather than escaped.
function uriPart(s) {
    var t = String(s === undefined || s === null ? "" : s);
    var out = "";
    for (var i = 0; i < t.length; i++) {
        var c = t.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF) {
            var d = i + 1 < t.length ? t.charCodeAt(i + 1) : 0;
            if (d >= 0xDC00 && d <= 0xDFFF) { out += t.substr(i, 2); i++; }
            continue;
        }
        if (c >= 0xDC00 && c <= 0xDFFF) continue;
        out += t.charAt(i);
    }
    return encodeURIComponent(out);
}

// radio-browser's /json/servers answer, reduced to the mirror names a retry
// walk may climb. Discovered names lead, the seeds not among them follow,
// "all" closes the walk — it is round-robin DNS over the same healthy set
// and stays as the everyone-else-is-down door. Replacing the seeds outright
// is what the settings page paid for once: the day the answer held one
// name and that name died, every retry knocked on the same door while de2
// answered fine. The widget's own walk kept doing that replacement until
// 2026-09-05. Names are validated to a hostname label before they may
// become part of a URL host.
function mirrorRungs(rows, seeds) {
    var seen = Object.create(null);
    var names = [], discovered = 0;
    seen.all = true;
    var list = Array.isArray(rows) ? rows : [];
    for (var i = 0; i < list.length; i++) {
        var nm = String((list[i] && list[i].name) || "");
        var m = nm.match(/^([a-z0-9-]+)\.api\.radio-browser\.info$/);
        if (!m || seen[m[1]]) continue;
        seen[m[1]] = true;
        names.push(m[1]);
        discovered++;
    }
    var s = Array.isArray(seeds) ? seeds : [];
    for (var j = 0; j < s.length; j++) {
        var sd = String(s[j] || "");
        if (sd === "" || seen[sd]) continue;
        seen[sd] = true;
        names.push(sd);
    }
    names.push("all");
    return { names: names, discovered: discovered };
}

// The settings page's list, a page at a time. It asked for 500 rows and named
// no order, and unordered the directory answers by raw name: the list opened
// on names that begin with a tab or a space and the stations people know sat
// hundreds of rows down. Asked by votes on 2026-09-21, bytag/rock leads with
// 60745, 58974 and 50866 votes, and a page of 100 is 118148 bytes in 0.28 s.
// The by-roads take order, reverse, limit and offset exactly as /search does
// (measured on bytag, byname and the bare list), so they stay: bycountry
// matches without regard to case and /search?country= does not.
var DIRECTORY_ROADS = { "byname": 1, "bycountry": 1, "bylanguage": 1, "bytag": 1 };

// Contract: no road or no word is the bare list; a road the combo box never
// offered reads as byname and never becomes a path segment; a mirror name
// that is not a hostname label never becomes a host.
function directoryBase(server, by, val) {
    var host = /^[a-z0-9-]+$/.test(String(server || "")) ? String(server) : "all";
    var base = "https://" + host + ".api.radio-browser.info/json/stations";
    var v = String(val === undefined || val === null ? "" : val).trim();
    if (!by || v === "") return base;
    return base + "/" + (DIRECTORY_ROADS.hasOwnProperty(by) ? by : "byname") + "/" + uriPart(v);
}

// The one query string both the first page and every later page go out with.
// Two hand-written copies are how the order went missing in the first place.
// Contract: a limit that is no positive number reads as 100, an offset that
// is no number as 0, and a base that still carries a query loses it.
function directoryPage(base, limit, offset) {
    var n = parseInt(limit, 10), o = parseInt(offset, 10);
    if (!(n >= 1)) n = 100;
    if (!(o >= 0)) o = 0;
    return String(base || "").split("?")[0]
        + "?hidebroken=true&order=votes&reverse=true&limit=" + n + "&offset=" + o;
}

// How long to wait before a later page that failed is asked again.
// failures: how many times this page has failed in a row. Returns ms, or -1
// when the page is not to be asked again by itself.
// The page's only trigger used to be the list moving near its end, and a
// list that already sits at its end does not move: one failed request for
// page two and the rows after 100 never came (seen on the bench, "rock",
// once in three walks). Two, four and eight seconds keep the directory's
// own spacing between questions, and three is where a mirror that is down
// stops being worth asking; scrolling still asks after that.
function pageRetryDelay(failures) {
    var n = parseInt(failures, 10);
    return n >= 1 && n <= 3 ? 1000 * Math.pow(2, n) : -1;
}

// The same list on another mirror: base with its host swapped for server.
// A page that failed on one door is asked at the next, the way the first
// page's retries walk the mirrors; asking the same dead one three times
// would only spend the three waits.
function rehost(base, server) {
    var s = String(base || "");
    var host = /^[a-z0-9-]+$/.test(String(server || "")) ? String(server) : "all";
    return s.replace(/^https:\/\/[a-z0-9-]+\.api\.radio-browser\.info\//, "https://" + host + ".api.radio-browser.info/");
}

// A list ordered by votes moves while it is paged: one vote between two
// requests carries a row across the page edge, and the next page opens with a
// station already on screen. True the first time a uuid is offered, false on
// every repeat; a row without a uuid cannot be told apart and is always shown.
function firstSight(seen, uuid) {
    var id = String(uuid === undefined || uuid === null ? "" : uuid);
    if (id === "") return true;
    // Prefixed, so a uuid of "constructor" or "__proto__" is only a key.
    if (seen["u:" + id] === true) return false;
    seen["u:" + id] = true;
    return true;
}

// A directory name as the row shows it and as the station list keeps it: one
// line, no runs of whitespace, 300 characters at most, and never cut through
// the middle of an emoji (a lone half makes encodeURIComponent throw later).
// The ampersand stays, unlike cleanLabel: this string is saved as the name.
function rowName(raw) {
    var s = String(raw === undefined || raw === null ? "" : raw).replace(/\s+/g, " ").trim();
    if (s.length <= 300) return s;
    var end = 300, c = s.charCodeAt(end - 1);
    if (c >= 0xD800 && c <= 0xDBFF) end--;
    return s.substring(0, end).trim();
}

// One stream's address as a key for telling two streams apart. The directory
// files the same mount under http and under https as separate rows: measured
// 2026-09-21 on name=rock by votes, rows 6 and 47 are
// mp3channels.webradio.rockantenne.de/heavy-metal twice, and "Radio Nova"
// leads name=nova with its https twin thirteen rows down. The scheme, the
// host's case, the scheme's own port and a trailing slash are no difference.
// The path's case and the query are: a mount is case-sensitive and the query
// often names the station. A key and never an address, nothing is fetched by it.
// Contract: urlKey("http://Host.FM:80/live/") = urlKey("https://host.fm/live")
//   = "host.fm/live"; what is no http(s) address comes back trimmed and whole.
function urlKey(url) {
    var u = String(url === undefined || url === null ? "" : url).trim();
    var m = /^(https?):\/\/([^\/?#]*)([^?#]*)(.*)$/i.exec(u);
    if (!m) return u;
    var port = m[1].toLowerCase() === "https" ? ":443" : ":80";
    var host = m[2].toLowerCase();
    if (host.slice(-port.length) === port) host = host.slice(0, -port.length);
    return host + m[3].replace(/\/+$/, "") + m[4];
}

// The directory's bitrate field in kbps. Most rows are kbps already and some
// are bps; only what is clearly bps is scaled. A cutoff at 1000 once turned a
// 1411 kbps lossless stream into "1 kb/s".
function kbps(raw) {
    var n = parseInt(raw, 10) || 0;
    return n >= 8000 ? Math.round(n / 1000) : n;
}

// What a row's number says about its SOUND. For ordering only: the row still
// shows what the directory said. Past 2000 the number is believed from a
// lossless container alone. Measured 2026-09-21 on the 200 most voted rows
// between 1500 and 7999: 147 claim more than 2000, 137 of them are HLS
// television (the picture's rate) and the other ten are Ogg radio. The 3072
// that led name=rock is Radio Club 80's Ogg FLAC at 96 kHz, 2 x 16 x 96 000,
// a true number.
function soundRate(row) {
    var r = row || {}, k = kbps(r.bitrate);
    if (k <= 0) return 0;
    if (k <= 2000) return k;
    return /^(OGG|FLAC)$/i.test(String(r.codec || "").trim()) ? k : 0;
}

// Whether a query string asks the directory for its bitrate order.
function asksBitrate(qs) {
    return String(qs === undefined || qs === null ? "" : qs).indexOf("&order=bitrate&") !== -1;
}

// One answer of the directory, ready to be walked. Asked by bitrate it sorts
// its RAW field, which mixes kbps and bps: measured on name=rock, a 64000 row
// (64 kb/s) led the list ahead of three FLAC streams, and the 140 rows at 320
// came in no order at all, Radio Paradise's 15 205 votes nineteenth. The rows
// the page will show are put in soundRate order, votes breaking a tie, and
// only those: "Show more" asks the directory from the position this walk
// reached, so what is shown has to be the FIRST rows of its order or the next
// page skips some and repeats others. Rows past `room` keep their place; they
// are walked only when a duplicate above them was dropped.
// Contract: another order, no array or no room -> the same object back.
function pageOrder(rows, qs, room) {
    var n = Math.min(Array.isArray(rows) ? rows.length : 0, parseInt(room, 10) || 0);
    if (n < 2 || !asksBitrate(qs)) return rows;
    var head = [];
    for (var i = 0; i < n; i++)
        head.push({ row: rows[i], at: i, rate: soundRate(rows[i]),
                    votes: parseInt(rows[i] && rows[i].votes, 10) || 0 });
    // The index closes every tie: V4's sort has not always been stable.
    head.sort(function(a, b) { return (b.rate - a.rate) || (b.votes - a.votes) || (a.at - b.at); });
    return head.map(function(h) { return h.row; }).concat(rows.slice(n));
}

// pageOrder sorts one answer, but one search fills the list from several:
// the name answer, the tag answer, the word pass, a stem, "Show more". Each
// came in bitrate order and went in under the last, so "nova radio" read as
// two lists (2026-09-23: a 320 from Croatia under a 64 from London). Under
// the chip the whole list is one order, by soundRate and then votes. The
// probe's dead stay under the living in the order _webSinkDead gave them,
// and a tie keeps its place, so sorting twice changes nothing.
// Contract: rateOrder([{rate, votes, alive}, ...]) -> the indices 0..n-1 in
//   the order the list shows under the Bitrate chip. No array -> [].
function rateOrder(rows) {
    if (!Array.isArray(rows)) return [];
    var keyed = [];
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i] || {};
        keyed.push({ at: i, dead: r.alive === 0 ? 1 : 0,
                     rate: parseInt(r.rate, 10) || 0, votes: parseInt(r.votes, 10) || 0 });
    }
    keyed.sort(function(a, b) {
        if (a.dead !== b.dead) return a.dead - b.dead;
        if (a.dead) return a.at - b.at;
        return (b.rate - a.rate) || (b.votes - a.votes) || (a.at - b.at);
    });
    return keyed.map(function(k) { return k.at; });
}

// A ListModel only moves one row at a time, and every move renumbers the rows
// behind it; cur keeps track of where each row stood when the order was made.
// Contract: applyOrder(model, order) moves the rows of a ListModel so the row
//   that stood at order[t] ends at t. An order that is no permutation of the
//   model's rows moves nothing. Returns whether it applied.
function applyOrder(model, order) {
    var n = model && typeof model.move === "function" ? model.count : -1;
    if (!Array.isArray(order) || order.length !== n) return false;
    var seen = [];
    for (var i = 0; i < n; i++) {
        var o = order[i];
        if (typeof o !== "number" || o !== Math.floor(o) || o < 0 || o >= n || seen[o]) return false;
        seen[o] = true;
    }
    var cur = [];
    for (var k = 0; k < n; k++) cur.push(k);
    for (var t = 0; t < n; t++) {
        var j = cur.indexOf(order[t], t);
        if (j === t) continue;
        model.move(j, t, 1);
        cur.splice(t, 0, cur.splice(j, 1)[0]);
    }
    return true;
}

// Contract: rateSort(model) puts a results ListModel (roles rate, votes,
//   alive) in rateOrder, in place.
function rateSort(model) {
    if (!model || typeof model.get !== "function") return;
    var rows = [];
    for (var i = 0; i < model.count; i++) {
        var m = model.get(i);
        rows.push({ rate: m.rate, votes: m.votes, alive: m.alive });
    }
    applyOrder(model, rateOrder(rows));
}
