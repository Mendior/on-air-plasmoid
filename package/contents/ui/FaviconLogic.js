/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Pure logic for station logos: the one http(s)-or-empty gate every road
// that persists a favicon must pass, the rule for whose logo a name search
// may lend a saved station (the runtime backfill and the settings page both
// ask it), how a homepage names its icons, and the monogram (initials +
// deterministic hue) that stands in when no logo can be obtained at all.
// No QML types, no I/O — everything here runs under qmltestrunner
// (tests/qml/).
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

// ── What a station's homepage says about its logo ───────────────────────
// The settings page's logo ladder reads a homepage and probes what it
// finds; the pure half of that lives here so the reading can be tested.

// "https://host:port" of an http(s) URL, "" for anything else.
function originOf(url) {
    const m = String(url).match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] : "";
}

// A link from a page made absolute against the page's own address; ""
// for fragments, data: and javascript: links, and when the page address
// itself has no origin.
function resolveUrl(href, baseUrl) {
    if (!href)
        return "";
    href = String(href).trim();
    if (href === "" || href.charAt(0) === "#" || href.indexOf("data:") === 0
        || href.indexOf("javascript:") === 0)
        return "";
    if (href.indexOf("//") === 0)
        return "https:" + href;
    if (/^https?:\/\//i.test(href))
        return href;
    const origin = originOf(baseUrl);
    if (origin === "")
        return "";
    if (href.charAt(0) === "/")
        return origin + href;
    // relative path - resolve against base URL directory
    const baseNoQuery = baseUrl.split("?")[0].split("#")[0];
    const lastSlash = baseNoQuery.lastIndexOf("/");
    const baseDir = lastSlash > 8 ? baseNoQuery.substring(0, lastSlash + 1) : (origin + "/");
    return baseDir + href;
}

// The longest tag the icon reader looks into; a longer one is passed over.
var MAX_TAG = 2048;

// The value of one attribute of a tag.
// Contract: tagAttr(attrs, name) reads attrs, the text between a tag's name
// and its ">", one attribute after another and gives the value of the first
// one called name, letter case aside: "" when it has no value, null when
// the tag has no such attribute. A name counts only where an attribute
// starts, so data-href is not href and "href=" inside another value is no
// attribute. Reading stops at the first thing that cannot start an
// attribute, a value whose quote never closes among them. Text that is no
// string has no attributes.
function tagAttr(attrs, name) {
    var want = "", m = null;
    if (typeof attrs !== "string" || typeof name !== "string" || name === "") return null;
    want = name.toLowerCase();
    // One step is what stands before the first attribute, or one attribute
    // (a name, then a value in either quote or bare, if it has one) with
    // what stands after it, or one character that is neither. A step
    // always starts where the last one ended, so nothing is searched for
    // and a tag of MAX_TAG characters is read once. A bare value does not
    // open with a quote: one that never closes leaves its attribute empty
    // and ends the reading at the quote.
    var step = /([\s\/]+)|([^\s=\/>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"'][^\s>]*))?)?[\s\/]*|[\s\S]/g;
    for (m = step.exec(attrs); m !== null; m = step.exec(attrs)) {
        if (m[1] !== undefined) continue;
        if (m[2] === undefined) return null;
        if (m[2].toLowerCase() === want) return m[3] || m[4] || m[5] || "";
    }
    return null;
}

// An attribute value with its ampersands as a browser reads them: "&amp;"
// (and "&AMP;"), "&#38;" and "&#x26;" with any zeros before the digits each
// become "&", once, so "&amp;amp;" is "&amp;". Every other reference is
// left as written. Contract: a string; "" for what is no string.
function ampDecoded(s) {
    return typeof s === "string" ? s.replace(/&(?:amp|AMP|#0*38|#[xX]0*26);/g, "&") : "";
}

// Every <link> whose rel names an icon, then every og:image, resolved and
// without repeats, in page order, as {url, kind} candidates for
// probeOrder: "page" for an icon link, "share" for an og:image.
// Safari's mask-icon is left out: it is one flat colour on transparency
// that the browser tints itself, and as a logo it is a black shape.
function extractIconLinks(html, baseUrl) {
    const icons = [], shares = [];
    const seen = {};
    if (!html)
        return [];
    // An address is resolved as a browser would have it: "?x=1&amp;y=2"
    // saved as written asked the host for a parameter called "amp;y".
    const keep = function(list, href, kind) {
        const resolved = resolveUrl(ampDecoded(href), baseUrl);
        if (resolved !== "" && !seen[resolved]) {
            seen[resolved] = true;
            list.push({ url: resolved, kind: kind });
        }
    };
    // One tag at a time, never past the next "<" and never longer than
    // MAX_TAG: the page comes from a record anyone can file, and the popup
    // reads it with no click. The old patterns ran two lazy runs per tag
    // over a head of "<meta/name='og:image'" with no ">" for 139 s on Qt
    // 6.12 (measured 2026-11-03), and the shell froze with them.
    const tagRe = new RegExp("<(link|meta)\\b([^<>]{0," + MAX_TAG + "})>", "gi");
    let m;
    while ((m = tagRe.exec(html)) !== null) {
        const attrs = m[2].replace(/\/\s*$/, "");
        if (m[1].toLowerCase() === "meta") {
            const prop = tagAttr(attrs, "property") || tagAttr(attrs, "name") || "";
            const content = tagAttr(attrs, "content");
            if (prop.toLowerCase() === "og:image" && content)
                keep(shares, content, "share");
            continue;
        }
        const rel = (tagAttr(attrs, "rel") || "").toLowerCase();
        const isIcon = rel.indexOf("icon") !== -1 || rel.indexOf("apple-touch") !== -1
                    || rel.indexOf("shortcut") !== -1 || rel.indexOf("fluid-icon") !== -1;
        if (!isIcon || rel.indexOf("mask-icon") !== -1)
            continue;
        const href = tagAttr(attrs, "href");
        if (href)
            keep(icons, href, "page");
    }
    return icons.concat(shares);
}

// Whether the settings page saves the best picture a hunt found. Re-fetch
// all asks the row's own logo first (kind "current"), so a find that is
// that very logo changes nothing, and any other find beat it or found it
// dead: a 16 px favicon or a banner used to replace a 1024 px logo the
// listener set, and a tab-sized find a dead one. An upgrade, a row whose
// logo is tab-sized, looks only for something larger.
// Contract: false for no find and for the row's own logo (current); for an
// upgrade, false for a tab-sized find too.
function keepsFind(best, current, upgrade) {
    if (!best || webUrlOrEmpty(best.url) === "") return false;
    if (webUrlOrEmpty(current) !== "" && best.url === current) return false;
    return !(upgrade === true && logoRank(best.url, best.size) === 4);
}

// The services a directory names as a station's homepage when the station
// has only a page there. The page's icons are the service's own. Measured on
// tunein.com/radio/EROTICA-LOUNGE-s260655/: TuneIn's 180 px apple-touch-icon
// was asked second and saved, and the station's og:image stood fourth.
// The stream hosts' list knows only where streams are rented, so of all
// these it held none.
// Only TuneIn was measured. The last eight are here by kind alone, a
// profile on a social service or a page in a radio catalogue, where the
// icon is never the tenant's. Other site builders (wordpress.com and the
// like) are left out: an owner often sets the icon there.
var HOMEPAGE_PLATFORMS = {
    "facebook.com": true, "instagram.com": true, "tunein.com": true,
    "radio.net": true, "onlineradiobox.com": true, "streema.com": true,
    "mytuner-radio.com": true, "mixcloud.com": true, "wixsite.com": true,
    "weebly.com": true, "blogspot.com": true, "sites.google.com": true,
    "twitter.com": true, "x.com": true, "youtube.com": true, "tiktok.com": true,
    "vk.com": true, "soundcloud.com": true, "linktr.ee": true, "radio.de": true
};

// Whether a homepage is a landlord's page: a station's page on a service
// from HOMEPAGE_PLATFORMS, or on a host that rents streams to many
// (HealLogic.sharedBase: zeno.fm, laut.fm).
// Contract: true only for a web address whose host is such a name or lies
// under one, whole labels compared: myradio.net is not radio.net, and
// maps.google.com is not sites.google.com.
function landlordPage(u) {
    // webUrlOrEmpty reads a list holding one address as that address.
    if (typeof u !== "string") return false;
    var host = StreamLogic.hostOf(webUrlOrEmpty(u));
    if (host === "") return false;
    if (HealLogic.sharedBase(StreamLogic.baseDomain(host))) return true;
    var labels = host.split(".");
    for (var i = 0; i < labels.length; i++)
        if (HOMEPAGE_PLATFORMS[labels.slice(i).join(".")] === true) return true;
    return false;
}

// What a homepage offers to look at for a station's logo: what the page
// names (extractIconLinks) and the well-known paths on its origin. A
// landlord's page names the landlord's own icons and keeps them at those
// paths, and only its og:image is the station's: laut.fm/mangoradio named
// laut.fm's 180 px apple-touch-icon and had the station's picture as
// og:image (measured 2026-11-03).
// Contract: images, then the guesses; on a landlord's page only the images
// of kind "share". images that is not a list counts as none.
function homepageCandidates(images, homepage) {
    var home = webUrlOrEmpty(homepage);
    var list = Array.isArray(images) ? images : [];
    if (landlordPage(home))
        return list.filter(function(c) { return c !== null && typeof c === "object" && c.kind === "share"; });
    return list.concat(wellKnownIcons(originOf(home)));
}

// The paths sites keep icons at without naming them, on one origin, as
// "guess" candidates. No origin, no guesses.
function wellKnownIcons(origin) {
    var out = [];
    if (origin) {
        out.push(
            origin + "/apple-touch-icon.png",
            origin + "/apple-touch-icon-precomposed.png",
            origin + "/favicon-194x194.png",
            origin + "/favicon-192x192.png",
            origin + "/favicon-96x96.png",
            origin + "/favicon-32x32.png",
            origin + "/favicon.ico"
        );
    }
    return out.map(function(u) { return { url: u, kind: "guess" }; });
}

// Whether a reply's first bytes are a picture: PNG, JPEG, GIF, ICO/CUR,
// BMP, WebP or SVG. The first five are known by their opening bytes. A
// bitmap and an SVG open with plain text ("BM", "<"), so they are asked
// for more: an XHTML error page, an RSS feed, a page with a drawing in its
// body and a sentence starting "BM" all passed here once, and the hunt
// saved them as logos.
function looksLikeImageBytes(buf) {
    if (!buf || buf.length < 4)
        return false;
    // PNG: 89 50 4E 47
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47)
        return true;
    // JPEG: FF D8 FF
    if (buf[0] === 0xFF && buf[1] === 0xD8 && buf[2] === 0xFF)
        return true;
    // GIF: 47 49 46 38
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38)
        return true;
    // ICO: 00 00 01 00 (icon) or 00 00 02 00 (cursor)
    if (buf[0] === 0x00 && buf[1] === 0x00 && (buf[2] === 0x01 || buf[2] === 0x02) && buf[3] === 0x00)
        return true;
    // BMP: 42 4D, then a header whose fields agree
    if (buf[0] === 0x42 && buf[1] === 0x4D)
        return _bmpHeader(buf);
    // WebP: RIFF....WEBP
    if (buf.length >= 12
        && buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46
        && buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50)
        return true;
    // SVG: '<', and the document's root element is svg
    if (buf[0] === 0x3C)
        return _svgRoot(buf);
    return false;
}

// How much of a reply is read for an SVG's root element. What drawing
// programs write before it (a declaration, a generator comment, a doctype
// with its entities) is a few hundred bytes.
var SVG_HEAD = 4096;

// Whether an XML document's root element is svg: declarations and other
// processing instructions, comments and one doctype are passed over, with
// white space between them, and the next thing has to be "<svg" ended by
// white space, ">" or "/", all of it inside the first SVG_HEAD bytes.
// Every construct is passed over once by a plain search for its end, so a
// reply made of half a megabyte of openings costs one look at that head.
// A doctype's own declarations end at its first "]". A reply this reads
// wrongly is refused, never taken.
function _svgRoot(b) {
    var n = Math.min(b.length, SVG_HEAD), s = "", i = 0, end = 0, sub = 0, c = 0, doctypes = 0;
    for (i = 0; i < n; i++) s += String.fromCharCode(b[i]);
    i = 0;
    while (i < n) {
        c = s.charCodeAt(i);
        if (c === 0x20 || c === 0x09 || c === 0x0A || c === 0x0D) {
            i++;
        } else if (s.substr(i, 4) === "<!--") {
            end = s.indexOf("-->", i + 4);
            if (end === -1) return false;
            i = end + 3;
        } else if (s.substr(i, 2) === "<?") {
            end = s.indexOf("?>", i + 2);
            if (end === -1) return false;
            i = end + 2;
        } else if (s.substr(i, 9) === "<!DOCTYPE") {
            if (++doctypes > 1) return false;
            end = s.indexOf(">", i + 9);
            sub = s.indexOf("[", i + 9);
            if (sub !== -1 && sub < end) {
                end = s.indexOf("]", sub + 1);
                if (end !== -1) end = s.indexOf(">", end + 1);
            }
            if (end === -1) return false;
            i = end + 1;
        } else {
            c = s.charCodeAt(i + 4);
            return s.substr(i, 4) === "<svg"
                && (c === 0x3E || c === 0x2F || c === 0x20 || c === 0x09 || c === 0x0A || c === 0x0D);
        }
    }
    return false;
}

// Whether the bytes open a Windows or OS/2 bitmap: "BM", both reserved
// words zero, a header length the format has, the pixels placed after the
// headers, one plane, a bit depth the format has, a width above zero and a
// height that is not zero (below zero means the rows run top down). Text
// cannot pass: the reserved words are four zero bytes.
function _bmpHeader(b) {
    var pixels = 0, dib = 0, w = 0, h = 0, planes = 0, bpp = 0;
    if (!(b.length >= 26) || b[0] !== 0x42 || b[1] !== 0x4D) return false;
    if (b[6] !== 0 || b[7] !== 0 || b[8] !== 0 || b[9] !== 0) return false;
    pixels = _le32(b, 10);
    dib = _le32(b, 14);
    if (pixels < 14 + dib) return false;
    if (dib === 12) {
        w = b[18] + b[19] * 256;
        h = b[20] + b[21] * 256;
        planes = b[22] + b[23] * 256;
        bpp = b[24] + b[25] * 256;
    } else if (dib === 40 || dib === 52 || dib === 56 || dib === 64 || dib === 108 || dib === 124) {
        if (b.length < 30) return false;
        w = _le32(b, 18);
        h = _le32(b, 22);
        planes = b[26] + b[27] * 256;
        bpp = b[28] + b[29] * 256;
        // Signed in the file: a width with its top bit set is below zero.
        if (w >= 0x80000000) return false;
    } else {
        return false;
    }
    return planes === 1 && w > 0 && h !== 0
        && (bpp === 1 || bpp === 4 || bpp === 8 || bpp === 16 || bpp === 24 || bpp === 32);
}

// What the logo hunt makes of one reply.
// Contract: { image, size }. image says whether a logo may be made of the
// bytes, size is imageSize(buf) when it may and null when not. When the
// listener asked for the hunt (strict is not true) every picture
// looksLikeImageBytes knows will do. When nobody clicked (strict is true)
// the picture must also say its size, or be an SVG or a bitmap, the two
// formats imageSize does not read. Bytes that are no list give
// { image: false, size: null }.
function logoVerdict(buf, strict) {
    var size = null;
    if (!looksLikeImageBytes(buf)) return { image: false, size: null };
    size = imageSize(buf);
    // looksLikeImageBytes has vouched for the bytes, so "<" is an SVG and
    // "BM" a bitmap, each held to a check as tight as a size.
    if (strict === true && size === null && buf[0] !== 0x3C && !(buf[0] === 0x42 && buf[1] === 0x4D))
        return { image: false, size: null };
    return { image: true, size: size };
}

// The pixel size a picture's own header declares, { width, height }, or
// null when the bytes are none of the formats below or stop before the
// size. Nothing is decoded, only the header is read.
//   PNG   the IHDR chunk, which the format puts first.
//   GIF   the logical screen.
//   ICO   the FIRST entry of the directory (a 0 byte means 256), because
//         that is the one Qt paints: an icon holding 16 and 256 px
//         entries, 16 first, came out 16 px wide with sourceSize 64 and
//         with sourceSize 256 (Qt 6.12, measured 2026-11-02).
//   JPEG  the first SOF marker, found by walking the segments by their
//         lengths, so the thumbnail an EXIF block carries is never taken
//         for the picture. Raadio Kadi's 1200x1200 logo is progressive:
//         SOF2 at byte 213, behind JFIF, Ducky, Adobe and DQT segments.
//         EXIF orientation is not read, a turned picture keeps its shorter
//         side and its shape.
//   WebP  the VP8 (lossy), VP8L (lossless) and VP8X (extended) headers.
// BMP, SVG and anything else answer null.
function imageSize(buf) {
    var b = buf, chunk = "";
    if (!b || !(b.length >= 10)) return null;
    if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) {
        if (b.length < 24 || _tag(b, 12) !== "IHDR") return null;
        return _size(_be32(b, 16), _be32(b, 20));
    }
    if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38)
        return _size(b[6] + b[7] * 256, b[8] + b[9] * 256);
    if (b[0] === 0 && b[1] === 0 && (b[2] === 1 || b[2] === 2) && b[3] === 0) {
        if (b.length < 22 || b[4] + b[5] * 256 < 1) return null;
        return _size(b[6] || 256, b[7] || 256);
    }
    if (b[0] === 0xFF && b[1] === 0xD8) return _jpegSize(b);
    if (b.length >= 16 && _tag(b, 0) === "RIFF" && _tag(b, 8) === "WEBP") {
        chunk = _tag(b, 12);
        if (chunk === "VP8 ") {
            if (b.length < 30 || b[23] !== 0x9D || b[24] !== 0x01 || b[25] !== 0x2A) return null;
            return _size((b[26] + b[27] * 256) & 0x3FFF, (b[28] + b[29] * 256) & 0x3FFF);
        }
        if (chunk === "VP8L") {
            if (b.length < 25 || b[20] !== 0x2F) return null;
            return _size(1 + (b[21] | ((b[22] & 0x3F) << 8)),
                         1 + ((b[22] >> 6) | (b[23] << 2) | ((b[24] & 0x0F) << 10)));
        }
        if (chunk === "VP8X") {
            if (b.length < 30) return null;
            return _size(1 + b[24] + b[25] * 256 + b[26] * 65536, 1 + b[27] + b[28] * 256 + b[29] * 65536);
        }
    }
    return null;
}

function _tag(b, i) {
    return String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);
}

