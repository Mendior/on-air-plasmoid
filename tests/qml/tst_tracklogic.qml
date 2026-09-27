// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Track strings the way stations actually send them: dressed in prefixes,
// station tails, ad stars and bitrate tags. Every ugly example here is one
// a real stream produced.
import QtQuick
import QtTest

import "../../package/contents/ui/TrackLogic.js" as TrackLogic

TestCase {
    name: "TrackLogic"

    function test_a_dressed_query_is_undressed() {
        compare(TrackLogic.normalizeQuery("NOW PLAYING: ABBA - Dancing Queen"),
                "ABBA - Dancing Queen")
        compare(TrackLogic.normalizeQuery("ABBA - Dancing Queen | Elmar"),
                "ABBA - Dancing Queen")
        compare(TrackLogic.normalizeQuery("np: ABBA - Dancing Queen"),
                "ABBA - Dancing Queen")
    }

    function test_playlist_numbering_and_noise_go_away() {
        compare(TrackLogic.normalizeQuery("01. Song"), "Song")
        compare(TrackLogic.normalizeQuery("2) Song"), "Song")
        compare(TrackLogic.normalizeQuery("Song (Live) [Remix] 128 kbps"), "Song")
        compare(TrackLogic.normalizeQuery("***Song***"), "Song")
    }

    function test_normalize_is_idempotent_and_safe_on_empty() {
        var once = TrackLogic.normalizeQuery("NOW PLAYING: A - B | X")
        compare(TrackLogic.normalizeQuery(once), once)
        compare(TrackLogic.normalizeQuery(""), "")
        compare(TrackLogic.normalizeQuery(null), "")
    }

    function test_preclean_drops_the_station_segment_only() {
        compare(TrackLogic.preCleanTrack("Artist - Title - Raadio Elmar"),
                "Artist - Title")
        compare(TrackLogic.preCleanTrack("Artist - Title"), "Artist - Title")
        // Parentheses are the split's business, not preclean's.
        compare(TrackLogic.preCleanTrack("Artist - Title (Live)"),
                "Artist - Title (Live)")
        compare(TrackLogic.preCleanTrack("NOW PLAYING: Artist - Title | Tail"),
                "Artist - Title")
        // Everything past the second segment goes, however many there are.
        compare(TrackLogic.preCleanTrack("A - B - C - D"), "A - B")
    }

    function test_preclean_sees_the_whole_dash_family() {
        compare(TrackLogic.preCleanTrack("Artist – Title – Raadio Elmar"),
                "Artist - Title")
        compare(TrackLogic.preCleanTrack("Artist — Title — Station"),
                "Artist - Title")
        compare(TrackLogic.preCleanTrack("Artist - Title – Station"),
                "Artist - Title")
        // Two segments stay whole no matter which dash joins them.
        compare(TrackLogic.preCleanTrack("Artist – Title"), "Artist – Title")
    }

    function test_the_split_takes_the_first_padded_separator() {
        var p = TrackLogic.parseTrackString("ABBA - Dancing Queen")
        compare(p.artist, "ABBA")
        compare(p.title, "Dancing Queen")
        p = TrackLogic.parseTrackString("A - B - C")
        compare(p.artist, "A")
        compare(p.title, "B - C")
    }

    function test_dashes_and_slashes_split_only_when_padded() {
        var p = TrackLogic.parseTrackString("ABBA – Dancing Queen")
        compare(p.artist, "ABBA")
        p = TrackLogic.parseTrackString("ABBA — Dancing Queen")
        compare(p.artist, "ABBA")
        p = TrackLogic.parseTrackString("Kraftwerk / Autobahn")
        compare(p.artist, "Kraftwerk")
        // No padding, no split: hyphenated and slashed names survive whole.
        p = TrackLogic.parseTrackString("Jay-Z - 99 Problems")
        compare(p.artist, "Jay-Z")
        p = TrackLogic.parseTrackString("AC/DC - Thunderstruck")
        compare(p.artist, "AC/DC")
    }

    function test_a_bare_title_has_no_artist() {
        var p = TrackLogic.parseTrackString("Bohemian Rhapsody")
        compare(p.artist, "")
        compare(p.title, "Bohemian Rhapsody")
        p = TrackLogic.parseTrackString("")
        compare(p.artist, "")
        compare(p.title, "")
    }

    function test_the_first_billed_artist_stands_alone() {
        compare(TrackLogic.primaryArtist("Elton John & Dua Lipa"), "Elton John")
        compare(TrackLogic.primaryArtist("Beyoncé feat. Jay-Z"), "Beyoncé")
        compare(TrackLogic.primaryArtist("A vs. B"), "A")
        compare(TrackLogic.primaryArtist("A, B, C"), "A")
        compare(TrackLogic.primaryArtist("Nico x Vinz"), "Nico")
        compare(TrackLogic.primaryArtist("BEYONCÉ FEAT. JAY-Z"), "BEYONCÉ")
        compare(TrackLogic.primaryArtist("Queen"), "Queen")
        compare(TrackLogic.primaryArtist(""), "")
    }

    // Dance Wave! on 2026-09-23: the title was "Dance Wave!" with no artist,
    // and iTunes answered with a stranger's album, palm tree and all.
    function test_the_station_saying_its_own_name_is_station_talk() {
        verify(TrackLogic.stationTalk("Dance Wave!", "Dance Wave!"))
        verify(TrackLogic.stationTalk("DANCE  WAVE", "Dance Wave!"))
        verify(TrackLogic.stationTalk("dance wave", "Dance Wave!"))
        verify(TrackLogic.stationTalk("NOW PLAYING: Dance Wave!", "Dance Wave!"))
        verify(TrackLogic.stationTalk("Rádió Élmar", "Radio Elmar"))
        // The directory's name often carries a tail the stream never says.
        verify(TrackLogic.stationTalk("Radio Paradise", "Radio Paradise - Main Mix (EN)"))
        verify(TrackLogic.stationTalk("Dance Wave!", "Dance Wave! (HU)"))
    }

    function test_a_line_with_a_web_address_is_station_talk() {
        verify(TrackLogic.stationTalk("Tracklist: https://dancewave.online/", "Dance Wave!"))
        verify(TrackLogic.stationTalk("Visit www.example.fm", "Other"))
        verify(TrackLogic.stationTalk("http://x.fm", ""))
    }

    function test_a_song_that_shares_words_with_the_station_is_music() {
        verify(!TrackLogic.stationTalk("Radio Ga Ga", "Radio"))
        verify(!TrackLogic.stationTalk("Paradise", "Radio Paradise"))
        verify(!TrackLogic.stationTalk("Madonna Frozen", "Frozen"))
        verify(!TrackLogic.stationTalk("Awww. Yeah", "Other"))
        verify(!TrackLogic.stationTalk("Anything", ""))
        verify(!TrackLogic.stationTalk("", "Dance Wave!"))
        verify(!TrackLogic.stationTalk("!!!", "???"))
        verify(!TrackLogic.stationTalk(null, null))
    }

    // A ListModel stand-in: the history hands its model over as it is.
    function _rows(list) {
        return { count: list.length, get: function(i) { return list[i] } }
    }

    function _row(artist, title, station) {
        return { artist: artist, trackName: title, station: station }
    }

    function test_the_history_takes_a_new_song() {
        verify(TrackLogic.historyTakes(_rows([]), "ABBA", "Dancing Queen", "Elmar"))
        verify(TrackLogic.historyTakes(_rows([_row("ABBA", "Waterloo", "Elmar")]),
                                       "ABBA", "Dancing Queen", "Elmar"))
        verify(!TrackLogic.historyTakes(_rows([]), "ABBA", "", "Elmar"))
    }

    function test_the_newest_row_again_is_no_new_row() {
        var rows = _rows([_row("ABBA", "Waterloo", "Elmar")])
        verify(!TrackLogic.historyTakes(rows, "ABBA", "Waterloo", "Elmar"))
        verify(!TrackLogic.historyTakes(rows, "abba", "WATERLOO", "Elmar"))
        // As before: the same song as the newest row, whatever station it is on.
        verify(!TrackLogic.historyTakes(rows, "ABBA", "Waterloo", "Elmar 320k"))
    }

    // Measured 2026-09-23 on Dance Wave!: two slogans every 15-20 s took
    // turns, so "same as the newest row" never fired and the thirty rows
    // were all slogans seven minutes in.
    function test_a_slogan_taking_turns_with_songs_gets_one_row() {
        var rows = _rows([_row("", "Tracklist", "Dance Wave!"),
                          _row("Artist", "Song", "Dance Wave!"),
                          _row("", "All about Dance from 2000 till today!", "Dance Wave!")])
        verify(!TrackLogic.historyTakes(rows, "", "All about Dance from 2000 till today!", "Dance Wave!"))
        verify(!TrackLogic.historyTakes(rows, "Artist", "Song", "Dance Wave!"))
    }

    function test_the_station_talking_is_not_history() {
        verify(!TrackLogic.historyTakes(_rows([]), "", "Dance Wave!", "Dance Wave!"))
        verify(!TrackLogic.historyTakes(_rows([]), "", "Tracklist: https://dancewave.online/", "Dance Wave!"))
    }

    function test_the_lookback_ends_at_another_station_and_at_ten_rows() {
        // Back on Elmar after a stop at Vikerraadio: Elmar's song is new again.
        var rows = _rows([_row("X", "News", "Vikerraadio"),
                          _row("ABBA", "Waterloo", "Elmar")])
        verify(TrackLogic.historyTakes(rows, "ABBA", "Waterloo", "Elmar"))
        var list = []
        for (var i = 0; i < 10; i++) list.push(_row("A", "Song " + i, "Elmar"))
        list.push(_row("ABBA", "Waterloo", "Elmar"))
        verify(TrackLogic.historyTakes(_rows(list), "ABBA", "Waterloo", "Elmar"))
        list.splice(9, 1)
        verify(!TrackLogic.historyTakes(_rows(list), "ABBA", "Waterloo", "Elmar"))
    }

    function test_local_cleanup_matches_its_promise() {
        compare(TrackLogic.cleanQueryLocal("Song (radio edit) [HQ] 192kbps"),
                "Song")
        compare(TrackLogic.cleanQueryLocal("  spaced   out  "), "spaced out")
        compare(TrackLogic.cleanQueryLocal(null), "")
    }
}
