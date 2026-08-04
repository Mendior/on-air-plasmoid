/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What a stream URL can tell without touching the network: its host, the
// registrable domain behind that host, the container format the path
// implies, and — given a radio-browser answer — whether a safer, better
// mount of the same station exists. Pure functions; the XHR plumbing and
// caches stay with the engine.
.pragma library

function hostOf(url) {
    // Strip userinfo and keep IPv6 brackets whole — "user@host" or
    // "[::1]:8000" would otherwise yield the wrong host.
    const m = String(url).match(/^https?:\/\/(?:[^\/?#@]*@)?(\[[^\]]*\]|[^\/:?#]+)/i);
    return m ? m[1].toLowerCase() : "";
}

function baseDomain(domain) {
    if (!domain) return "";
    // An IP literal has no registrable "base" — exact match only.
    if (domain.charAt(0) === "[" || /^\d+(\.\d+){3}$/.test(domain)) return domain;
    const parts = domain.split(".");
    if (parts.length <= 2) return domain;
    // ccSLD heuristic (no bundled public-suffix list): under a
    // "co.uk"-style pair the registrable name is THREE labels — two
    // would make every *.co.uk host look like the same station.
    const n = /(^|\.)(co|com|net|org|gov|edu|ac|or|ne|go)\.[a-z]{2}$/.test(parts.slice(-2).join(".")) ? 3 : 2;
    return parts.slice(-n).join(".");
}

// strict: extension-only verdict, used by the RECORDER's container
// choice — a substring guess ("mp3" somewhere in the path) written with
// -c copy into .mp3 produces a broken file when the codec is anything
// else; "unknown" routes to mka, which holds any codec. Playback
// heuristics (canRecordUrl, auto-bitrate) keep the fuzzy match, where
// a wrong guess costs nothing.
function streamFormat(url, strict) {
    const lower = String(url).toLowerCase();
    const noQuery = lower.split("?")[0];
    if (noQuery.endsWith(".m3u8")) return "hls";
    if (noQuery.endsWith(".m3u")) return "playlist";
    if (noQuery.endsWith(".pls")) return "playlist";
    if (noQuery.endsWith(".aac") || noQuery.endsWith(".aacp")) return "aac";
    if (noQuery.endsWith(".ogg")) return "ogg";
    if (noQuery.endsWith(".opus")) return "opus";
    if (noQuery.endsWith(".flac")) return "flac";
    if (noQuery.endsWith(".mp3")) return "mp3";
    if (strict) return "unknown";
    if (noQuery.indexOf("aacp") !== -1 || noQuery.indexOf("aac") !== -1) return "aac";
    if (noQuery.indexOf("mp3") !== -1) return "mp3";
    return "unknown";
}

// radio-browser reports bitrate sometimes in kbps, sometimes in bps.
function _bitrateOf(r) {
    let br = parseInt(r.bitrate) || 0;
    if (br >= 8000) br = Math.round(br / 1000);
    return br;
}

// Given a radio-browser search answer, the station's display name and the
// URL already playing, pick the best safe upgrade — or hand the original
// back. Every refusal in here is load-bearing; the tests hold the full
// list of reasons not to switch.
function pickBitrateUpgrade(results, stationName, origUrl) {
    const nameLower = (stationName || "").replace(/\s+/g, " ").trim().toLowerCase();
    const orig = (origUrl || "").toString();
    const origBase = baseDomain(hostOf(orig));
    const origFmt = streamFormat(orig);
    const origUrlNoProto = orig.replace(/^https?:\/\//i, "").replace(/\/$/, "").toLowerCase();

    // First pass: find the user's exact URL in the results so we
    // know its reported bitrate. Without this floor, the first
    // same-bitrate candidate would be picked as a false "upgrade".
    let origBr = 0;
    let foundOrig = false;
    for (const r of results) {
        const rn = (r.name || "").replace(/\s+/g, " ").trim().toLowerCase();
        if (rn !== nameLower) continue;
        const u = (r.url_resolved || r.url || "").toString();
        if (!u) continue;
        const uNoProto = u.replace(/^https?:\/\//i, "").replace(/\/$/, "").toLowerCase();
        if (uNoProto !== origUrlNoProto) continue;
        origBr = _bitrateOf(r);
        foundOrig = true;
        break;
    }
    // If we can't find the user's URL in radio-browser we can't
    // judge "higher bitrate" safely — skip the upgrade entirely.
    // Same when its reported bitrate is 0: that is the
    // directory's "unknown", not a floor, and treating it as
    // one let any low-rate sibling replace an unreported
    // main mount as an "upgrade". No baseline, no switch.
    if (!foundOrig || origBr === 0) return orig;

    // Second pass: pick the candidate with the highest bitrate
    // that's STRICTLY greater than what the user already has.
    let bestBr = origBr;
    let bestUrl = orig;
    for (const r of results) {
        const rn = (r.name || "").replace(/\s+/g, " ").trim().toLowerCase();
        if (rn !== nameLower) continue;
        const url = (r.url_resolved || r.url || "").toString();
        if (!url) continue;
        if (baseDomain(hostOf(url)) !== origBase) continue;
        const urlFmt = streamFormat(url);
        // Reject playlist wrappers — Qt may follow them but our
        // ICY reader cannot, and HLS support differs by backend.
        if (urlFmt === "playlist" || urlFmt === "hls") continue;
        // Don't silently switch codecs (mp3→aac etc).
        if (origFmt !== "unknown" && urlFmt !== "unknown"
            && origFmt !== urlFmt) continue;
        const br = _bitrateOf(r);
        if (br <= 0 || br > 2000) continue;
        if (br > bestBr) {
            bestBr = br;
            bestUrl = url;
        }
    }
    return bestUrl;
}