function _be16(b, i) {
    return b[i] * 256 + b[i + 1];
}

// Multiplied, not shifted: a shift works in 32-bit signed integers and
// turns a width with its top bit set into a negative number.
function _be32(b, i) {
    return ((b[i] * 256 + b[i + 1]) * 256 + b[i + 2]) * 256 + b[i + 3];
}

function _le32(b, i) {
    return ((b[i + 3] * 256 + b[i + 2]) * 256 + b[i + 1]) * 256 + b[i];
}

function _size(w, h) {
    return (w > 0 && h > 0) ? { width: w, height: h } : null;
}

// Segment by segment from the start of the file. Every segment but the
// few bare markers says how long it is, and its payload is skipped
// unread: an APP1 holding an EXIF thumbnail holds a frame header too.
function _jpegSize(b) {
    var i = 2, m = 0, len = 0;
    while (i + 3 < b.length) {
        if (b[i] !== 0xFF) return null;
        m = b[i + 1];
        if (m === 0xFF) {
            i += 1;                      // fill byte before the marker
        } else if (m === 0xD8 || m === 0x01 || (m >= 0xD0 && m <= 0xD7)) {
            i += 2;                      // markers with no length
        } else if (m === 0xD9 || m === 0xDA) {
            return null;                 // the image ended, or its scan began, with no frame header
        } else {
            len = _be16(b, i + 2);
            if (len < 2) return null;
            // C4, C8 and CC share the range and are tables, not frames.
            if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC)
                return (i + 8 < b.length) ? _size(_be16(b, i + 7), _be16(b, i + 5)) : null;
            i += 2 + len;
        }
    }
    return null;
}

