// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// What a picture a catalogue offers is of: the cover of the song on air, a
// picture of the artist, or the sleeve of another record of theirs. The
// answers in CoverAnswers.js are the ones Deezer and iTunes gave on
// 2026-11-12, when the panel showed another single's sleeve under a song.
import QtQuick
import QtTest

import "../../package/contents/ui/SearchLogic.js" as SL
import "CoverAnswers.js" as Answers

TestCase {
    name: "ArtKind"

    function _rows(list) {
        return list.map(function(r) { return { artist: r[0], title: r[1] } })
    }

    function test_a_kind_is_one_of_three_words() {
        compare(SL.artKind("track"), "track")
        compare(SL.artKind("artist"), "artist")
        compare(SL.artKind("release"), "release")
        compare(SL.artKind("Track"), "")
        compare(SL.artKind("cover"), "")
        compare(SL.artKind(""), "")
        compare(SL.artKind(undefined), "")
        compare(SL.artKind(null), "")
        compare(SL.artKind(1), "")
        // Words every object answers to are no kinds.
        compare(SL.artKind("constructor"), "")
        compare(SL.artKind("toString"), "")
        compare(SL.artKind({ toString: function() { return "track" } }), "")
    }

    function test_the_artists_other_song_is_another_release_and_never_the_track() {
        var rows = _rows([["Alen Veziko", "Nüüd taas sajab lund"]])
        var got = SL.artChoice("Alen Veziko", "Päiksepoolsel tänaval", rows)
        compare(got.index, 0)
        compare(got.kind, "release")
        // The old door still takes the row, which is why it cannot say what it took.
        compare(SL.artPickEither("Alen Veziko", "Päiksepoolsel tänaval", rows), 0)
    }

    function test_the_song_itself_is_the_track_guest_credit_and_all() {
        var rows = _rows([["Mari-Leen", "Rahutu tuhkatriinu"], ["Mari-Leen", "Rahutu Tuhkatriinu (Remix)"]])
        var got = SL.artChoice("Moon Taxi feat. Mari-Leen", "Rahutu tuhkatriinu", rows)
        compare(got.index, 0)
        compare(got.kind, "track")
        // A title that only holds the song's is still the song: a remaster, a remix.
        got = SL.artChoice("Mari-Leen", "Rahutu tuhkatriinu", rows.slice(1))
        compare(got.index, 0)
        compare(got.kind, "track")
    }

    function test_the_song_wins_over_another_release_wherever_it_stands() {
        var rows = _rows([["Alen Veziko", "Nüüd taas sajab lund"], ["Somebody Else", "Päiksepoolsel tänaval"],
                          ["Alen Veziko", "Päiksepoolsel tänaval"]])
        var got = SL.artChoice("Alen Veziko", "Päiksepoolsel tänaval", rows)
        compare(got.index, 2)
        compare(got.kind, "track")
    }

    // "Title - ARTIST", as Jazz Radio Blues sends it. A band that happens to
    // be named like the song used to end the choice with its own record.
    function test_the_swapped_reading_is_tried_before_another_release_is_settled_for() {
        var rows = _rows([["Lenny", "Some Other Song"], ["Stevie Ray Vaughan", "Lenny"]])
        var got = SL.artChoice("Lenny", "STEVIE RAY VAUGHAN", rows)
        compare(got.index, 1)
        compare(got.kind, "track")
        compare(SL.artPickEither("Lenny", "STEVIE RAY VAUGHAN", rows), 0)
    }

    function test_a_stranger_a_part_of_a_name_and_a_karaoke_pressing_are_nothing() {
        var none = function(got) { compare(got.index, -1); compare(got.kind, "") }
        none(SL.artChoice("Alen Veziko", "Päiksepoolsel tänaval", _rows([["Mia", "Miks Aeg Nii Kiirelt Käib"]])))
        // "Laura" is a part of Laura Mvula's name: taken with the song only.
        none(SL.artChoice("Laura", "Muusa", _rows([["Laura Mvula", "Green Garden"]])))
        compare(SL.artChoice("Laura", "Green Garden", _rows([["Laura Mvula", "Green Garden"]])).kind, "track")
        none(SL.artChoice("Alen Veziko", "Päiksepoolsel tänaval",
                          _rows([["Alen Veziko", "Nüüd taas sajab lund (Karaoke Version)"]])))
    }

    function test_no_artist_no_rows_and_rows_that_are_no_rows() {
        var none = function(got) { compare(got.index, -1); compare(got.kind, "") }
        // Without an artist nothing can be the artist's.
        none(SL.artChoice("", "Rahutu tuhkatriinu", _rows([["Mari-Leen", "Rahutu tuhkatriinu"]])))
        none(SL.artChoice(undefined, undefined, _rows([["Mari-Leen", "Rahutu tuhkatriinu"]])))
        none(SL.artChoice("Mari-Leen", "Rahutu tuhkatriinu", []))
        none(SL.artChoice("Mari-Leen", "Rahutu tuhkatriinu", null))
        none(SL.artChoice("Mari-Leen", "Rahutu tuhkatriinu", [null, undefined, {}, 7]))
        // An artist with no title to go by: any record of theirs is another release.
        compare(SL.artChoice("Mari-Leen", "", _rows([["Mari-Leen", "Rahutu tuhkatriinu"]])).kind, "release")
        var many = []
        for (var i = 0; i < 2000; i++) many.push({ artist: "Mari-Leen", title: "Song " + i })
        many.push({ artist: "Mari-Leen", title: "Rahutu tuhkatriinu" })
        var got = SL.artChoice("Mari-Leen", "Rahutu tuhkatriinu", many)
        compare(got.index, 2000)
        compare(got.kind, "track")
    }

    function test_a_deezer_picture_without_a_picture_in_it_is_none() {
        compare(SL.artDeezerReal(Answers.moonCover), Answers.moonCover)
        compare(SL.artDeezerReal(Answers.DEEZER + "artist//250x250-000000-80-0-0.jpg"), "")
        compare(SL.artDeezerReal(Answers.DEEZER + "cover/d41d8cd98f00b204e9800998ecf8427e/500x500-000000-80-0-0.jpg"), "")
        compare(SL.artDeezerReal(""), "")
        compare(SL.artDeezerReal(undefined), "")
        compare(SL.artDeezerReal(null), "")
    }

    function test_deezers_song_answer_is_read_with_its_kind() {
        var got = SL.artFromDeezerSongs(Answers.moonTrack, { artist: "Moon Taxi feat. Mari-Leen", title: "Rahutu tuhkatriinu" })
        compare(got.url, Answers.moonCover)
        compare(got.kind, "track")
        // The same rows under another of her songs: her record, not this song.
        got = SL.artFromDeezerSongs(Answers.moonTrack, { artist: "Mari-Leen", title: "1987" })
        compare(got.url, Answers.moonCover)
        compare(got.kind, "release")
        compare(SL.artFromDeezerSongs(Answers.deezerNothing, { artist: "Alen Veziko", title: "Päiksepoolsel tänaval" }), null)
        compare(SL.artFromDeezerSongs(Answers.moonTrack, { artist: "Alen Veziko", title: "Päiksepoolsel tänaval" }), null)
    }

    // A row whose album has no sleeve falls back on Deezer's picture of the
    // artist. That is a picture of the artist, however well the song matched.
    function test_a_song_row_without_a_sleeve_offers_the_artists_picture_as_such() {
        var face = Answers.DEEZER + "artist/" + Answers.MARI_LEEN + "/250x250-000000-80-0-0.jpg"
        var bare = { data: [{ title: "Rahutu tuhkatriinu", artist: { name: "Mari-Leen", picture_medium: face },
                              album: { cover_medium: Answers.DEEZER + "cover//250x250-000000-80-0-0.jpg", cover_big: "" } }] }
        var got = SL.artFromDeezerSongs(bare, { artist: "Mari-Leen", title: "Rahutu tuhkatriinu" })
        compare(got.url, face)
        compare(got.kind, "artist")
        // The medium sleeve is taken where the big one is missing.
        bare.data[0].album.cover_medium = Answers.DEEZER + "cover/" + Answers.MARI_LEEN + "/250x250-000000-80-0-0.jpg"
        got = SL.artFromDeezerSongs(bare, { artist: "Mari-Leen", title: "Rahutu tuhkatriinu" })
        compare(got.kind, "track")
        // Neither a sleeve nor a picture: nothing.
        bare.data[0].album = {}
        bare.data[0].artist.picture_medium = Answers.DEEZER + "artist//250x250-000000-80-0-0.jpg"
        compare(SL.artFromDeezerSongs(bare, { artist: "Mari-Leen", title: "Rahutu tuhkatriinu" }), null)
    }

    function test_itunes_song_answer_is_read_with_its_kind() {
        var want = { artist: "Alen Veziko", title: "Nüüd taas sajab lund" }
        var got = SL.artFromItunesSongs(Answers.alenSongs, want)
        compare(got.url, Answers.alenOtherSingle)
        compare(got.kind, "track")
        // Under a song the rows do not have, the first record with his name
        // on it is the album he shares with Kristjan Matson.
        got = SL.artFromItunesSongs(Answers.alenSongs, { artist: "Alen Veziko", title: "Päiksepoolsel tänaval" })
        compare(got.url, Answers.APPLE + Answers.MATSON + "/600x600bb.jpg")
        compare(got.kind, "release")
        compare(SL.artFromItunesSongs(Answers.itunesNothing, want), null)
        // The chosen row has no picture: nothing, not the next row's.
        var bare = { results: [{ artistName: "Alen Veziko", trackName: "Nüüd taas sajab lund" },
                               { artistName: "Alen Veziko", trackName: "Another", artworkUrl100: "http://x/100x100bb.jpg" }] }
        compare(SL.artFromItunesSongs(bare, want), null)
    }

    function test_deezers_artist_answer_is_a_picture_of_the_artist() {
        var got = SL.artFromDeezerArtist(Answers.starArtist, "Star Sisters")
        compare(got.url, Answers.starPicture)
        compare(got.kind, "artist")
        // Another act of nearly that name is nobody's picture.
        compare(SL.artFromDeezerArtist(Answers.starArtist, "Star Sister"), null)
        compare(SL.artFromDeezerArtist(Answers.starArtist, ""), null)
        compare(SL.artFromDeezerArtist(Answers.deezerNothing, "Star Sisters"), null)
        var medium = { data: [{ name: "Star Sisters", picture_big: "", picture_medium: Answers.starPicture }] }
        compare(SL.artFromDeezerArtist(medium, "Star Sisters").url, Answers.starPicture)
        var grey = { data: [{ name: "Star Sisters", picture_big: Answers.DEEZER + "artist//500x500-000000-80-0-0.jpg" }] }
        compare(SL.artFromDeezerArtist(grey, "Star Sisters"), null)
    }

    // The request that put "Nüüd taas sajab lund" on the panel. The row it
    // picks has not changed; what it is called has.
    function test_the_artists_itunes_songs_are_another_release() {
        var got = SL.artFromItunesArtist(Answers.alenSongs, "Alen Veziko")
        compare(got.url, Answers.alenOtherSingle)
        compare(got.kind, "release")
        compare(SL.artFromItunesArtist(Answers.alenSongs, "Alen Vesiko"), null)
        compare(SL.artFromItunesArtist(Answers.alenSongs, ""), null)
        compare(SL.artFromItunesArtist(Answers.itunesNothing, "Alen Veziko"), null)
    }

    function test_an_answer_that_is_no_answer_offers_nothing_data() {
        return [
            { tag: "undefined", answer: undefined },
            { tag: "null", answer: null },
            { tag: "text", answer: "Too many requests" },
            { tag: "number", answer: 429 },
            { tag: "empty object", answer: {} },
            { tag: "rows that are no list", answer: { data: 7, results: "none" } },
            { tag: "rows of nothing", answer: { data: [null, 3, "x", {}], results: [null, 3, "x", {}] } },
            { tag: "rows without names", answer: { data: [{ artist: null, album: null }], results: [{ artistName: null }] } }
        ]
    }
    function test_an_answer_that_is_no_answer_offers_nothing(data) {
        var want = { artist: "Alen Veziko", title: "Päiksepoolsel tänaval" }
        compare(SL.artFromDeezerSongs(data.answer, want), null)
        compare(SL.artFromItunesSongs(data.answer, want), null)
        compare(SL.artFromDeezerArtist(data.answer, "Alen Veziko"), null)
        compare(SL.artFromItunesArtist(data.answer, "Alen Veziko"), null)
        // Nor does a lookup that does not know what it wants.
        compare(SL.artFromDeezerSongs(Answers.moonTrack, undefined), null)
        compare(SL.artFromItunesSongs(Answers.alenSongs, null), null)
    }

    function test_each_request_of_the_plan_is_sent_for_one_thing() {
        compare(SL.artBrings("deezer"), "track")
        compare(SL.artBrings("itunes"), "track")
        compare(SL.artBrings("deezerArtist"), "artist")
        compare(SL.artBrings("itunesArtist"), "release")
        // A request nobody named is a song search: what it brings besides waits.
        compare(SL.artBrings(undefined), "track")
        compare(SL.artBrings(""), "track")
    }

    // What was met on the way stands in for a request only once every song
    // search has been heard, and the artist's picture goes before a record.
    function test_a_kept_picture_answers_only_after_the_song_searches() {
        var face = { url: "http://x/face.jpg", kind: "artist" }
        var sleeve = { url: "http://x/sleeve.jpg", kind: "release" }
        compare(SL.artSpare({ artist: face, release: sleeve }, "track"), null)
        compare(SL.artSpare({ artist: face, release: sleeve }, "artist"), face)
        compare(SL.artSpare({ artist: face, release: sleeve }, "release"), face)
        compare(SL.artSpare({ artist: face, release: sleeve }, ""), face)
        // A kept record does not spare the question after the artist's picture.
        compare(SL.artSpare({ release: sleeve }, "artist"), null)
        compare(SL.artSpare({ release: sleeve }, "release"), sleeve)
        compare(SL.artSpare({ release: sleeve }, ""), sleeve)
        compare(SL.artSpare({}, ""), null)
        compare(SL.artSpare({}, "release"), null)
        compare(SL.artSpare(undefined, ""), null)
        compare(SL.artSpare(null, "artist"), null)
    }
}
