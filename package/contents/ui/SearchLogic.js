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

// Any-order containment: every query word appears somewhere in the name, and
// a word of digits alone has to be one of the name's whole numbers. Measured
// 2026-11-02: under "Raadio 2" the word pass kept Vikerraadio and Raadio 4 on
// the 2 in "128 kbps", and "BBC Radio 1" kept ten 128k streams of other
// stations. Letters stay a plain substring however short they are: "big fm"
// has to find "bigFM Deutschland" and "z 100" has to find "Z100". The price
// is that "80" no longer finds "1980s".
function matchesAllWords(name, ws) {
    if (!ws || ws.length === 0) return false;
    var n = fold(name), nums = n.match(/[0-9]+/g) || [];
    for (var i = 0; i < ws.length; i++) {
        var found = /^[0-9]+$/.test(ws[i]) ? nums.indexOf(ws[i]) !== -1 : n.indexOf(ws[i]) !== -1;
        if (!found) return false;
    }
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
// trailing letters — never below four left. They are the last retry:
// each runs only when the spellings (below) and every longer stem came
// back empty.
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

// A number glued to a word: "raadio2", "bbc radio1", "rtl102.5". No name in
// the directory contains "raadio2", and the stems then asked for "raadio":
// thirty stations, Raadio 2 HQ the third of them. Asked for "raadio 2" the
// three Raadio 2 streams are the answer (measured 2026-11-02). The space goes
// in at every seam between a letter and a digit, in the listener's own case.
// Not under five units: "nrj2" and "yle1" each found one station that had
// nothing to do with them, and it went into the search history.
// A letter is a folded unit in the class _nameTokens splits on. Not \p{L}:
// Qt's V4 does not know it, and /\p{L}/u.test("a") answers false there.
// Contract: spellings("raadio2") = ["raadio 2"]; spellings("Raadio2") =
//   ["Raadio 2"]; spellings("104.6rtl") = ["104.6 rtl"]; spellings("1live") =
//   ["1 live"]; spellings("nrj2") = spellings("jazz") = spellings(null) = [].
function spellings(q) {
    var t = String(q === undefined || q === null ? "" : q).trim();
    if (t.length < 5) return [];
    var out = "", was = 0, apart = false;
    for (var i = 0; i < t.length; i++) {
        var c = t.charAt(i);
        // An accent typed as its own mark is part of the letter before it:
        // fold() drops the mark, so on folded text the two are one letter.
        if (/[\u0300-\u036f]/.test(c)) { out += c; continue; }
        var kind = c >= "0" && c <= "9" ? 2
                 : /^[a-z\u00c0-\u1fff\u2c00-\uffff]/.test(fold(c)) ? 1 : 0;
        if (kind !== 0 && was !== 0 && kind !== was) { out += " "; apart = true; }
        out += c;
        was = kind;
    }
    return apart ? [out] : [];
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

// One pass of the liveness probe over the rows on screen: what the session
// already knows about them, and which get a knock now.
// The pass used to mark a row the moment it met a remembered verdict, and
// marking a dead row sinks it to the end of the list the pass was walking.
// The row behind it slid into its place and was stepped over. Reproduced on
// [a, b, DEAD1, DEAD2, c, DEAD3, DEAD4, DEAD5, d] with every verdict
// remembered: after one pass DEAD2 and DEAD4 were still bright and the dead
// stood in reverse order, and it took a second pass to put that right. So a
// query typed again inside the cache's fifteen minutes showed dead stations
// as if nobody had asked. The pass only reads now, and markAlive applies
// what it found once the walk is over.
// Loopback and private hosts never get the knock: such a row keeps its
// unknown verdict and stays clickable, because a preview is the listener's
// own act and the background probe is not.
// Contract: probePass(rows, s) = { spent, known, knock }.
//   rows are the list's rows as shown ({ url, alive }); s = { spent,
//   verdicts, inFlight, active, now, ttl, slots }: the urls dealt with in this
//   search, the remembered verdicts ({ v, t } by url), the urls with a probe in
//   the air, how many of those there are, the time, a verdict's lifetime and
//   how many probes may run at once.
//   spent: the urls this pass settles (a host that is never knocked on, a
//   remembered verdict, a knock). known: [{ url, v }] in row order, v 1 or 0
//   from a verdict younger than ttl; a remembered "unknown" is spent and not
//   listed. knock: the urls to probe now, never one already in the air and
//   never more than the free slots; the rest wait for the next pass.
//   A row already judged or already spent is not looked at. No rows, or an s
//   that is no object, is an empty pass.
function probePass(rows, s) {
    var out = { spent: [], known: [], knock: [] };
    if (!Array.isArray(rows) || s === null || typeof s !== "object") return out;
    var has = function(book, url) {
        return book !== null && typeof book === "object"
               && Object.prototype.hasOwnProperty.call(book, url);
    };
    var free = (parseInt(s.slots, 10) || 0) - (parseInt(s.active, 10) || 0);
    var mine = Object.create(null);
    for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (row === null || typeof row !== "object" || typeof row.url !== "string") continue;
        var url = row.url;
        if (row.alive !== -1 || mine[url] === true || (has(s.spent, url) && s.spent[url])) continue;
        var hit = has(s.verdicts, url) ? s.verdicts[url] : null;
        var fresh = hit !== null && typeof hit === "object" && typeof hit.t === "number"
                    && s.now - hit.t < s.ttl;
        var safe = isProbeSafeHost(url);
        if (safe && !fresh) {
            if ((has(s.inFlight, url) && s.inFlight[url]) || free <= 0) continue;
            out.knock.push(url);
            free--;
        } else if (safe && (hit.v === 0 || hit.v === 1)) {
            out.known.push({ url: url, v: hit.v });
        }
        mine[url] = true;
        out.spent.push(url);
    }
    return out;
}

// Rows the probe condemned sink below the living and keep their own order
// there: the list is a recommendation, and "not answering" is not one.
// Each dead row goes to the very END in encounter order. Moving into a
// shrinking last slot came out reversed, and re-runs flip-flopped the block
// (measured on a real ListModel). This form is stable and idempotent: a
// second pass rotates the dead block through the tail and lands it exactly
// where it started.
// Contract: sinkDead(model) moves the rows of a results ListModel with
//   alive === 0 under all the others, both groups in the order they stood.
function sinkDead(model) {
    if (!model || typeof model.get !== "function" || typeof model.move !== "function") return;
    var moved = 0;
    var i = 0;
    while (i < model.count - moved) {
        if (model.get(i).alive === 0) {
            model.move(i, model.count - 1, 1);
            moved++;
        } else {
            i++;
        }
    }
}

// Verdicts land by url and not by index: probes race against relevance
// moves, "Show more" pages and the star's remove.
// Contract: markAlive(model, known) gives the first row with each known[i].url
//   the verdict known[i].v, and only then sinks the dead, once, so several dead
//   rows marked together keep the order they stood in. A url the list no
//   longer shows is passed over. No model or no list does nothing.
function markAlive(model, known) {
    if (!model || typeof model.get !== "function" || !Array.isArray(known)) return;
    // Nothing moves until every mark is in, so a row's index holds that long.
    var at = Object.create(null);
    for (var i = model.count - 1; i >= 0; i--) at["u:" + model.get(i).url] = i;
    var dead = false;
    for (var k = 0; k < known.length; k++) {
        var mark = known[k];
        if (mark === null || typeof mark !== "object" || typeof mark.v !== "number") continue;
        var row = at["u:" + mark.url];
        if (row === undefined) continue;
        model.setProperty(row, "alive", mark.v);
        if (mark.v === 0) dead = true;
    }
    if (dead) sinkDead(model);
}

// "70s in UK" — what a scoped query MEANS. Every " in " / " from "
// separator offers its tail to the resolver (the country map), longest
// tail first; only a tail the resolver recognizes splits the query into
// {text, cc, country}. "alice in chains" stays one query — "chains" is
// no country — and the resolver decides, never this parser, so the
// country vocabulary lives in exactly one place.
// A tail the resolver does not know is offered once more without a leading
// "the": measured 2026-11-10, "rock in the uk" and "jazz in the united
// states" were no fence at all, and "pop in the netherlands" only worked
// because the directory's own name begins with the article.
// Contract: null, or { text, cc, country } with country the tail as the
//   resolver took it.
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
        var bare = tail.replace(/^the\s+/i, "")
        cc = bare !== tail ? resolve(bare) : ""
        if (cc !== "") return { text: text, cc: cc, country: bare }
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
// Contract: null, or { text, tags, cc, country, loose } where text is the
// query without its country words (what runs as the name inside the country),
// tags are tagList fragments in typed order, cc/country are "" when no
// country was named, and loose counts the unknown words that were read as a
// tag. A reading needs two facets, a lone decade excepted.
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
    return { text: kept.join(" "), tags: tags, cc: cc, country: country, loose: loose };
}

