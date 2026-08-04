/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The string a station broadcasts as "what's playing" and the string a
// search service can answer are rarely the same string. What arrives is
// dressed: "NOW PLAYING:" prefixes, "| Station" tails, ad stars, bitrate
// tags, playlist numbering. Everything here undresses it — pure string
// functions, no engine state, shared by the art lookup, the downloader
// and the liked-track key.
.pragma library

// Fast local title cleanup for search queries: bracketed asides and
// bitrate tags out, whitespace folded. Always available — the optional
// AI cleanup falls back to this.
function cleanQueryLocal(s) {
    return (s || "")
        .replace(/\s*\([^)]*\)\s*/g, " ")
        .replace(/\s*\[[^\]]*\]\s*/g, " ")
        .replace(/\b\d{2,3}\s?kbps\b/gi, " ")
        .replace(/\s+/g, " ").trim();
}

// The broadcast dressing radio stations wrap around a track name —
// measured live: "NOW PLAYING: ABBA - Dancing Queen" and
// "ABBA - Dancing Queen | Elmar" both return EMPTY from Deezer
// while the undressed string finds the cover. This also fixes the
// negative-cache key: a dressed query's definitive "no cover"
// used to pin the track coverless for the whole TTL.
function normalizeQuery(s) {
    return (s || "").replace(/^\s*(now\s+playing|playing\s+now|np)\s*[:\-–]\s*/i, "")
                    .replace(/^\s*\d{1,3}[\.\)]\s+/, "")
                    .replace(/\*{2,}/g, " ")
                    .replace(/\s*\|.*$/, "")
                    .replace(/\s*\([^)]*\)\s*/g, " ")
                    .replace(/\s*\[[^\]]*\]\s*/g, " ")
                    .replace(/\b\d{2,3}\s?kbps\b/gi, " ")
                    .replace(/\s+/g, " ").trim();
}

// Undress the RAW track string before the artist/title split: the
// same broadcast prefixes and tails, plus the third dash segment —
// Estonian stations love "Artist - Title - Station", and the station
// name poisons every search it rides into. The segment split takes the
// whole padded-dash family, same as the artist/title split below: this
// used to be ASCII " - " only, which let an en-dash station ride its
// name straight into the title.
function preCleanTrack(s) {
    var t = (s || "").replace(/^\s*(now\s+playing|playing\s+now|np)\s*[:\-–]\s*/i, "")
                     .replace(/^\s*\d{1,3}[\.\)]\s+/, "")
                     .replace(/\*{2,}/g, " ")
                     .replace(/\s*\|.*$/, "")
                     .trim();
    var parts = t.split(/\s+[-–—]\s+/);
    if (parts.length >= 3) t = parts[0] + " - " + parts[1];
    return t;
}

// Stations separate artist and title with more than the ASCII " - ":
// en-dash, em-dash and slash (all space-padded) are just as common.
// Only the FIRST separator splits — the rest belongs to the title.
// The surrounding spaces are required: a bare "-" would break
// hyphenated names like "Jay-Z".
function parseTrackString(s) {
    if (!s) return { artist: "", title: "" };
    var m = s.match(/\s+[-–—\/]\s+/);
    if (m) {
        return { artist: s.substring(0, m.index).trim(),
                 title: s.substring(m.index + m[0].length).trim() };
    }
    return { artist: "", title: s.trim() };
}

// The first-billed name alone — collaboration glue ("feat.", "&", "vs")
// derails an artist search more often than it narrows one.
function primaryArtist(artist) {
    if (!artist) return "";
    var s = artist;
    var splitters = [" & ", " feat. ", " feat ", " ft. ", " ft ", " with ", " vs. ", " vs ", ", ", " and ", " x ", " X "];
    for (var i = 0; i < splitters.length; i++) {
        var idx = s.toLowerCase().indexOf(splitters[i].toLowerCase());
        if (idx > 0) {
            s = s.substring(0, idx);
            break;
        }
    }
    return s.trim();
}
