/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// OPML in and out — the universal podcast-subscription exchange format, so
// On Air is a real podcatcher you can migrate into and out of, not a walled
// garden. Pure string work, under qmltestrunner. An imported OPML is
// untrusted like any feed: this parser never throws and returns only
// {title, feedUrl} pairs; the caller still gates every feedUrl through
// HostGuard before subscribing.
.pragma library
.import "PodcastLogic.js" as PodcastLogic

// One value, XML-attribute-safe: the five characters that must not appear
// raw inside a double-quoted attribute.
function _xmlAttr(s) {
    return String(s === undefined || s === null ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;").replace(/'/g, "&apos;")
}

// Build an OPML 2.0 document from [{title, feedUrl}]. Entries without a
// feed URL are skipped — an outline with no xmlUrl is a folder, not a sub.
function buildOpml(subs) {
    var lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="2.0">',
        '  <head>',
        '    <title>On Air podcast subscriptions</title>',
        '  </head>',
        '  <body>'
    ]
    for (var i = 0; i < (subs || []).length; i++) {
        var s = subs[i] || {}
        if (!s.feedUrl) continue
        var t = _xmlAttr(s.title || s.feedUrl)
        lines.push('    <outline text="' + t + '" title="' + t
                   + '" type="rss" xmlUrl="' + _xmlAttr(s.feedUrl) + '"/>')
    }
    lines.push('  </body>')
    lines.push('</opml>')
    return lines.join("\n") + "\n"
}

// Parse an OPML document to [{title, feedUrl}]. Nested folders are flattened
// (every outline that carries an xmlUrl is a subscription, wherever it
// sits); duplicates by feed URL collapse to the first. Never throws — a
// non-OPML file returns []. Title falls back to text, then to the URL.
function parseOpml(xml) {
    var text = String(xml || "")
    var out = [], seen = {}
    var re = /<outline\b[^>]*>/gi
    var m
    while ((m = re.exec(text)) !== null && out.length < 1000) {
        var tag = m[0]
        var xu = _attr(tag, "xmlUrl")
        if (xu === "") continue
        var url = PodcastLogic.decodeEntities(xu).trim()
        if (url === "" || seen[url]) continue
        seen[url] = true
        var title = PodcastLogic.decodeEntities(
            _attr(tag, "title") || _attr(tag, "text")).trim()
        out.push({ title: title !== "" ? title : url, feedUrl: url })
    }
    return out
}

// One attribute out of a single tag's text, either quote style.
function _attr(tagText, name) {
    var m = new RegExp(name + "\\s*=\\s*\"([^\"]*)\"", "i").exec(tagText)
    if (m) return m[1]
    m = new RegExp(name + "\\s*=\\s*'([^']*)'", "i").exec(tagText)
    return m ? m[1] : ""
}