// How a typed query is read before the directory is asked anything.
// "70s in UK": the tail names a country and the head is the real query
// (scopedQuery; not in the country mode, where the text is the country).
// "rock 80 uk": the same wish without the word "in" (facetQuery; in the All
// and Genre modes). Measured before that reading: the directory was asked for
// a station NAMED that, had none, and the stem retry answered with French and
// German "rock 80" stations; tagList=rock,80 inside GB has sixteen.
// A fence read without "in" beside a word nothing knows is a guess: "new
// jersey" is read as "new" in Jersey and finds nothing there, while six
// stations carry the name (measured 2026-11-10). bareScope marks the guess,
// and plain is the retry that does not make it.
// Contract: reading(q, mode, resolve, plain) = { cc, scoped, bareScope }.
//   cc is the country the whole text names, "" for none. scoped is null or
//   { text, cc, country }, the fence the text itself names. bareScope says
//   the fence came without "in" and one of the words beside it was unknown.
//   plain === true reads no fence without "in". resolve(text) answers a
//   country code or ""; without one nothing is a country.
function reading(q, mode, resolve, plain) {
    var t = String(q === undefined || q === null ? "" : q).trim();
    var ask = function(text) {
        var code = typeof resolve === "function" ? resolve(text) : "";
        return typeof code === "string" ? code : "";
    };
    var out = { cc: ask(t), scoped: null, bareScope: false };
    if (t === "" || out.cc !== "") return out;
    if (mode !== "country") out.scoped = scopedQuery(t, ask);
    if (out.scoped === null && plain !== true && (mode === "all" || mode === "genre")) {
        var bare = facetQuery(t, ask);
        if (bare !== null && bare.cc !== "") {
            out.scoped = { text: bare.text, cc: bare.cc, country: bare.country };
            out.bareScope = bare.loose > 0;
        }
    }
    return out;
}

