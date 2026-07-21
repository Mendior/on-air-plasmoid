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

// ── show notes ─────────────────────────────────────────────────────────
// Episode notes arrive as untrusted HTML (content:encoded / description).
// This turns them into ONE plain string that is safe to put in a
// PlainText Label — tags stripped, entities decoded, whitespace collapsed,
// length capped. The URL inside an <a href> is inlined as "text (url)" so
// links survive the strip and can be pulled back out; nothing here ever
// produces markup for a rich-text sink.
function notesToPlain(html, cap) {
    var lim = cap > 0 ? cap : 4000
    var s = String(html || "")
    // <a href="U">T</a> -> "T (U)" (or just "U" when the text IS the url).
    // The inner match is BOUNDED (not a greedy scan to end): an unclosed
    // <a> in a multi-megabyte notes block would otherwise scan quadratically
    // and freeze the UI — the bound keeps this linear whatever the feed
    // sends, without blindly truncating the note (which cut real text when
    // a huge leading tag, e.g. a data-URI image, straddled a byte cap).
    s = s.replace(/<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]{0,4000}?)<\/a>/gi,
        function(_, url, text) {
            var t = text.replace(/<[^>]+>/g, "").trim()
            var u = url.trim()
            if (t === "" || t === u) return " " + u + " "
            return " " + t + " (" + u + ") "
        })
    s = s.replace(/<(br|p|div|li|tr|h[1-6])\b[^>]*>/gi, "\n")  // block breaks
    s = s.replace(/<[^>]+>/g, "")                              // every other tag
    s = decodeEntities(s)
    s = s.replace(/[ \t\f\v]+/g, " ").replace(/\s*\n\s*/g, "\n")
         .replace(/\n{3,}/g, "\n\n").trim()
    if (s.length > lim) s = s.substring(0, lim).trim() + "…"
    return s
}

// The http(s) links inside plain notes, de-duplicated, order preserved.
// Trailing sentence punctuation is trimmed; the caller still gates each
// through HostGuard before opening. Capped so a link-farm note can't
// spawn a thousand rows.
function extractLinks(plain) {
    var re = /https?:\/\/[^\s<>()"']+/gi
    var seen = {}, out = [], m
    while ((m = re.exec(String(plain || ""))) !== null && out.length < 40) {
        var u = m[0].replace(/[.,;:!?)]+$/, "")
        if (!seen[u]) { seen[u] = true; out.push(u) }
    }
    return out
}