// A logo source that is small by construction: bare /favicon.ico, an
// explicit 16/32-pixel variant, or the Google s2 service (64 px). Worth
// one upgrade attempt when the user asks for logos — a 16 px icon
// upscaled into the popup's cover panel reads as "broken logo".
function tinyLogoUrl(u) {
    return /(?:^|\/)favicon\.ico(?:$|\?)|favicon-(?:16|32)x(?:16|32)|google\.com\/s2\/favicons/i
           .test(String(u || ""));
}

// ── Which picture a logo hunt keeps ─────────────────────────────────────
// Sizes are the shorter side in pixels, as imageSize reads it.
//
// LARGE_SIDE 96: half again the 64 px every station row decodes its logo
// at (MediaListItem sourceSize), so a large logo is never upscaled in the
// list. The vinyl centre (256) and the cover panel (600) still upscale it.
// TINY_SIDE 32: the sizes browser tabs use, 16 to 32. A row upscales them
// two to four times; Raadio Kadi's favicon.ico is one of them, 16 px.
// Square enough: the longer side at most 5/4 of the shorter. Both views
// crop a logo to a square (PreserveAspectCrop), and at 5:4 the crop keeps
// 80% of the picture's width, where a 1200x630 sharing banner keeps 52%.
var LARGE_SIDE = 96;
var TINY_SIDE = 32;