// Whether two country vocabularies read a text the same way. The directory's
// own country list arrives after the session's first search has gone out,
// and that search was read without it. Measured 2026-11-10: the first
// "portugal" listed 27 stations with Portugal in their name, every later one
// Portugal's chart, and 3 of the first 30 rows were the same.
// Contract: readingKey(q, mode, resolve) is a string, equal for two resolvers
//   exactly when the search would ask the same thing with both: the country
//   the whole text names (in the All and Country modes, the only ones that
//   use it) and the fence the text names. Nothing typed has one key.
function readingKey(q, mode, resolve) {
    var r = reading(q, mode, resolve);
    var whole = (mode === "all" || mode === "country") ? r.cc : "";
    return JSON.stringify(r.scoped === null ? [whole] : [whole, r.scoped.cc, r.scoped.text]);
}

// The code a typed text has in the country maps: the hand-written one first,
// then the directory's own list. The widget looked both up with a plain
// index, and the directory's map started the session as an ordinary object:
// "constructor" came back as a function and would have gone out as
// countrycode=function Object() { [native code] }.
// Contract: countryCode(q, hand, api) is the two-letter code fold(q) has as
//   an own entry of hand, else of api, else "". A map that is no object and a
//   text that is no string have no countries.
function countryCode(q, hand, api) {
    var f = typeof q === "string" ? fold(q) : "";
    var maps = [hand, api];
    for (var i = 0; i < maps.length; i++) {
        var m = maps[i];
        if (m === null || typeof m !== "object" || !Object.prototype.hasOwnProperty.call(m, f)) continue;
        if (typeof m[f] === "string" && /^[A-Z]{2}$/.test(m[f])) return m[f];
    }
    return "";
}

// Inside a fence read without "in" the country word may be part of the name
// after all. Measured 2026-11-10: "bbc wales" asks for name=bbc inside GB,
// and the row "bbc Wales" is the 39th of that answer, past the page's 30.
// The rows that hold every word as typed lead the fenced answer in the
// directory's own order, and the rest of it follows them.
// Contract: fenceLead(typed) = function(row) -> bool, true for a row whose
//   name holds every word of typed (matchesAllWords). Text without a word
//   gives a filter that keeps nothing; a row without a name is not kept.
function fenceLead(typed) {
    var ws = words(typeof typed === "string" ? typed : "");
    return function(row) {
        return row !== null && typeof row === "object" && typeof row.name === "string"
               && matchesAllWords(row.name, ws);
    };
}

// A station name typed with its country: "retro fm eesti". A station word
// or a number makes the text a name and facetQuery leaves it alone, so the
// country was never tried as a fence. Measured 2026-11-10: the three words
// as a name showed one row with no votes, while name=retro fm inside EE
// answers four, Retro FM Estonia with 166 votes among them. The name stays
// the first reading ("virgin radio uk" is a station); this is what an empty
// answer, or one of a row or two, falls back on.
// Contract: nameInCountry(q, resolve) = null | { text, cc, country }. The
//   text holds exactly one country the resolver knows (up to three words,
//   the longest phrase first) and at least one other word; text is those
//   other words as typed. null for what facetQuery already reads as a wish,
//   for two countries, for a country alone, past six words and for no text.
function nameInCountry(q, resolve) {
    var t = typeof q === "string" ? q.trim() : "";
    var typed = t.split(/\s+/), ws = words(t);
    if (ws.length < 2 || ws.length > 6 || typed.length !== ws.length) return null;
    var ask = function(text) {
        var code = typeof resolve === "function" ? resolve(text) : "";
        return typeof code === "string" ? code : "";
    };
    if (facetQuery(t, ask) !== null) return null;
    var kept = [], cc = "", country = "";
    for (var i = 0; i < ws.length; ) {
        var hit = 0;
        for (var len = Math.min(3, ws.length - i); len >= 1 && hit === 0; len--) {
            var phrase = ws.slice(i, i + len).join(" ");
            var code = ask(phrase);
            if (code === "") continue;
            if (cc !== "") return null;
            cc = code; country = phrase; hit = len;
        }
        if (hit === 0) { kept.push(typed[i]); hit = 1; }
        i += hit;
    }
    return cc !== "" && kept.length > 0 ? { text: kept.join(" "), cc: cc, country: country } : null;
}

