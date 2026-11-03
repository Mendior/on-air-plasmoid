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
//
// The four walmradio stations in the default list send "Title by Artist -
// <tagline>" instead, and read as it stands the artist was "Chattanooga Choo
// Choo by Ray Conniff" and the title the tagline: 0 of their 16 songs on the
// bench found a cover (2026-11-02). Two segments whose second one is nothing
// but a short tagline ending in a bare domain, and whose first names the
// artist after its last " by ", come back as "Artist - Title". A www.
// address stays where it is, because stationTalk reads that as the station
// talking, and a line that does not split at " by " stays as it came.
// Contract: preCleanTrack("Chattanooga Choo Choo by Ray Conniff - Classic
//   Vinyl on walmradio.com") = "Ray Conniff - Chattanooga Choo Choo";
//   "Walk On By by Dionne Warwick - walmradio.com" = "Dionne Warwick - Walk
//   On By"; "Radio Swiss Classic - www.radioswissclassic.ch" and "Stand by
//   Me" come back unchanged.
//
// Virgin Radio Classic Rock sends its database record instead of a title:
// "Walk Of Life~Dire Straits~~1985~ISRC~225~<start>~<end>~station~…". The
// whole record became the title and 4 of 4 songs got no cover after three
// requests each. A record of that shape, title and artist both present and
// timestamps in the seventh and eighth fields, reads as "Artist - Title".
// The station's own ident leaves the artist field empty, and a "~" that is
// only part of a title fails the timestamp check, so both stay as they came.
// Contract: preCleanTrack("Walk Of Life~Dire Straits~~1985~~225~
//   2026-11-02T17:05:05~2026-11-02T17:05:07~Virgin Radio Classic Rock~…")
//   = "Dire Straits - Walk Of Life";
//   "Virgin Radio Classic Rock~~~~~14~<start>~<end>~…" comes back unchanged.
//
// station is the saved name of what is playing, and only a line of three or
// more segments looks at it. Kaaosradio opens every title with its own name
// and channel, "Kaaosradio 24h - Fuji Kureta - Rope", so the cut above kept
// "Kaaosradio 24h" as the artist and none of its 11 recorded songs found a
// cover. A first segment that is the station goes: equal to its name or to
// the part before a padded dash, or starting with its first two words when
// those make eight letters or more and the segment goes on past them. That
// last condition keeps "Elvis Presley - Suspicious Minds - 1969" on "Elvis
// Presley Radio" an Elvis song. In all three the segment must also read as
// a station, with a word that is or ends in
// "radio", "raadio" or "fm", or the word "24h" or "24/7". Without that, a
// station named after an artist lost the artist: on "Bob Marley Radio",
// "Bob Marley & The Wailers - One Love - Exodus" read as "Exodus" by "One
// Love", and on "Queen - Greatest Hits" Queen went the same way. Two
// segments are never cut, because "Metallica - Enter Sandman" on "Metallica
// Radio" is a song.
// Contract: preCleanTrack("Kaaosradio 24h - Fuji Kureta - Rope",
//   "Kaaosradio - 24h Chill") = "Fuji Kureta - Rope"; with no station, or
//   "", it is "Kaaosradio 24h - Fuji Kureta" as before;
//   preCleanTrack("Bob Marley & The Wailers - One Love - Exodus", "Bob Marley
//   Radio") = "Bob Marley & The Wailers - One Love".
function preCleanTrack(s, station) {
    return _preClean(s, station).text;
}

// One pass for preCleanTrack and stationDropped, so the cover lookup and the
// parse can never disagree about whether the station's name was cut.
function _preClean(s, station) {
    var t = (s || "").replace(/^\s*(now\s+playing|playing\s+now|np)\s*[:\-–]\s*/i, "")
                     .replace(/^\s*\d{1,3}[\.\)]\s+/, "")
                     .replace(/\*{2,}/g, " ")
                     .replace(/\s*\|.*$/, "")
                     .trim();
    var tf = t.split("~");
    if (tf.length >= 8 && tf[0].trim() !== "" && tf[1].trim() !== ""
        && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$/.test(tf[6])
        && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$/.test(tf[7]))
        t = tf[1].trim() + " - " + tf[0].trim();
    var parts = t.split(/\s+[-–—]\s+/);
    var dropped = parts.length >= 3 && _namesStation(parts[0], station);
    if (dropped) parts = parts.slice(1);
    if (parts.length >= 3 || dropped) t = parts[0] + " - " + parts[1];
    else if (parts.length === 2 && _TAGLINE.test(parts[1])) t = _byArtist(parts[0]) || t;
    return { text: t, dropped: dropped };
}

// Whether a leading segment is the station's own name (the rule is spelled
// out above preCleanTrack). An empty name on either side never matches.
function _namesStation(seg, station) {
    var name = normalizeQuery(station);
    var a = _bare(normalizeQuery(seg));
    var b = _bare(name);
    if (a === "" || b === "" || !_stationWord(seg)) return false;
    var head = name.split(/\s+[-–—]\s+/)[0];
    if (a === b || a === _bare(head)) return true;
    var words = head.split(/\s+/).filter(function(w) { return _bare(w) !== ""; });
    var prefix = _bare(words.slice(0, 2).join(" "));
    return prefix.length >= 8 && a.length > prefix.length && a.indexOf(prefix) === 0;
}

