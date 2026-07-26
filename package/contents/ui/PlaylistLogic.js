/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What a fetched .pls/.m3u body actually MEANS for playback. Pure string
// logic, no network — main.qml fetches, this file decides, qmltestrunner
// covers the decisions (real-world playlists are too creative to trust
// untested parsing: relative mounts, HLS media wearing a .m3u name,
// playlists pointing at playlists).
.pragma library

// Classify a playlist body against the address it was fetched from.
// Returns { kind, url }:
//   "hls"   — the body is HLS MEDIA (#EXTM3U + #EXT-X- tags): its entries
//             are SEGMENTS, not streams. Play the playlist url itself —
//             the FFmpeg backend speaks HLS natively, and "unwrapping" it
//             would loop the first few seconds of audio forever.
//   "entry" — url is the first stream entry, resolved to an absolute
//             address against the wrapper's own.
//   "none"  — nothing usable in the body: play the original url and let
//             the player report what it really is.
function classify(body, baseUrl) {
    var txt = (body || "");
    if (/^#EXTM3U/.test(txt.trim()) && txt.indexOf("#EXT-X-") !== -1)
        return { kind: "hls", url: baseUrl };
    var cand = "";
    var m = txt.match(/^File\d+\s*=\s*(\S+)/mi);
    if (m) {
        cand = m[1];
    } else {
        var lines = txt.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim();
            if (ln !== "" && ln.indexOf("#") !== 0) { cand = ln; break; }
        }
    }
    if (cand === "") return { kind: "none", url: baseUrl };
    var abs = resolveEntry(cand, baseUrl);
    if (!/^https?:\/\//i.test(abs)) return { kind: "none", url: baseUrl };
    return { kind: "entry", url: abs };
}

// A playlist entry against its wrapper's address, browser rules: absolute
// stays; //host inherits the wrapper's scheme; /path the wrapper's host;
// anything else the wrapper's directory. Relative entries are common on
// Icecast servers whose playlist generator only knows its own mounts.
function resolveEntry(entry, baseUrl) {
    if (/^https?:\/\//i.test(entry)) return entry;
    var schemeM = baseUrl.match(/^(https?):\/\//i);
    var hostM = baseUrl.match(/^https?:\/\/[^\/?#]+/i);
    if (!schemeM || !hostM) return entry;
    if (entry.indexOf("//") === 0) return schemeM[1] + ":" + entry;
    if (entry.indexOf("/") === 0) return hostM[0] + entry;
    var dir = baseUrl.replace(/[?#].*$/, "").replace(/[^\/]*$/, "");
    // A bare "http://host" strips to "http://" above — the host IS the dir.
    if (dir.length < hostM[0].length + 1) dir = hostM[0] + "/";
    return dir + entry;
}

// Does this address look like one MORE wrapper (a .pls whose entry is a
// .m3u)? .m3u8 is deliberately not a wrapper — that is HLS, a real format.
function isWrapper(url) {
    var low = (url || "").toLowerCase().split("?")[0];
    return low.indexOf(".pls", low.length - 4) !== -1
        || low.indexOf(".m3u", low.length - 4) !== -1;
}
