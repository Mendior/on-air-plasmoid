/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Where the listener can read about the artist on air: a search for the
// name on Last.fm and on Discogs. The addresses are only built here. They
// are opened in the listener's browser, by the listener's click, and the
// widget asks neither site for anything.
//
// The host and the path are fixed text and the name goes in as one query
// value, so nothing a stream writes into its title can change where the
// link leads. Pure functions.
.pragma library
.import "TrackLogic.js" as TrackLogic

// No artist's name is this long; a title line can be 4080 bytes, and that
// much in an address is more than some servers read.
var MAX_NAME = 200;

// The name as it is searched for and shown.
// Contract: control characters count as spaces, direction marks and a lone
// half of a surrogate pair are dropped (encodeURIComponent throws on a lone
// half), runs of white space become one space and the ends are trimmed. At
// most MAX_NAME UTF-16 units, never cut through a pair. "" for what is no
// text or holds nothing.
function name(artist) {
    if (typeof artist !== "string") return "";
    var out = "";
    for (var i = 0; i < artist.length; i++) {
        var c = artist.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF) {
            var d = i + 1 < artist.length ? artist.charCodeAt(i + 1) : 0;
            if (d >= 0xDC00 && d <= 0xDFFF) { out += artist.substr(i, 2); i++; }
            continue;
        }
        if (c >= 0xDC00 && c <= 0xDFFF) continue;
        out += (c < 0x20 || (c >= 0x7F && c <= 0x9F)) ? " " : artist.charAt(i);
    }
    out = out.replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "").replace(/\s+/g, " ").trim();
    if (out.length <= MAX_NAME) return out;
    var last = out.charCodeAt(MAX_NAME - 1);
    return out.substring(0, last >= 0xD800 && last <= 0xDBFF ? MAX_NAME - 1 : MAX_NAME).trim();
}

// The artist a link is offered for.
// trackArtist: what the title line parsed to. station: the station's name.
// Contract: name(trackArtist); "" when that is the station talking about
// itself (its own name, a web address: TrackLogic.stationTalk). A station
// is not an artist, and a search for "Kiss FM" among artists is a wrong
// answer with a friendly face.
function artist(trackArtist, station) {
    var who = name(trackArtist);
    return who !== "" && TrackLogic.stationTalk(who, typeof station === "string" ? station : "") ? "" : who;
}

// The name as one query value. encodeURIComponent leaves ! ' ( ) * as they
// are; they go out escaped too, so the value holds letters, digits, - _ . ~
// and escapes, and nothing a shell or a careless handler could read.
function _value(who) {
    return encodeURIComponent(who).replace(/[!'()*]/g, function(ch) {
        return "%" + ch.charCodeAt(0).toString(16).toUpperCase();
    });
}

// Contract: the address of a Last.fm artist search for name(artist); "" when
// there is no name to search for.
function lastfm(artist) {
    var who = name(artist);
    return who === "" ? "" : "https://www.last.fm/search/artists?q=" + _value(who);
}

// Contract: the address of a Discogs artist search for name(artist); "" when
// there is no name to search for.
function discogs(artist) {
    var who = name(artist);
    return who === "" ? "" : "https://www.discogs.com/search/?type=artist&q=" + _value(who);
}