// Whether a segment carries a word only a station's name has: one that is or
// ends in "radio", "raadio" or "fm" (Kiss FM, Kaaosradio, Vikerraadio,
// 181.fm), or "24h" or "24/7". The end of the word and nowhere else, or
// Radiohead and Wolfmother would be stations.
// Contract: _stationWord("Kaaosradio 24h") = true; _stationWord("Bob Marley &
//   The Wailers") = false; _stationWord("Radiohead") = false.
function _stationWord(seg) {
    return normalizeQuery(seg).split(/\s+/).some(function(word) {
        var w = _bare(word);
        return /(?:radio|raadio|fm)$/.test(w) || w === "24h" || w === "247";
    });
}

// True when preCleanTrack took the station's name off the front of this line.
// The cover lookup asks before it trusts the artist found behind the name
// with a photo: on Kaaosradio two of the four photos that artist brought
// were somebody else's (a metal album, a skate-punk band), where a sleeve
// has to carry the artist's own records.
// Contract: stationDropped("Kaaosradio 24h - Fuji Kureta - Rope",
//   "Kaaosradio - 24h Chill") = true; the same line with station "" = false;
//   "Fuji Kureta - Rope" on that station = false.
function stationDropped(s, station) {
    return _preClean(s, station).dropped;
}

// Up to four words, an optional "on", a bare domain: "Classic Vinyl on
// walmradio.com", "walmradio.com". No www., no brackets, nothing after it.
var _TAGLINE = /^(?:[^\s{}()\[\]]+\s+){0,4}(?:on\s+)?[a-z0-9-]+\.(?:com|net|org|fm|online|radio|live|ee|fi|de|uk|ru|eu|ch|it|nl|se|no|pl)$/i;

// "Title by Artist" as "Artist - Title", or "" when the segment does not
// read that way. The greedy first group splits at the last " by ", which
// keeps "Walk On By by Dionne Warwick" whole, and a padded slash already
// separates artist from title for parseTrackString, so that line is left be.
function _byArtist(seg) {
    if (/\s+[-–—\/]\s+/.test(seg)) return "";
    var m = seg.match(/^(.+) by (.+)$/i);
    if (!m) return "";
    var title = m[1].trim();
    var artist = m[2].trim();
    return title && artist ? artist + " - " + title : "";
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

// True when a "now playing" line is the station talking about itself rather
// than a record: its own name, or a web address.
// Contract: stationTalk("DANCE  WAVE", "Dance Wave!") = true;
//   stationTalk("Tracklist: https://x.online/", "Any") = true;
//   stationTalk("Radio Ga Ga", "Radio") = false; stationTalk("x", "") = false.
function stationTalk(line, station) {
    var s = line || "";
    if (/(?:\bhttps?:\/\/|\bwww\.)\S/i.test(s)) return true;
    var said = _bare(normalizeQuery(s));
    if (said === "") return false;
    // The directory's name wears tails the stream never says: "(EN)",
    // "| 320k", " - Main Mix". normalizeQuery takes the first two, the
    // split the third.
    var name = normalizeQuery(station);
    return said === _bare(name) || said === _bare(name.split(/\s+[-–—]\s+/)[0]);
}

// Letters and digits only, accents and case folded away. Everything else is
// punctuation that varies between the stream and the directory.
function _bare(s) {
    return (s || "").toLowerCase().normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "")
        .replace(/[\s!-\/:-@\[-`{-~\u00a1-\u00bf\u2010-\u205e]/g, "");
}

// Ten rows is a good half hour of real songs, and no station repeats a
// record inside that; a slogan comes back every few minutes at the most.
var HISTORY_LOOKBACK = 10;

// Whether a parsed title earns a row in the listening history. rows is the
// history newest first, anything with count and get(i) (the ListModel).
function historyTakes(rows, artist, title, station) {
    if (!title) return false;
    if (stationTalk((artist ? artist + " " : "") + title, station)) return false;
    var a = _bare(artist), t = _bare(title);
    var n = Math.min(rows.count, HISTORY_LOOKBACK);
    for (var i = 0; i < n; i++) {
        var r = rows.get(i);
        var here = (r.station || "") === (station || "");
        // The newest row counts whatever station it came from, which is how
        // the one-row check always read. Past it, only this station's rows
        // do, and the first row from somewhere else ends the look: back on
        // a station after a stop elsewhere, its song is being heard again.
        if (i > 0 && !here) break;
        if (_bare(r.artist) === a && _bare(r.trackName) === t) return false;
        if (!here) break;
    }
    return true;
}

// The name whose photo may stand in when no record matched: the whole
// credit, with only a feat./ft. tail cut. primaryArtist also cuts at "&",
// "and", ",", "x", "with" and "vs", and those sit inside band names: on
// 2026-11-02 "Love & Fate" searched as "Love" got the photo of a band
// called Love, and "Florence and the Machine" as "Florence" got "Florence &
// The Bare Souls".
// Contract: photoArtist("Love & Fate") = "Love & Fate";
//   photoArtist("Sia feat. Sean Paul & X") = "Sia";
//   photoArtist("A & B feat. C") = "A & B"; photoArtist(null) = "".
function photoArtist(artist) {
    var s = artist || "";
    var m = s.match(/\s+(?:feat\.?|ft\.?)\s+/i);
    return (m ? s.substring(0, m.index) : s).trim();
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