// How few rows still count as next to nothing (emptyNext's "incountry").
var THIN_ANSWER = 3;

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

// "techno berlin": a genre and a place, and no station is named either way.
// The directory files a city or a region in its state field, so the genre is
// asked inside it. Measured 2026-11-02: "techno berlin" found nothing in five
// requests, and tag=techno&state=berlin answered with seventeen Berlin techno
// stations; "jazz paris" found 3, "jazz vienna" 5, "rock barcelona" 3 and
// "pop tallinn" 19. Where the field says something else ("jazz wien", "techno
// munich") it costs one request before the stems.
// Two words, one a GENRES key. The other is the place: no digit, four letters
// or more, no station word. The state filter is a case-blind substring, so a
// shorter word lands in every region that holds it. A pair that is itself a
// GENRES phrase ("smooth jazz") is the genre and nothing else.
// Contract: genrePlace("techno berlin") = { tag: "techno", state: "berlin" };
//   genrePlace("Berlin Techno") = { tag: "techno", state: "Berlin" }, the place
//   as typed; genrePlace("rock 1live"), ("rock radio"), ("pop rio"),
//   ("smooth jazz"), ("techno"), ("") and (null) are null.
function genrePlace(q) {
    var ws = words(q);
    var typed = String(q === undefined || q === null ? "" : q).trim().split(/\s+/);
    if (ws.length !== 2 || typed.length !== 2 || GENRES[ws.join(" ")] === true) return null;
    for (var i = 0; i < 2; i++) {
        var place = ws[1 - i];
        var letters = (place.match(/[a-z\u00c0-\u1fff\u2c00-\uffff]/g) || []).length;
        if (GENRES[ws[i]] === true && letters >= 4 && !/[0-9]/.test(place)
            && !NAME_WORDS.hasOwnProperty(place))
            return { tag: ws[i], state: typed[1 - i] };
    }
    return null;
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
// States Of America", and nobody types either. What the neighbours call us
// is here too. Measured 2026-11-02: "Viro", "Estland", "Finnland", "Kreeka",
// "Mehhiko" and "Tšehhi" each went out as a name, a tag and two stems and
// found nothing in four requests; as a country each is one request and a
// full page. "Island" stays out: Iceland in Estonian, but an English word.
var COUNTRY_ALIASES = (function() {
    var src = {
        "soome": "FI", "finland": "FI", "suomi": "FI", "finnland": "FI",
        "eesti": "EE", "estonia": "EE", "viro": "EE", "estland": "EE",
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
        "kreeka": "GR", "mehhiko": "MX", "tšehhi": "CZ",
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

// The spelling a station and a catalogue disagree on, folded away for the
// cover choice only: fold(), then every apostrophe and backtick as one, "&"
// and "+" as "and", and the punctuation _bare drops gone, commas excepted,
// because nameAkin reads "Sia, Sean Paul" as a list. Measured 2026-11-02:
// 181.fm sent "Guns N` Roses - Sweet Child O` Mine" and both services
// filed it under the apostrophe, so it got no cover, and Jazz Radio Blues
// writes "G LOVE AND SPECIAL SAUCE" for "G. Love & Special Sauce". An
// artist is matched on this fold whole, never looked for inside another
// name (artArtistScore): without its dots "t.A.T.u." is "tatu", and "art
// tatum" contains that. The class is spelled out rather than \w, which in
// V4 is ASCII and would wipe a Cyrillic name. A name of punctuation alone
// comes back as fold() has it, so "!!!" never turns into no artist. fold()
// itself stays as it is: the station search matches on it.
// Contract: artFold("Guns N` Roses") = "guns n roses"; artFold("Florence +
//   The Machine") = artFold("Florence and the Machine"); artFold("Кино") =
//   "кино"; artFold("!!!") = "!!!"; artFold(null) = "".
function artFold(s) {
    var f = artSpelling(s)
        .replace(/[!-+\--\/:-@\[-`{-~\u00a1-\u00bf\u2010-\u205e]/g, "")
        .replace(/\s+/g, " ").trim();
    return f === "" ? fold(s) : f;
}

// The first half of artFold on its own: fold(), every apostrophe and
// backtick as one, "&" and "+" as "and", and no punctuation dropped.
function artSpelling(s) {
    return fold(s)
        .replace(/[\u2018\u2019\u201a\u201b\u02bc\u00b4`\u2032]/g, "'")
        .replace(/\s*[&+]\s*/g, " and ")
        .replace(/\s+/g, " ").trim();
}

// Whether Deezer's first artist is the one we asked for, before its photo
// stands in for a record nobody found. The name has to be the same: case,
// accents, quote style and "&"/"+"/"and" aside, nothing contained and no
// punctuation dropped. On 231 live titles (2026-11-02) the photo step
// painted 18 pictures and 9 were of somebody else, among them "KLASSIK RADIO
// POPS ORCHESTRA" for Klassik Radio and "NANCY & SIDOROV" for Nancy, both
// let in by nameAkin's containment. The art fold's punctuation drop stays
// out of it: on the 77 recorded artist answers it would also have taken
// "EL–P" for ELP and "AURA..." for the trance act Aura.
// Contract: artPhotoTakes("Love & Fate", "Love") = false;
//   artPhotoTakes("Guns N` Roses", "Guns N' Roses") = true;
//   artPhotoTakes("ELP", "EL–P") = false; artPhotoTakes("", "") = false.
function artPhotoTakes(wantName, gotName) {
    var want = artSpelling(wantName);
    return want !== "" && want === artSpelling(gotName);
}

// A title without its bracketed tail: "(Radio Edit)", "[Remastered 2021]".
// Both sides get this, or a station's "(Radio Edit)" would never match a
// catalogue's plain title and vice versa.
function artCoreTitle(t) {
    return artFold(String(t || "").replace(/\s*[\(\[][^\)\]]*[\)\]]/g, " "));
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
// any spelling, 1 for a name that is only a part of a longer one, 0 for a
// stranger. On the art fold one name has to sit in the other as whole words,
// in one run: "mary j blige" in a station's "Mary J Blige feat. Drake", never
// "tatu" in "art tatum" or "y and t" in "bob marley and the wailers". Taken
// letter by letter, the fold matched those strangers, and taken whole only,
// it lost every credit with a guest (measured 2026-11-03). The run is the
// same name when the credit ends or a word that joins performers stands on
// each side of it. Anything else is a part of somebody's name: "Queen" in
// Queen Latifah, "Laine" in Frankie Laine, "Pink" for Pink Floyd. Counted as
// the artist, such a part gave a station's "Laura - Muusa" a Laura Mvula
// sleeve, so artPick takes it only together with the song. A name under four
// letters is the artist only at the start of a credit, before a word that
// joins performers, as nameAkin has it, and is never a part. The initials
// are read off the names as written, not off the art fold: that one turns
// "&" into a word and drops the apostrophe of N', and "CSNY" or "GNR" would
// stop finding their bands.
// Contract: artArtistScore("Drake", "Mary J Blige feat. Drake") = 2;
//   artArtistScore("Laura", "Laura Mvula") = 1; artArtistScore("Sia", "Sia
//   Furler") = 0; artArtistScore("", "Anyone") = 0.
function artArtistScore(wantArtist, gotArtist) {
    var wa = artFold(wantArtist), ga = artFold(gotArtist);
    if (wa === "" || ga === "") return 0;
    if (wa.replace(/ /g, "") === ga.replace(/ /g, "")) return 2;
    var run = _wordRun(_creditWords(wantArtist), _creditWords(gotArtist));
    if (run === 2) return 2;
    if (ga.length >= 2 && artInitials(wantArtist) === ga) return 2;
    if (wa.length >= 2 && artInitials(gotArtist) === wa) return 2;
    return run;
}

var _JOINS = { ",": true, "and": true, "feat": true, "ft": true, "featuring": true, "with": true, "vs": true, "x": true };

// Whether two words of two credits are one word. Any two that join
// performers are: a station's "feat." is a catalogue's "&", and a slash in
// one list is a comma in the other. A station's "Merlyn Uusküla feat. Ice
// Dog M" met iTunes' "Merlyn Uusküla & Ice Dog M" as a stranger, and the
// sleeve went to the next row, another song filed under her name alone.
function _sameWord(x, y) {
    return x.w === y.w || (_joins(x.w) && _joins(y.w));
}

function _joins(w) {
    return w === "/" || _JOINS[w] === true;
}

// Letters on both sides of a dot, a hyphen, an apostrophe or a "!" inside one
// word, which the art fold then joins: "will.i.am", "t.A.T.u.", "P!nk".
var _LETTER = "0-9A-Za-z\u00c0-\u024f\u0370-\u03ff\u0400-\u04ff";
var _JOINED = new RegExp("[" + _LETTER + "][.!$'\u2018\u2019\u2010-\u2015-][" + _LETTER + "]");

// The words of an artist credit on the art fold, a list split where it is a
// list: a comma, a semicolon, "×", "、" or a full-width ampersand is a word of
// its own (a joining one), and so is a slash, which the fold would otherwise
// drop and run two names together ("Santi/RUSSI"). A word the fold made by
// joining letters across inner punctuation is marked. Measured on 2026-11-03
// against the recorded answers: kept on the words, "Pritam, Arijit Singh"
// lost Pritam's records.
function _creditWords(s) {
    var parts = String(s === undefined || s === null ? "" : s).split(/\s*([,;\/\u00d7\u3001\uff06\uff0c])\s*/), out = [];
    for (var i = 0; i < parts.length; i++) {
        if (parts[i] === "/") { out.push({ w: "/", joined: false }); continue; }
        if (/^[,;\u00d7\u3001\uff06\uff0c]$/.test(parts[i])) { out.push({ w: ",", joined: false }); continue; }
        var raw = parts[i].split(/\s+/);
        for (var r = 0; r < raw.length; r++) {
            var f = artFold(raw[r]);
            if (f === "") continue;
            var ws = f.split(" "), joined = ws.length === 1 && _JOINED.test(raw[r]);
            for (var k = 0; k < ws.length; k++) out.push({ w: ws[k], joined: joined });
        }
    }
    return out;
}

// Whether the shorter of two credits is an unbroken run of the longer one's
// words: 2 when the run is a performer of its own, 1 when it is only a part
// of a longer name, 0 when there is no run. A performer of its own has the
// end of the credit, a word that joins performers or a slash on each side.
// A "the" in front of it is passed over: a station's "Rolling Stones" and a
// catalogue's "The Rolling Stones" are one band, and the word alone makes
// nobody a namesake. One under four letters counts only at the start,
// followed by nothing or by a word that joins performers ("AC/DC" is a name,
// not AC and company), and is never a part. A word the fold joined meeting a
// plain one counts like a short name: the "william" of will.i.am is no
// William Orbit, and the "tatu" of t.A.T.u. no Tatu Kantomaa.
function _wordRun(a, b) {
    var letters = function(ws) {
        return ws.filter(function(x) { return x.w !== "," && x.w !== "/"; })
                 .map(function(x) { return x.w; }).join("").length;
    };
    var s = letters(a) <= letters(b) ? a : b, l = s === a ? b : a;
    if (s.length === 0) return 0;
    var ends = function(k) { return k < 0 || k >= l.length || _joins(l[k].w); };
    var part = 0;
    for (var i = 0; i + s.length <= l.length; i++) {
        var j = 0, mixed = false;
        while (j < s.length && _sameWord(l[i + j], s[j])) {
            if (l[i + j].joined !== s[j].joined) mixed = true;
            j++;
        }
        if (j < s.length) continue;
        if (i === 0 && (s.length === l.length || _JOINS[l[s.length].w] === true)) return 2;
        if (mixed || letters(s) < 4) continue;
        if (ends(i > 0 && l[i - 1].w === "the" ? i - 2 : i - 1) && ends(i + s.length)) return 2;
        part = 1;
    }
    return part;
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
// requireTitle (true) also refuses a row whose title does not match, so the
// artist's other records no longer count: artPickEither needs that.
function artPick(wantArtist, wantTitle, cands, requireTitle) {
    if (!cands || cands.length === 0) return -1;
    var wa = artFold(wantArtist);
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
        // With an artist known the ranks are 6 and 5 for the artist whole
        // with the exact title and with one that holds it, 3 and 2 for a
        // part of a longer name with the same two, and 1 for the artist
        // whole with another song. A part of a name without the song ranks
        // 0, which the > below never takes: see artArtistScore.
        var wantCore = artCoreTitle(wantTitle);
        var candCore = artCoreTitle(c.title);
        var te = 0;
        if (wantCore !== "" && wantCore === candCore) te = 3;
        else if (nameAkin(wantCore, candCore)) te = 2;
        var score;
        if (wa !== "") {
            var ae = artArtistScore(wantArtist, c.artist);
            if (ae === 0 || (requireTitle === true && te === 0)) continue;
            score = ae === 1 ? te : (te === 0 ? 1 : te + 3);
        } else {
            // Nothing in the widget reaches this branch since 2026-11-02:
            // ArtworkEngine turns a line without an artist away before the
            // network. A call with no artist is still decided on the title alone.
            if (te === 0) continue;
            score = te;
        }
        if (score > bestScore) { best = i; bestScore = score; }
    }
    return best;
}

// artPick, and when nothing matches, artPick again with artist and title
// swapped, where both halves must match. Jazz Radio Blues and SWR3 send some
// songs as "Title - ARTIST" or "Title / Artist": on 231 live titles
// (2026-11-02) all six of those got no cover or the photo of a stranger
// named like the song ("LENNY" for Stevie Ray Vaughan's "Lenny"). The free
// text search already carries both words, so the right rows were in the
// answer and only the reading was the wrong way round. The title has to
// match in the swapped reading, or the artist's other records would let a
// title such as "John Williams" pull any John Williams soundtrack.
// Contract: artPickEither("A bar song (Tipsy)", "Shaboozey", [Shaboozey /
//   A Bar Song (Tipsy)]) = 0; artPickEither("Goin' to chicago", "KURT
//   ELLING", [Kurt Elling / Nature Boy]) = -1; with either half empty it is
//   artPick's answer alone.
function artPickEither(wantArtist, wantTitle, cands) {
    var i = artPick(wantArtist, wantTitle, cands);
    if (i >= 0 || artFold(wantArtist) === "" || artFold(wantTitle) === "") return i;
    return artPick(wantTitle, wantArtist, cands, true);
}

// For the last resort, a song no catalogue has: the first row filed under
// exactly our artist, art fold aside, that has a picture. cands are
// {artist, title, art}. The whole credit has to match, so a guest spot
// ("Rivo Rehe" with "Suvesaladus (feat. Anne Loho)"), a duo she is half of
// and a namesake spelled one letter off ("Anne Loo") are all refused; the
// title is not asked at all, because the song is the one thing missing.
// Karaoke and tribute pressings are dropped as artPick drops them.
// Contract: artPickByArtist("Anne Loho", [Roderic H & Anne Loho / Next To
//   Me, Anne Loho / Hinges Prii]) = 1; artPickByArtist("Anne Loho", [Anne
//   Loo / Perfect Rainy Day]) = -1; artPickByArtist("", rows) = -1.
function artPickByArtist(wantArtist, cands) {
    var want = artFold(wantArtist);
    if (want === "" || !cands) return -1;
    for (var i = 0; i < cands.length; i++) {
        var c = cands[i] || {};
        if (!c.art) continue;
        if (_ART_JUNK.test(String(c.title || "")) || _ART_JUNK.test(String(c.artist || "")))
            continue;
        if (artFold(c.artist) === want) return i;
    }
    return -1;
}

// How long a changed title waits before its cover is looked up, in ms.
// first: the title follows an empty header. sinceMoveMs: how long before
// this change the lookup key last moved.
// The full window is for a StreamTitle that flaps, so that each flap does
// not start a chain of requests. It was also what every ordinary song
// change waited: 1.50 to 1.53 s on 29 of 29 changes, 87% of the time from
// title to cover, where the catalogues answer in 0.15 to 0.26 s. A title
// that has stood for four seconds is not flapping. The polled titles are at
// least five seconds apart, so on that road nothing waits the window out.
// A span that is no number, or runs backwards after a clock change, gets
// the full window.
// Contract: artWaitMs(true, 0) = 200; artWaitMs(false, 4000) = 200;
//   artWaitMs(false, 3999) = 1500; artWaitMs(false, undefined) = 1500.
function artWaitMs(first, sinceMoveMs) {
    if (first === true) return 200;
    return sinceMoveMs >= 4000 ? 200 : 1500;
}

// Whether a lookup that found no cover is asked once more, and after how
// long: ms, or -1 for no. unanswered: some service timed out, refused or
// reported a quota, so the chain did not end on everybody's "no". key: the
// lookup's key. currentKey: the key of what plays now. retriedKey: the
// track that already had its second attempt. enabled: covers are switched on.
// Such an end is not cached, and nothing asked again until the title
// changed: measured with two timeouts in the chain, the song stayed without
// a cover for its whole play. One more attempt, never two, and only while
// the same track stands. Twenty-five seconds leaves a per-minute limit time
// to ease (iTunes refuses at about 20 requests a minute) and most of a song
// is still ahead.
// The engine asks twice with the same arguments: when the chain ends, and
// again when the wait is over, since by then the track may have changed.
// Contract: artRetryMs(true, "a b", "a b", "", true) = 25000;
//   artRetryMs(false, "a b", "a b", "", true) = -1;
//   artRetryMs(true, "a b", "c d", "", true) = -1;
//   artRetryMs(true, "a b", "a b", "a b", true) = -1;
//   artRetryMs(true, "a b", "a b", "", false) = -1.
function artRetryMs(unanswered, key, currentKey, retriedKey, enabled) {
    if (unanswered !== true || !enabled || !key) return -1;
    return key === currentKey && key !== retriedKey ? 25000 : -1;
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

// What an empty answer tries next: "unscope", "astyped", "incountry", "stems"
// or "done".
// A country chip pinned by an EARLIER search keeps scoping what is typed
// after it — that is its job ("Popular in Finland", then "rock"). But when
// the new text finds nothing inside that country, the chip is yesterday's
// intent standing in front of today's: seen live, "jazz united states" and
// then "virgin radio uk" answered "No matching stations" with the American
// chip still up. The scope goes and the text runs again everywhere. A scope
// the text itself names ("80s in uk") is the listener's word and stays.
// A fence the search read out of the text without "in", beside a word it did
// not know (reading's bareScope), was a guess: the text runs again as it was
// typed, as a name, and the chip the guess put up goes. That comes before the
// stems, which would shorten the one word left inside the wrong country.
// A name typed with its country ("retro fm eesti", nameInCountry) is asked
// inside that country when the name alone found nothing, and also when it
// found under THIN_ANSWER rows: that is the one answer with rows in it that
// still gets another question.
// Contract: s = { count, gotAnswer, mode, inheritedScope, bareScope, inCountry,
//   countryQuery, stemCount }. No answer from the network is never "no results".
function emptyNext(s) {
    if (!s || s.gotAnswer !== true) return "done";
    var inCountry = s.inCountry === true && s.mode === "all";
    if (s.count > 0) return inCountry && s.count < THIN_ANSWER ? "incountry" : "done";
    if (s.inheritedScope === true) return "unscope";
    if (s.bareScope === true) return "astyped";
    if (inCountry) return "incountry";
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

// bycountry matches its word inside the directory's English country names,
// and those do not hold the words people type. Measured 2026-11-10:
// bycountry/uk answered a hundred rows and every one was Ukrainian,
// bycountry/usa answered none. A word the popup's hand-written aliases know
// is asked by its code instead; bycountrycodeexact takes order, reverse,
// limit and offset like the other roads (GB by votes: LBC Radio, Radio
// Caroline, Capital FM London, and offset=1 opens on Radio Caroline).
// Contract: no road or no word is the bare list; a road the combo box never
// offered reads as byname and never becomes a path segment; a mirror name
// that is not a hostname label never becomes a host; on the country road a
// word COUNTRY_ALIASES knows, folded, is asked as bycountrycodeexact/<code>
// and any other word as it was typed.
function directoryBase(server, by, val) {
    var host = /^[a-z0-9-]+$/.test(String(server || "")) ? String(server) : "all";
    var base = "https://" + host + ".api.radio-browser.info/json/stations";
    var v = String(val === undefined || val === null ? "" : val).trim();
    if (!by || v === "") return base;
    var code = by === "bycountry" ? COUNTRY_ALIASES[fold(v)] : undefined;
    if (code !== undefined) return base + "/bycountrycodeexact/" + code;
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

// Whether a directory row is a station the list already holds. The popup
// compared the saved address with the row's, and the directory moves a
// record between a broadcaster's servers: measured 2026-11-10 on the twenty
// default stations, four came back under "From the web" beside their saved
// selves, Groove Salad saved at ice3.somafm.com and listed at ice2 under the
// same uuid, and a star then saved the twin.
// Contract: knownStationAt(savedRows, row) is the index of the first saved
//   row ({hostname, prev, uuid}) that holds one of the row's two addresses
//   (url_resolved, url) as its hostname or its prev, by urlKey, or carries the
//   row's stationuuid; -1 for none. An empty address or an empty uuid matches
//   nothing. No list, no row and rows that are no objects answer -1.
function knownStationAt(savedRows, row) {
    if (!Array.isArray(savedRows) || row === null || typeof row !== "object") return -1;
    var text = function(v) { return typeof v === "string" ? v.trim() : ""; };
    var a = urlKey(text(row.url_resolved)), b = urlKey(text(row.url)), id = text(row.stationuuid);
    for (var i = 0; i < savedRows.length; i++) {
        var s = savedRows[i];
        if (s === null || typeof s !== "object") continue;
        if (id !== "" && text(s.uuid) === id) return i;
        var at = urlKey(text(s.hostname)), was = urlKey(text(s.prev));
        if (at !== "" && (at === a || at === b)) return i;
        if (was !== "" && (was === a || was === b)) return i;
    }
    return -1;
}

// Whether the list holds the row's station, for the results, which drop it.
// What they drop the list has to show: its own filter reads names alone, so a
// saved station the directory found by its country, its language or its genre
// was dropped here and hidden there, and stood nowhere on the screen.
// Contract: knownStation(savedRows, row, named) = knownStationAt(...) !== -1.
//   named, when it is a list, gets the saved row an answer names, once, as
//   { url_resolved: its hostname, url: "", stationuuid: its uuid }: the list's
//   own words and not the mirror's, and a row knownStationAt finds that
//   station by again, also after the list was reloaded or the station healed.
function knownStation(savedRows, row, named) {
    var at = knownStationAt(savedRows, row);
    if (at === -1 || !Array.isArray(named)) return at !== -1;
    var text = function(v) { return typeof v === "string" ? v.trim() : ""; };
    var own = { url_resolved: text(savedRows[at].hostname), url: "", stationuuid: text(savedRows[at].uuid) };
    for (var i = 0; i < named.length; i++) {
        var n = named[i];
        if (n !== null && typeof n === "object" && n.url_resolved === own.url_resolved
            && n.stationuuid === own.stationuuid) return true;
    }
    named.push(own);
    return true;
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

// Where "Show more" stands in the list it pages, once an answer was walked.
// The popup read both things off the rows left on screen: the next offset was
// the row count, and the button showed only while the count filled the cap.
// The walk drops what the listener has saved, so a full page of 50 holding 25
// saved stations left 25 rows under a cap of 30 and the button went, the rest
// of the directory's list never asked for; 30 rows and a next page of 30
// duplicates and 20 new made 50 under a cap of 60, and it went the same way.
// Here both come from the directory's own page. The next page starts behind
// the last row the walk passed, shown or dropped. There may be more while rows
// of the answer are still unwalked (the cap cut the walk short) or while the
// answer was a full page; a short page is the end of the list, an empty one too.
// Contract: pageAfter(qs, from, parsed, consumed) -> { at, more }. qs is the
//   query as sent, without its offset (its limit= is the page size); from the
//   offset it was asked at; parsed the rows the answer carried; consumed the
//   rows of it the walk passed. at = from + consumed. No answer yet,
//   pageAfter(), is { at: 0, more: false }. What is no count reads as 0,
//   consumed never passes parsed, and a query without a limit has no full page.
function pageAfter(qs, from, parsed, consumed) {
    var n = function(v) { v = parseInt(v, 10); return v > 0 ? v : 0; };
    var m = /[?&]limit=(\d+)/.exec(String(qs));
    var size = m ? n(m[1]) : 0, got = n(parsed), walked = Math.min(n(consumed), got);
    return { at: n(from) + walked, more: walked < got || (size > 0 && got >= size) };
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
