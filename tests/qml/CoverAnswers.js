// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// What Deezer and iTunes answered on 2026-11-12 for three lines Elmari
// tantsuõhtu 24/7 sent that morning, cut down to the fields the cover lookup
// reads and in the order the rows came. The addresses are the real ones,
// spelled with their common beginnings taken out. The artist's iTunes songs
// are thirteen of the fourteen rows; the one left out was another track of
// the shared album.
.pragma library

var APPLE = "https://is1-ssl.mzstatic.com/image/thumb/";
var DEEZER = "https://cdn-images.dzcdn.net/images/";

function _song(artist, title, art) {
    return { "artistName": artist, "trackName": title, "artworkUrl100": APPLE + art + "/100x100bb.jpg" };
}

// Nobody had a row for these three as artist and title together:
// "Alen Veziko Päiksepoolsel tänaval", "Star Sisters Waterloo" and, by free
// text, "Moon Taxi feat. Mari-Leen Rahutu tuhkatriinu".
var deezerNothing = { "data": [], "total": 0 };
var itunesNothing = { "resultCount": 0, "results": [] };

// iTunes, the songs filed under "Alen Veziko". The first row that is his
// alone comes after eight that are not, and it is another single.
var MATSON = "Music126/v4/ea/f9/e2/eaf9e23e-9bdb-631d-2797-b0ce7c0bd3c6/b290aa30-f566-4479-8333-7c87bbda4a31.jpg";
var ALEN_SINGLE = "Music221/v4/42/a7/e9/42a7e925-da48-1887-336d-de2ab66ba478/199811109382_cover.jpg";
var alenSongs = { "resultCount": 13, "results": [
    _song("Mia", "Miks Aeg Nii Kiirelt Käib (feat. Alen Veziko)",
          "Music4/v4/05/4d/df/054ddf70-f413-a19f-aac1-808dcf2c62e4/859712583048_cover.tif"),
    _song("Kristjan Matson & Alen Veziko", "Ainult Tänaseks Ööks (feat. Alen Veziko, Ingmar Päid & Andre Hein)", MATSON),
    _song("Daniele Guastella", "One Dream Away (feat. Alen Veziko)",
          "Music113/v4/e9/75/60/e975606f-8cb1-1045-54cd-03498b5d5248/cover.jpg"),
    _song("Kristjan Matson & Alen Veziko", "Vastu Müüri (feat. Alen Veziko, Ingmar Päid & Andre Hein)", MATSON),
    _song("Kristjan Matson, Alen Veziko & Ingmar Päid",
          "Aeg Meil Minna Üheskoos (feat. Alen Veziko, Ingmar Päid & Andre Hein)", MATSON),
    _song("Kristjan Matson & Alen Veziko", "Süütu Naer (feat. Andre Hein, Alen Veziko & Ingmar Päid)", MATSON),
    _song("Kristjan Matson & Alen Veziko", "Vala Veini (feat. Alen Veziko, Ingmar Päid & Andre Hein)", MATSON),
    _song("Kristjan Matson & Ingmar Päid", "Igatsus (feat. Ingmar Päid, Andre Hein & Alen Veziko)", MATSON),
    _song("Alen Veziko", "Nüüd taas sajab lund", ALEN_SINGLE),
    _song("Kristjan Matson & Ingmar Päid", "Südamest (feat. Ingmar Päid, Alen Veziko & Andre Hein)", MATSON),
    _song("Kristjan Matson, Alen Veziko & Ingmar Päid", "Talveöö (feat. Alen Veziko, Ingmar Päid & Andre Hein)", MATSON),
    _song("Kristjan Matson & Ingmar Päid", "Mööda Lumeveski Teed (feat. Ingmar Päid, Alen Veziko & Andre Hein)", MATSON),
    _song("Kristjan Matson & Andre Hein", "Haara Käest (feat. Ingmar Päid & Alen Veziko)", MATSON)
] };
// The sleeve of that other single, as the panel, the lock screen and a
// television all showed it under "Päiksepoolsel tänaval".
var alenOtherSingle = APPLE + ALEN_SINGLE + "/600x600bb.jpg";

// Deezer, track:"Rahutu tuhkatriinu".
var MARI_LEEN = "66c417c0edf1e9d8b8581f5a34d8dc55";
function _deezerSong(title, cover) {
    return { "title": title,
             "artist": { "name": "Mari-Leen", "picture_medium": DEEZER + "artist/" + MARI_LEEN + "/250x250-000000-80-0-0.jpg" },
             "album": { "cover_medium": DEEZER + "cover/" + cover + "/250x250-000000-80-0-0.jpg",
                        "cover_big": DEEZER + "cover/" + cover + "/500x500-000000-80-0-0.jpg" } };
}
var moonTrack = { "data": [
    _deezerSong("Rahutu tuhkatriinu", MARI_LEEN),
    _deezerSong("Rahutu Tuhkatriinu (Remix)", "384618c82496e2f3d391b54a0a6eb7cc")
], "total": 2 };
var moonCover = DEEZER + "cover/" + MARI_LEEN + "/500x500-000000-80-0-0.jpg";

// Deezer's artist search for "Star Sisters". The picture is the sleeve of
// their album "Umqabaqhaba", which has no "Waterloo" on it.
var STAR = "bc64574e7f5c2da03d26762d48ea84c7";
var starArtist = { "data": [
    { "name": "Star Sisters", "picture_medium": DEEZER + "artist/" + STAR + "/250x250-000000-80-0-0.jpg",
      "picture_big": DEEZER + "artist/" + STAR + "/500x500-000000-80-0-0.jpg" }
], "total": 25 };
var starPicture = DEEZER + "artist/" + STAR + "/500x500-000000-80-0-0.jpg";
