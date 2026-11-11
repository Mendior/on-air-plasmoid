// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// A Play that names nothing. On the bench (2026-09-23) a search result was
// auditioned, stopped, and the Play button put MANGORADIO on, the first row
// of the list, because an audition leaves lastPlay at -1 and every road fell
// back to row 0. The same happened on Space.
import QtQuick
import QtTest

import "../../package/contents/ui/TransportLogic.js" as TL

TestCase {
    name: "TransportLogic"

    function test_a_stopped_audition_is_what_play_brings_back() {
        compare(TL.bareplay(true, -1, 12).what, "audition");
    }

    function test_the_audition_wins_over_the_row_a_deletion_pointed_at() {
        // Deleting a row during a stopped audition sets lastPlay to 0
        // (removeStation), which is not a station anyone chose.
        compare(TL.bareplay(true, 0, 12).what, "audition");
        compare(TL.bareplay(true, 5, 12).what, "audition");
    }

    function test_an_audition_plays_even_with_an_empty_list() {
        // Someone with no saved stations yet can still get back the result
        // they were listening to.
        compare(TL.bareplay(true, -1, 0).what, "audition");
    }

    function test_the_last_station_comes_back_when_nothing_was_auditioned() {
        var p = TL.bareplay(false, 4, 12);
        compare(p.what, "station");
        compare(p.index, 4);
    }

    function test_a_row_that_is_gone_falls_back_to_the_first() {
        // The list shrank under lastPlay, or a local file played last.
        compare(TL.bareplay(false, 12, 12).index, 0);
        compare(TL.bareplay(false, -1, 12).index, 0);
        compare(TL.bareplay(false, -1, 12).what, "station");
    }

    function test_nothing_to_play_is_nothing() {
        compare(TL.bareplay(false, -1, 0).what, "nothing");
        compare(TL.bareplay(false, 0, 0).what, "nothing");
        compare(TL.bareplay(false, 3, undefined).what, "nothing");
    }

    // ── a stop the person can actually reach ──────────────────────────────
    // Egon, on his own panel (2026-09-27): "there is no stop, I cannot shut
    // it off". The big button had turned into a Pause, which is what it does
    // on any station with a buffer behind it, and a pause keeps the stream
    // and the capture running. The expectations below come from what a player
    // owes a listener, not from what the code answers today.

    function test_a_station_that_can_pause_still_needs_a_stop() {
        // The big button says Pause here, so the stop has to live elsewhere.
        verify(TL.stopOffered(true, false, true, false, false, true));
    }

    function test_a_station_that_cannot_pause_already_has_its_stop() {
        // Here the big button IS the stop. A second one beside it would be
        // two stops side by side.
        verify(!TL.stopOffered(true, false, true, false, false, false));
    }

    function test_the_wait_between_two_knocks_offers_a_stop() {
        // Nothing is audible, the footer says Reconnecting, and the big
        // button has flipped to Play. Without this there is no way to call
        // off the ladder — the half of issue #13 the budget never covered.
        verify(TL.stopOffered(false, false, true, false, false, false));
        verify(TL.stopOffered(false, false, true, false, false, true));
    }

    function test_a_parked_or_moved_buffer_can_be_let_go_of() {
        verify(TL.stopOffered(false, false, false, true, false, true));
        verify(TL.stopOffered(false, false, false, false, true, false));
    }

    function test_a_cast_follows_the_same_rule_as_the_local_player() {
        // Casting with a buffer ready: the big button pauses, so the stop is
        // needed. Without one it is already the stop.
        verify(TL.stopOffered(false, true, true, false, false, true));
        verify(!TL.stopOffered(false, true, true, false, false, false));
    }

    function test_an_idle_widget_offers_nothing_to_stop() {
        verify(!TL.stopOffered(false, false, false, false, false, false));
        verify(!TL.stopOffered(false, false, false, false, false, true));
    }

    function test_nothing_but_true_counts_as_true() {
        // Properties read before the component is ready, and the truthy
        // strings a binding can hand over. None of them may conjure a
        // control out of nothing.
        verify(!TL.stopOffered(undefined, undefined, undefined, undefined, undefined, undefined));
        verify(!TL.stopOffered(null, null, null, null, null, null));
        verify(!TL.stopOffered("yes", 1, "true", {}, [], 1));
    }

    // --- held: is anything "on" at all ---------------------------------------

    function test_sound_a_standing_order_or_a_seat_in_the_buffer_is_held() {
        verify(TL.held(true, false, false, false, false));    // playing
        verify(TL.held(false, true, false, false, false));    // casting
        verify(TL.held(false, false, true, false, false));    // between two knocks
        verify(TL.held(false, false, false, true, false));    // parked
        verify(TL.held(false, false, false, false, true));    // moved inside the buffer
    }

    function test_an_idle_widget_holds_nothing() {
        verify(!TL.held(false, false, false, false, false));
    }

    function test_held_takes_nothing_but_true() {
        verify(!TL.held(undefined, undefined, undefined, undefined, undefined));
        verify(!TL.held(null, 1, "true", {}, []));
    }

    function test_held_and_the_stop_rule_agree_on_what_is_on() {
        // The panel text and the Stop button must not disagree about
        // whether the widget is on: whenever a stop is offered, something
        // is held.
        var b = [false, true];
        for (var p = 0; p < 2; p++) for (var c = 0; c < 2; c++)
        for (var w = 0; w < 2; w++) for (var tp = 0; tp < 2; tp++)
        for (var ts = 0; ts < 2; ts++) for (var pa = 0; pa < 2; pa++) {
            if (TL.stopOffered(b[p], b[c], b[w], b[tp], b[ts], b[pa]))
                verify(TL.held(b[p], b[c], b[w], b[tp], b[ts]),
                       "a stop is offered while nothing is held");
        }
    }

    // --- wheelLevel: what one notch of the wheel asks for ----------------------

    function near(got, want) {
        verify(Math.abs(got - want) < 1e-9, "got " + got + ", wanted " + want);
    }

    function test_a_notch_moves_the_level_that_is_playing() {
        near(TL.wheelLevel(0.60, -1, -1, 0.05), 0.65);
        near(TL.wheelLevel(0.60, -1, -1, -0.05), 0.55);
        // A gesture still waiting to be saved is the level that plays, so
        // without a fade it is not asked.
        near(TL.wheelLevel(0.60, -1, 40, 0.05), 0.65);
    }

    function test_a_notch_during_the_sleep_fade_counts_from_where_the_fade_began() {
        // The scenario: 60 % faded to 30 %, one notch up. 35 % became the
        // default volume and the radio started at 35 % in the morning.
        near(TL.wheelLevel(0.30, 0.60, -1, 0.05), 0.65);
        near(TL.wheelLevel(0.30, 0.60, -1, -0.05), 0.55);
        // In the fade's last moment nothing is left of the level at all.
        near(TL.wheelLevel(0, 0.60, -1, 0.05), 0.65);
    }

    function test_a_burst_of_notches_during_the_fade_adds_up() {
        // setUserVolume holds the gesture for a second before it is saved;
        // the next notch of the same burst goes on from there.
        var first = TL.wheelLevel(0.30, 0.60, -1, 0.05);
        near(first, 0.65);
        var second = TL.wheelLevel(0.29, 0.60, Math.round(first * 100), 0.05);
        near(second, 0.70);
        near(TL.wheelLevel(0.28, 0.60, Math.round(second * 100), 0.05), 0.75);
        // Down as well, and across the level the fade began at.
        near(TL.wheelLevel(0.28, 0.60, 65, -0.05), 0.60);
        near(TL.wheelLevel(0.28, 0.60, 60, -0.05), 0.55);
    }

    function test_the_edges_of_a_fade() {
        // A fade that has only just begun: both levels are the same one.
        near(TL.wheelLevel(0.60, 0.60, -1, 0.05), 0.65);
        // A fade from silence is a fade, not the absence of one: the second
        // notch of a burst still goes on from the first.
        near(TL.wheelLevel(0, 0, -1, 0.05), 0.05);
        near(TL.wheelLevel(0, 0, 5, 0.05), 0.10);
        // A mute made during the fade is the gesture the next notch leaves.
        near(TL.wheelLevel(0.20, 0.60, 0, 0.05), 0.05);
        // The ends of the scale hold.
        near(TL.wheelLevel(0.50, 1, -1, 0.05), 1);
        near(TL.wheelLevel(0.01, 0.02, -1, -0.05), 0);
        near(TL.wheelLevel(0.50, 0.60, 100, 0.05), 1);
        near(TL.wheelLevel(0.98, -1, -1, 0.05), 1);
        near(TL.wheelLevel(0.02, -1, -1, -0.05), 0);
    }

    function test_what_is_not_a_number_is_not_a_fade_and_not_a_gesture() {
        // No fade told: the level that plays is the base.
        near(TL.wheelLevel(0.30, undefined, -1, 0.05), 0.35);
        near(TL.wheelLevel(0.30, null, -1, 0.05), 0.35);
        near(TL.wheelLevel(0.30, NaN, -1, 0.05), 0.35);
        near(TL.wheelLevel(0.30, "0.6", -1, 0.05), 0.35);
        near(TL.wheelLevel(0.30, true, -1, 0.05), 0.35);
        // No gesture told: the fade's own start is.
        near(TL.wheelLevel(0.30, 0.60, undefined, 0.05), 0.65);
        near(TL.wheelLevel(0.30, 0.60, null, 0.05), 0.65);
        near(TL.wheelLevel(0.30, 0.60, NaN, 0.05), 0.65);
        near(TL.wheelLevel(0.30, 0.60, "70", 0.05), 0.65);
        // No level and no step: silence, and nowhere to go from it.
        near(TL.wheelLevel(undefined, -1, -1, 0.05), 0.05);
        near(TL.wheelLevel(NaN, -1, -1, 0.05), 0.05);
        near(TL.wheelLevel(0.30, -1, -1, undefined), 0.30);
        near(TL.wheelLevel(0.30, 0.60, -1, NaN), 0.60);
        near(TL.wheelLevel(), 0);
    }

    function test_numbers_far_off_the_scale_stay_on_it() {
        near(TL.wheelLevel(7, -1, -1, 0.05), 1);
        near(TL.wheelLevel(-3, -1, -1, 0.05), 0);
        near(TL.wheelLevel(0.30, 1e9, -1, 0.05), 1);
        near(TL.wheelLevel(0.30, 0.60, 5000, 0.05), 1);
        near(TL.wheelLevel(0.30, 0.60, -1, -1e9), 0);
        near(TL.wheelLevel(0.30, 0.60, -1, 1e9), 1);
        // Infinity is no level to count from: it is absent like any other
        // thing that is not a number, and never a jump to full volume.
        near(TL.wheelLevel(0.30, Infinity, -1, 0.05), 0.35);
        near(TL.wheelLevel(0.30, -Infinity, -1, 0.05), 0.35);
        near(TL.wheelLevel(0.30, 0.60, Infinity, -0.05), 0.55);
        near(TL.wheelLevel(Infinity, -1, -1, 0.05), 0.05);
        near(TL.wheelLevel(0.30, 0.60, -1, Infinity), 0.60);
    }

    // The star's and the trash's list write. playing(): the facts main.qml
    // hands over, a My Music file sounding unless a test says otherwise.
    function playing(over) {
        var p = { "audible": true, "preview": false,
                  "source": "file:///home/u/Music/OnAir/song.mp3", "episode": "",
                  "tone": "file:///usr/share/onair/chime.ogg",
                  "bufferPath": "/run/user/1000/onair/ts-7.mka", "shifted": false };
        for (var k in over) p[k] = over[k];
        return p;
    }

    function test_a_my_music_file_plays_on_through_a_list_write() {
        compare(TL.listWriteKeepsSound(playing({})), true);
        compare(TL.listWriteKeepsSound(playing({ "source": "file:///home/u/a%20b.flac" })), true);
    }

    function test_an_episode_plays_on_whether_it_is_on_disk_or_streamed() {
        var disk = "file:///home/u/Podcasts/show/ep1.mp3";
        compare(TL.listWriteKeepsSound(playing({ "source": disk, "episode": disk })), true);
        var stream = "https://cdn.example/show/ep1.mp3";
        compare(TL.listWriteKeepsSound(playing({ "source": stream, "episode": stream })), true);
    }

    function test_a_list_station_keeps_the_road_it_had() {
        // Untouched by the write or the very row removed: the write stops it
        // and its caller decides what starts again. Not this rule's business.
        compare(TL.listWriteKeepsSound(playing({ "source": "http://ice.example/live" })), false);
        compare(TL.listWriteKeepsSound(playing({ "source": "https://ice.example/live.mp3" })), false);
        // An episode that played earlier does not make a station an episode.
        compare(TL.listWriteKeepsSound(playing({ "source": "http://ice.example/live",
                                                 "episode": "https://cdn.example/ep1.mp3" })), false);
    }

    function test_an_audition_keeps_the_road_it_had() {
        compare(TL.listWriteKeepsSound(playing({ "preview": true, "source": "http://ice.example/try" })), false);
        compare(TL.listWriteKeepsSound(playing({ "preview": true })), false);
    }

    function test_nothing_playing_keeps_nothing() {
        compare(TL.listWriteKeepsSound(playing({ "audible": false })), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "source": "" })), false);
        // A file paused or ended is not sounding.
        var disk = "file:///home/u/Podcasts/show/ep1.mp3";
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "source": disk, "episode": disk })), false);
    }

    function test_a_shifted_listen_is_a_stations_and_ends_as_before() {
        var buf = "file:///run/user/1000/onair/ts-7.mka";
        compare(TL.listWriteKeepsSound(playing({ "source": buf, "shifted": true })), false);
        // Either sign is enough: the flag without the address, the address without the flag.
        compare(TL.listWriteKeepsSound(playing({ "shifted": true })), false);
        compare(TL.listWriteKeepsSound(playing({ "source": buf })), false);
    }

    function test_the_wake_up_tone_is_the_alarms_and_not_a_file_to_keep() {
        compare(TL.listWriteKeepsSound(playing({ "source": "file:///usr/share/onair/chime.ogg" })), false);
    }

    function test_an_empty_buffer_or_tone_address_matches_nothing() {
        // Disarmed, the engine has no buffer path at all.
        compare(TL.listWriteKeepsSound(playing({ "bufferPath": "", "tone": "" })), true);
        compare(TL.listWriteKeepsSound(playing({ "source": "file://", "bufferPath": "", "tone": "" })), true);
        compare(TL.listWriteKeepsSound(playing({ "bufferPath": undefined, "tone": undefined })), true);
        compare(TL.listWriteKeepsSound(playing({ "source": "", "bufferPath": "", "tone": "", "episode": "" })), false);
    }

    function test_a_state_nobody_can_read_stops_the_sound_as_it_always_did() {
        compare(TL.listWriteKeepsSound(), false);
        compare(TL.listWriteKeepsSound(null), false);
        compare(TL.listWriteKeepsSound({}), false);
        compare(TL.listWriteKeepsSound("file:///x.mp3"), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": 1 })), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": "true" })), false);
        compare(TL.listWriteKeepsSound(playing({ "source": undefined })), false);
        compare(TL.listWriteKeepsSound(playing({ "source": 7 })), false);
        compare(TL.listWriteKeepsSound(playing({ "preview": undefined })), false);
        compare(TL.listWriteKeepsSound(playing({ "preview": "yes" })), false);
        compare(TL.listWriteKeepsSound(playing({ "shifted": 1 })), false);
        compare(TL.listWriteKeepsSound(playing({ "shifted": undefined })), false);
    }

    function test_only_the_file_scheme_at_the_start_is_a_file() {
        compare(TL.listWriteKeepsSound(playing({ "source": "http://h.example/file://x.mp3" })), false);
        compare(TL.listWriteKeepsSound(playing({ "source": "FILE:///home/u/x.mp3" })), false);
        compare(TL.listWriteKeepsSound(playing({ "source": "file:///" + new Array(5000).join("a") + ".mp3" })), true);
    }
}