// How a probed picture would do as the station's logo, 0 best:
//   0  square enough and LARGE_SIDE or more
//   1  square enough, between the two sides
//   2  no size to read (an SVG paints at any size; a header nobody knows)
//   3  any other shape over TINY_SIDE, a sharing banner
//   4  tiny: TINY_SIDE or less whatever the shape (a 1x10000 strip too),
//      a tiny-class address whose size is unknown, and Google's icon
//      service whatever it answers, the old ladder's last resort and
//      somebody else's copy of the icon
// A bare favicon.ico with a known size is judged by the picture Qt paints.
function logoRank(url, size) {
    var side = 0, edge = 0;
    if (/google\.com\/s2\/favicons/i.test(String(url || ""))) return 4;
    if (!size) return tinyLogoUrl(url) ? 4 : 2;
    side = Math.min(size.width, size.height);
    edge = Math.max(size.width, size.height);
    if (side <= TINY_SIDE) return 4;
    if (4 * edge > 5 * side) return 3;
    return side >= LARGE_SIDE ? 0 : 1;
}

// The best of the pictures a hunt found, {url, size} entries in the order
// they were asked: the lowest rank, then the longer shorter side, then the
// first asked. null when nothing was found.
function bestLogo(found) {
    var best = null, bestRank = 5, bestSide = -1, rank = 0, side = 0;
    for (var i = 0; found && i < found.length; i++) {
        if (!found[i]) continue;
        rank = logoRank(found[i].url, found[i].size);
        side = found[i].size ? Math.min(found[i].size.width, found[i].size.height) : 0;
        if (rank < bestRank || (rank === bestRank && side > bestSide)) {
            best = found[i];
            bestRank = rank;
            bestSide = side;
        }
    }
    return best;
}

