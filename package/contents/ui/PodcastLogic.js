/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What a podcast feed MEANS — pure string decisions, no network, under
// qmltestrunner. A feed is hostile input: it arrives from an arbitrary
// server the user typed or a directory suggested, it may be HTML, broken
// XML, CDATA soup or a honeypot pointing its enclosures at the LAN. This
// file turns that into clean episode rows or refuses politely; the
// engine in main.qml only ever sees the survivors.
.pragma library
.import "HostGuard.js" as HostGuard

// ── text plumbing ────────────────────────────────────────────────────────

// One CDATA layer off. RSS titles routinely arrive as
// <![CDATA[Show — Episode 12]]>; nested CDATA is not legal XML and the
// leftovers of an attempt at it stay visibly weird rather than parsed.
function stripCdata(s) {
    var m = /^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/.exec(s || "")
    return m ? m[1] : (s || "")
}

// The five named entities XML guarantees plus numeric forms. Anything
// exotic stays literal — better a visible &ouml; than a homemade decoder
// with surprise behavior.
function decodeEntities(s) {
    return (s || "")
        .replace(/&#x([0-9a-fA-F]+);/g, function(_, h) {
            var c = parseInt(h, 16)
            return c > 0 && c <= 0x10FFFF ? String.fromCodePoint(c) : ""
        })
        .replace(/&#(\d+);/g, function(_, d) {
            var c = parseInt(d, 10)
            return c > 0 && c <= 0x10FFFF ? String.fromCodePoint(c) : ""
        })
        .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
        .replace(/&nbsp;/g, " ")
        .replace(/&amp;/g, "&")   // last, or double-encoded text over-decodes
}

function _cleanText(s) {
    return decodeEntities(stripCdata(s)).replace(/\s+/g, " ").trim()
}

// First <tag>…</tag> body inside a fragment, namespace-tolerant when
// asked ("itunes:duration" matches with or without the prefix — feeds
// disagree about it in the wild).
function _tagBody(fragment, tag) {
    var names = tag.indexOf(":") !== -1
        ? [tag, tag.split(":")[1]]
        : [tag]
    for (var i = 0; i < names.length; i++) {
        var re = new RegExp("<" + names[i] + "(?:\\s[^>]*)?>([\\s\\S]*?)</" + names[i] + ">", "i")
        var m = re.exec(fragment)
        if (m) return m[1]
    }
    return ""
}

// One attribute out of a single tag's text, either quote style, any order.
function _attr(tagText, name) {
    var m = new RegExp(name + "\\s*=\\s*\"([^\"]*)\"", "i").exec(tagText)
    if (m) return m[1]
    m = new RegExp(name + "\\s*=\\s*'([^']*)'", "i").exec(tagText)
    return m ? m[1] : ""
}

// ── judgement calls ──────────────────────────────────────────────────────

