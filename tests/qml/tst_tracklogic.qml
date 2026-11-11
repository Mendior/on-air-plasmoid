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

    // The walmradio stations, live on 2026-11-02: "Title by Artist", then the
    // station's tagline. Read as it came, the artist was the whole sentence.
    function test_a_title_by_its_artist_over_a_station_tagline() {
        var p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Chattanooga Choo Choo by Ray Conniff - Classic Vinyl on walmradio.com"))
        compare(p.artist, "Ray Conniff")
        compare(p.title, "Chattanooga Choo Choo")
        p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "I Wish You Loved Me by B. Andrews Band - walmradio.com"))
        compare(p.artist, "B. Andrews Band")
        compare(p.title, "I Wish You Loved Me")
        p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Deep Purple/Blue Velvet by Jackie Gleason - Classic Vinyl on walmradio.com"))
        compare(p.artist, "Jackie Gleason")
        compare(p.title, "Deep Purple/Blue Velvet")
    }

    // The artist follows the LAST " by ": the first one can be the song's.
    function test_a_title_with_by_in_it_keeps_its_title() {
        var p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Walk On By by Dionne Warwick - Classic Vinyl on walmradio.com"))
        compare(p.artist, "Dionne Warwick")
        compare(p.title, "Walk On By")
        p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Stand by Me by Ben E. King - Classic Vinyl on walmradio.com"))
        compare(p.artist, "Ben E. King")
        compare(p.title, "Stand by Me")
        compare(TrackLogic.preCleanTrack("Stand BY Me BY Ben E. King - walmradio.com"),
                "Ben E. King - Stand BY Me")
    }

    function test_the_by_rule_leaves_other_lines_alone() {
        // A www. address is the station talking (stationTalk), not a tagline.
        compare(TrackLogic.preCleanTrack("Radio Swiss Classic - www.radioswissclassic.ch"),
                "Radio Swiss Classic - www.radioswissclassic.ch")
        // Even after a "by", or the address would vanish from the line it marks.
        compare(TrackLogic.preCleanTrack("Song by Band - www.walmradio.com"),
                "Song by Band - www.walmradio.com")
        verify(TrackLogic.stationTalk(TrackLogic.preCleanTrack("Song by Band - www.walmradio.com"), "WALM HD"))
        // Venice Classic's real line: the domain sits inside a longer aside.
        var venice = "Ludwig Van Beethoven (1770-1827) - Sonata per pianoforte in la Maggiore No.28 Op.101 (AndrÃ¡s Schiff, pianoforte)  {+info: veniceclassicradio.eu}"
        compare(TrackLogic.preCleanTrack(venice), venice)
        var p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack("Stand by Me"))
        compare(p.artist, "")
        compare(p.title, "Stand by Me")
        compare(TrackLogic.preCleanTrack("Ben E. King - Stand by Me"), "Ben E. King - Stand by Me")
        // No " by " to split at, or nothing on one side of it: as it came.
        compare(TrackLogic.preCleanTrack("Golden Oldies - walmradio.com"),
                "Golden Oldies - walmradio.com")
        compare(TrackLogic.preCleanTrack("Standby - walmradio.com"), "Standby - walmradio.com")
        compare(TrackLogic.preCleanTrack("by Ray Conniff - walmradio.com"), "by Ray Conniff - walmradio.com")
        // A tagline of five words before the address is not a tagline.
        compare(TrackLogic.preCleanTrack("Song by Band - One Two Three Four Five walmradio.com"),
                "Song by Band - One Two Three Four Five walmradio.com")
        // A padded slash already splits artist from title: today's parse stays.
        compare(TrackLogic.preCleanTrack("Medley / Song by Band - walmradio.com"),
                "Medley / Song by Band - walmradio.com")
        compare(TrackLogic.preCleanTrack(""), "")
        compare(TrackLogic.preCleanTrack(null), "")
    }

    function test_an_overlong_by_line_still_reads_quickly() {
        var title = ""
        for (var i = 0; i < 400; i++) title += "word by word "
        var t0 = Date.now()
        compare(TrackLogic.preCleanTrack(title + "by Band - Classic Vinyl on walmradio.com"),
                "Band - " + title.trim())
        compare(TrackLogic.preCleanTrack(title + "- " + title + "walmradio.com"),
                title + "- " + title + "walmradio.com")
        verify(Date.now() - t0 < 1000)
    }

    // Virgin Radio Classic Rock, live on 2026-11-02: the record, not a title.
    function test_a_virgin_radio_record_reads_as_artist_and_title() {
        var p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Walk Of Life~Dire Straits~~1985~GBUM72102500~225~2026-11-02T17:05:05~2026-11-02T17:05:07~Virgin Radio Classic Rock~2.50~f0086e65-2d5c-4199-9ab8-e5346d08ca7d"))
        compare(p.artist, "Dire Straits")
        compare(p.title, "Walk Of Life")
        p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Babe I'm Gonna Leave You~Led Zeppelin~~1969~~394~2026-11-02T16:53:37~2026-11-02T16:53:38~Virgin Radio Classic Rock~1.61~2d1a0910-bd40-44e3-ba31-9433fa916535"))
        compare(p.artist, "Led Zeppelin")
        compare(p.title, "Babe I'm Gonna Leave You")
        // Eight fields are enough; the spaces around a field are not the song's.
        compare(TrackLogic.preCleanTrack(" Space Oddity ~ David Bowie ~~1969~~273~2026-11-02T17:14:04~2026-11-02T17:14:07"),
                "David Bowie - Space Oddity")
        // A title with its own dash keeps the usual cut after the rewrite.
        compare(TrackLogic.preCleanTrack("Layla - Unplugged~Eric Clapton~~1992~~280~2026-11-02T17:14:04~2026-11-02T17:18:44~Virgin Radio Classic Rock"),
                "Eric Clapton - Layla")
    }

    function test_a_record_without_an_artist_or_the_shape_stays_as_it_came() {
        // The station's ident and a news bulletin, both live: no artist field.
        var ident = "Virgin Radio Classic Rock~~~~~14~2026-11-02T17:54:50~2026-11-02T17:54:51~Virgin Radio Classic Rock~1.30~92ea57b4-55c6-4979-b019-7460916f1660"
        compare(TrackLogic.preCleanTrack(ident), ident)
        var news = "TGcom24 Breaking News~~~~~125~2026-11-02T18:00:24~2026-11-02T18:00:54~Virgin Radio Classic Rock~30.32~750cf5c7-12dd-4d31-9b0c-60f801c6ac98"
        compare(TrackLogic.preCleanTrack(news), news)
        // A "~" inside the title shifts the fields, so no timestamp lines up.
        var shifted = "Love ~ Peace~Some Band~~1990~~200~2026-11-02T17:05:05~2026-11-02T17:05:07~Virgin Radio Classic Rock~1.00~x"
        compare(TrackLogic.preCleanTrack(shifted), shifted)
        compare(TrackLogic.preCleanTrack("A~B~~1985~~225~2026-11-02T17:05:05"), "A~B~~1985~~225~2026-11-02T17:05:05")
        compare(TrackLogic.preCleanTrack("Walk Of Life~Dire Straits~~1985~~225~2026-11-02 17:05:05~2026-11-02T17:05:07"),
                "Walk Of Life~Dire Straits~~1985~~225~2026-11-02 17:05:05~2026-11-02T17:05:07")
        compare(TrackLogic.preCleanTrack("~~~~~~~~"), "~~~~~~~~")
        var many = "Walk Of Life~Dire Straits~~1985~~225~2026-11-02T17:05:05~2026-11-02T17:05:07"
        for (var i = 0; i < 2000; i++) many += "~x"
        compare(TrackLogic.preCleanTrack(many), "Dire Straits - Walk Of Life")
    }

    // Kaaosradio, live on 2026-11-02: its own name and channel come first.
    function test_the_station_name_in_front_of_artist_and_title_goes() {
        var p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Kaaosradio 24h - Fuji Kureta - Rope", "Kaaosradio - 24h Chill"))
        compare(p.artist, "Fuji Kureta")
        compare(p.title, "Rope")
        p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Kaaosradio 24h Ma Hardstyle - D-Mind - I Love U (The Eternal Love Mix) [UA]",
            "Kaaos Radio Techno Electro"))
        compare(p.artist, "D-Mind")
        compare(p.title, "I Love U (The Eternal Love Mix) [UA]")
        // The whole station name, and a fourth segment as well.
        compare(TrackLogic.preCleanTrack("Kiss FM - Dua Lipa - Levitating", "Kiss FM"),
                "Dua Lipa - Levitating")
        compare(TrackLogic.preCleanTrack("Radio Bob! Rockparty - Artist - Title - Extra", "Radio Bob! Rockparty"),
                "Artist - Title")
        verify(TrackLogic.stationDropped("Kaaosradio 24h - Fuji Kureta - Rope", "Kaaosradio - 24h Chill"))
        verify(TrackLogic.stationDropped("NOW PLAYING: Kiss FM - Dua Lipa - Levitating", "Kiss FM"))
    }

    function test_an_artist_the_station_is_named_after_keeps_the_song() {
        // The station's first two words ARE the segment: an artist, not a channel.
        var p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Elvis Presley - Suspicious Minds - 1969", "Elvis Presley Radio"))
        compare(p.artist, "Elvis Presley")
        compare(p.title, "Suspicious Minds")
        compare(TrackLogic.preCleanTrack("The Beatles - Help! - Remastered 2009", "The Beatles Radio"),
                "The Beatles - Help!")
        // Two segments are never cut, whatever the station is called.
        compare(TrackLogic.preCleanTrack("Metallica - Enter Sandman", "Metallica Radio"),
                "Metallica - Enter Sandman")
        compare(TrackLogic.preCleanTrack("ABBA - SOS", "ABBA"), "ABBA - SOS")
        compare(TrackLogic.preCleanTrack("ABBA - SOS", "ABBA - Greatest Hits"), "ABBA - SOS")
        verify(!TrackLogic.stationDropped("Elvis Presley - Suspicious Minds - 1969", "Elvis Presley Radio"))
        verify(!TrackLogic.stationDropped("ABBA - SOS", "ABBA"))
    }

    // The band behind the name, a station named after the artist, a station
    // saved under the bare artist: the line reads as it did with no station.
    function test_an_artist_in_front_is_never_taken_for_the_station() {
        var p = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(
            "Bob Marley & The Wailers - One Love - Exodus", "Bob Marley Radio"))
        compare(p.artist, "Bob Marley & The Wailers")
        compare(p.title, "One Love")
        compare(TrackLogic.preCleanTrack("Elvis Presley & The Jordanaires - Teddy Bear - Loving You",
                                         "Elvis Presley Radio"),
                "Elvis Presley & The Jordanaires - Teddy Bear")
        compare(TrackLogic.preCleanTrack("Bob Marley feat. Lauryn Hill - Turn Your Lights Down Low - Chant Down Babylon",
                                         "Bob Marley Radio"),
                "Bob Marley feat. Lauryn Hill - Turn Your Lights Down Low")
        compare(TrackLogic.preCleanTrack("Queen - Bohemian Rhapsody - A Night at the Opera", "Queen - Greatest Hits"),
                "Queen - Bohemian Rhapsody")
        // "Radio" further on in the saved name does not make Queen a station.
        compare(TrackLogic.preCleanTrack("Queen - Bohemian Rhapsody - A Night at the Opera", "Queen - Greatest Hits Radio"),
                "Queen - Bohemian Rhapsody")
        compare(TrackLogic.preCleanTrack("ABBA - SOS - Arrival", "ABBA"), "ABBA - SOS")
        verify(!TrackLogic.stationDropped("Bob Marley & The Wailers - One Love - Exodus", "Bob Marley Radio"))
        verify(!TrackLogic.stationDropped("Queen - Bohemian Rhapsody - A Night at the Opera", "Queen - Greatest Hits"))
        verify(!TrackLogic.stationDropped("ABBA - SOS - Arrival", "ABBA"))
        var band = ""
        for (var i = 0; i < 300; i++) band += "Bob Marley & "
        compare(TrackLogic.preCleanTrack(band + "The Wailers - One Love - Exodus", "Bob Marley Radio"),
                band + "The Wailers - One Love")
    }

    // A station word counts alone or at the end of a word, never at its start
    // or inside it.
    function test_a_station_word_has_to_end_its_word() {
        compare(TrackLogic.preCleanTrack("Radiohead - Creep - Pablo Honey", "Radiohead"), "Radiohead - Creep")
        compare(TrackLogic.preCleanTrack("Wolfmother - Woman - Wolfmother", "Wolfmother"), "Wolfmother - Woman")
        compare(TrackLogic.preCleanTrack("Bob Marley Radio - Bob Marley - One Love", "Bob Marley Radio"),
                "Bob Marley - One Love")
        compare(TrackLogic.preCleanTrack("Vikerraadio - Artist - Title", "Vikerraadio"), "Artist - Title")
        compare(TrackLogic.preCleanTrack("181.fm - Guns N' Roses - Patience", "181.fm"), "Guns N' Roses - Patience")
        compare(TrackLogic.preCleanTrack("Kaaos 24h - Artist - Title", "Kaaos 24h"), "Artist - Title")
        compare(TrackLogic.preCleanTrack("Elmari tantsuõhtu 24/7 - Artist - Title", "Elmari tantsuõhtu 24/7"),
                "Artist - Title")
    }

    function test_without_a_station_the_line_reads_as_before() {
        compare(TrackLogic.preCleanTrack("Kaaosradio 24h - Fuji Kureta - Rope"),
                "Kaaosradio 24h - Fuji Kureta")
        compare(TrackLogic.preCleanTrack("Kaaosradio 24h - Fuji Kureta - Rope", ""),
                "Kaaosradio 24h - Fuji Kureta")
        compare(TrackLogic.preCleanTrack("Kaaosradio 24h - Fuji Kureta - Rope", null),
                "Kaaosradio 24h - Fuji Kureta")
        // A name of punctuation alone is no name to match.
        compare(TrackLogic.preCleanTrack("• - Artist - Title", "•"), "• - Artist")
        compare(TrackLogic.preCleanTrack("A - B - C - D", ""), "A - B")
        // Seven letters of prefix are too few to tell a channel from a word.
        compare(TrackLogic.preCleanTrack("Radio Xy 24 - Artist - Title", "Radio Xy Rock"),
                "Radio Xy 24 - Artist")
        compare(TrackLogic.preCleanTrack("Radio Xyz 24 - Artist - Title", "Radio Xyz Rock"),
                "Artist - Title")
        verify(!TrackLogic.stationDropped("Kaaosradio 24h - Fuji Kureta - Rope", ""))
        verify(!TrackLogic.stationDropped("Fuji Kureta - Rope", "Kaaosradio - 24h Chill"))
        verify(!TrackLogic.stationDropped("", "Kaaosradio - 24h Chill"))
        verify(!TrackLogic.stationDropped(null, null))
        var longName = ""
        for (var i = 0; i < 300; i++) longName += "Kaaosradio "
        compare(TrackLogic.preCleanTrack(longName + "- A - T", longName), "A - T")
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

    // A credit with an aside in brackets: the splitters cut inside it, and
    // "Nightlight Duo (Rita Liiver & Elise Mängel) - Armid näol" went out to
    // the catalogues as "Nightlight Duo (Rita Liiver Armid näol".
    function test_the_first_billed_artist_ends_before_an_aside() {
        compare(TrackLogic.primaryArtist("Nightlight Duo (Rita Liiver & Elise Mängel)"), "Nightlight Duo")
        compare(TrackLogic.primaryArtist("Sigur Rós (live)"), "Sigur Rós")
        compare(TrackLogic.primaryArtist("Sia (feat. Sean Paul)"), "Sia")
        compare(TrackLogic.primaryArtist("Sia [feat. Sean Paul] & Diplo"), "Sia")
        // A bracket that never closes goes with everything after it.
        compare(TrackLogic.primaryArtist("Nightlight Duo (Rita Liiver & Elise Mängel"), "Nightlight Duo")
        compare(TrackLogic.primaryArtist("Nightlight Duo (Rita Liiver"), "Nightlight Duo")
        // With no space in front, the bracket is part of the name.
        compare(TrackLogic.primaryArtist("(G)I-DLE"), "(G)I-DLE")
        compare(TrackLogic.primaryArtist("(G)I-DLE & Friends"), "(G)I-DLE")
        compare(TrackLogic.primaryArtist("Sunn O)))"), "Sunn O)))")
        // A credit that is one aside and nothing else is not cut to nothing.
        compare(TrackLogic.primaryArtist("(Various Artists)"), "(Various Artists)")
        compare(TrackLogic.primaryArtist("  (Various Artists)"), "(Various Artists)")
        compare(TrackLogic.primaryArtist(null), "")
        compare(TrackLogic.primaryArtist(undefined), "")
        var crowd = "Band"
        for (var i = 0; i < 300; i++) crowd += " (with Guest " + i + " & Friends)"
        compare(TrackLogic.primaryArtist(crowd), "Band")
    }

    // The photo search keeps a closed aside, which can be what tells two acts
    // apart, but it never asks with a bracket left open.
    function test_the_photo_search_leaves_no_bracket_open() {
        compare(TrackLogic.photoArtist("Sia (feat. Sean Paul)"), "Sia")
        compare(TrackLogic.photoArtist("Sia [ft. Sean Paul]"), "Sia")
        compare(TrackLogic.photoArtist("Nightlight Duo (Rita Liiver feat. Elise Mängel)"), "Nightlight Duo")
        compare(TrackLogic.photoArtist("Nightlight Duo (Rita Liiver & Elise Mängel"), "Nightlight Duo")
        compare(TrackLogic.photoArtist("Nirvana (UK)"), "Nirvana (UK)")
        compare(TrackLogic.photoArtist("Nightlight Duo (Rita Liiver & Elise Mängel)"),
                "Nightlight Duo (Rita Liiver & Elise Mängel)")
        compare(TrackLogic.photoArtist("(G)I-DLE"), "(G)I-DLE")
        compare(TrackLogic.photoArtist("Sunn O)))"), "Sunn O)))")
        compare(TrackLogic.photoArtist("("), "(")
        compare(TrackLogic.photoArtist(undefined), "")
        var crowd = "Band"
        for (var i = 0; i < 300; i++) crowd += " & Band " + i
        compare(TrackLogic.photoArtist(crowd + " (feat. Guest & Another)"), crowd)
    }

    // The photo search asks for the band, not the first word of it.
    function test_the_photo_search_keeps_the_whole_band_name() {
        compare(TrackLogic.photoArtist("Love & Fate"), "Love & Fate")
        compare(TrackLogic.photoArtist("Florence and the Machine"), "Florence and the Machine")
        compare(TrackLogic.photoArtist("Simon & Garfunkel"), "Simon & Garfunkel")
        compare(TrackLogic.photoArtist("Queen"), "Queen")
        // Only a featuring credit is cut, wherever it sits.
        compare(TrackLogic.photoArtist("Frontliner feat. Ellie"), "Frontliner")
        compare(TrackLogic.photoArtist("Sia feat. Sean Paul & X"), "Sia")
        compare(TrackLogic.photoArtist("A & B feat. C"), "A & B")
        compare(TrackLogic.photoArtist("BEYONCÉ FT. JAY-Z"), "BEYONCÉ")
        compare(TrackLogic.photoArtist("Alok feat Ellie Goulding"), "Alok")
        compare(TrackLogic.photoArtist("Calvin Harris ft Dua Lipa"), "Calvin Harris")
        // "Feat" inside a word, or with nothing before it, is no credit.
        compare(TrackLogic.photoArtist("Featherstone"), "Featherstone")
        compare(TrackLogic.photoArtist("Daft Punk feat."), "Daft Punk feat.")
        compare(TrackLogic.photoArtist(""), "")
        compare(TrackLogic.photoArtist(null), "")
        var crowd = "Band"
        for (var i = 0; i < 300; i++) crowd += " & Band " + i
        compare(TrackLogic.photoArtist(crowd + " feat. Guest"), crowd)
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