// The addresses a hunt asks, in the order it asks them, each once.
// Candidates are {url, kind}: "page" for a link the page names as its icon
// (or the directory's own logo field), "share" for its og:image, "guess"
// for a well-known path on the homepage nobody declared and for Google's
// icon service, "host" for one on the stream's own server.
//   1. what the page names, unless tiny by its address: that is the logo
//   2. a guessed /apple-touch-icon.png, the path iOS asks for unasked
//   3. the og:image, often the logo (Kadi's is) but sometimes a photo,
//      which is why the station's own icons go first
//   4. the other guesses on the homepage
//   5. the stream host's paths, after everything the homepage offers:
//      Kadi streams from a CDN, and a CDN's icon is the CDN's
//   6. everything tiny by its address
//   7. Google's icon service
function probeOrder(candidates) {
    var lanes = [[], [], [], [], [], [], [], []], seen = {}, out = [], c = null, u = "", lane = 0;
    for (var i = 0; candidates && i < candidates.length; i++) {
        c = candidates[i];
        if (!c || typeof c.url !== "string" || c.url === "") continue;
        u = c.url;
        // The logo the row already has goes first, whatever its address, so
        // it is weighed against every find and kept on a tie.
        if (c.kind === "current") { lanes[0].push(u); continue; }
        if (/google\.com\/s2\/favicons/i.test(u)) lane = 7;
        else if (tinyLogoUrl(u)) lane = 6;
        else if (c.kind === "page") lane = 1;
        else if (c.kind === "share") lane = 3;
        else if (c.kind === "host") lane = 5;
        else if (/\/apple-touch-icon\.png$/i.test(u)) lane = 2;
        else lane = 4;
        lanes[lane].push(u);
    }
    for (var l = 0; l < lanes.length; l++) {
        for (var k = 0; k < lanes[l].length; k++) {
            if (seen[lanes[l][k]]) continue;
            seen[lanes[l][k]] = true;
            out.push(lanes[l][k]);
        }
    }
    return out;
}

