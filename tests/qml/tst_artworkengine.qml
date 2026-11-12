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
import "../../package/contents/ui/TrackLogic.js" as TL
import "CoverAnswers.js" as Answers

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
        e._artFinish("a|b", "http://x/cover.jpg", true, "track");
        compare(e.albumArtUrl, "http://x/cover.jpg");
        // A cover that arrives for a track we already left is cached but
        // never painted over what plays now.
        tc.curKey = "c|d";
        e._artFinish("stale|key", "http://x/old.jpg", true, "track");
        compare(e.albumArtUrl, "http://x/cover.jpg");
        e.destroy();
    }

    function test_the_cache_is_bounded_at_two_hundred() {
        var e = makeEngine();
        for (var i = 0; i < 250; i++) {
            tc.curKey = "k" + i;
            e._artFinish("k" + i, "http://x/" + i + ".jpg", true, "track");
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
        e._artFinish("Dance Wave!", "http://x/palm.jpg", true, "track");
        tc.curKey = "Dance Wave!";
        verify(e._artFromCache("Dance Wave!", ""));
        compare(e.albumArtUrl, "");
        e.destroy();
        // On another station the same words are not the station talking, but
        // with no artist they are no song either, so the sleeve stays unpainted.
        e = makeEngine(true, "Radio Elmar");
        tc.curKey = "elsewhere";
        e._artFinish("Dance Wave!", "http://x/palm.jpg", true, "track");
        verify(e._artFromCache("Dance Wave!", ""));
        compare(e.albumArtUrl, "");
        // Give them an artist and they are a song like any other.
        e._artFinish("DJ Mike Dance Wave!", "http://x/mix.jpg", true, "track");
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
        e._artFinish("Nachrichten", "http://x/tribute.jpg", true, "track");
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
        var hit = function(q, key, onResult) { asked.push(q); onResult("http://x/sleeve.jpg", true, "track"); };
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
            else onResult(q === "second" ? a : "", true, q === "second" ? "track" : "");
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
        var hit = function(q, key, onResult) { onResult("http://x/found.jpg", true, "track"); };
        e._runAttempts([{ fn: hiccup, q: "a" }, { fn: hit, q: "b" }], "third song", {}, c.again);
        compare(e.albumArtUrl, "http://x/found.jpg");
        verify(!e._artRetryArmed);
        compare(c.calls, 0);
        e.destroy();
    }

    // Requests that stay in the air until the test answers them: asked lists
    // what went out, answer[n] is the nth request's way home.
    function _held(e, key, count) {
        var h = { asked: [], answer: [] };
        var step = function(q, k, onResult) { h.asked.push(q); h.answer.push(onResult); };
        var plan = [];
        for (var i = 0; i < count; i++) plan.push({ fn: step, q: "q" + i });
        e._runAttempts(plan, key, { artist: "Artist", title: "Song" });
        return h;
    }

    // The online covers are switched off while the first request is in the
    // air. Its empty answer used to send the second one, because the chain
    // only asked whether the track was still the same. Measured with the
    // real engine: two requests where one was due.
    function test_covers_switched_off_end_a_chain_that_is_in_the_air() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var h = _held(e, "artist song", 3);
        compare(h.asked, ["q0"]);
        e.cfg.albumArtEnabled = false;
        h.answer[0]("", true);
        compare(h.asked, ["q0"]);
        // The chain did not reach its end, so the track is not filed as coverless.
        verify(e._artCache["artist song"] === undefined);
        e.destroy();
    }

    // The request that was in the air may come home with a cover. It is not
    // painted: the listener has just said no to covers from the network.
    function test_a_cover_that_comes_home_after_the_switch_is_not_painted() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var h = _held(e, "artist song", 2);
        e.cfg.albumArtEnabled = false;
        h.answer[0]("http://x/late.jpg", true, "track");
        compare(e.albumArtUrl, "");
        verify(e._artCache["artist song"] === undefined);
        compare(h.asked, ["q0"]);
        e.destroy();
    }

    function test_covers_switched_back_on_are_looked_up_again() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var h = _held(e, "artist song", 2);
        e.cfg.albumArtEnabled = false;
        h.answer[0]("", true);
        e.cfg.albumArtEnabled = true;
        // The chain that was cut stays cut: its late word starts nothing.
        compare(h.asked, ["q0"]);
        var again = _held(e, "artist song", 2);
        compare(again.asked, ["q0"]);
        again.answer[0]("", true);
        compare(again.asked, ["q0", "q1"]);
        again.answer[1]("http://x/sleeve.jpg", true, "track");
        compare(e.albumArtUrl, "http://x/sleeve.jpg");
        e.destroy();
    }

    // Off and on again before the answer is home: the lookup is wanted at the
    // moment that counts, and the one chain goes on.
    function test_a_switch_flicked_off_and_on_in_the_air_keeps_its_chain() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var h = _held(e, "artist song", 2);
        e.cfg.albumArtEnabled = false;
        e.cfg.albumArtEnabled = true;
        h.answer[0]("", true);
        compare(h.asked, ["q0", "q1"]);
        e.destroy();
    }

    function test_a_track_change_ends_a_chain_that_is_in_the_air() {
        var e = makeEngine();
        tc.curKey = "artist song";
        var h = _held(e, "artist song", 3);
        tc.curKey = "next artist next song";
        h.answer[0]("", true);
        compare(h.asked, ["q0"]);
        e.destroy();
    }

    // A long plan, cut after its third answer: the fourth request and the
    // thirty-six behind it stay home. A switch that reads as nothing counts
    // as off, the way lookupAlbumArt's own door reads it.
    function test_a_long_chain_stops_where_the_switch_went_off_data() {
        return [
            { tag: "false", off: false },
            { tag: "undefined", off: undefined },
            { tag: "null", off: null },
            { tag: "zero", off: 0 },
            { tag: "empty text", off: "" }
        ];
    }
    function test_a_long_chain_stops_where_the_switch_went_off(data) {
        var e = makeEngine();
        tc.curKey = "artist song";
        var h = _held(e, "artist song", 40);
        h.answer[0]("", true);
        h.answer[1]("", false);
        compare(h.asked, ["q0", "q1", "q2"]);
        e.cfg.albumArtEnabled = data.off;
        h.answer[2]("", true);
        compare(h.asked.length, 3);
        verify(!e._artRetryArmed);
        e.destroy();
    }

    function test_a_new_track_drops_the_previous_cover_before_the_network() {
        var e = makeEngine();
        // A settled cover for the current track…
        tc.curKey = "old|one";
        e._artFinish("old one", "http://x/old.jpg", true, "track");
        e._albumArtKey = "old one";
        e.albumArtUrl = "http://x/old.jpg";
        // …a lookup for a different, uncached track clears it at once, so the
        // old sleeve never poses over the new song while the network answers.
        e.lookupAlbumArt("New Artist - New Song");
        compare(e.albumArtUrl, "");
        e.destroy();
    }

    // ── What a picture is of ────────────────────────────────────────────────
    // The lookup key main.qml would hold for a title line.
    function _key(line, station) {
        var parsed = TL.parseTrackString(TL.preCleanTrack(line, station || ""));
        return TL.normalizeQuery((parsed.artist + " " + parsed.title).trim() || line);
    }

    // A catalogue the engine asks in place of the network. book maps a
    // request, written "deezer <words>", "itunes <words>", "deezerArtist
    // <name>" or "itunesArtist <name>", to what it is answered: an object is
    // a 200 with that body, text a 200 with that text, a number that status
    // and no body, { status, body } that status with that body. A request
    // the book does not have gets the service's own "nothing found". With
    // hold set the answers wait in held[] to be called.
    function _catalogue(e, book) {
        var c = { asked: [], held: [], hold: false };
        var doors = [
            ["deezerArtist", /^https:\/\/api\.deezer\.com\/search\/artist\?q=(.*)&limit=1$/],
            ["deezer", /^https:\/\/api\.deezer\.com\/search\?q=(.*)&limit=10$/],
            ["itunesArtist", /^https:\/\/itunes\.apple\.com\/search\?term=(.*)&entity=song&limit=25$/],
            ["itunes", /^https:\/\/itunes\.apple\.com\/search\?term=(.*)&entity=song&limit=10&media=music$/]
        ];
        e._fetch = function(address, done) {
            var name = "";
            for (var i = 0; i < doors.length && name === ""; i++) {
                var m = doors[i][1].exec(address);
                if (m) name = doors[i][0] + " " + decodeURIComponent(m[1]);
            }
            verify(name !== "", "a request to an address nobody knows: " + address);
            c.asked.push(name);
            var a = book[name];
            if (a === undefined) a = name.indexOf("deezer") === 0 ? Answers.deezerNothing : Answers.itunesNothing;
            var answer = function() {
                if (typeof a === "number") done(a, "");
                else if (a.status !== undefined && a.body !== undefined) done(a.status, JSON.stringify(a.body));
                else done(200, typeof a === "string" ? a : JSON.stringify(a));
            };
            if (c.hold) c.held.push(answer);
            else answer();
        };
        return c;
    }

    // Starts the lookup the way a new title does.
    function _play(e, line, station) {
        tc.curKey = _key(line, station);
        e.lookupAlbumArt(line);
    }

    // A Deezer song row that was not recorded: an artist's record under some title.
    function _deezerRow(artist, title, sleeve) {
        return { title: title, artist: { name: artist, picture_medium: "" },
                 album: { cover_big: sleeve, cover_medium: "" } };
    }

    readonly property string elmar: "Elmari tantsuõhtu 24/7"

    // 2026-11-12, measured on the panel: "Alen Veziko - Päiksepoolsel
    // tänaval" wore the sleeve of his single "Nüüd taas sajab lund", and the
    // lock screen showed it too. The five requests are the ones the panel
    // logged; what the first four answered is recorded for the two song
    // searches by free text, and known from that log for the other two only
    // as "nothing taken".
    function test_another_single_of_the_artist_is_another_release_and_never_the_songs_cover() {
        var e = makeEngine(true, elmar);
        var c = _catalogue(e, { "itunesArtist Alen Veziko": Answers.alenSongs });
        _play(e, "Alen Veziko - Päiksepoolsel tänaval", elmar);
        compare(c.asked, ["deezer Alen Veziko Päiksepoolsel tänaval", 'deezer track:"Päiksepoolsel tänaval"',
                          "itunes Alen Veziko Päiksepoolsel tänaval", "deezerArtist Alen Veziko",
                          "itunesArtist Alen Veziko"]);
        compare(e.albumArtUrl, Answers.alenOtherSingle);
        compare(e.albumArtKind, "release");
        compare(e.trackArtUrl, "");
        // The second time round it comes from the cache, and is still no cover.
        e.artClear();
        compare(e.albumArtKind, "");
        verify(e._artFromCache(tc.curKey, "Alen Veziko"));
        compare(e.albumArtUrl, Answers.alenOtherSingle);
        compare(e.albumArtKind, "release");
        compare(e.trackArtUrl, "");
        compare(c.asked.length, 5);
        e.destroy();
    }

    function test_the_song_found_under_its_guest_is_the_cover() {
        var e = makeEngine(true, elmar);
        var c = _catalogue(e, { 'deezer track:"Rahutu tuhkatriinu"': Answers.moonTrack });
        _play(e, "Moon Taxi feat. Mari-Leen - Rahutu tuhkatriinu", elmar);
        compare(c.asked, ["deezer Moon Taxi feat. Mari-Leen Rahutu tuhkatriinu", 'deezer track:"Rahutu tuhkatriinu"']);
        compare(e.albumArtUrl, Answers.moonCover);
        compare(e.albumArtKind, "track");
        compare(e.trackArtUrl, Answers.moonCover);
        e.artClear();
        verify(e._artFromCache(tc.curKey, "Moon Taxi feat. Mari-Leen"));
        compare(e.albumArtKind, "track");
        compare(e.trackArtUrl, Answers.moonCover);
        e.destroy();
    }

    // "Star Sisters - Waterloo": no catalogue has the song, and Deezer's
    // picture of the artist is the sleeve of an album without it.
    function test_the_artists_picture_is_a_picture_of_the_artist() {
        var e = makeEngine(true, elmar);
        var c = _catalogue(e, { "deezerArtist Star Sisters": Answers.starArtist });
        _play(e, "Star Sisters - Waterloo", elmar);
        compare(c.asked, ["deezer Star Sisters Waterloo", 'deezer track:"Waterloo"', "itunes Star Sisters Waterloo",
                          "deezerArtist Star Sisters"]);
        compare(e.albumArtUrl, Answers.starPicture);
        compare(e.albumArtKind, "artist");
        compare(e.trackArtUrl, "");
        e.artClear();
        verify(e._artFromCache(tc.curKey, "Star Sisters"));
        compare(e.albumArtKind, "artist");
        compare(e.trackArtUrl, "");
        e.destroy();
    }

    // Deezer's first answer used to end the chain with the artist's other
    // record, so iTunes, which has the song, was never asked.
    function test_another_record_at_the_first_request_does_not_keep_the_song_from_being_found() {
        var e = makeEngine(true, elmar);
        var other = { data: [_deezerRow("Alen Veziko", "Päiksepoolsel tänaval", "http://x/other-record.jpg")] };
        var c = _catalogue(e, { "deezer Alen Veziko Nüüd taas sajab lund": other,
                                "itunes Alen Veziko Nüüd taas sajab lund": Answers.alenSongs });
        _play(e, "Alen Veziko - Nüüd taas sajab lund", elmar);
        compare(c.asked, ["deezer Alen Veziko Nüüd taas sajab lund", 'deezer track:"Nüüd taas sajab lund"',
                          "itunes Alen Veziko Nüüd taas sajab lund"]);
        compare(e.albumArtUrl, Answers.alenOtherSingle);
        compare(e.albumArtKind, "track");
        compare(e.trackArtUrl, Answers.alenOtherSingle);
        e.destroy();
    }

    // The song the first request already has costs one request, as before.
    function test_an_ordinary_hit_still_costs_one_request() {
        var e = makeEngine(true, elmar);
        var c = _catalogue(e, { "deezer Mari-Leen Rahutu tuhkatriinu": Answers.moonTrack });
        _play(e, "Mari-Leen - Rahutu tuhkatriinu", elmar);
        compare(c.asked, ["deezer Mari-Leen Rahutu tuhkatriinu"]);
        compare(e.albumArtKind, "track");
        e.destroy();
    }

    // A record met on the way waits until the artist's picture has been
    // asked for, and then spares the request for the artist's other songs.
    function test_a_record_met_on_the_way_is_used_once_the_picture_is_not_there() {
        var e = makeEngine(true, elmar);
        var other = { data: [_deezerRow("Alen Veziko", "Nüüd taas sajab lund", "http://x/other-record.jpg")] };
        var c = _catalogue(e, { "deezer Alen Veziko Päiksepoolsel tänaval": other });
        _play(e, "Alen Veziko - Päiksepoolsel tänaval", elmar);
        compare(c.asked, ["deezer Alen Veziko Päiksepoolsel tänaval", 'deezer track:"Päiksepoolsel tänaval"',
                          "itunes Alen Veziko Päiksepoolsel tänaval", "deezerArtist Alen Veziko"]);
        compare(e.albumArtUrl, "http://x/other-record.jpg");
        compare(e.albumArtKind, "release");
        compare(e.trackArtUrl, "");
        e.destroy();
    }

    // Two song searches each bring another record. The first one met is the
    // one kept: Deezer is asked first, and what it offers is what a single
    // request used to settle on.
    function test_the_first_record_met_on_the_way_is_the_one_kept() {
        var e = makeEngine(true, elmar);
        var first = { data: [_deezerRow("Alen Veziko", "Nüüd taas sajab lund", "http://x/first-record.jpg")] };
        var c = _catalogue(e, { "deezer Alen Veziko Päiksepoolsel tänaval": first,
                                "itunes Alen Veziko Päiksepoolsel tänaval": Answers.alenSongs });
        _play(e, "Alen Veziko - Päiksepoolsel tänaval", elmar);
        compare(c.asked.length, 4);
        compare(e.albumArtUrl, "http://x/first-record.jpg");
        compare(e.albumArtKind, "release");
        e.destroy();
    }

    function test_the_artists_picture_goes_before_a_record_met_on_the_way() {
        var e = makeEngine(true, elmar);
        var other = { data: [_deezerRow("Star Sisters", "Hamba Juba", "http://x/other-record.jpg")] };
        var c = _catalogue(e, { "deezer Star Sisters Waterloo": other, "deezerArtist Star Sisters": Answers.starArtist });
        _play(e, "Star Sisters - Waterloo", elmar);
        compare(c.asked.length, 4);
        compare(e.albumArtUrl, Answers.starPicture);
        compare(e.albumArtKind, "artist");
        e.destroy();
    }

    // A row whose album has no sleeve brings Deezer's picture of its artist.
    // It waits for the other song searches like a record does, and then
    // spares the request for the artist's picture.
    function test_a_picture_of_the_artist_met_on_the_way_spares_the_question_for_it() {
        var e = makeEngine(true, elmar);
        var row = _deezerRow("Mari-Leen", "Rahutu tuhkatriinu", "");
        row.artist.picture_medium = "http://x/face.jpg";
        var c = _catalogue(e, { "deezer Mari-Leen Rahutu tuhkatriinu": { data: [row] } });
        _play(e, "Mari-Leen - Rahutu tuhkatriinu", elmar);
        compare(c.asked, ["deezer Mari-Leen Rahutu tuhkatriinu", 'deezer track:"Rahutu tuhkatriinu"',
                          "itunes Mari-Leen Rahutu tuhkatriinu"]);
        compare(e.albumArtUrl, "http://x/face.jpg");
        compare(e.albumArtKind, "artist");
        compare(e.trackArtUrl, "");
        e.destroy();
    }

    // An artist read from behind the station's own name gets neither of the
    // two last requests, and a record met on the way is still all there is.
    function test_a_record_met_on_the_way_is_used_where_the_plan_ends_with_the_songs() {
        var station = "Kaaosradio - 24h Chill";
        var e = makeEngine(true, station);
        var other = { data: [_deezerRow("Organoid", "Another Tune", "http://x/other-record.jpg")] };
        var c = _catalogue(e, { "deezer Organoid Metamorphosis": other });
        _play(e, "Kaaosradio 24h - Organoid - Metamorphosis", station);
        compare(c.asked.filter(function(a) { return a.indexOf("Artist ") !== -1; }), []);
        verify(c.asked.length >= 3);
        compare(e.albumArtUrl, "http://x/other-record.jpg");
        compare(e.albumArtKind, "release");
        e.destroy();
    }

    // Three songs in a row: another record, the song's own cover, nothing.
    // Each wears its own kind, and no place that takes only a song's cover
    // is ever handed anything else, not even between two writes.
    function test_the_kind_goes_with_its_picture_from_song_to_song() {
        var e = makeEngine(true, elmar);
        var seen = [];
        e.trackArtUrlChanged.connect(function() { seen.push(e.trackArtUrl); });
        var c = _catalogue(e, { "itunesArtist Alen Veziko": Answers.alenSongs,
                                'deezer track:"Rahutu tuhkatriinu"': Answers.moonTrack,
                                "deezerArtist Star Sisters": Answers.starArtist });
        _play(e, "Alen Veziko - Päiksepoolsel tänaval", elmar);
        compare(e.albumArtKind, "release");
        var alenKey = tc.curKey;
        _play(e, "Moon Taxi feat. Mari-Leen - Rahutu tuhkatriinu", elmar);
        compare(e.albumArtUrl, Answers.moonCover);
        compare(e.albumArtKind, "track");
        var moonKey = tc.curKey;
        _play(e, "Marco - Vaikiv tunne", elmar);
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        _play(e, "Star Sisters - Waterloo", elmar);
        compare(e.albumArtKind, "artist");
        // Straight from one cached picture to another, with no clearing between.
        tc.curKey = moonKey;
        verify(e._artFromCache(moonKey, "Moon Taxi feat. Mari-Leen"));
        compare(e.albumArtKind, "track");
        tc.curKey = alenKey;
        verify(e._artFromCache(alenKey, "Alen Veziko"));
        compare(e.albumArtUrl, Answers.alenOtherSingle);
        compare(e.albumArtKind, "release");
        tc.curKey = moonKey;
        verify(e._artFromCache(moonKey, "Moon Taxi feat. Mari-Leen"));
        compare(e.trackArtUrl, Answers.moonCover);
        verify(seen.length >= 4, "the song's cover came and went: " + seen.length);
        for (var i = 0; i < seen.length; i++)
            verify(seen[i] === "" || seen[i] === Answers.moonCover, "handed out as a song's cover: " + seen[i]);
        e.destroy();
    }

    // The covers are switched off while the request that would bring another
    // record is in the air. Neither the picture nor its kind is left behind.
    function test_covers_switched_off_in_the_air_leave_no_picture_and_no_kind() {
        var e = makeEngine(true, elmar);
        var c = _catalogue(e, { "itunesArtist Alen Veziko": Answers.alenSongs });
        c.hold = true;
        _play(e, "Alen Veziko - Päiksepoolsel tänaval", elmar);
        for (var i = 0; i < 4; i++) c.held[i]();
        compare(c.asked.length, 5);
        e.cfg.albumArtEnabled = false;
        c.held[4]();
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        compare(e.trackArtUrl, "");
        verify(e._artCache[tc.curKey] === undefined);
        // And a picture that was up when the switch went off goes with the next title.
        e.cfg.albumArtEnabled = true;
        e._artFinish(tc.curKey, Answers.starPicture, true, "artist");
        compare(e.albumArtKind, "artist");
        e.cfg.albumArtEnabled = false;
        e.lookupAlbumArt("Alen Veziko - Päiksepoolsel tänaval");
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        e.destroy();
    }

    // The cache is this engine's own and holds nothing older than it. An
    // entry that does not say what its picture is of would still not be
    // taken for a song's cover: the track is looked up again.
    function test_a_cache_entry_without_a_kind_is_looked_up_again_data() {
        return [
            { tag: "the old shape", entry: { url: "http://x/old.jpg", t: Date.now() } },
            { tag: "a word that is no kind", entry: { url: "http://x/old.jpg", t: Date.now(), kind: "cover" } },
            { tag: "an empty kind", entry: { url: "http://x/old.jpg", t: Date.now(), kind: "" } },
            { tag: "a kind that is no text", entry: { url: "http://x/old.jpg", t: Date.now(), kind: true } }
        ];
    }
    function test_a_cache_entry_without_a_kind_is_looked_up_again(data) {
        var e = makeEngine();
        tc.curKey = "artist song";
        e._artCache["artist song"] = data.entry;
        verify(!e._artFromCache("artist song", "Artist"));
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        compare(e.trackArtUrl, "");
        // A miss never had a kind and is still a settled answer.
        e._artCache["nobody has it"] = { url: "", t: Date.now() };
        verify(e._artFromCache("nobody has it", "Artist"));
        e.destroy();
    }

    // A picture nobody can name is not shown and not filed, whoever sends it.
    function test_a_picture_without_a_kind_is_not_shown_data() {
        return [
            { tag: "no kind", kind: undefined },
            { tag: "a word that is no kind", kind: "cover" },
            { tag: "an empty kind", kind: "" },
            { tag: "null", kind: null }
        ];
    }
    function test_a_picture_without_a_kind_is_not_shown(data) {
        var e = makeEngine();
        tc.curKey = "artist song";
        var nameless = function(q, key, onResult) { onResult("http://x/whose.jpg", true, data.kind); };
        e._runAttempts([{ fn: nameless, q: "a" }], "artist song", { artist: "Artist", title: "Song" });
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        e._artFinish("artist song", "http://x/whose.jpg", true, data.kind);
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        verify(e._artCache["artist song"] === undefined || e._artCache["artist song"].url === "");
        e.destroy();
    }

    // A song search timed out, so whether the song has a cover is not known.
    // The artist's picture is shown meanwhile and is not filed as the answer:
    // the one later attempt goes out and brings the cover.
    function test_a_stand_in_found_after_a_timeout_is_shown_and_the_song_is_asked_for_again() {
        var e = makeEngine(true, elmar);
        var book = { "deezer Mari-Leen Rahutu tuhkatriinu": 0, "deezerArtist Mari-Leen":
                     { data: [{ name: "Mari-Leen", picture_big: "http://x/face.jpg" }] } };
        var c = _catalogue(e, book);
        _play(e, "Mari-Leen - Rahutu tuhkatriinu", elmar);
        compare(e.albumArtUrl, "http://x/face.jpg");
        compare(e.albumArtKind, "artist");
        verify(e._artCache[tc.curKey] === undefined);
        verify(e._artRetryArmed);
        book["deezer Mari-Leen Rahutu tuhkatriinu"] = Answers.moonTrack;
        e._artAskAgain();
        compare(e.albumArtUrl, Answers.moonCover);
        compare(e.albumArtKind, "track");
        compare(e._artCache[tc.curKey].kind, "track");
        verify(!e._artRetryArmed);
        e.destroy();
    }

    // With every service answering, the stand-in is the answer and is filed.
    function test_a_stand_in_everybody_agreed_on_is_filed_with_its_kind() {
        var e = makeEngine(true, elmar);
        var c = _catalogue(e, { "deezerArtist Star Sisters": Answers.starArtist });
        _play(e, "Star Sisters - Waterloo", elmar);
        compare(e._artCache[tc.curKey].kind, "artist");
        compare(e._artCache[tc.curKey].url, Answers.starPicture);
        verify(!e._artRetryArmed);
        // The song's own cover is filed whatever timed out before it.
        _catalogue(e, { "deezer Mari-Leen Rahutu tuhkatriinu": 0, 'deezer track:"Rahutu tuhkatriinu"': Answers.moonTrack });
        _play(e, "Mari-Leen - Rahutu tuhkatriinu", elmar);
        compare(e._artCache[tc.curKey].kind, "track");
        verify(!e._artRetryArmed);
        e.destroy();
    }

    // What counts as a service not answering: a status that is not 200, a
    // body that is no JSON, Deezer's quota word and an iTunes body without
    // its results. None of them is "no such record".
    function test_an_answer_that_is_no_answer_is_not_filed_as_a_miss_data() {
        return [
            { tag: "timeout", answer: 0 },
            { tag: "refused", answer: 403 },
            { tag: "not JSON", answer: "<html>Too many requests</html>" },
            { tag: "JSON null", answer: "null" },
            { tag: "deezer quota", answer: { error: { type: "Exception", message: "Quota limit exceeded", code: 4 } } },
            { tag: "no results key", answer: { resultCount: 0 } }
        ];
    }
    function test_an_answer_that_is_no_answer_is_not_filed_as_a_miss(data) {
        var e = makeEngine(true, elmar);
        var book = {};
        ["deezer Marco Vaikiv tunne", 'deezer track:"Vaikiv tunne"', "itunes Marco Vaikiv tunne", "deezerArtist Marco",
         "itunesArtist Marco"].forEach(function(r) { book[r] = data.answer; });
        var c = _catalogue(e, book);
        _play(e, "Marco - Vaikiv tunne", elmar);
        compare(c.asked.length, 5);
        compare(e.albumArtUrl, "");
        verify(e._artCache[tc.curKey] === undefined);
        verify(e._artRetryArmed);
        e.destroy();
    }

    // The same, one service at a time, with everybody else answering "nothing
    // found": the one that did not answer is enough to leave the question
    // open. A refusal that carries a readable body is a refusal all the same.
    function test_one_service_not_answering_leaves_the_question_open_data() {
        var quota = { error: { type: "Exception", message: "Quota limit exceeded", code: 4 } };
        return [
            { tag: "deezer song search, quota", request: "deezer Marco Vaikiv tunne", answer: quota },
            { tag: "deezer field search, quota", request: 'deezer track:"Vaikiv tunne"', answer: quota },
            { tag: "deezer artist search, quota", request: "deezerArtist Marco", answer: quota },
            { tag: "itunes song search, no results key", request: "itunes Marco Vaikiv tunne", answer: { resultCount: 0 } },
            { tag: "itunes artist songs, no results key", request: "itunesArtist Marco", answer: { resultCount: 0 } },
            { tag: "deezer refusing with a body", request: "deezer Marco Vaikiv tunne",
              answer: { status: 503, body: Answers.deezerNothing } },
            { tag: "itunes refusing with a body", request: "itunes Marco Vaikiv tunne",
              answer: { status: 403, body: Answers.itunesNothing } }
        ];
    }
    function test_one_service_not_answering_leaves_the_question_open(data) {
        var e = makeEngine(true, elmar);
        var book = {};
        book[data.request] = data.answer;
        var c = _catalogue(e, book);
        _play(e, "Marco - Vaikiv tunne", elmar);
        compare(c.asked.length, 5);
        verify(c.asked.indexOf(data.request) !== -1, "the test asks for something the plan does not: " + c.asked);
        compare(e.albumArtUrl, "");
        verify(e._artCache[tc.curKey] === undefined, "filed as a song nobody has");
        verify(e._artRetryArmed);
        e.destroy();
    }

    // Everybody saying no is an answer: filed, and nothing is asked again.
    function test_a_song_nobody_has_is_filed_as_such() {
        var e = makeEngine(true, elmar);
        var c = _catalogue(e, {});
        _play(e, "Marco - Vaikiv tunne", elmar);
        compare(c.asked.length, 5);
        compare(e._artCache[tc.curKey].url, "");
        verify(!e._artRetryArmed);
        _play(e, "Marco - Vaikiv tunne", elmar);
        compare(c.asked.length, 5);
        // No picture, so no kind and no track it would belong to.
        compare(e.albumArtKind, "");
        compare(e._albumArtKey, "");
        e.destroy();
    }

    function test_a_local_files_own_cover_is_that_songs_cover() {
        var e = makeEngine();
        e.artLocal("file:///home/user/Music/Album/cover.jpg");
        compare(e.albumArtUrl, "file:///home/user/Music/Album/cover.jpg");
        compare(e.albumArtKind, "track");
        compare(e.trackArtUrl, "file:///home/user/Music/Album/cover.jpg");
        // It belongs to no lookup key, so any title's lookup would clear it;
        // main.qml keeps both away while the file plays.
        e.artClearUnless("some song");
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        e.artLocal("");
        compare(e.albumArtKind, "");
        e.destroy();
    }

    function test_clearing_takes_the_picture_its_kind_and_its_key_together() {
        var e = makeEngine();
        tc.curKey = "artist song";
        e._artFinish("artist song", Answers.starPicture, true, "artist");
        compare(e._albumArtKey, "artist song");
        // The cover of the track that plays stays…
        e.artClearUnless("artist song");
        compare(e.albumArtUrl, Answers.starPicture);
        compare(e.albumArtKind, "artist");
        // …and goes for any other.
        e.artClearUnless("another song");
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        compare(e._albumArtKey, "");
        e.artClearUnless("another song");
        compare(e.albumArtUrl, "");
        e._artFinish("artist song", Answers.starPicture, true, "artist");
        e.artClear();
        compare(e.albumArtUrl, "");
        compare(e.albumArtKind, "");
        compare(e._albumArtKey, "");
        e.destroy();
    }
}