// The HH:MM:SS / MM:SS timestamps in plain notes, as {label, sec} for
// tap-to-seek. Only sensible times survive: minutes/seconds < 60, and a
// bare "M:SS" needs the colon so a price like "5:00" in prose is at least
// shaped like a time (podcasts write chapter marks this way). De-duped,
// capped, sorted by position of appearance.
function extractTimestamps(plain) {
    var re = /\b(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\b/g
    var seen = {}, out = [], m
    var s = String(plain || "")
    while ((m = re.exec(s)) !== null && out.length < 200) {
        var h = m[1] === undefined ? 0 : parseInt(m[1], 10)
        var mi = parseInt(m[2], 10)
        var se = parseInt(m[3], 10)
        if (se >= 60) continue
        if (m[1] !== undefined && mi >= 60) continue
        var sec = h * 3600 + mi * 60 + se
        if (seen[sec]) continue
        seen[sec] = true
        out.push({ label: m[0], sec: sec })
    }
    return out
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
    // The show's own artwork: the itunes:image href, else the plain RSS
    // <image><url>. This is fallback art for episodes carrying none, and the
    // ONLY art a hand-typed feed URL brings (no iTunes row stands behind it).
    // Gated by the same http(s)-and-not-private rule as every fetched URL.
    // Entity-decoded like the enclosure URL — a legal XML href carries
    // &amp; where the fetched address needs a bare &.
    var chImg = /<itunes:image\b[^>]*>/i.exec(head)
    var showImg = chImg ? decodeEntities(_attr(chImg[0], "href")).trim() : ""
    if (showImg === "") {
        var rssImg = /<image\b[^>]*>([\s\S]*?)<\/image>/i.exec(head)
        if (rssImg) showImg = _cleanText(_tagBody(rssImg[1], "url"))
    }
    out.image = urlAllowed(showImg) ? showImg : ""
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
        // Notes: prefer the richer content:encoded, else description, else
        // the itunes summary — all untrusted HTML, sanitized to plain here.
        var rawNotes = _tagBody(item, "content:encoded")
        if (rawNotes === "") rawNotes = _tagBody(item, "description")
        if (rawNotes === "") rawNotes = _tagBody(item, "itunes:summary")
        // Per-episode artwork: the itunes:image href (a self-closing tag,
        // so read the attribute off the tag itself), kept only if it passes
        // the same http(s)-and-not-private gate as every other fetched URL.
        var imgTag = /<itunes:image\b[^>]*>/i.exec(item)
        var img = imgTag ? decodeEntities(_attr(imgTag[0], "href")).trim() : ""
        // No i18n here — a .pragma library has no QML context; an
        // untitled episode ships as "" and the delegate names it.
        out.episodes.push({
            title: title,
            url: url,
            guid: guid !== "" ? guid : url,
            pubMs: isNaN(when) ? 0 : when,
            durationSec: parseDuration(_tagBody(item, "itunes:duration")),
            sizeBytes: parseInt(_attr(encTag[0], "length"), 10) || 0,
            notes: notesToPlain(stripCdata(rawNotes), 4000),
            image: urlAllowed(img) ? img : ""
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
    // Null-tolerant reads: the map comes from a persisted config a hand
    // edit can corrupt, and one {"key": null} entry must not throw the
    // whole save away.
    keys.sort(function(a, b) {
        return (((map[b] || {}).at || 0)) - (((map[a] || {}).at || 0))
    })
    var out = {}
    for (var i = 0; i < cap; i++) out[keys[i]] = map[keys[i]]
    return out
}

// The playback speeds the chip cycles through. 1x always present.
var SPEEDS = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

// A safe playback rate. The backend misbehaves outside a sane band and a
// hand-edited config must not hand it a wild value; 0 or negative would
// freeze or reverse. Clamped to [0.5, 3.0], NaN falls back to 1.0.
function clampRate(r) {
    var n = Number(r)
    if (!isFinite(n) || n <= 0) return 1.0
    return Math.max(0.5, Math.min(3.0, n))
}

// The next speed in the ring after `cur` (wraps). Snaps an off-list rate
// to the nearest listed one first, so cycling always lands on a clean step.
function nextRate(cur) {
    var c = clampRate(cur)
    var best = 0, bestD = Infinity
    for (var i = 0; i < SPEEDS.length; i++) {
        var d = Math.abs(SPEEDS[i] - c)
        if (d < bestD) { bestD = d; best = i }
    }
    // On an exact match advance; otherwise jump to the nearest step first.
    if (bestD < 0.001) return SPEEDS[(best + 1) % SPEEDS.length]
    return SPEEDS[best]
}

// A rate reads as "1x" / "1.5x" / "0.8x" — trailing zeros trimmed.
function fmtRate(r) {
    var n = clampRate(r)
    var s = (Math.round(n * 100) / 100).toString()
    return s + "x"
}

// Where a ±N-second skip lands, clamped inside the media. All in ms; a
// skip past either end parks at that end rather than erroring.
function skipTarget(posMs, deltaSec, durMs) {
    var t = (Number(posMs) || 0) + (Number(deltaSec) || 0) * 1000
    var d = Number(durMs) || 0
    if (t < 0) return 0
    if (d > 0 && t > d) return d
    return t
}

// A byte count as "12 MB" / "340 KB" / "1.2 GB" — the enclosure size on
// the meta line so a download's cost is visible before the tap. 0 (a feed
// that omitted length) reads as "".
function fmtSize(bytes) {
    var b = Number(bytes) || 0
    if (b <= 0) return ""
    if (b < 1024) return b + " B"
    var kb = b / 1024
    if (kb < 1024) return Math.round(kb) + " KB"
    var mb = kb / 1024
    if (mb < 1024) return (mb < 10 ? Math.round(mb * 10) / 10 : Math.round(mb)) + " MB"
    return (Math.round(mb / 1024 * 10) / 10) + " GB"
}

// m:ss under an hour, h:mm:ss over it — the seek row's clock.
function fmtTime(sec) {
    var s = Math.max(0, Math.round(sec))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
    var mm = (m < 10 ? "0" : "") + m, rr = (r < 10 ? "0" : "") + r
    return h > 0 ? h + ":" + mm + ":" + rr : m + ":" + rr
}

// ── The podcatcher's housekeeping brains — pure, tested ─────────────────

// ffmpeg silencedetect output → [[startSec, endSec], …]. Only closed pairs
// (a start with its end), only stretches at least minLen long, capped at
// 300 — a corrupt log must not balloon the ledger. Input is UNTRUSTED
// process output: everything non-matching is ignored.
function parseSilences(text, minLen) {
    var lo = (minLen > 0 ? minLen : 0.9)
    var out = []
    var start = -1
    var re = /silence_(start|end): ([0-9.]+)/g
    var m
    while ((m = re.exec(String(text || ""))) !== null && out.length < 300) {
        var t = parseFloat(m[2])
        if (!isFinite(t) || t < 0) continue
        if (m[1] === "start") {
            start = t
        } else if (start >= 0) {
            if (t - start >= lo) out.push([start, t])
            start = -1
        }
    }
    return out
}

// The silence interval the position sits INSIDE (with entry/exit pads so a
// seek never lands back in the same stretch), or null. Linear is fine: the
// list is capped and playback asks a few times a second.
function silenceAt(silences, posSec, pad) {
    var p = (pad > 0 ? pad : 0.25)
    var arr = silences || []
    for (var i = 0; i < arr.length; i++) {
        var s = arr[i]
        if (!s || s.length < 2) continue
        if (posSec >= s[0] + p && posSec < s[1] - p) return s
    }
    return null
}

// The next episode continuous play should start when one ends: same show,
// downloaded, unplayed, not the one that just finished — oldest first, so
// a serial plays forward. Returns the ledger FILENAME or "".
function nextUnplayed(ledger, feed, playedMap, exceptKey) {
    var best = "", bestAt = Infinity
    for (var f in (ledger || {})) {
        var e = ledger[f]
        if (!e || e.feed !== feed || !e.key || e.key === exceptKey) continue
        if (playedMap && playedMap[e.key] !== undefined) continue
        var at = Number(e.at) || 0
        if (at < bestAt) { bestAt = at; best = f }
    }
    return best
}

// The episode a podcast ALARM wakes with: newest unplayed download of the
// show; when everything is heard, the newest download at all — a re-listen
// beats a chime. "" only when nothing of the show is on disk.
function newestForAlarm(ledger, feed, playedMap) {
    var bestUnplayed = "", bestUnplayedAt = -1
    var bestAny = "", bestAnyAt = -1
    for (var f in (ledger || {})) {
        var e = ledger[f]
        if (!e || e.feed !== feed) continue
        var at = Number(e.at) || 0
        if (at > bestAnyAt) { bestAnyAt = at; bestAny = f }
        if (e.key && (!playedMap || playedMap[e.key] === undefined)
            && at > bestUnplayedAt) { bestUnplayedAt = at; bestUnplayed = f }
    }
    return bestUnplayed !== "" ? bestUnplayed : bestAny
}

// Storage auto-care: which downloaded files may be deleted. Two rules,
// both deliberately timid: a PLAYED episode older than maxAgeDays goes;
// past keepPerShow files in one show, the oldest PLAYED ones go. An
// unplayed download is never touched — a binge queued for a flight must
// survive every cleanup.
function cleanCandidates(ledger, playedMap, nowMs, keepPerShow, maxAgeDays) {
    var keep = keepPerShow > 0 ? keepPerShow : 10
    var maxAge = (maxAgeDays > 0 ? maxAgeDays : 3) * 24 * 3600 * 1000
    // The newest file of every show is untouchable, played or not: the
    // podcast alarm's "everything heard -> the newest plays again" promise
    // rests on it, and a weekly show would otherwise have NOTHING on disk
    // by Thursday for a Friday alarm.
    var newestOf = {}
    for (var nf in (ledger || {})) {
        var ne = ledger[nf]
        if (!ne) continue
        var nshow = ne.feed || ""
        if (newestOf[nshow] === undefined
            || (Number(ne.at) || 0) > (Number(ledger[newestOf[nshow]].at) || 0))
            newestOf[nshow] = nf
    }
    var byShow = {}
    var out = []
    for (var f in (ledger || {})) {
        var e = ledger[f]
        if (!e) continue
        if (newestOf[e.feed || ""] === f) continue
        var played = !!(e.key && playedMap && playedMap[e.key] !== undefined)
        if (played && (Number(e.at) || 0) < nowMs - maxAge) { out.push(f); continue }
        var show = e.feed || ""
        if (!byShow[show]) byShow[show] = []
        byShow[show].push({ f: f, at: Number(e.at) || 0, played: played })
    }
    for (var s in byShow) {
        var rows = byShow[s]
        if (rows.length <= keep) continue
        rows.sort(function(a, b) { return b.at - a.at })   // newest first
        for (var i = keep; i < rows.length; i++)
            if (rows[i].played) out.push(rows[i].f)
    }
    return out
}

// One canonical key per feed ADDRESS: scheme dropped (http and https twins
// are the same show), host lowercased, default ports and trailing slashes
// shed. Directories disagree about all three; the dedupe must not.
function feedKey(url) {
    var u = String(url || "").trim()
    var m = /^https?:\/\/([^\/?#]+)([^?#]*)/i.exec(u)
    if (!m) return u.toLowerCase()
    var host = m[1].toLowerCase().replace(/:(80|443)$/, "")
    var path = (m[2] || "").replace(/\/+$/, "")
    return host + path
}
