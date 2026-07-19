/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The ONE answer to "may this URL's host be touched from here?" — shared
// by the search's automatic liveness probe (SearchLogic.js) and the
// settings pages' logo fetcher (configGeneral.qml), so a representation
// hole closed for one can never stay open in the other. Catalogue data is
// publicly writable: a crafted entry must not point a background GET at
// 127.0.0.1 or the LAN, and an address has more spellings than a dotted
// quad — Qt's URL layer resolves decimal ("2130706433"), octal
// ("0177.0.0.1"), hex ("0x7f.0.0.1") and shortened ("127.1") IPv4 forms,
// IPv6 has mapped/compat embeddings and zero-run spellings, and glibc
// resolves "localhost." (trailing root dot) to loopback. Literal
// addresses only: QML has no resolver, so a DNS name that resolves
// privately (rebinding) stays out of scope — every plain hostname passes.
.pragma library

// The lowercased host of a URL, brackets kept on an IPv6 literal.
// Userinfo is stripped up to the LAST "@" so "a@b@10.0.0.5" cannot hide
// the real host behind an earlier "@". No match (no scheme, no host)
// returns "" — callers treat that as "nothing safe to contact".
function hostOf(url) {
    var m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^\/?#]*@)?(\[[^\]]*\]|[^\/:?#]*)/i
            .exec(url || "");
    return m ? m[1].toLowerCase() : "";
}

// One inet_aton part: decimal, 0x-hex or leading-0 octal. -1 if not a
// number in any of the three dialects.
function _v4Part(s) {
    if (/^0x[0-9a-f]+$/.test(s)) return parseInt(s.slice(2), 16);
    if (/^0[0-7]*$/.test(s)) return parseInt(s || "0", 8);
    if (/^[1-9]\d*$/.test(s)) return parseInt(s, 10);
    return -1;
}

// The 32-bit address a numeric host actually connects to, or -1 for
// anything that is not inet_aton-valid. The grammar allows 1-4 parts and
// the LAST part swallows the remaining bytes — "127.1", "2130706433" and
// "0177.0.0.1" all reach loopback.
function v4Of(host) {
    if (host === "" || !/^[0-9a-fx.]+$/.test(host)) return -1;
    var parts = host.split(".");
    if (parts.length > 4) return -1;
    var nums = [];
    for (var i = 0; i < parts.length; i++) {
        var n = _v4Part(parts[i]);
        if (n < 0) return -1;
        nums.push(n);
    }
    var tailBytes = 5 - nums.length;            // bytes the last part fills
    var last = nums[nums.length - 1];
    if (last >= Math.pow(256, tailBytes)) return -1;
    var addr = 0;
    for (var j = 0; j < nums.length - 1; j++) {
        if (nums[j] > 255) return -1;
        addr = addr * 256 + nums[j];
    }
    return addr * Math.pow(256, tailBytes) + last;
}

// Private/loopback/link-local IPv4, by the integer address. 0/8 counts:
// Linux routes 0.0.0.0 (and inet_aton's bare "0") to loopback.
function _v4Private(a) {
    var b1 = Math.floor(a / 16777216) % 256;
    var b2 = Math.floor(a / 65536) % 256;
    if (b1 === 0 || b1 === 127 || b1 === 10) return true;
    if (b1 === 172 && b2 >= 16 && b2 <= 31) return true;
    if (b1 === 192 && b2 === 168) return true;
    if (b1 === 169 && b2 === 254) return true;
    return false;
}

// An IPv6 literal (brackets stripped) as its eight 16-bit groups, or null
// if it does not parse. Handles the "::" zero-run, a zone index
// ("fe80::1%eth0") and a trailing embedded dotted quad ("::ffff:10.0.0.5").
function _v6Groups(h6) {
    h6 = h6.split("%")[0];
    var dotted = /^(.*:)(\d{1,3}(?:\.\d{1,3}){3})$/.exec(h6);
    if (dotted) {
        var emb = v4Of(dotted[2]);
        if (emb < 0) return null;
        h6 = dotted[1] + Math.floor(emb / 65536).toString(16) + ":"
           + (emb % 65536).toString(16);
    }
    var dc = h6.indexOf("::");
    var head, tail;
    if (dc !== -1) {
        head = h6.slice(0, dc);
        tail = h6.slice(dc + 2);
        if (tail.indexOf("::") !== -1) return null;   // one zero-run only
    } else {
        head = h6;
        tail = "";
    }
    var hg = head === "" ? [] : head.split(":");
    var tg = tail === "" ? [] : tail.split(":");
    if (dc === -1 ? hg.length !== 8 : hg.length + tg.length > 7) return null;
    var all = hg.concat(new Array(8 - hg.length - tg.length).fill("0"), tg);
    var out = [];
    for (var i = 0; i < 8; i++) {
        if (!/^[0-9a-f]{1,4}$/.test(all[i])) return null;
        out.push(parseInt(all[i], 16));
    }
    return out;
}

// Whether a host (as returned by hostOf) targets the machine itself or
// the private/link-local space — in ANY spelling. An unparseable bracket
// literal counts as private: refusing a malformed address is the safe
// answer for both callers.
function isPrivateHost(host) {
    if (host === "") return true;
    if (host.charAt(host.length - 1) === ".")
        host = host.slice(0, -1);                 // DNS root dot: "localhost."
    if (host.charAt(0) === "[") {
        var g = _v6Groups(host.slice(1, -1));
        if (!g) return true;
        if (g[0] === 0 && g[1] === 0 && g[2] === 0 && g[3] === 0
            && g[4] === 0 && (g[5] === 0 || g[5] === 65535)) {
            // ::/96 (unspecified, loopback, v4-compatible) and v4-mapped
            // ::ffff:a.b.c.d — judge by the embedded IPv4. "::" and "::1"
            // land in _v4Private's 0/8 by construction.
            return _v4Private(g[6] * 65536 + g[7]);
        }
        if ((g[0] & 0xfe00) === 0xfc00) return true;   // fc00::/7 unique-local
        if ((g[0] & 0xffc0) === 0xfe80) return true;   // fe80::/10 link-local
        return false;
    }
    if (host === "localhost" || /\.localhost$/.test(host)) return true;
    var a = v4Of(host);
    return a >= 0 && _v4Private(a);
}
