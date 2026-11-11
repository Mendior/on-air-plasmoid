// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Which catalogue row is the record on the air. The rows here are the ones
// Deezer and iTunes really returned for live station lines on 2026-11-02;
// a station spells a name its own way, and the catalogue its own.
import QtQuick
import QtTest

import "../../package/contents/ui/SearchLogic.js" as SL

TestCase {
    name: "ArtPick"

    function _rows(list) {
        return list.map(function(r) { return { artist: r[0], title: r[1] } })
    }

    function test_the_art_fold_forgets_quote_style_ampersands_and_punctuation() {
        compare(SL.artFold("Guns N` Roses"), "guns n roses")
        compare(SL.artFold("Guns N’ Roses"), SL.artFold("Guns N' Roses"))
        compare(SL.artFold("Florence + The Machine"), SL.artFold("Florence and the Machine"))
        compare(SL.artFold("Simon & Garfunkel"), "simon and garfunkel")
        compare(SL.artFold("G. Love & Special Sauce"), "g love and special sauce")
        compare(SL.artFold("AC/DC"), "acdc")
        compare(SL.artFold("Björk"), "bjork")
        // Commas stay: nameAkin reads "Sia, Sean Paul" as a list of names.
        compare(SL.artFold("Crosby, Stills, Nash & Young"), "crosby, stills, nash and young")
    }

    function test_the_art_fold_keeps_other_alphabets_and_never_empties_a_name() {
        compare(SL.artFold("Кино"), "кино")
        // fold() already takes the breve off й, on both sides of a match.
        compare(SL.artFold("Мумий Тролль"), SL.fold("Мумий Тролль"))
        verify(SL.artFold("Мумий Тролль").length === "Мумий Тролль".length)
        // Letters and a digit together: an ASCII-only fold would leave "2".
        compare(SL.artFold("Би-2"), "би2")
        // A name of punctuation alone stays itself, so it is never "no artist".
        compare(SL.artFold("!!!"), "!!!")
        compare(SL.artFold(""), "")
        compare(SL.artFold(null), "")
        compare(SL.artFold(undefined), "")
        var name = ""
        for (var i = 0; i < 500; i++) name += "Rock & Roll! "
        compare(SL.artFold(name).length, 500 * "rock and roll ".length - 1)
    }

    // 181.fm The Eagle sends backticks for apostrophes; both services filed
    // the record under the real apostrophe, and it got no cover.
    function test_a_backtick_is_an_apostrophe() {
        var rows = _rows([["Guns N' Roses", "Sweet Child O' Mine"],
                          ["Guns N' Roses", "Sweet Child O' Mine (Live In Paris / 1992)"]])
        compare(SL.artPick("Guns N` Roses", "Sweet Child O` Mine", rows), 0)
    }

    // Jazz Radio Blues writes names in capitals without their punctuation.
    function test_a_name_without_its_punctuation_is_the_same_name() {
        compare(SL.artArtistScore("G LOVE AND SPECIAL SAUCE", "G. Love & Special Sauce"), 2)
        compare(SL.artArtistScore("SIMON AND GARFUNKEL", "Simon & Garfunkel"), 2)
        compare(SL.artArtistScore("Florence and the Machine", "Florence + The Machine"), 2)
    }

    // The art fold takes the dots and hyphens out, and the letters they kept
    // apart join into a word that a stranger's name contains: "tatu" in "art
    // tatum", "william" in "robbie williams", "modo" in "commodores".
    function test_a_name_joined_up_is_not_inside_a_strangers() {
        compare(SL.artArtistScore("t.A.T.u.", "Art Tatum"), 0)
        compare(SL.artArtistScore("Art Tatum", "t.A.T.u."), 0)
        compare(SL.artArtistScore("will.i.am", "Robbie Williams"), 0)
        compare(SL.artArtistScore("Robbie Williams", "will.i.am"), 0)
        compare(SL.artArtistScore("Mo-Do", "Commodores"), 0)
        compare(SL.artArtistScore("Commodores", "Mo-Do"), 0)
        compare(SL.artPick("t.A.T.u.", "All the Things She Said", _rows([["Art Tatum", "Tea for Two"]])), -1)
        compare(SL.artPick("will.i.am", "Scream & Shout", _rows([["Robbie Williams", "Angels"]])), -1)
        // Listed first, the stranger used to win the tie with her own record.
        compare(SL.artPick("will.i.am", "Scream & Shout",
                           _rows([["Robbie Williams", "Angels"], ["will.i.am", "This Is Love"]])), 1)
        var crowd = "Art Tatum"
        for (var i = 0; i < 300; i++) crowd += " & Friends"
        compare(SL.artArtistScore("t.A.T.u.", crowd), 0)
    }

    // A station that puts the guest into the artist field and leaves the
    // dots out still finds the main artist's record, where the catalogue
    // files the guest under the title.
    function test_a_credit_with_a_guest_still_holds_its_artist() {
        compare(SL.artArtistScore("Mary J Blige feat. Drake", "Mary J. Blige"), 2)
        compare(SL.artArtistScore("TI feat. Rihanna", "T.I."), 2)
        compare(SL.artArtistScore("Lil Kim feat. Lil Cease", "Lil' Kim"), 2)
        compare(SL.artArtistScore("BOB feat. Bruno Mars", "B.o.B"), 2)
        compare(SL.artArtistScore("Dr Dre feat. Snoop Dogg", "Dr. Dre"), 2)
        compare(SL.artArtistScore("Sia (feat. Sean Paul)", "Sia"), 2)
        compare(SL.artArtistScore("Jay-Z", "Jay Z"), 2)
    }

    // A list of performers is split where it is a list. Measured against the
    // recorded answers on 2026-11-03: kept whole, a comma stuck to the first
    // name and a slash ran two names together, and the first artist's records
    // were lost.
    function test_a_list_of_performers_still_holds_its_first_one() {
        compare(SL.artArtistScore("Pritam, Arijit Singh, Sunidhi Chauhan & Amitabh Bhattacharya", "Pritam"), 2)
        compare(SL.artArtistScore("David Guetta, Alphaville & Ava Max", "David Guetta"), 2)
        compare(SL.artArtistScore("Santi/RUSSI/Miles Barker/Afro Queen", "Santi"), 2)
        compare(SL.artArtistScore("Sia, Sean Paul", "Sia"), 2)
    }

    // A name the fold joins across its dots is no first name of a stranger:
    // "will.i.am" folds to "william", "t.A.T.u." to "tatu".
    function test_a_joined_up_name_is_no_strangers_first_name() {
        compare(SL.artArtistScore("will.i.am", "William Orbit"), 0)
        compare(SL.artArtistScore("William Bell", "will.i.am"), 0)
        compare(SL.artArtistScore("t.A.T.u.", "Tatu Kantomaa"), 0)
        compare(SL.artArtistScore("will.i.am", "will.i.am feat. Britney Spears"), 2)
        compare(SL.artArtistScore("BOB feat. Bruno Mars", "B.o.B"), 2)
        compare(SL.artArtistScore("TI feat. Rihanna", "T.I."), 2)
        compare(SL.artArtistScore("TATU", "t.A.T.u."), 2)
    }

    // One word of a longer name is not that name. A station sent "Laura -
    // Muusa", Deezer answered "Laura Muusa" with these three rows, and the
    // widget wore a Laura Mvula sleeve.
    function test_a_part_of_a_longer_name_needs_the_song_too() {
        compare(SL.artPickEither("Laura", "Muusa", _rows([
            ["Jose James", "Nobody Knows My Name"], ["Laura Mvula", "Africa - InVersions 80s"],
            ["Laura Mvula", "You Work for Me"]])), -1)
        compare(SL.artArtistScore("Queen", "Queen Latifah"), 1)
        compare(SL.artArtistScore("Prince", "Prince Royce"), 1)
        compare(SL.artArtistScore("Laine", "Frankie Laine"), 1)
        compare(SL.artArtistScore("Pink Floyd", "Pink"), 1)
        compare(SL.artPick("Queen", "Radio Ga Ga", _rows([["Queen Latifah", "U.N.I.T.Y."]])), -1)
        // The swapped reading is held to the same rule.
        compare(SL.artPickEither("Muusa", "Laura", _rows([["Laura Mvula", "You Work for Me"]])), -1)
        // With the song it is the record after all: a station that sends a
        // surname, or the first half of a band's name.
        compare(SL.artPick("Marley", "One Love", _rows([
            ["Bob Marley & The Wailers", "One Love / People Get Ready"]])), 0)
        compare(SL.artPickEither("Florence", "Dog Days Are Over", _rows([
            ["Florence + The Machine", "Dog Days Are Over"]])), 0)
    }

    // A name that stands whole between the ends of a credit and the words
    // that join performers is that performer, with or without the song.
    function test_a_whole_name_in_a_credit_is_the_artist_without_the_song() {
        compare(SL.artArtistScore("Mary J Blige", "Mary J Blige feat. Drake"), 2)
        compare(SL.artArtistScore("Drake", "Mary J Blige feat. Drake"), 2)
        compare(SL.artArtistScore("Bob Marley", "Bob Marley & The Wailers"), 2)
        compare(SL.artArtistScore("Alphaville", "David Guetta, Alphaville & Ava Max"), 2)
        compare(SL.artArtistScore("RUSSI", "Santi/RUSSI/Miles Barker/Afro Queen"), 2)
        compare(SL.artArtistScore("Calvin Harris", "Rihanna with Calvin Harris"), 2)
        compare(SL.artPick("Drake", "Hotline Bling", _rows([["Mary J Blige feat. Drake", "Whole Damn Year"]])), 0)
        // A "The" one side leaves out is not a longer name. It excuses the
        // left side only: what follows the name still makes it a part.
        compare(SL.artArtistScore("Rolling Stones", "The Rolling Stones"), 2)
        compare(SL.artArtistScore("The Beatles", "Beatles"), 2)
        compare(SL.artArtistScore("Wailers", "Bob Marley & The Wailers"), 2)
        compare(SL.artArtistScore("Eagles", "The Eagles of Death Metal"), 1)
        compare(SL.artArtistScore("Marley", "The Bob Marley Band"), 1)
        // Four letters are enough for a part of a name, three are not: a
        // short name is the artist at the start of a credit or nobody.
        compare(SL.artArtistScore("Pink", "Pink Floyd"), 1)
        compare(SL.artArtistScore("Sia", "Sia Furler"), 0)
        compare(SL.artArtistScore("Furler", "Sia Furler"), 1)
    }

    // The order between the rows of one answer: the artist whole with the
    // exact song, whole with a title that holds it, a part of a name with the
    // exact song, a part with a title that holds it, and last the artist
    // whole with another song. Each pair is listed worse row first.
    function test_the_artist_whole_outranks_a_part_of_a_name() {
        compare(SL.artPick("Queen", "Radio Ga Ga", _rows([
            ["Queen", "Radio Ga Ga - Remastered 2011"], ["Queen", "Radio Ga Ga"]])), 1)
        compare(SL.artPick("Queen", "Radio Ga Ga", _rows([
            ["Queen Latifah", "Radio Ga Ga"], ["Queen", "Radio Ga Ga - Remastered 2011"]])), 1)
        compare(SL.artPick("Prince", "Kiss", _rows([
            ["Prince Royce", "Kiss the Sky"], ["Prince Royce", "Kiss"]])), 1)
        compare(SL.artPick("Prince", "Kiss", _rows([
            ["Prince", "Purple Rain"], ["Prince Royce", "Kiss the Sky"]])), 1)
        // And each pair the other way round, so it is the rank that decides
        // and not the place in the list.
        compare(SL.artPick("Queen", "Radio Ga Ga", _rows([
            ["Queen", "Radio Ga Ga - Remastered 2011"], ["Queen Latifah", "Radio Ga Ga"]])), 0)
        compare(SL.artPick("Prince", "Kiss", _rows([
            ["Prince Royce", "Kiss the Sky"], ["Prince", "Purple Rain"]])), 0)
        // The artist's other record still beats a namesake's other record.
        compare(SL.artPick("Prince", "Kiss", _rows([
            ["Prince Royce", "Stand by Me"], ["Prince", "Purple Rain"]])), 1)
    }

    function test_a_part_of_a_name_with_nothing_to_go_on() {
        // No title on the line: a part of a name has nothing to stand on.
        compare(SL.artPick("Laura", "", _rows([["Laura Mvula", "You Work for Me"]])), -1)
        compare(SL.artPick("Laura", null, _rows([["Laura Mvula", ""]])), -1)
        // Rows that are not rows, and one without a title.
        compare(SL.artPick("Laura", "Muusa", [null, {}, { artist: "Laura Mvula" }, { title: "Muusa" }]), -1)
        // A very long credit and a very long title are walked, not hung on.
        var crowd = "Laura"
        for (var i = 0; i < 300; i++) crowd += " Mvula"
        compare(SL.artArtistScore("Laura", crowd), 1)
        compare(SL.artArtistScore(crowd, "Laura"), 1)
        var longTitle = ""
        for (var k = 0; k < 400; k++) longTitle += "Muusa "
        compare(SL.artPick("Laura", longTitle, _rows([[crowd, "You Work for Me"]])), -1)
        compare(SL.artPick("Laura", "Muusa", _rows([[crowd, longTitle]])), 0)
    }

    // A station writes "feat." where the catalogue writes "&". The line was
    // "Merlyn Uusküla feat. Ice Dog M - 1995" and these are iTunes' first two
    // rows: the record itself counted as a stranger's, so the second row won.
    function test_two_performers_are_the_same_two_however_they_are_joined() {
        compare(SL.artPickEither("Merlyn Uusküla feat. Ice Dog M", "1995", _rows([
            ["Merlyn Uusküla & Ice Dog M", "1995"], ["Merlyn Uusküla", "Ihuüksi (I.M.T.B Remix)"]])), 0)
        compare(SL.artArtistScore("Merlyn Uusküla feat. Ice Dog M", "Merlyn Uusküla & Ice Dog M"), 2)
        compare(SL.artArtistScore("David Guetta ft. Sia", "David Guetta featuring Sia"), 2)
        compare(SL.artArtistScore("Sia, Sean Paul", "Sia with Sean Paul"), 2)
        compare(SL.artArtistScore("Rihanna x Calvin Harris", "Rihanna vs. Calvin Harris"), 2)
        compare(SL.artArtistScore("Santi/RUSSI/Miles Barker", "Santi, RUSSI & Miles Barker"), 2)
        // Only the words that join are one word. Another word in their place,
        // or another partner behind them, is another credit.
        compare(SL.artArtistScore("Merlyn Uusküla feat. Ice Dog M", "Merlyn Uusküla meets Ice Dog M"), 0)
        compare(SL.artArtistScore("Nas & Damian Marley", "Nas feat. Lauryn Hill"), 0)
        compare(SL.artArtistScore("AC", "AC/DC"), 0)
        // A long list, joined one way on the air and another in the catalogue.
        var onAir = "Act 0", filed = "Act 0"
        for (var i = 1; i < 200; i++) {
            onAir += (i % 2 ? " feat. " : " & ") + "Act " + i
            filed += ", Act " + i
        }
        compare(SL.artArtistScore(onAir, filed), 2)
        compare(SL.artArtistScore(onAir, ""), 0)
        compare(SL.artArtistScore(onAir, null), 0)
    }

    // Lists written with ×, 、 or a full-width ampersand and no spaces.
    function test_a_list_joined_without_spaces_still_holds_its_first_one() {
        compare(SL.artArtistScore("LiSA×Uru", "LiSA"), 2)
        compare(SL.artArtistScore("YOASOBI、Ayase", "YOASOBI"), 2)
        compare(SL.artArtistScore("Aimer＆milet", "Aimer"), 2)
    }

    // An ampersand read as "and" is no reason for "Y&T" to be inside every
    // act called something and the something.
    function test_an_ampersand_does_not_make_a_strangers_name() {
        compare(SL.artArtistScore("Y&T", "Bob Marley & The Wailers"), 0)
        compare(SL.artArtistScore("Bob Marley & The Wailers", "Y&T"), 0)
        compare(SL.artArtistScore("Y&T", "Tom Petty & The Heartbreakers"), 0)
        compare(SL.artArtistScore("&ME", "Roland Meyer"), 0)
        compare(SL.artArtistScore("Y&T", "Y & T"), 2)
        // A short name is the artist only at the start of a credit.
        compare(SL.artArtistScore("AC", "AC Slater"), 0)
        compare(SL.artArtistScore("AC", "AC/DC"), 0)
    }

    // What the art fold is for stays: one name in two spellings is one act,
    // a credit with guests still holds its artist, and a record of the
    // artist's own still beats no cover.
    function test_a_dotted_name_still_finds_its_own_records() {
        compare(SL.artArtistScore("TATU", "t.A.T.u."), 2)
        compare(SL.artArtistScore("t.A.T.u.", "t.A.T.u"), 2)
        compare(SL.artArtistScore("Mo-Do", "Mo–Do"), 2)
        compare(SL.artArtistScore("will.i.am", "will.i.am feat. Britney Spears"), 2)
        compare(SL.artArtistScore("Stevie Ray Vaughan", "Stevie Ray Vaughan & Double Trouble"), 2)
        compare(SL.artArtistScore("Nas & Damian Marley", "Nas"), 2)
        compare(SL.artArtistScore("Sia", "Sia feat. Sean Paul"), 2)
        compare(SL.artArtistScore("-", "Mo-Do"), 0)
        compare(SL.artPick("will.i.am", "Scream & Shout", _rows([["will.i.am", "This Is Love"]])), 0)
        var name = ""
        for (var i = 0; i < 300; i++) name += "t.A.T.u. "
        compare(SL.artArtistScore(name, name.toUpperCase()), 2)
    }

    // Initials are read off the names as written: "&" is no word and N' is.
    function test_initials_still_count_as_they_did() {
        compare(SL.artArtistScore("CSNY", "Crosby, Stills, Nash & Young"), 2)
        compare(SL.artArtistScore("Crosby, Stills, Nash & Young", "CSNY"), 2)
        compare(SL.artArtistScore("GNR", "Guns N' Roses"), 2)
        compare(SL.artArtistScore("BWO", "Bodies Without Organs"), 2)
        compare(SL.artArtistScore("AC", "AC/DC"), 0)
    }

    // The names Deezer's artist search put first for live lines, 2026-11-02.
    function test_an_artist_photo_needs_the_same_name() {
        verify(!SL.artPhotoTakes("Love & Fate", "Love"))
        verify(!SL.artPhotoTakes("Klassik Radio", "KLASSIK RADIO POPS ORCHESTRA"))
        verify(!SL.artPhotoTakes("Nancy", "NANCY & SIDOROV"))
        verify(!SL.artPhotoTakes("Florence", "Florence & The Bare Souls"))
        verify(!SL.artPhotoTakes("Blues music", "Blues Music King"))
        // Contained the other way round is no better: the price is Grieg.
        verify(!SL.artPhotoTakes("Edvard Grieg", "Grieg"))
        // Same letters, other act: the dash and the dots are part of the name.
        verify(!SL.artPhotoTakes("ELP", "EL–P"))
        verify(!SL.artPhotoTakes("Aura", "AURA..."))
    }

    function test_an_artist_photo_forgives_case_accents_quotes_and_and() {
        verify(SL.artPhotoTakes("Simon & Garfunkel", "Simon & Garfunkel"))
        verify(SL.artPhotoTakes("Florence and the Machine", "Florence + The Machine"))
        verify(SL.artPhotoTakes("Guns N` Roses", "Guns N' Roses"))
        verify(SL.artPhotoTakes("STEVIE RAY VAUGHAN", "Stevie Ray Vaughan"))
        verify(SL.artPhotoTakes("Bjork", "Björk"))
        verify(SL.artPhotoTakes("Кино", "КИНО"))
        verify(!SL.artPhotoTakes("", ""))
        verify(!SL.artPhotoTakes("   ", "   "))
        verify(!SL.artPhotoTakes(null, "Queen"))
        verify(!SL.artPhotoTakes("Queen", undefined))
        var name = ""
        for (var i = 0; i < 400; i++) name += "Band & "
        verify(SL.artPhotoTakes(name + "Friends", name.replace(/&/g, "and") + "FRIENDS"))
    }

    // Jazz Radio Blues and SWR3 send some songs title first. The rows are the
    // ones the free-text search returned for those very lines.
    function test_a_reversed_line_finds_its_record() {
        compare(SL.artPickEither("A bar song (Tipsy)", "Shaboozey", _rows([
            ["Shaboozey", "A Bar Song (Tipsy)"], ["Shaboozey", "A Bar Song (Tipsy) [Remix]"],
            ["CoverSideMusic", "A Bar Song (Irish Folk)"],
            ["Piano Covers", "Shaboozey - A Bar Song (Tipsy) - Piano Cover"]])), 0)
        compare(SL.artPickEither("Lenny", "STEVIE RAY VAUGHAN", _rows([
            ["Stevie Ray Vaughan & Double Trouble", "Lenny"],
            ["Stevie Ray Vaughan", "Lenny (Live) (Remastered)"],
            ["Pickin' On Series", "Lenny"],
            ["Albert 2 Stone", "Lenny (Karaoke Version) (Originally Performed By Stevie Ray Vaughan)"],
            ["Howard Hart", "The Things I Used to Do"]])), 0)
        compare(SL.artPickEither("Better days", "Glockenbach feat. Declan J Donovan",
                                 _rows([["Glockenbach", "Better Days"]])), 0)
        // iTunes' rows for "Goin’ to chicago - KURT ELLING": the curly
        // apostrophe on the air and the straight one in the catalogue.
        compare(SL.artPickEither("Goin’ to chicago", "KURT ELLING", _rows([
            ["Kurt Elling", "Goin' to Chicago (Live)"],
            ["Kurt Elling & Charlie Hunter", "Goin’ to Chicago (feat. Huntertones)"],
            ["Van Morrison", "Ain't Gonna Moan No More (feat. Kurt Elling)"],
            ["Kurt Elling", "Nightmoves"]])), 0)
        compare(SL.artPickEither("Rendezvous with the blues", "MELVIN TAYLOR", _rows([
            ["Melvin Taylor", "Help The Poor"], ["Melvin Taylor", "Rendezvous With The Blues"],
            ["Melvin Taylor", "Blue Jean Blues"]])), 1)
    }

    function test_the_swapped_reading_needs_the_title_too() {
        var other = _rows([["Kurt Elling", "Nature Boy"]])
        compare(SL.artPickEither("Goin’ to chicago", "KURT ELLING", other), -1)
        // Read the right way round, the artist's other record still counts.
        compare(SL.artPick("KURT ELLING", "Goin’ to chicago", other), 0)
        compare(SL.artPick("KURT ELLING", "Goin’ to chicago", other, true), -1)
        // A tribute pressing named after the song is no way in either.
        compare(SL.artPickEither("OneRepublic", "Counting Stars", _rows([
            ["Counting Stars", "Counting Stars - Tribute to OneRepublic"],
            ["Counting By 2's", "Counting Stars (OneRepublic Cover)"]])), -1)
        // A song called "John Williams" pulls none of John Williams' records
        // when the swapped reading makes the song title the artist.
        compare(SL.artPickEither("Fado Tradicional", "John Williams", _rows([
            ["John Williams", "Star Wars (Main Theme)"]])), -1)
    }

    function test_the_normal_reading_comes_first_and_empty_halves_do_not_swap() {
        // "Kuule, mees!" for "Curly Strings - Kuu" stays the band's own record.
        compare(SL.artPickEither("Curly Strings", "Kuu", _rows([["Curly Strings", "Kuule, mees!"]])), 0)
        var rows = _rows([["Lenny", "Stevie Ray Vaughan"], ["Stevie Ray Vaughan", "Lenny"]])
        compare(SL.artPickEither("Lenny", "Stevie Ray Vaughan", rows), 0)
        compare(SL.artPickEither("Lenny", "", _rows([["Stevie Ray Vaughan", "Lenny"]])), -1)
        compare(SL.artPickEither("", "Lenny", _rows([["Lenny", "Something Else"]])), -1)
        compare(SL.artPickEither("  ", "Lenny", _rows([["Lenny", "Something Else"]])), -1)
        compare(SL.artPickEither(null, null, rows), -1)
        compare(SL.artPickEither("A", "B", []), -1)
        compare(SL.artPickEither("A", "B", null), -1)
        var many = []
        for (var i = 0; i < 999; i++) many.push(["Somebody " + i, "Song " + i])
        many.push(["Melvin Taylor", "Rendezvous With The Blues"])
        compare(SL.artPickEither("Rendezvous with the blues", "MELVIN TAYLOR", _rows(many)), 999)
    }

    // iTunes' answer to term=Anne Loho&entity=song&limit=25, recorded
    // 2026-11-02 (artistName, trackName, and whether artworkUrl100 was set).
    // Elmari tantsuõhtu played her "Uus algus", which no catalogue has.
    function _anneLoho() {
        var rows = [
            ["Roderic H & Anne Loho", "Next To Me"], ["Roderic H & Anne Loho", "All I Need Is You"],
            ["Roderic H & Anne Loho", "Hellitavad tuuled (Roderic H Club Remix)"],
            ["Roderic H & Anne Loho", "Pöörane"], ["Bennex", "sa suudad (feat. Anne Loho)"],
            ["Bennex", "õhtu on noor (feat. Anne Loho)"], ["Roderic H & Anne Loho", "Hellitavad Tuuled"],
            ["Roderic H & Anne Loho", "Hellitavad tuuled (Roderic H Club Remix Extended)"],
            ["Roderic H & Anne Loho", "All I Need Is You (Extended Mix)"], ["Anne Loho", "Hinges Prii"],
            ["Anne Loho", "Rannaliiva peitsin tiivad (feat. SunshineBand)"], ["Anne Loho", "Tagatulede valgus"],
            ["Rivo Rehe", "Suvesaladus (feat. Anne Loho)"], ["Bennex", "Pöial Liisi (feat. Anne Loho & Ave Altmäe)"],
            ["Anne Loo", "Why Don't We Run Away"], ["Anne Loo", "Girl Who Rocks Your World"]]
        return rows.map(function(r) { return { artist: r[0], title: r[1], art: "https://is1-ssl.mzstatic.com/x/100x100bb.jpg" } })
    }

    function test_the_artists_own_song_is_the_last_resort() {
        compare(SL.artPickByArtist("Anne Loho", _anneLoho()), 9)
        compare(SL.artPickByArtist("ANNE LOHO", _anneLoho()), 9)
        compare(SL.artPickByArtist("G LOVE AND SPECIAL SAUCE", [
            { artist: "G. Love & Special Sauce", title: "Rodeo Clowns", art: "a" }]), 0)
    }

    function test_only_the_artist_herself_counts() {
        var rows = _anneLoho()
        // A guest spot, a duo and a namesake one letter off are not hers.
        compare(SL.artPickByArtist("Anne Loho", rows.slice(12)), -1)
        compare(SL.artPickByArtist("Anne Loho", rows.slice(0, 9)), -1)
        compare(SL.artPickByArtist("Anne Loho", rows.slice(14)), -1)
        // The credit is matched whole, never split.
        compare(SL.artPickByArtist("Roderic H & Anne Loho", rows), 0)
        compare(SL.artPickByArtist("Roderic H", rows), -1)
        // A row without a picture is passed over; so is a karaoke pressing.
        compare(SL.artPickByArtist("Anne Loho", [
            { artist: "Anne Loho", title: "Hinges Prii", art: "" },
            { artist: "Anne Loho", title: "Hinges Prii (Karaoke Version)", art: "a" },
            { artist: "Anne Loho", title: "Tagatulede valgus", art: "a" }]), 2)
    }

    function test_the_last_resort_with_nothing_to_go_on() {
        compare(SL.artPickByArtist("", _anneLoho()), -1)
        compare(SL.artPickByArtist(null, _anneLoho()), -1)
        compare(SL.artPickByArtist("Anne Loho", []), -1)
        compare(SL.artPickByArtist("Anne Loho", null), -1)
        compare(SL.artPickByArtist("Anne Loho", [null, {}]), -1)
        var many = []
        for (var i = 0; i < 999; i++) many.push({ artist: "Anne Loo", title: "Song " + i, art: "a" })
        many.push({ artist: "Anne Loho", title: "Hinges Prii", art: "a" })
        compare(SL.artPickByArtist("Anne Loho", many), 999)
    }

    function test_a_stranger_is_still_a_stranger() {
        compare(SL.artPick("Кино", "Группа крови", _rows([["Кино", "Группа крови"]])), 0)
        compare(SL.artPick("Кино", "Группа крови", _rows([["Мумий Тролль", "Группа крови"]])), -1)
        compare(SL.artArtistScore("Би-2", "Звери 2"), 0)
        // "!!!" must not fold to nothing and turn into a title-only match.
        compare(SL.artPick("!!!", "Heart of Hearts", _rows([["Someone Else", "Heart of Hearts"]])), -1)
        compare(SL.artArtistScore("", "Anyone"), 0)
        compare(SL.artArtistScore(null, null), 0)
    }
}