// Whether a hunt has asked enough. It stops at the first large square:
// the order puts what the station names first, and a large picture there
// is the logo. Otherwise it asks at most PROBE_CAP addresses once a real
// picture is in hand: Kadi's logo is the second address asked (behind
// one 404), and six leaves room for a page's own icons and the guess
// behind them. With nothing real yet it goes on to PROBE_LIMIT, as the
// old ladder went on to its end: a station whose only icon is the bare
// /favicon.ico has it seventh in the popup's list, behind five guessed
// paths and favicon-32x32.png. A page naming forty dead icons gets twelve
// requests, not forty.
var PROBE_CAP = 6;
var PROBE_LIMIT = 12;

function huntSettled(found, asked) {
    var n = found ? found.length : 0;
    for (var i = 0; i < n; i++)
        if (found[i] && logoRank(found[i].url, found[i].size) === 0) return true;
    return asked >= PROBE_LIMIT || (asked >= PROBE_CAP && n > 0);
}

// The homepage a name search may lend a saved station to look for a logo
// on: the first public one among the same donorRows that may lend it a
// logo, so a namesake's page is never read for it.
function pickHomepage(rows, wantNorm, normFn, savedUrl, asked) {
    var from = donorRows(rows, wantNorm, normFn, savedUrl, asked), home = "";
    for (var i = 0; i < from.length; i++) {
        home = webUrlOrEmpty((from[i] || {}).homepage);
        if (home !== "") return home;
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
