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

    function test_local_cleanup_matches_its_promise() {
        compare(TrackLogic.cleanQueryLocal("Song (radio edit) [HQ] 192kbps"),
                "Song")
        compare(TrackLogic.cleanQueryLocal("  spaced   out  "), "spaced out")
        compare(TrackLogic.cleanQueryLocal(null), "")
    }
}
