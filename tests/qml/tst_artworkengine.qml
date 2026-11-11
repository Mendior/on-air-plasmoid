// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The artwork engine's cache and stale-clear logic, driven through a mock
// app. The network calls (_queryDeezer/_queryItunes) fire real XHRs, so the
// tests exercise the parts that decide WITHOUT the network: the bounded
// cache with its negative TTL, and the guarantee that a new track never
// wears the previous track's cover.
import QtQuick
import QtTest
import "../../package/contents/ui"

TestCase {
    id: tc
    name: "ArtworkEngine"

    property string curKey: ""
    // Every request the engine sends arms its timeout first.
    property int armed: 0

    Component {
        id: engineComp
        ArtworkEngine {}
    }

    function makeEngine(artEnabled, station) {
        tc.armed = 0;
        var cfg = { albumArtEnabled: artEnabled !== false };
        var app = {
            playerSourceString: function() { return ""; },
            _localArtForSource: "",
            currentStation: station || "",
            trackArtistTitleKey: function() { return tc.curKey; },
            _armXhrTimeout: function() { tc.armed++; },
            _clearXhrTimeout: function() {}
        };
        return engineComp.createObject(tc, { app: app, cfg: cfg });
    }

    // The debounce fires lookupAlbumArt; with album art switched off that
    // call clears albumArtUrl, which makes the moment it fires visible
    // without the network.
    function test_the_first_title_of_a_station_does_not_wait_out_the_debounce() {
        var e = makeEngine(false);
        e.albumArtUrl = "http://x/marker.jpg";
        e._artLookupPendingRaw = "Artist - Song";
        // The header went empty a moment ago, as it does on a station
        // switch, so only being the first title can spare this one the wait.
        e.debounceStop();
        e.debounceRestart(true);
        wait(500);
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    function test_a_changing_title_still_waits_for_a_stable_window() {
        var e = makeEngine(false);
        e.albumArtUrl = "http://x/marker.jpg";
        e._artLookupPendingRaw = "Artist - Song";
        e.debounceRestart(true);      // a first title came…
        e.debounceRestart();          // …and flapped before it fired
        wait(500);
        compare(e.albumArtUrl, "http://x/marker.jpg");
        wait(1300);
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    // An ordinary song change: the title before it stood for minutes, so
    // there is no flap to wait out. Every one of them used to wait 1.5 s.
    function test_a_title_after_a_quiet_stretch_does_not_wait_out_the_flap_window() {
        var e = makeEngine(false);
        e._artLookupPendingRaw = "Artist - Song";
        e.albumArtUrl = "http://x/marker.jpg";
        e._artKeyMovedAt = Date.now() - 5000;     // the song has played for five seconds
        e.debounceRestart();                      // the next one starts
        wait(500);
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    // A title the cache settled is a change of title all the same, and so is
    // a header that went empty: the one after either is inside the window.
    function test_a_title_right_after_a_settled_one_waits_for_the_window() {
        var e = makeEngine(false);
        e.albumArtUrl = "http://x/marker.jpg";
        e._artLookupPendingRaw = "Artist - Song";
        e._artKeyMovedAt = Date.now() - 60000;
        e.debounceStop();                         // a cached title came and was painted
        e.debounceRestart();                      // and flapped to another at once
        wait(500);
        compare(e.albumArtUrl, "http://x/marker.jpg");
        e.destroy();
    }

    function test_a_definitive_miss_is_cached_and_answered_from_cache() {
        var e = makeEngine();
        tc.curKey = "artist|song";
        e._artFinish("artist|song", "", true);        // definitive: no art
        // _artFromCache returns true (settled) even for a fresh miss.
        verify(e._artFromCache("artist|song", "artist"));
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    function test_a_found_cover_is_applied_only_to_the_current_track() {
        var e = makeEngine();
        tc.curKey = "a|b";
        e._artFinish("a|b", "http://x/cover.jpg", true);
        compare(e.albumArtUrl, "http://x/cover.jpg");
        // A cover that arrives for a track we already left is cached but
        // never painted over what plays now.
        tc.curKey = "c|d";
        e._artFinish("stale|key", "http://x/old.jpg", true);
        compare(e.albumArtUrl, "http://x/cover.jpg");
        e.destroy();
    }

    function test_the_cache_is_bounded_at_two_hundred() {
        var e = makeEngine();
        for (var i = 0; i < 250; i++) {
            tc.curKey = "k" + i;
            e._artFinish("k" + i, "http://x/" + i + ".jpg", true);
        }
        // The oldest keys were evicted; the newest survive.
        verify(!e._artFromCache("k0", "artist"));
        verify(e._artFromCache("k249", "artist"));
        e.destroy();
    }

    function test_disabling_album_art_clears_and_looks_up_nothing() {
        var e = makeEngine(false);
        e.albumArtUrl = "http://x/left.jpg";
        e.lookupAlbumArt("Someone - A Song");
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    function test_an_empty_title_paints_no_cover() {
        var e = makeEngine();
        e.albumArtUrl = "http://x/prev.jpg";
        e.lookupAlbumArt("");
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    // Seen on the bench 2026-09-23: Dance Wave! sends its own name as the
    // title, iTunes found an album of that name, and the palm-tree sleeve
    // went to the popup and to MPRIS. The station's logo belongs there.
    function test_the_station_saying_its_name_asks_nobody_for_a_cover() {
        var e = makeEngine(true, "Dance Wave!");
        tc.curKey = "Dance Wave!";
        e.albumArtUrl = "http://x/previous-song.jpg";
        e._albumArtKey = "previous song";
        e.lookupAlbumArt("Dance Wave!");
        compare(tc.armed, 0);
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    // The metadata handler paints from the cache before any lookup runs, and
    // the second "Dance Wave!" of the bench run came back that way, at once.
    function test_a_cached_cover_is_not_painted_over_the_station_name() {
        var e = makeEngine(true, "Dance Wave!");
        tc.curKey = "elsewhere";
        e._artFinish("Dance Wave!", "http://x/palm.jpg", true);
        tc.curKey = "Dance Wave!";
        verify(e._artFromCache("Dance Wave!", ""));
        compare(e.albumArtUrl, "");
        e.destroy();
        // On another station the same words are not the station talking, but
        // with no artist they are no song either, so the sleeve stays unpainted.
        e = makeEngine(true, "Radio Elmar");
        tc.curKey = "elsewhere";
        e._artFinish("Dance Wave!", "http://x/palm.jpg", true);
        verify(e._artFromCache("Dance Wave!", ""));
        compare(e.albumArtUrl, "");
        // Give them an artist and they are a song like any other.
        e._artFinish("DJ Mike Dance Wave!", "http://x/mix.jpg", true);
        verify(e._artFromCache("DJ Mike Dance Wave!", "DJ Mike"));
        compare(e.albumArtUrl, "http://x/mix.jpg");
        e.destroy();
    }

    // Deutschlandfunk, 2026-11-02: the news hour is "Nachrichten", no artist,
    // and the free-text search hung a Kraftwerk tribute sleeve on it.
    function test_a_line_without_an_artist_asks_nobody_for_a_cover() {
        var e = makeEngine(true, "Deutschlandfunk");
        tc.curKey = "Nachrichten";
        e.albumArtUrl = "http://x/previous-song.jpg";
        e._albumArtKey = "previous song";
        e.lookupAlbumArt("Nachrichten");
        compare(tc.armed, 0);
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    // A cover cached for an artist-less line stays in the cache and off the
    // panel. The door still says settled, so no lookup starts behind it.
    function test_a_cached_cover_is_not_painted_over_a_line_without_an_artist() {
        var e = makeEngine(true, "Deutschlandfunk");
        tc.curKey = "elsewhere";
        e._artFinish("Nachrichten", "http://x/tribute.jpg", true);
        tc.curKey = "Nachrichten";
        verify(e._artFromCache("Nachrichten", ""));
        compare(e.albumArtUrl, "");
        verify(e._artFromCache("Nachrichten"));
        compare(e.albumArtUrl, "");
        verify(e._artFromCache("Nachrichten", null));
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    // The station's own name split like a song: "Radio Paradise - Main Mix"
    // parses with an artist, so only the station check keeps it off the
    // network, and that check has to know which station is playing.
    function test_the_station_name_split_like_a_song_asks_nobody_for_a_cover() {
        var e = makeEngine(true, "Radio Paradise - Main Mix (EN)");
        tc.curKey = "Radio Paradise Main Mix";
        e.lookupAlbumArt("Radio Paradise - Main Mix");
        compare(tc.armed, 0);
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    function test_a_web_address_in_the_title_asks_nobody_for_a_cover() {
        var e = makeEngine(true, "Dance Wave!");
        tc.curKey = "Tracklist: https://dancewave.online/";
        e.lookupAlbumArt("Tracklist: https://dancewave.online/");
        compare(tc.armed, 0);
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    function _svcs(plan) {
        return plan.map(function(a) { return a.svc; });
    }

    // Elmari tantsuõhtu, 2026-11-02: "Anne Loho - Uus algus" is in no
    // catalogue, and Deezer does not know her, but iTunes has her singles.
    function test_the_artists_own_songs_are_asked_for_last() {
        var e = makeEngine(true, "Elmari tantsuõhtu 24/7");
        var plan = e._artPlan({ artist: "Anne Loho", title: "Uus algus" }, "Anne Loho Uus algus",
                              "Anne Loho - Uus algus");
        var last = plan[plan.length - 1];
        compare(last.svc, "itunesArtist");
        compare(last.q, "Anne Loho");
        compare(plan[plan.length - 2].svc, "deezerArtist");
        compare(_svcs(plan).filter(function(s) { return s === "itunesArtist"; }).length, 1);
        // The whole credit goes out, guest and all.
        plan = e._artPlan({ artist: "Frontliner feat. Ellie", title: "Lose The Style" },
                          "Frontliner feat. Ellie Lose The Style", "Frontliner feat. Ellie - Lose The Style");
        compare(plan[plan.length - 1].q, "Frontliner feat. Ellie");
        e.destroy();
    }

    // Deezer reads track:"…" as the title and nothing else. Asked for
    // track:"Kaotand pea (2026)" it answered total 0, and for track:"Kaotand
    // pea" it had "Marco Margna / Kaotand pea (Radio Edit)".
    function test_the_field_search_asks_for_the_title_without_its_brackets() {
        var e = makeEngine(true, "Raadio");
        var field = function(title) {
            return e._artPlan({ artist: "Marco Margna", title: title }, "Marco Margna Kaotand pea",
                              "Marco Margna - " + title)[1];
        };
        compare(field("Kaotand pea (2026)").q, 'track:"Kaotand pea"');
        compare(field("Kaotand pea (2026)").svc, "deezer");
        compare(field("Enter Sandman [Remastered 2021] 320kbps").q, 'track:"Enter Sandman"');
        compare(field("(I Can't Get No) Satisfaction").q, 'track:"Satisfaction"');
        compare(field('Say "Hello" (Live)').q, 'track:"Say Hello"');
        // A title with nothing to take out goes as it came.
        compare(field("Uus algus").q, 'track:"Uus algus"');
        // A bracket that never closes is no aside, and a title that is one
        // aside and nothing else is still asked for rather than nothing.
        compare(field("Kaotand pea (2026").q, 'track:"Kaotand pea (2026"');
        compare(field("(Intro)").q, 'track:"(Intro)"');
        compare(field("").q, 'track:""');
        compare(field(undefined).q, 'track:""');
        var longTitle = "";
        for (var i = 0; i < 400; i++) longTitle += "Pea ";
        compare(field(longTitle + "(Extended Club Mix)").q, 'track:"' + longTitle.trim() + '"');
        e.destroy();
    }

    // "Nightlight Duo (Rita Liiver & Elise Mängel) - Armid näol": one of the
    // requests went out as "Nightlight Duo (Rita Liiver Armid näol".
    function test_no_request_goes_out_with_a_bracket_left_open() {
        var e = makeEngine(true, "Raadio");
        var plan = e._artPlan({ artist: "Nightlight Duo (Rita Liiver & Elise Mängel)", title: "Armid näol" },
                              "Nightlight Duo Armid näol",
                              "Nightlight Duo (Rita Liiver & Elise Mängel) - Armid näol");
        verify(plan.length >= 3);
        for (var i = 0; i < plan.length; i++)
            compare(plan[i].q.split("(").length, plan[i].q.split(")").length, plan[i].svc + ": " + plan[i].q);
        // The first-billed name is the duo, so that request is the plain one
        // again and is not sent twice.
        compare(plan.filter(function(a) { return a.q === "Nightlight Duo Armid näol"; }).length, 2);
        compare(_svcs(plan).filter(function(s) { return s === "deezer"; }).length, 2);
        e.destroy();
    }

    // The artist behind the station's own name gets neither the photo nor
    // the artist's other songs: on Kaaosradio such names were namesakes.
    function test_an_artist_found_behind_the_station_name_gets_no_last_resort() {
        var e = makeEngine(true, "Kaaosradio - 24h Chill");
        var plan = e._artPlan({ artist: "Organoid", title: "Metamorphosis" }, "Organoid Metamorphosis",
                              "Kaaosradio 24h - Organoid - Metamorphosis");
        compare(_svcs(plan).indexOf("deezerArtist"), -1);
        compare(_svcs(plan).indexOf("itunesArtist"), -1);
        verify(plan.length > 0);
        e.destroy();
    }

    // Nothing after the first cover found is asked; a chain where everything
    // answered "no" is a definitive miss, cached like any other.
    function test_the_chain_stops_at_the_first_cover() {
        var e = makeEngine();
        tc.curKey = "anne loho uus algus";
        var asked = [];
        var hit = function(q, key, onResult) { asked.push(q); onResult("http://x/sleeve.jpg", true); };
        var miss = function(q, key, onResult) { asked.push(q); onResult("", true); };
        e._runAttempts([{ fn: miss, q: "a" }, { fn: hit, q: "b" }, { fn: miss, q: "last" }],
                       "anne loho uus algus", { artist: "Anne Loho", title: "Uus algus" });
        compare(asked, ["a", "b"]);
        compare(e.albumArtUrl, "http://x/sleeve.jpg");
        asked = [];
        tc.curKey = "nobody has it";
        e._runAttempts([{ fn: miss, q: "a" }, { fn: miss, q: "last" }], "nobody has it", {});
        compare(asked, ["a", "last"]);
        compare(e._artCache["nobody has it"].url, "");
        verify(e._artFromCache("nobody has it", "Nobody"));
        e.destroy();
    }

    // A chain of fake requests for the retry tests. answers[n] is what the
    // nth run of the chain ends on: "timeout" (transient), "none" (everybody
    // said no) or a cover's address. again() is what the engine is handed
    // to start the lookup over, as lookupAlbumArt hands it itself.
    function _chain(e, key, answers) {
        var c = { calls: 0, runs: 0 };
        var step = function(q, k, onResult) {
            c.calls++;
            var a = answers[Math.min(c.runs, answers.length) - 1];
            if (a === "timeout") onResult("", false);
            else if (a === "none") onResult("", true);
            else onResult(q === "second" ? a : "", true);
        };
        c.again = function() {
            c.runs++;
            e._runAttempts([{ fn: step, q: "first" }, { fn: step, q: "second" }], key,
                           { artist: "Artist", title: "Song" }, c.again);
        };
        return c;
    }

    // Measured with the real engine and two timeouts: two requests, nothing
    // cached, no cover, and still two requests 3.5 s later. The song stayed
    // bare for its whole play.
    function test_a_transient_miss_is_asked_once_more_while_the_title_stands() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var c = _chain(e, "artist song", ["timeout", "http://x/second-try.jpg"]);
        c.again();
        compare(c.calls, 2);
        compare(e.albumArtUrl, "");
        verify(e._artCache["artist song"] === undefined);
        verify(e._artRetryArmed);
        compare(e._artRetryWaitMs, 25000);
        e._artAskAgain();                 // 25 s later
        compare(c.calls, 4);
        compare(e.albumArtUrl, "http://x/second-try.jpg");
        verify(!e._artRetryArmed);
        e.destroy();
    }

    function test_a_transient_miss_is_not_asked_again_after_the_track_changed() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var c = _chain(e, "artist song", ["timeout", "http://x/late.jpg"]);
        c.again();
        verify(e._artRetryArmed);
        tc.curKey = "next artist next song";
        e._artAskAgain();
        compare(c.calls, 2);
        compare(e.albumArtUrl, "");
        verify(!e._artRetryArmed);
        // Nor when the covers were switched off while it waited.
        tc.curKey = "other song";
        c = _chain(e, "other song", ["timeout", "http://x/late.jpg"]);
        c.again();
        verify(e._artRetryArmed);
        e.cfg.albumArtEnabled = false;
        e._artAskAgain();
        compare(c.calls, 2);
        e.destroy();
    }

    function test_a_transient_miss_is_not_asked_a_third_time() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var c = _chain(e, "artist song", ["timeout"]);
        c.again();
        verify(e._artRetryArmed);
        e._artAskAgain();
        compare(c.calls, 4);
        // The second attempt timed out as well, and that is the end of it.
        verify(!e._artRetryArmed);
        e._artAskAgain();
        compare(c.calls, 4);
        compare(e.albumArtUrl, "");
        // The same title coming round again gets its lookup, as it always
        // did, but no second attempt on top of that.
        c.again();
        compare(c.calls, 6);
        verify(!e._artRetryArmed);
        e.destroy();
    }

    // Everybody saying no is an answer, and a chain nobody can start over
    // (the tests' own three-argument calls) has nothing to ask again with.
    function test_only_a_transient_end_is_asked_again() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var c = _chain(e, "artist song", ["none"]);
        c.again();
        compare(c.calls, 2);
        verify(!e._artRetryArmed);
        compare(e._artCache["artist song"].url, "");
        tc.curKey = "another song";
        var asked = 0;
        var timeout = function(q, key, onResult) { asked++; onResult("", false); };
        e._runAttempts([{ fn: timeout, q: "a" }], "another song", {});
        compare(asked, 1);
        verify(!e._artRetryArmed);
        e._artAskAgain();
        compare(asked, 1);
        // A cover found after a timeout earlier in the chain is a cover.
        tc.curKey = "third song";
        c = _chain(e, "third song", ["http://x/found.jpg"]);
        var hiccup = function(q, key, onResult) { onResult("", false); };
        var hit = function(q, key, onResult) { onResult("http://x/found.jpg", true); };
        e._runAttempts([{ fn: hiccup, q: "a" }, { fn: hit, q: "b" }], "third song", {}, c.again);
        compare(e.albumArtUrl, "http://x/found.jpg");
        verify(!e._artRetryArmed);
        compare(c.calls, 0);
        e.destroy();
    }

    function test_a_new_track_drops_the_previous_cover_before_the_network() {
        var e = makeEngine();
        // A settled cover for the current track…
        tc.curKey = "old|one";
        e._artFinish("old one", "http://x/old.jpg", true);
        e._albumArtKey = "old one";
        e.albumArtUrl = "http://x/old.jpg";
        // …a lookup for a different, uncached track clears it at once, so the
        // old sleeve never poses over the new song while the network answers.
        e.lookupAlbumArt("New Artist - New Song");
        compare(e.albumArtUrl, "");
        e.destroy();
    }
}
