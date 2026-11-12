// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// MusicLinks: the addresses of the artist searches, and who counts as an
// artist. Nothing here opens or asks for an address.
import QtQuick
import QtTest

import "../../package/contents/ui/MusicLinks.js" as ML

TestCase {
    name: "MusicLinks"

    readonly property string lastfm: "https://www.last.fm/search/artists?q="
    readonly property string discogs: "https://www.discogs.com/search/?type=artist&q="

    function test_a_name_goes_into_the_address_as_one_value_data() {
        return [
            { tag: "Björk", who: "Björk", q: "Bj%C3%B6rk" },
            { tag: "AC/DC", who: "AC/DC", q: "AC%2FDC" },
            { tag: "Earth, Wind & Fire", who: "Earth, Wind & Fire", q: "Earth%2C%20Wind%20%26%20Fire" },
            { tag: "A+B", who: "A+B", q: "A%2BB" },
            { tag: "a percent sign", who: "100% Pure", q: "100%25%20Pure" },
            { tag: "a percent escape of its own", who: "A%20B%2F..", q: "A%2520B%252F.." },
            { tag: "double quotes", who: "\"Weird Al\" Yankovic", q: "%22Weird%20Al%22%20Yankovic" },
            { tag: "an apostrophe", who: "Guns N' Roses", q: "Guns%20N%27%20Roses" },
            { tag: "brackets, a star and a bang", who: "P!nk (*live*)", q: "P%21nk%20%28%2Alive%2A%29" },
            { tag: "what ends a query", who: "Who? #1 & x=y;z", q: "Who%3F%20%231%20%26%20x%3Dy%3Bz" },
            { tag: "a second address", who: "x&q=evil https://evil.example/", q: "x%26q%3Devil%20https%3A%2F%2Fevil.example%2F" },
            { tag: "a shell's favourites", who: "a`b$(c)|d>e\\f", q: "a%60b%24%28c%29%7Cd%3Ee%5Cf" },
            { tag: "Cyrillic", who: "Кино", q: "%D0%9A%D0%B8%D0%BD%D0%BE" },
            { tag: "a whole emoji", who: "🎵 Live", q: "%F0%9F%8E%B5%20Live" },
            { tag: "a lone high half", who: "Bj\uD83Dörk", q: "Bj%C3%B6rk" },
            { tag: "a lone low half", who: "\uDE00Low", q: "Low" },
            { tag: "a half at the very end", who: "Moby\uD83C", q: "Moby" },
            { tag: "line breaks, a tab and a NUL", who: "A\nB\tC\u0000D\r\nE", q: "A%20B%20C%20D%20E" },
            { tag: "spaces all round", who: "   Daft   Punk  ", q: "Daft%20Punk" },
            { tag: "a direction mark", who: "\u202eknup tfaD", q: "knup%20tfaD" }
        ];
    }
    function test_a_name_goes_into_the_address_as_one_value(data) {
        compare(ML.lastfm(data.who), lastfm + data.q);
        compare(ML.discogs(data.who), discogs + data.q);
    }

    function test_no_name_is_no_address_data() {
        return [
            { tag: "empty", who: "" },
            { tag: "spaces", who: "   \t\n " },
            { tag: "only what is dropped", who: "\uD83D\u202e\u0000" },
            { tag: "null", who: null },
            { tag: "undefined", who: undefined },
            { tag: "a number", who: 42 },
            { tag: "a list", who: ["Björk"] },
            { tag: "an object", who: { artist: "Björk" } },
            { tag: "true", who: true }
        ];
    }
    function test_no_name_is_no_address(data) {
        compare(ML.lastfm(data.who), "");
        compare(ML.discogs(data.who), "");
        compare(ML.name(data.who), "");
        compare(ML.artist(data.who, "Radio"), "");
    }

    function test_a_very_long_name_is_cut_and_never_through_a_pair() {
        var huge = new Array(5001).join("a");
        compare(ML.name(huge).length, 200);
        compare(ML.lastfm(huge), lastfm + new Array(201).join("a"));
        // The 200th unit is the first half of an emoji: the whole emoji goes.
        var split = new Array(200).join("a") + "🎵" + "tail";
        compare(ML.name(split), new Array(200).join("a"));
        compare(ML.discogs(split), discogs + new Array(200).join("a"));
        // The emoji fits to the unit.
        var fits = new Array(199).join("a") + "🎵" + "tail";
        compare(ML.name(fits), new Array(199).join("a") + "🎵");
        // A cut that lands behind a space leaves no space at the end.
        var spaced = new Array(200).join("a") + " b";
        compare(ML.name(spaced), new Array(200).join("a"));
        compare(ML.name(new Array(201).join("a")), new Array(201).join("a"));
    }

    // Whatever the name, the value holds only what RFC 3986 calls unreserved
    // and percent escapes, the address starts with the fixed text, and the
    // value read back is the name.
    function test_six_hundred_names_keep_the_address_whole() {
        var seed = 20261111;
        function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; }
        var pool = ["a", "Z", "9", " ", "&", "=", "?", "#", "%", "+", "/", "\\", "\"", "'", "<", ">", "`", "$", ";", ":", "@", "!",
                    "(", ")", "*", "~", ".", "-", "_", "ö", "Ж", "中", "🎵", "\uD83D", "\uDE00", "\n", "\u0000", "\u202e"];
        for (var n = 0; n < 600; n++) {
            var who = "";
            for (var k = rnd(40); k >= 0; k--) who += pool[rnd(pool.length)];
            var shown = ML.name(who);
            var urls = [[ML.lastfm(who), lastfm], [ML.discogs(who), discogs]];
            for (var u = 0; u < urls.length; u++) {
                if (shown === "") { compare(urls[u][0], ""); continue; }
                compare(urls[u][0].indexOf(urls[u][1]), 0);
                var value = urls[u][0].substring(urls[u][1].length);
                verify(/^(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+$/.test(value), "value " + n + ": " + value);
                compare(decodeURIComponent(value), shown);
            }
        }
    }

    function test_a_station_is_not_an_artist_data() {
        return [
            { tag: "an artist", artist: "Björk", station: "Raadio 2", want: "Björk" },
            { tag: "the station's own name", artist: "Kiss FM", station: "Kiss FM", want: "" },
            { tag: "its name as the stream spells it", artist: "DANCE  WAVE", station: "Dance Wave!", want: "" },
            { tag: "its name without the directory's tail", artist: "Chillout", station: "Chillout - Main Mix", want: "" },
            { tag: "a web address", artist: "www.station.example", station: "Any", want: "" },
            { tag: "a song that starts like the station", artist: "Radio Ga Ga", station: "Radio", want: "Radio Ga Ga" },
            { tag: "no station known", artist: "Kiss FM", station: "", want: "Kiss FM" },
            { tag: "a station that is no text", artist: "Björk", station: null, want: "Björk" },
            { tag: "the name tidied", artist: "  Earth,\tWind & Fire ", station: "Soul", want: "Earth, Wind & Fire" },
            { tag: "nobody", artist: "", station: "Kiss FM", want: "" }
        ];
    }
    function test_a_station_is_not_an_artist(data) {
        compare(ML.artist(data.artist, data.station), data.want);
    }
}
