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

    function test_a_definitive_miss_is_cached_and_answered_from_cache() {
        var e = makeEngine();
        tc.curKey = "artist|song";
        e._artFinish("artist|song", "", true);        // definitive: no art
        // _artFromCache returns true (settled) even for a fresh miss.
        verify(e._artFromCache("artist|song"));
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
        verify(!e._artFromCache("k0"));
        verify(e._artFromCache("k249"));
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
        verify(e._artFromCache("Dance Wave!"));
        compare(e.albumArtUrl, "");
        e.destroy();
        // The same words on another station are a title like any other.
        e = makeEngine(true, "Radio Elmar");
        tc.curKey = "elsewhere";
        e._artFinish("Dance Wave!", "http://x/palm.jpg", true);
        verify(e._artFromCache("Dance Wave!"));
        compare(e.albumArtUrl, "http://x/palm.jpg");
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