// May this URL be fetched/downloaded at all? http(s) only, and never a
// private/loopback address in ANY spelling — a hostile feed must not be
// able to point the episode download (or the feed refresh) at the LAN.
// The judgement itself lives in HostGuard.js, shared with the search
// probe and the logo fetcher.
function urlAllowed(url) {
    if (!/^https?:\/\//i.test(url || "")) return false
    var host = HostGuard.hostOf(url)
    return host !== "" && !HostGuard.isPrivateHost(host)
}

// An enclosure the audio player can honestly attempt. Feeds omit the
// type often enough that an empty one passes; a declared non-audio type
// (video, PDF "bonus material") is refused.
function _enclosurePlayable(mime) {
    if (mime === "") return true
    if (/^audio\//i.test(mime)) return true
    return /^application\/octet-stream$/i.test(mime)
}

// itunes:duration wears three coats: plain seconds, m:ss, h:mm:ss.
// -1 = the feed did not say (never 0 — 0 is a real duration claim).
function parseDuration(s) {
    var t = (s || "").trim()
    if (t === "") return -1
    if (/^\d+$/.test(t)) return parseInt(t, 10)
    var m = /^(?:(\d+):)?(\d{1,2}):(\d{2})$/.exec(t)
    if (!m) return -1
    return (parseInt(m[1] || "0", 10) * 3600)
           + (parseInt(m[2], 10) * 60) + parseInt(m[3], 10)
}

// ── the feed ─────────────────────────────────────────────────────────────

// RSS text in, episode rows out. Never throws. A page that is not an RSS
// feed (HTML error page, a JSON API response) comes back ok:false so the
// UI can say so instead of showing zero rows with a straight face.
function parseFeed(xml, maxItems) {
    var text = String(xml || "")
    var cap = maxItems > 0 ? maxItems : 50
    var out = { ok: false, title: "", episodes: [] }
    if (text.indexOf("<") === -1) return out
    // The channel's own title (fallback naming for a hand-typed feed URL);
    // taken from BEFORE the first item so an episode title cannot shadow it.
    var firstItem = text.search(/<item[\s>]/i)
    var head = firstItem === -1 ? text : text.substring(0, firstItem)
    out.title = _cleanText(_tagBody(head, "title"))
    var itemRe = /<item[\s>][\s\S]*?<\/item>/gi
    var m
    while ((m = itemRe.exec(text)) !== null && out.episodes.length < cap) {
        var item = m[0]
        var encTag = /<enclosure\b[^>]*>/i.exec(item)
        if (!encTag) continue                       // an episode IS its audio
        var url = decodeEntities(_attr(encTag[0], "url")).trim()
        var mime = _attr(encTag[0], "type").trim()
        if (!urlAllowed(url) || !_enclosurePlayable(mime)) continue
        var title = _cleanText(_tagBody(item, "title"))
        var guid = _cleanText(_tagBody(item, "guid"))
        var when = Date.parse(_cleanText(_tagBody(item, "pubDate")))
        // No i18n here — a .pragma library has no QML context; an
        // untitled episode ships as "" and the delegate names it.
        out.episodes.push({
            title: title,
            url: url,
            guid: guid !== "" ? guid : url,
            pubMs: isNaN(when) ? 0 : when,
            durationSec: parseDuration(_tagBody(item, "itunes:duration")),
            sizeBytes: parseInt(_attr(encTag[0], "length"), 10) || 0
        })
    }
    // A real feed with zero usable episodes is still a feed — ok reports
    // "this parsed as RSS", not "you will like the contents".
    out.ok = out.episodes.length > 0
             || /<rss[\s>]|<channel[\s>]/i.test(text)
    return out
}

// ── files and positions ──────────────────────────────────────────────────

// A filename the shell, the filesystem and the eye can all live with.
// Path separators, control characters, quotes and leading dots go; long
// titles are capped so the enclosure extension still fits.
function safeFileName(title, fallback) {
    var t = String(title || "")
        .replace(/[\x00-\x1f\x7f]/g, " ")
        .replace(/[\/\\:*?"'<>|`$]/g, " ")
        .replace(/\s+/g, " ").trim()
        // Leading dot-runs go WITH their whitespace: "../../etc" arrives
        // here as ".. .. etc" and must shed the whole prefix, not one run.
        .replace(/^[.\s]+/, "")
    if (t.length > 120) t = t.substring(0, 120).trim()
    return t !== "" ? t : (fallback || "episode")
}

// The audio extension the enclosure URL wears, whitelisted; anything
// else records as .mp3 — a wrong label plays fine, an injected path
// does not.
function fileExt(url) {
    var m = /\.([a-z0-9]{2,4})(?:[?#]|$)/i.exec(url || "")
    var ext = m ? m[1].toLowerCase() : ""
    return ["mp3", "m4a", "aac", "ogg", "opus", "oga", "flac", "wav"]
           .indexOf(ext) !== -1 ? ext : "mp3"
}

// One episode's identity in the positions map.
function episodeKey(guid, url) {
    return (guid && guid !== "") ? guid : (url || "")
}

// A string wrapped as ONE safe POSIX single-quoted shell word. The whole
// value lives inside single quotes, and each embedded single quote is
// closed, an escaped quote is emitted, and quoting reopens — the classic
// '\'' idiom. Written as a JS literal the escaped quote is "'\\''" (FOUR
// visible chars): a plain "'\''" collapses to ''' at runtime and lets a
// feed-supplied URL break out of its quoting — the exact command-
// injection this function exists to make impossible. Every shell word
// built from untrusted input (feed URLs, titles, paths) goes through here.
function shQuote(s) {
    return "'" + String(s === undefined || s === null ? "" : s)
                 .replace(/'/g, "'\\''") + "'"
}

// The resume map, kept honest: entries are {sec, dur, at}; the newest
// `cap` survive. Returns a NEW map — the caller owns persistence.
function prunePositions(map, cap) {
    var keys = Object.keys(map || {})
    if (keys.length <= cap) return map || {}
    keys.sort(function(a, b) { return (map[b].at || 0) - (map[a].at || 0) })
    var out = {}
    for (var i = 0; i < cap; i++) out[keys[i]] = map[keys[i]]
    return out
}

// m:ss under an hour, h:mm:ss over it — the seek row's clock.
function fmtTime(sec) {
    var s = Math.max(0, Math.round(sec))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
    var mm = (m < 10 ? "0" : "") + m, rr = (r < 10 ? "0" : "") + r
    return h > 0 ? h + ":" + mm + ":" + rr : m + ":" + rr
}
