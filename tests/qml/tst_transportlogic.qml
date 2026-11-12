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

    // ── what the desk is told Play can do ────────────────────────────────
    // CanPlay was "the list has a row", written apart from the action. The
    // expectations are what a Play or a PlayPause would do in each state.

    function test_a_playing_audition_can_be_played_with_no_station_saved() {
        // Nothing saved, a search result on: there is a track, and after its
        // stop a bare Play brings it back.
        compare(TL.canPlay(true, false, false, false, true, -1, 0, false), true);
        compare(TL.canPlay(false, false, false, false, true, -1, 0, false), true);
    }

    function test_whatever_is_on_can_be_played_with_no_station_saved() {
        // An episode, a My Music file, a cast: each is a track while it is on.
        compare(TL.canPlay(true, false, false, false, false, -1, 0, false), true);
        compare(TL.canPlay(false, true, false, false, false, -1, 0, false), true);
    }

    function test_a_paused_file_can_be_played_with_no_station_saved() {
        compare(TL.canPlay(false, false, false, false, false, -1, 0, true), true);
    }

    function test_a_seat_in_the_buffer_can_be_played_from() {
        compare(TL.canPlay(false, false, true, false, false, -1, 0, false), true);
        compare(TL.canPlay(false, false, false, true, false, -1, 0, false), true);
    }

    function test_nothing_at_all_cannot_be_played() {
        compare(TL.canPlay(false, false, false, false, false, -1, 0, false), false);
        compare(TL.canPlay(false, false, false, false, false, 0, 0, false), false);
    }

    function test_one_station_is_enough_to_play() {
        compare(TL.canPlay(false, false, false, false, false, -1, 1, false), true);
        compare(TL.canPlay(false, false, false, false, false, 0, 1, false), true);
        compare(TL.canPlay(true, false, false, false, false, 0, 1, false), true);
    }

    function test_the_capability_is_the_bare_plays_own_answer() {
        // Stopped, with nothing in the buffer: Play does what bareplay says,
        // so the two may never disagree.
        var counts = [0, 1, 12], rows = [-1, 0, 5, 12];
        for (var bits = 0; bits < 4; bits++)
            for (var c = 0; c < counts.length; c++)
                for (var r = 0; r < rows.length; r++) {
                    var heard = (bits & 1) !== 0, held = (bits & 2) !== 0;
                    compare(TL.canPlay(false, false, false, false, heard, rows[r], counts[c], held),
                            TL.bareplay(heard, rows[r], counts[c], held).what !== "nothing",
                            "audition " + heard + ", paused " + held + ", row " + rows[r] + " of " + counts[c]);
                }
    }

    function test_can_play_takes_nothing_but_true_and_a_real_count() {
        compare(TL.canPlay(), false);
        compare(TL.canPlay(1, "yes", {}, [], "true", "0", undefined, 1), false);
        compare(TL.canPlay(undefined, null, undefined, null, undefined, -1, NaN, "true"), false);
        compare(TL.canPlay(false, false, false, false, false, -1, -3, false), false);
        compare(TL.canPlay(false, false, false, false, false, 99999999, 100000000, false), true);
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

    // --- ownLevel: the listener's own level now ------------------------------

    function test_the_level_is_the_one_the_listener_chose_last() {
        compare(TL.ownLevel(-1, -1, 80), 0.8);
        compare(TL.ownLevel(-1, -1, 5), 0.05);
    }

    function test_a_gesture_not_yet_saved_is_already_the_level() {
        // The wheel took the widget to 20 %; the save waits a second.
        compare(TL.ownLevel(20, -1, 80), 0.2);
        compare(TL.ownLevel(100, -1, 80), 1);
        compare(TL.ownLevel(1, -1, 80), 0.01);
    }

    function test_a_mute_is_not_a_level_and_what_comes_back_is_the_level_under_it() {
        compare(TL.ownLevel(0, -1, 80), 0.8);
        compare(TL.ownLevel(0, 40, 80), 0.4);
    }

    function test_the_alarms_level_counts_while_it_stands_and_a_gesture_after_it_wins() {
        compare(TL.ownLevel(-1, 40, 80), 0.4);
        compare(TL.ownLevel(-1, 15, 80), 0.15);
        compare(TL.ownLevel(55, 40, 80), 0.55);
        compare(TL.ownLevel(-1, 0, 80), 0);
    }

    function test_a_level_stays_on_the_scale_and_takes_nothing_it_cannot_read() {
        compare(TL.ownLevel(), 0);
        compare(TL.ownLevel(-1, -1, 250), 1);
        compare(TL.ownLevel(-1, -1, -30), 0);
        compare(TL.ownLevel(250, -1, 80), 1);
        compare(TL.ownLevel(-1, 250, 80), 1);
        compare(TL.ownLevel("20", -1, 80), 0.8);
        compare(TL.ownLevel(NaN, -1, 80), 0.8);
        compare(TL.ownLevel(-1, "40", 80), 0.8);
        compare(TL.ownLevel(-1, NaN, 80), 0.8);
        compare(TL.ownLevel(-1, -1, "80"), 0);
        compare(TL.ownLevel(9e15, 9e15, 9e15), 1);
    }

    // --- wheelLevel: what one notch of the wheel asks for ----------------------

    function test_where_a_device_plays_alone_a_notch_counts_from_the_listeners_level() {
        // An alarm at 40 % on a device; the widget's own output, which nobody hears, still stands at 80 %.
        near(TL.wheelLevel(0.80, -1, -1, -0.05, true, 0.40), 0.35);
        near(TL.wheelLevel(0.80, -1, -1, 0.05, true, 0.40), 0.45);
        // A second notch of the same burst counts from the first: the level then includes it.
        near(TL.wheelLevel(0.35, -1, 35, -0.05, true, 0.35), 0.30);
    }

    function test_where_this_computer_is_heard_a_notch_counts_as_it_did() {
        near(TL.wheelLevel(0.80, -1, -1, -0.05, false, 0.40), 0.75);
        near(TL.wheelLevel(0.80, -1, -1, -0.05, undefined, 0.40), 0.75);
        near(TL.wheelLevel(0.80, -1, -1, -0.05, "true", 0.40), 0.75);
        near(TL.wheelLevel(0.30, 0.60, -1, 0.05, false, 0.40), 0.65);
    }

    function test_a_level_nobody_can_read_leaves_the_notch_to_what_is_shown() {
        near(TL.wheelLevel(0.80, -1, -1, -0.05, true), 0.75);
        near(TL.wheelLevel(0.80, -1, -1, -0.05, true, NaN), 0.75);
        near(TL.wheelLevel(0.80, -1, -1, -0.05, true, "0.4"), 0.75);
        near(TL.wheelLevel(0.80, -1, -1, 0.05, true, 9e15), 1);
        near(TL.wheelLevel(0.80, -1, -1, -0.05, true, -3), 0);
    }

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

    // ── a pause that keeps what it paused ────────────────────────────────
    // An episode plays, the headset's key says Pause, and later Play: the
    // first station of the list came on. A pause was a stop for anything
    // without a timeshift buffer, the stop threw the episode away, and a
    // Play that names nothing fell back to row 0. MPRIS says Play after
    // Pause goes on from the same place; the expectations below are that
    // sentence, and for every other state "as it was".

    // The transport's facts, nothing on unless a test says so.
    function key(cmd, over) {
        var f = { "playing": false, "casting": false, "wantsPlaying": false, "parked": false,
                  "shifted": false, "ownFile": false, "pausedFile": false, "inPlace": false, "audition": false };
        for (var k in over) f[k] = over[k];
        return TL.mediaKey(cmd, f.playing, f.casting, f.wantsPlaying, f.parked, f.shifted, f.ownFile, f.pausedFile, f.inPlace, f.audition);
    }

    // An audition on its way to sound: its address stands, the player is not up yet.

    function test_stop_and_pause_take_down_an_audition_that_is_on_its_way() {
        compare(key("Stop", { "audition": true }), "stop");
        compare(key("Pause", { "audition": true }), "stop");
    }

    function test_the_button_takes_it_down_too_and_a_play_does_not_start_it_twice() {
        compare(key("PlayPause", { "audition": true }), "stop");
        compare(key("Play", { "audition": true }), "none");
        compare(TL.face([false, false, false, false, false, false, false, false, true], false), "stop");
        compare(TL.keyFor("Stop", [false, false, false, false, false, false, false, false, true]), "stop");
    }

    function test_an_audition_that_sounds_keeps_the_roads_it_had() {
        var words = ["Stop", "Pause", "PlayPause", "Play"];
        for (var i = 0; i < words.length; i++) {
            compare(key(words[i], { "audition": true, "playing": true }), key(words[i], { "playing": true }), words[i]);
            compare(key(words[i], { "audition": true, "casting": true }), key(words[i], { "casting": true }), words[i] + " on a device");
        }
    }

    function test_an_audition_with_a_seat_in_its_buffer_is_not_on_its_way_it_is_parked() {
        // On the relay road a result that sounds has a buffer, and a pause parks it: its address stands, nothing
        // plays, and what the keys do is what they do for any parked station.
        var words = ["Stop", "Pause", "PlayPause", "Play"];
        for (var i = 0; i < words.length; i++) {
            compare(key(words[i], { "audition": true, "parked": true }), key(words[i], { "parked": true }), words[i] + " over a parked result");
            compare(key(words[i], { "audition": true, "shifted": true }), key(words[i], { "shifted": true }), words[i] + " inside its buffer");
        }
        compare(key("PlayPause", { "audition": true, "parked": true }), "resume");
        compare(key("Play", { "audition": true, "parked": true }), "resume");
        compare(key("Pause", { "audition": true, "parked": true }), "none");
        compare(key("PlayPause", { "audition": true, "shifted": true }), "unpause");
        compare(TL.face([false, false, false, true, false, false, false, false, true], true), "play");
    }

    // auditionComing(address, lastWord): mediaKey's ninth fact.

    function test_an_audition_is_on_its_way_from_its_click_until_its_ladder_has_spoken() {
        compare(TL.auditionComing("http://try.example/live", ""), true);
        compare(TL.auditionComing("http://try.example/live", "The station did not answer."), false);
    }

    function test_nothing_is_on_its_way_without_an_address() {
        compare(TL.auditionComing("", ""), false);
        compare(TL.auditionComing("", "The station did not answer."), false);
    }

    function test_a_word_nobody_can_read_was_not_said_and_an_address_nobody_can_read_is_none() {
        compare(TL.auditionComing(), false);
        compare(TL.auditionComing(undefined, ""), false);
        compare(TL.auditionComing(null, ""), false);
        compare(TL.auditionComing(7, ""), false);
        compare(TL.auditionComing(true, ""), false);
        compare(TL.auditionComing("http://try.example/live"), true);
        compare(TL.auditionComing("http://try.example/live", null), true);
        compare(TL.auditionComing("http://try.example/live", 7), true);
        compare(TL.auditionComing("http://try.example/live", false), true);
        compare(TL.auditionComing("h" + new Array(5000).join("x"), "w" + new Array(5000).join("y")), false);
        compare(TL.auditionComing("h" + new Array(5000).join("x"), ""), true);
    }

    function test_an_audition_is_on_its_way_only_when_that_is_exactly_true() {
        compare(key("Stop", { "audition": "true" }), "none");
        compare(key("Stop", { "audition": 1 }), "none");
        compare(key("PlayPause", { "audition": "http://try.example/live" }), "bare");
        compare(TL.keyFor("Stop", [false, false, false, false, false, false, false, false]), "none");
        compare(TL.face([false, false, false, false, false, false, false, false], false), "play");
        compare(TL.face([false, false, false, false, false, false, false, false, "true"], false), "play");
    }

    // What 2026.43 did with the four words, branch for branch, for a state
    // that holds no file: the roads that must not change.
    function before(cmd, f) {
        if (cmd === "Stop")
            return (f.playing || f.casting || f.wantsPlaying || f.parked || f.shifted) ? "stop" : "none";
        if (cmd === "Pause") {
            if (f.playing) return "pause";
            return (f.casting || f.wantsPlaying) ? "stop" : "none";
        }
        if (cmd === "PlayPause") {
            if (f.playing || f.casting) return "pause";
            if (f.parked) return "resume";
            return f.shifted ? "unpause" : "bare";
        }
        if (f.parked) return "resume";
        if (f.shifted && !f.playing) return "unpause";
        return (!f.playing && !f.casting) ? "bare" : "none";
    }

    function test_a_pause_keeps_the_episode_or_the_file_that_plays() {
        compare(key("Pause", { "playing": true, "ownFile": true }), "keep");
        compare(key("PlayPause", { "playing": true, "ownFile": true }), "keep");
    }

    function test_play_after_the_pause_is_a_bare_play_and_it_names_the_paused_file() {
        compare(key("Play", { "pausedFile": true }), "bare");
        compare(key("PlayPause", { "pausedFile": true }), "bare");
        compare(TL.bareplay(false, -1, 12, true).what, "paused");
        // Whatever else could answer, the file the listener set down goes first.
        compare(TL.bareplay(true, 3, 12, true).what, "paused");
        compare(TL.bareplay(false, -1, 0, true).what, "paused");
    }

    function test_a_second_pause_changes_nothing() {
        compare(key("Pause", { "pausedFile": true }), "none");
    }

    function test_stop_lets_go_of_a_paused_file() {
        compare(key("Stop", { "pausedFile": true }), "stop");
        compare(key("Stop", {}), "none");
    }

    function test_while_the_stop_still_fades_a_second_press_keeps_the_file_again() {
        // The player is audible for the length of the fade with the file
        // already remembered: a PlayPause there is another pause, not a play.
        compare(key("PlayPause", { "playing": true, "ownFile": true, "pausedFile": true }), "keep");
        compare(key("Play", { "playing": true, "ownFile": true, "pausedFile": true }), "none");
        compare(key("Stop", { "playing": true, "ownFile": true, "pausedFile": true }), "stop");
    }

    function test_a_file_beside_a_cast_is_not_kept() {
        // filePause answers null while a device carries the stream, so the
        // fact arrives false; and a fact that arrived true without the local
        // player being audible keeps nothing either.
        compare(key("Pause", { "casting": true, "ownFile": true }), "stop");
        compare(key("PlayPause", { "casting": true, "ownFile": true }), "pause");
    }

    function test_every_road_without_a_file_is_the_road_it_was() {
        var names = ["playing", "casting", "wantsPlaying", "parked", "shifted"];
        var words = ["Stop", "Pause", "PlayPause", "Play"];
        for (var bits = 0; bits < 32; bits++) {
            var f = {};
            for (var n = 0; n < names.length; n++) f[names[n]] = (bits & (1 << n)) !== 0;
            for (var w = 0; w < words.length; w++)
                compare(key(words[w], f), before(words[w], f), words[w] + " in " + JSON.stringify(f));
        }
    }

    function test_the_roads_a_station_knows() {
        compare(key("Pause", { "playing": true, "wantsPlaying": true }), "pause");
        compare(key("PlayPause", { "playing": true, "wantsPlaying": true }), "pause");
        compare(key("Play", { "parked": true }), "resume");
        compare(key("PlayPause", { "parked": true }), "resume");
        compare(key("Play", { "shifted": true }), "unpause");
        compare(key("PlayPause", { "shifted": true }), "unpause");
        compare(key("PlayPause", { "playing": true, "shifted": true }), "pause");
        compare(key("Play", { "playing": true, "shifted": true }), "none");
        compare(key("Pause", { "casting": true }), "stop");
        compare(key("Pause", { "wantsPlaying": true }), "stop");
        compare(key("Play", { "playing": true }), "none");
        compare(key("Play", {}), "bare");
    }

    function test_no_word_does_the_opposite_of_what_it_says() {
        // Stop and Pause never start anything; Play never silences anything.
        var starts = ["resume", "unpause", "bare"], silences = ["stop", "pause", "keep"];
        for (var bits = 0; bits < 128; bits++) {
            var b = function(n) { return (bits & (1 << n)) !== 0; };
            var args = [b(0), b(1), b(2), b(3), b(4), b(5), b(6)];
            var said = function(cmd) { return TL.mediaKey(cmd, args[0], args[1], args[2], args[3], args[4], args[5], args[6]); };
            verify(starts.indexOf(said("Stop")) < 0, "Stop starts something in " + bits);
            verify(starts.indexOf(said("Pause")) < 0, "Pause starts something in " + bits);
            verify(silences.indexOf(said("Play")) < 0, "Play silences something in " + bits);
            // A file is kept only out of a local player that is audible.
            if (said("Pause") === "keep" || said("PlayPause") === "keep") verify(args[0] && args[5], "kept in " + bits);
        }
    }

    function test_a_word_nobody_knows_does_nothing() {
        var on = { "playing": true, "ownFile": true };
        compare(key("pause", on), "none");
        compare(key("", on), "none");
        compare(key(undefined, on), "none");
        compare(key(null, {}), "none");
        compare(key(7, {}), "none");
        compare(key("Play" + new Array(5000).join("y"), {}), "none");
        compare(key("Seek 1000000", on), "none");
    }

    function test_the_transport_takes_nothing_but_true() {
        compare(TL.mediaKey("Pause", 1, 0, 0, 0, 0, "yes", 0), "none");
        compare(TL.mediaKey("Pause", true, false, false, false, false, 1, false), "pause");
        compare(TL.mediaKey("Stop", undefined, null, "true", {}, [], 1, "1"), "none");
        compare(TL.mediaKey("Play"), "bare");
        compare(TL.mediaKey("PlayPause", false, false, false, false, false, false, 1), "bare");
        compare(TL.bareplay(false, -1, 12, 1).what, "station");
        compare(TL.bareplay(false, -1, 12, "true").what, "station");
        compare(TL.bareplay(false, -1, 12).what, "station");
    }

    // filePause: playing() is a My Music file sounding; the rest of what
    // main.qml hands over for a pause is added here.
    function pausing(over) {
        var p = playing({ "casting": false, "stopping": false, "raw": "", "title": "A song", "key": "", "show": "", "art": "",
                          "feed": "", "positionMs": 42700, "seekSec": -1 });
        for (var k in over) p[k] = over[k];
        return p;
    }

    // The second a pause kept, or a sentence when it kept nothing at all.
    function secOf(over) {
        var r = TL.filePause(pausing(over));
        return r === null ? "nothing kept" : r.sec;
    }

    function test_a_my_music_file_is_kept_with_its_second() {
        var r = TL.filePause(pausing({}));
        verify(r !== null);
        compare(r.episode, false);
        compare(r.url, "file:///home/u/Music/OnAir/song.mp3");
        compare(r.title, "A song");
        compare(r.sec, 42);
        // An address left over from an episode is not this file's.
        var stale = TL.filePause(pausing({ "raw": "file:///home/u/Podcasts/old.mp3" }));
        compare(stale === null ? "nothing kept" : stale.url, "file:///home/u/Music/OnAir/song.mp3");
    }

    function test_an_episode_is_kept_with_everything_its_start_was_told() {
        var disk = "file:///home/u/Podcasts/ep%201.mp3", raw = "file:///home/u/Podcasts/ep 1.mp3";
        var r = TL.filePause(pausing({ "source": disk, "episode": disk, "raw": raw, "title": "Episode one",
                                       "key": "guid-1", "show": "The Show", "art": "http://art.example/c.png",
                                       "feed": "http://feed.example/rss", "positionMs": 754000 }));
        verify(r !== null);
        compare(r.episode, true);
        // The address it was started with, not the player's spelling of it:
        // the start compares that one when it decides what is already on.
        compare(r.url, raw);
        compare(r.title, "Episode one");
        compare(r.key, "guid-1");
        compare(r.show, "The Show");
        compare(r.art, "http://art.example/c.png");
        compare(r.feed, "http://feed.example/rss");
        compare(r.sec, 754);
    }

    function test_a_streamed_episode_is_kept_like_one_on_disk() {
        var stream = "https://cdn.example/show/ep1.mp3?x=1";
        var r = TL.filePause(pausing({ "source": stream, "episode": stream, "raw": stream, "key": "guid-1",
                                       "positionMs": 91999 }));
        verify(r !== null);
        compare(r.episode, true);
        compare(r.url, stream);
        compare(r.sec, 91);
        // An episode whose start address was not recorded comes back by the
        // player's own.
        var bare = TL.filePause(pausing({ "source": stream, "episode": stream, "raw": "" }));
        compare(bare === null ? "nothing kept" : bare.url, stream);
    }

    function test_a_pause_while_the_file_still_loads_keeps_the_second_it_was_going_to() {
        // The resume seek waits for the media to load and the needle reads 0
        // until it lands.
        compare(secOf({ "positionMs": 0, "seekSec": 597 }), 597);
        compare(secOf({ "positionMs": 12000, "seekSec": 0 }), 0);
        compare(secOf({ "positionMs": 0, "seekSec": -1 }), 0);
    }

    function test_what_is_not_the_listeners_own_file_is_not_kept() {
        compare(TL.filePause(pausing({ "source": "http://ice.example/live" })), null);
        compare(TL.filePause(pausing({ "preview": true, "source": "http://ice.example/try" })), null);
        compare(TL.filePause(pausing({ "source": "file:///usr/share/onair/chime.ogg" })), null);
        compare(TL.filePause(pausing({ "source": "file:///run/user/1000/onair/ts-7.mka", "shifted": true })), null);
        compare(TL.filePause(pausing({ "source": "file:///run/user/1000/onair/ts-7.mka" })), null);
        compare(TL.filePause(pausing({ "audible": false })), null);
        compare(TL.filePause(pausing({ "source": "" })), null);
    }

    function test_nothing_is_kept_while_a_device_carries_the_stream() {
        compare(TL.filePause(pausing({ "casting": true })), null);
        // Nor when nobody can say whether one does.
        compare(TL.filePause(pausing({ "casting": undefined })), null);
        compare(TL.filePause(pausing({ "casting": 0 })), null);
    }

    function test_a_pause_nobody_can_read_keeps_nothing_or_keeps_it_whole() {
        compare(TL.filePause(), null);
        compare(TL.filePause(null), null);
        compare(TL.filePause({}), null);
        compare(TL.filePause("file:///x.mp3"), null);
        var r = TL.filePause(pausing({ "title": undefined, "key": 7, "show": null, "art": {}, "feed": [],
                                       "raw": undefined, "positionMs": "soon", "seekSec": "later" }));
        verify(r !== null);
        compare(r.title, "");
        compare(r.key, "");
        compare(r.show, "");
        compare(r.art, "");
        compare(r.feed, "");
        compare(r.url, "file:///home/u/Music/OnAir/song.mp3");
        compare(r.sec, 0);
        compare(secOf({ "positionMs": -5000 }), 0);
        compare(secOf({ "positionMs": NaN, "seekSec": NaN }), 0);
        compare(secOf({ "positionMs": Infinity }), 0);
    }

    function test_a_place_far_off_the_scale_still_fits_the_seek() {
        // The seek is kept in a 32-bit property.
        compare(secOf({ "positionMs": 9e15 }), 2147483647);
        compare(secOf({ "seekSec": 9e15 }), 2147483647);
        var url = "file:///" + new Array(5000).join("a") + ".mp3";
        var kept = TL.filePause(pausing({ "source": url }));
        compare(kept === null ? "nothing kept" : kept.url, url);
    }

    function test_the_desk_reads_a_paused_file_as_paused() {
        compare(TL.playbackStatus(false, false, false, false, true), "Paused");
        compare(TL.playbackStatus(true, false, false, false, false), "Playing");
        compare(TL.playbackStatus(false, true, false, false, false), "Playing");
        compare(TL.playbackStatus(false, false, true, false, false), "Paused");
        compare(TL.playbackStatus(false, false, false, true, false), "Paused");
        compare(TL.playbackStatus(false, false, false, false, false), "Stopped");
        // The stop that keeps a file fades first, and what fades still plays.
        compare(TL.playbackStatus(true, false, false, false, true), "Playing");
    }

    function test_the_status_takes_nothing_but_true() {
        compare(TL.playbackStatus(), "Stopped");
        compare(TL.playbackStatus(1, "yes", {}, [], "true"), "Stopped");
        compare(TL.playbackStatus(undefined, null, undefined, null, 1), "Stopped");
    }

    // ── which knob the output menu's volume row turns ────────────────────
    // The system default selected, a television carrying the stream, this
    // computer silent: the row's slider and mute turned this computer's
    // master. volumeRoad(casting, localAlong, combine, followsDefault, dragRoad).

    function test_a_device_playing_alone_is_what_the_row_turns() {
        // The reported state first: follow-default routing, cast only.
        compare(TL.volumeRoad(true, false, false, true, ""), "player");
        compare(TL.volumeRoad(true, false, false, false, ""), "player");
        // A sync group that is up but silent does not claim the row either.
        compare(TL.volumeRoad(true, false, true, true, ""), "player");
        compare(TL.volumeRoad(true, false, true, false, ""), "player");
    }

    function test_this_computer_alone_keeps_the_knob_its_routing_gives() {
        compare(TL.volumeRoad(false, false, false, true, ""), "sink");
        compare(TL.volumeRoad(false, false, false, false, ""), "player");
    }

    function test_a_sync_group_is_the_rooms_knob() {
        compare(TL.volumeRoad(false, false, true, false, ""), "sink");
        compare(TL.volumeRoad(false, false, true, true, ""), "sink");
    }

    function test_a_device_that_is_only_ticked_changes_nothing() {
        // Not casting: whatever is ticked, and whatever the multi-room box
        // was left at, the answer is this computer's own.
        compare(TL.volumeRoad(false, true, false, true, ""), "sink");
        compare(TL.volumeRoad(false, true, false, false, ""), "player");
        compare(TL.volumeRoad(false, false, false, true, ""), "sink");
    }

    function test_this_computer_beside_a_device_keeps_the_road_it_had() {
        compare(TL.volumeRoad(true, true, false, true, ""), "sink");
        compare(TL.volumeRoad(true, true, true, false, ""), "sink");
        compare(TL.volumeRoad(true, true, false, false, ""), "player");
    }

    function test_a_drag_keeps_the_knob_it_started_on() {
        // The cast ended under the pointer: the gesture stays the widget's own.
        compare(TL.volumeRoad(false, false, false, true, "player"), "player");
        // A cast began under it: the gesture stays the room's.
        compare(TL.volumeRoad(true, false, false, true, "sink"), "sink");
        compare(TL.volumeRoad(true, false, false, true, ""), "player");
    }

    function test_a_drag_road_nobody_knows_is_no_drag() {
        var odd = [undefined, null, "cast", "Sink", 1, true, {}, "player" + new Array(4000).join("r")];
        for (var i = 0; i < odd.length; i++) {
            compare(TL.volumeRoad(true, false, false, true, odd[i]), "player", "drag " + i);
            compare(TL.volumeRoad(false, false, false, true, odd[i]), "sink", "drag " + i);
        }
    }

    function test_the_road_takes_nothing_but_true() {
        // A cast nobody can read is no cast, and a routing nobody can read
        // is the widget's own volume: that one reaches no further than this widget.
        compare(TL.volumeRoad(1, false, false, true, ""), "sink");
        compare(TL.volumeRoad("yes", false, false, true, ""), "sink");
        compare(TL.volumeRoad(true, 1, false, true, ""), "player");
        compare(TL.volumeRoad(true, "true", false, true, ""), "player");
        compare(TL.volumeRoad(false, false, 1, "yes", ""), "player");
        compare(TL.volumeRoad(), "player");
        compare(TL.volumeRoad(undefined, undefined, undefined, undefined, undefined), "player");
    }

    function test_a_mute_displaces_a_level_that_still_waits_to_be_saved() {
        compare(TL.muteDisplaces(25, 0), true);
        compare(TL.muteDisplaces(100, 0), true);
        compare(TL.muteDisplaces(1, 0), true);
        compare(TL.muteDisplaces(25, -0.2), true);
    }

    function test_nothing_is_displaced_when_nothing_waits_or_nothing_is_muted() {
        compare(TL.muteDisplaces(-1, 0), false);
        // A mute that is already waiting has no level to lose.
        compare(TL.muteDisplaces(0, 0), false);
        compare(TL.muteDisplaces(25, 0.3), false);
        compare(TL.muteDisplaces(25, 1), false);
        compare(TL.muteDisplaces(25, 0.01), false);
    }

    function test_a_level_nobody_can_read_displaces_nothing() {
        compare(TL.muteDisplaces(), false);
        compare(TL.muteDisplaces(NaN, 0), false);
        compare(TL.muteDisplaces("25", 0), false);
        compare(TL.muteDisplaces(null, 0), false);
        compare(TL.muteDisplaces(Infinity, 0), false);
        compare(TL.muteDisplaces(25, NaN), false);
        compare(TL.muteDisplaces(25, undefined), false);
        compare(TL.muteDisplaces(25, "0"), false);
        compare(TL.muteDisplaces(9e15, 0), true);
    }

    // ── the face of the big button, and a pause that stays on the page ───
    // Since 2026.44 a press on the big button keeps an episode's place, and
    // the button still read Stop there: it asked only about the timeshift
    // buffer. The face is what a press does, and it is asked of the very
    // facts the press is answered from. facts(): mediaKey's eight, nothing on.

    function facts(over) {
        var f = { "playing": false, "casting": false, "wantsPlaying": false, "parked": false,
                  "shifted": false, "ownFile": false, "pausedFile": false, "inPlace": false };
        for (var k in over) f[k] = over[k];
        return [f.playing, f.casting, f.wantsPlaying, f.parked, f.shifted, f.ownFile, f.pausedFile, f.inPlace];
    }

    function test_an_episode_or_a_file_that_plays_wears_the_pause_face() {
        compare(TL.face(facts({ "playing": true, "ownFile": true }), false), "pause");
        // The timeshift buffer has nothing to do with it.
        compare(TL.face(facts({ "playing": true, "ownFile": true }), true), "pause");
    }

    function test_a_paused_file_wears_the_play_face() {
        compare(TL.face(facts({ "pausedFile": true, "inPlace": true }), false), "play");
        compare(TL.face(facts({ "pausedFile": true }), false), "play");
    }

    function test_live_radio_with_no_buffer_keeps_the_stop_face() {
        // A live stream cannot be paused, and the button must not promise it.
        compare(TL.face(facts({ "playing": true, "wantsPlaying": true }), false), "stop");
    }

    function test_the_buffers_states_show_what_they_showed() {
        compare(TL.face(facts({ "playing": true, "wantsPlaying": true }), true), "pause");
        compare(TL.face(facts({ "parked": true }), true), "play");
        compare(TL.face(facts({ "playing": true, "shifted": true }), false), "pause");
        compare(TL.face(facts({ "shifted": true }), true), "play");
    }

    function test_a_cast_keeps_the_stop_face() {
        // The device's place is not known, so nothing is kept there.
        compare(TL.face(facts({ "casting": true }), false), "stop");
        compare(TL.face(facts({ "playing": true, "casting": true }), false), "stop");
    }

    function test_nothing_on_is_the_play_face() {
        compare(TL.face(facts({}), false), "play");
        compare(TL.face(facts({ "wantsPlaying": true }), false), "play");
    }

    function test_for_every_state_the_face_is_what_a_press_does() {
        // What each answer of the transport means to the person pressing.
        for (var bits = 0; bits < 512; bits++) {
            var b = function(n) { return (bits & (1 << n)) !== 0; };
            var f = [b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7)], buffer = b(8);
            var act = TL.keyFor("PlayPause", f), shown = TL.face(f, buffer), where = "state " + bits;
            if (act === "keep") compare(shown, "pause", where);
            else if (act === "pause") compare(shown, (buffer || f[4]) ? "pause" : "stop", where);
            else if (act === "resume" || act === "unpause" || act === "bare") compare(shown, "play", where);
            else fail("PlayPause answered " + act + " in " + where);
        }
    }

    function test_a_face_nobody_can_read_is_play() {
        compare(TL.face(), "play");
        compare(TL.face(null, true), "play");
        compare(TL.face("playing", true), "play");
        compare(TL.face([1, "yes", {}, [], "true", 1, 1, 1], true), "play");
        compare(TL.face(facts({ "playing": true }), "yes"), "stop");
        compare(TL.face(facts({ "playing": true, "ownFile": 1 }), false), "stop");
        var many = facts({ "playing": true, "ownFile": true });
        for (var i = 0; i < 5000; i++) many.push(true);
        compare(TL.face(many, false), "pause");
    }

    function test_the_facts_as_an_array_are_the_facts() {
        var words = ["Stop", "Pause", "PlayPause", "Play", "Next", ""];
        for (var bits = 0; bits < 256; bits++) {
            var b = function(n) { return (bits & (1 << n)) !== 0; };
            var f = [b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7)];
            for (var w = 0; w < words.length; w++)
                compare(TL.keyFor(words[w], f), TL.mediaKey(words[w], f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]),
                        words[w] + " in " + bits);
        }
        compare(TL.keyFor("Play"), "bare");
        compare(TL.keyFor("Play", null), "bare");
        compare(TL.keyFor("Stop", "x"), "none");
    }

    function test_a_file_the_player_still_holds_simply_plays_on() {
        compare(key("Play", { "pausedFile": true, "inPlace": true }), "unpause");
        compare(key("PlayPause", { "pausedFile": true, "inPlace": true }), "unpause");
        // The player lost it, or it streams: it is started again from what was kept.
        compare(key("Play", { "pausedFile": true }), "bare");
        compare(key("PlayPause", { "pausedFile": true }), "bare");
        // In place means nothing without a pause that keeps something.
        compare(key("Play", { "inPlace": true }), "bare");
        compare(key("PlayPause", { "inPlace": true }), "bare");
        compare(TL.mediaKey("Play", false, false, false, false, false, false, true, 1), "bare");
    }

    function test_a_pause_in_place_changes_no_other_word() {
        compare(key("Pause", { "pausedFile": true, "inPlace": true }), "none");
        compare(key("Stop", { "pausedFile": true, "inPlace": true }), "stop");
        // Nothing but a paused player is asked to play on.
        var starts = 0;
        for (var bits = 0; bits < 256; bits++) {
            var b = function(n) { return (bits & (1 << n)) !== 0; };
            var f = [b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7)];
            var play = TL.keyFor("Play", f), toggle = TL.keyFor("PlayPause", f);
            if (play === "unpause" || toggle === "unpause") { verify(f[4] || (f[6] && f[7]), "state " + bits); starts++; }
            verify(["resume", "unpause", "bare"].indexOf(TL.keyFor("Stop", f)) < 0, "Stop starts in " + bits);
            verify(["resume", "unpause", "bare"].indexOf(TL.keyFor("Pause", f)) < 0, "Pause starts in " + bits);
        }
        verify(starts > 0);
    }

    function test_the_player_holds_a_kept_file_only_paused_and_on_disk() {
        var kept = TL.filePause(pausing({}));
        verify(kept !== null && kept.local === true, "a file on disk is not kept as one");
        compare(TL.inPlace(kept, true), true);
        compare(TL.inPlace(kept, false), false);
        var stream = "https://cdn.example/show/ep1.mp3";
        var away = TL.filePause(pausing({ "source": stream, "episode": stream, "raw": stream, "key": "guid-1" }));
        verify(away !== null && away.local === false, "a streamed episode is kept as a file on disk");
        // The server drops a connection nobody reads from: it is opened again.
        compare(TL.inPlace(away, true), false);
    }

    function test_in_place_takes_nothing_but_a_kept_file_and_true() {
        compare(TL.inPlace(), false);
        compare(TL.inPlace(null, true), false);
        compare(TL.inPlace(undefined, true), false);
        compare(TL.inPlace("file:///x.mp3", true), false);
        compare(TL.inPlace({}, true), false);
        compare(TL.inPlace({ "local": 1 }, true), false);
        compare(TL.inPlace({ "local": true }, 1), false);
        compare(TL.inPlace({ "local": true }, "true"), false);
        compare(TL.inPlace({ "local": true }, true), true);
    }

    function test_what_a_stop_is_fading_out_is_not_kept() {
        compare(TL.ownFile(pausing({})), true);
        compare(TL.ownFile(pausing({ "stopping": true })), false);
        compare(TL.filePause(pausing({ "stopping": true })), null);
        // Nor when nobody can say whether a stop runs.
        compare(TL.ownFile(pausing({ "stopping": undefined })), false);
        compare(TL.ownFile(pausing({ "stopping": 0 })), false);
    }

    function test_own_file_is_the_rule_a_pause_keeps_by() {
        var cases = [{}, { "casting": true }, { "source": "http://ice.example/live" }, { "audible": false },
                     { "preview": true }, { "shifted": true }, { "source": "file:///usr/share/onair/chime.ogg" },
                     { "source": "" }, { "stopping": true }, { "casting": undefined }];
        for (var i = 0; i < cases.length; i++)
            compare(TL.ownFile(pausing(cases[i])), TL.filePause(pausing(cases[i])) !== null, JSON.stringify(cases[i]));
        compare(TL.ownFile(), false);
        compare(TL.ownFile(null), false);
        compare(TL.ownFile({}), false);
    }

    function test_a_kept_file_is_opened_again_where_its_needle_stands() {
        // The player still sits paused and was moved along its line since.
        compare(TL.needle(754, true, 912300), 912);
        // The player lost the pause: the second that was kept.
        compare(TL.needle(754, false, 0), 754);
        compare(TL.needle(754, false, 912300), 754);
    }

    function test_a_needle_taken_to_the_start_under_a_pause_is_the_listeners_choice() {
        // Paused at 120 s, the seek slider dragged to the start: zero is a place, not a needle nobody knows.
        compare(TL.needle(120, true, 0), 0);
        compare(TL.needle(120, true, 0, false), 0);
        compare(TL.needle(120, true, 500), 0);
        compare(TL.needle(120, true, 999), 0);
        compare(TL.needle(120, true, 1000), 1);
    }

    function test_a_needle_whose_seek_still_waits_for_the_file_to_load_is_not_known_yet() {
        // The pause came while the episode was loading: the player reads zero until the seek lands.
        compare(TL.needle(597, true, 0, true), 597);
        compare(TL.needle(597, true, 4000, true), 597);
        // Anything but a plain true is no seek waiting.
        compare(TL.needle(597, true, 0, "true"), 0);
        compare(TL.needle(597, true, 0, 1), 0);
    }

    function test_a_second_nobody_knows_leaves_the_place_to_the_bookmark() {
        // The player does not hold the source and nothing was kept above the first second.
        compare(TL.needle(0, false, 0), -1);
        compare(TL.needle(0.9, false, 0), -1);
        compare(TL.needle(0, true, 0, true), -1);
        compare(TL.needle(), -1);
        compare(TL.needle(NaN, true, NaN), -1);
        compare(TL.needle("754", "true", "912300"), -1);
        compare(TL.needle(-5, true, -912300), -1);
        compare(TL.needle(754, 1, 912300), 754);
        compare(TL.needle(754.9, false, 0), 754);
        compare(TL.needle(9e15, false, 0), 2147483647);
        compare(TL.needle(1, true, 9e15), 2147483647);
    }


    function test_a_tap_on_the_row_that_plays_or_is_paused_is_the_transports_toggle() {
        compare(TL.rowTap(true, true, false, false), true);
        compare(TL.rowTap(true, false, true, false), true);
        // Another row, or the same one with nothing on: a start.
        compare(TL.rowTap(false, true, false, false), false);
        compare(TL.rowTap(false, false, true, false), false);
        compare(TL.rowTap(true, false, false, false), false);
    }

    function test_the_wake_up_starts_its_episode_by_its_own_road() {
        // The episode the alarm wants sits paused: the alarm does not resume
        // it through a person's toggle, it starts it.
        compare(TL.rowTap(true, false, true, true), false);
        compare(TL.rowTap(true, false, true, undefined), true);
        compare(TL.rowTap(true, false, true, 1), true);
    }

    function test_a_row_tap_takes_nothing_but_true() {
        compare(TL.rowTap(), false);
        compare(TL.rowTap(1, true, true, false), false);
        compare(TL.rowTap(true, 1, "yes", false), false);
        compare(TL.rowTap("true", true, true, false), false);
    }

    function test_a_stop_stays_within_reach_of_a_file_that_plays_or_is_paused() {
        // The big button is a Pause on an episode, so the stop lives beside it.
        verify(TL.stopOffered(true, false, false, false, false, true, false));
        // And a paused file is held: it can be let go of.
        verify(TL.stopOffered(false, false, false, false, false, false, true));
        verify(!TL.stopOffered(false, false, false, false, false, false, false));
        verify(!TL.stopOffered(false, false, false, false, false, false, 1));
    }

    function test_the_stop_beside_the_button_is_there_exactly_when_the_button_is_no_stop() {
        for (var bits = 0; bits < 512; bits++) {
            var b = function(n) { return (bits & (1 << n)) !== 0; };
            var f = [b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7)], shown = TL.face(f, b(8));
            var holds = TL.held(f[0], f[1], f[2], f[3], f[4], f[6]);
            compare(TL.stopOffered(f[0], f[1], f[2], f[3], f[4], shown === "pause", f[6]),
                    holds && shown !== "stop", "state " + bits);
        }
    }

    function test_a_list_write_leaves_a_paused_file_in_the_player() {
        // playing() is the star's and the trash's facts; nothing sounds here.
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "paused": true })), true);
        var stream = "https://cdn.example/show/ep1.mp3";
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "paused": true, "source": stream, "episode": stream })), true);
        // The pause only speaks for a file the player still holds.
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "paused": true, "source": "" })), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "paused": true, "source": "http://ice.example/live" })), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "paused": true, "preview": true })), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "paused": 1 })), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": false, "paused": "true" })), false);
        compare(TL.listWriteKeepsSound(playing({ "audible": false })), false);
    }

    function test_a_file_that_is_paused_already_is_not_kept_a_second_time() {
        compare(TL.ownFile(pausing({ "audible": false, "paused": true })), false);
        compare(TL.filePause(pausing({ "audible": false, "paused": true })), null);
    }

    function test_a_paused_file_is_held() {
        verify(TL.held(false, false, false, false, false, true));
        verify(!TL.held(false, false, false, false, false, false));
        verify(!TL.held(false, false, false, false, false, 1));
        verify(!TL.held(false, false, false, false, false));
    }

    // ── one master for this computer and a device that play together ─────
    // On the default sink the menu's slider moved this computer's master and
    // left a device that played along where it stood; with an output pinned
    // the same slider moved both. The rule: a device is sent
    // deviceLevel(castMaster(...), its balance), in every routing.

    function test_a_device_is_sent_the_master_times_its_balance() {
        compare(TL.deviceLevel(0.6, 0.5), 0.3);
        compare(TL.deviceLevel(0.6, 1), 0.6);
        compare(TL.deviceLevel(1, 1), 1);
        compare(TL.deviceLevel(0.8, 0.05), 0.04);
    }

    function test_the_balance_survives_a_master_at_zero() {
        // It is a stored number: nothing is worked out of two levels that are both 0.
        compare(TL.deviceLevel(0, 0.5), 0);
        compare(TL.deviceLevel(0.6, 0.5), 0.3);
    }

    function test_a_device_is_never_sent_more_than_the_master_or_than_full() {
        compare(TL.deviceLevel(1, 1), 1);
        compare(TL.deviceLevel(7, 1), 1);
        compare(TL.deviceLevel(1, 7), 1);
        compare(TL.deviceLevel(0.5, 7), 0.5);
        compare(TL.deviceLevel(9e15, 9e15), 1);
        // Just off the scale is off the scale: a balance of 1.5 is not one, a master of 1.5 is full.
        compare(TL.deviceLevel(0.5, 1.5), 0.5);
        compare(TL.deviceLevel(1.5, 0.5), 0.5);
    }

    function test_a_balance_nobody_can_read_is_full_level_and_a_master_nobody_can_read_is_silence() {
        compare(TL.deviceLevel(0.5), 0.5);
        compare(TL.deviceLevel(0.5, null), 0.5);
        compare(TL.deviceLevel(0.5, "0.5"), 0.5);
        compare(TL.deviceLevel(0.5, NaN), 0.5);
        compare(TL.deviceLevel(0.5, 0.0005), 0.5);
        compare(TL.deviceLevel(0.5, -1), 0.5);
        compare(TL.deviceLevel(), 0);
        compare(TL.deviceLevel(NaN, 0.5), 0);
        compare(TL.deviceLevel("0.6", 0.5), 0);
        compare(TL.deviceLevel(-3, 0.5), 0);
    }

    function test_beside_this_computer_on_the_rooms_knob_a_device_follows_both_volumes() {
        // The room at 40 %, the widget's own volume at 75 %.
        compare(TL.castMaster("sink", 40, false, false, 0.75), 0.3);
        compare(TL.castMaster("sink", 80, false, false, 0.75), 0.6);
        compare(TL.castMaster("sink", 100, false, false, 1), 1);
        // The room's master above its own 100 % is full, not more.
        compare(TL.castMaster("sink", 150, false, false, 1), 1);
    }

    function test_on_the_widgets_own_knob_a_device_follows_the_widgets_volume() {
        // A device alone, or beside a pinned output: this computer's master is not the row's.
        compare(TL.castMaster("player", 40, false, false, 0.75), 0.75);
        compare(TL.castMaster("player", 40, true, false, 0.75), 0.75);
        compare(TL.castMaster("player", -1, false, false, 0.2), 0.2);
    }

    function test_silent_is_silent_for_the_device_whichever_was_muted() {
        compare(TL.castMaster("sink", 40, true, false, 0.75), 0);
        compare(TL.castMaster("sink", 40, false, true, 0.75), 0);
        compare(TL.castMaster("player", 40, false, true, 0.75), 0);
        compare(TL.castMaster("sink", 0, false, false, 0.75), 0);
    }

    function test_a_device_is_muted_by_the_listener_and_by_nothing_else() {
        // Not muted is the level the volume stands at for the listener, whatever the stream is
        // passing through: castMaster is not told the stream at all.
        compare(TL.castMaster("player", -1, false, false, 0.75), 0.75);
        compare(TL.castMaster("sink", 40, false, false, 0.75), 0.3);
        // And anything but a plain true is not a mute.
        compare(TL.castMaster("sink", 40, false, undefined, 0.75), 0.3);
        compare(TL.castMaster("sink", 40, false, "true", 0.75), 0.3);
        compare(TL.castMaster("sink", 40, false, 1, 0.75), 0.3);
        compare(TL.castMaster("sink", 40, false, 0, 0.75), 0.3);
        compare(TL.castMaster("sink", 40, false, NaN, 0.75), 0.3);
    }

    function test_a_room_nobody_has_read_yet_leaves_the_widgets_own_volume() {
        compare(TL.castMaster("sink", -1, false, false, 0.75), 0.75);
        compare(TL.castMaster("sink", undefined, false, false, 0.75), 0.75);
        compare(TL.castMaster("sink", NaN, false, false, 0.75), 0.75);
        compare(TL.castMaster("sink", "40", false, false, 0.75), 0.75);
    }

    function test_a_master_takes_nothing_it_cannot_read() {
        compare(TL.castMaster(), 0);
        compare(TL.castMaster("sink", 40, false, false), 0);
        compare(TL.castMaster("sink", 40, false, false, NaN), 0);
        compare(TL.castMaster("sink", 40, false, false, "0.75"), 0);
        compare(TL.castMaster("sink", 40, 1, false, 0.75), 0.3);
        compare(TL.castMaster("Sink", 40, false, false, 0.75), 0.75);
        compare(TL.castMaster(undefined, 40, false, false, 0.75), 0.75);
        compare(TL.castMaster("sink", 40, false, false, 7), 0.4);
        compare(TL.castMaster("sink", 40, false, false, -3), 0);
        compare(TL.castMaster("sink", 9e15, false, false, 9e15), 1);
    }

    // ownMute(stood, byHand, level): whether the listener's own mute stands
    // after the widget's volume was written.

    function test_a_gesture_at_zero_is_the_listeners_mute_and_one_above_it_ends_it() {
        compare(TL.ownMute(false, true, 0), true);
        compare(TL.ownMute(true, true, 0), true);
        compare(TL.ownMute(true, true, 0.4), false);
        compare(TL.ownMute(false, true, 0.4), false);
    }

    function test_a_zero_nobody_asked_for_is_no_mute() {
        // A start, the end of a fade, a calibration: the stream is written to zero by the widget.
        compare(TL.ownMute(false, false, 0), false);
        // And one that was asked for stands through it.
        compare(TL.ownMute(true, false, 0), true);
    }

    function test_anything_that_lifts_the_stream_ends_the_mute() {
        // The first frame of a fade is enough: 0.00064 was measured 20 ms into one.
        compare(TL.ownMute(true, false, 0.00064), false);
        compare(TL.ownMute(true, false, 0.8), false);
        compare(TL.ownMute(true, false, 1e-12), false);
    }

    function test_a_mute_takes_nothing_but_true_and_a_level_it_can_read() {
        compare(TL.ownMute(), false);
        compare(TL.ownMute("true", false, 0), false);
        compare(TL.ownMute(1, false, 0), false);
        compare(TL.ownMute(false, "true", 0), false);
        compare(TL.ownMute(false, 1, 0), false);
        // A gesture whose level nobody can read mutes nothing, and a write nobody can read lifts nothing.
        compare(TL.ownMute(false, true), false);
        compare(TL.ownMute(false, true, NaN), false);
        compare(TL.ownMute(false, true, "0"), false);
        compare(TL.ownMute(true, false, NaN), true);
        compare(TL.ownMute(true, false, "0.8"), true);
        compare(TL.ownMute(true, false), true);
    }

    function test_a_mute_off_the_scale_is_still_one_or_none() {
        compare(TL.ownMute(false, true, -9e15), true);
        compare(TL.ownMute(false, true, 9e15), false);
        compare(TL.ownMute(true, false, 9e15), false);
        compare(TL.ownMute(true, false, -9e15), true);
    }

    // roomFollowed(casting, road): whether a device that plays follows this
    // computer's master as the widget last read it.

    function test_a_device_beside_this_computer_on_the_rooms_knob_follows_the_reading() {
        compare(TL.roomFollowed(true, "sink"), true);
    }

    function test_nothing_follows_the_reading_without_a_device_or_on_the_widgets_own_knob() {
        compare(TL.roomFollowed(false, "sink"), false);
        compare(TL.roomFollowed(true, "player"), false);
        compare(TL.roomFollowed(false, "player"), false);
    }

    function test_the_reading_is_followed_by_nothing_it_cannot_read() {
        compare(TL.roomFollowed(), false);
        compare(TL.roomFollowed(1, "sink"), false);
        compare(TL.roomFollowed("true", "sink"), false);
        compare(TL.roomFollowed(true, "Sink"), false);
        compare(TL.roomFollowed(true, undefined), false);
        compare(TL.roomFollowed(true, "sink" + new Array(4000).join("k")), false);
    }

    // masterGesture(gesture, road, casting, localAlong, level, stream, target, ownMuted)

    function test_a_stream_at_zero_that_nobody_muted_does_not_silence_the_device() {
        // A click on the slider while a start or a calibration has the stream at zero.
        var to = TL.masterGesture("move", "sink", true, true, 0.5, 0, 0.75, false);
        compare(to.sink, 50);
        compare(to.cast, 0.375);
        // Anything but a plain true is not a mute.
        compare(TL.masterGesture("move", "sink", true, true, 0.5, 0, 0.75).cast, 0.375);
        compare(TL.masterGesture("move", "sink", true, true, 0.5, 0, 0.75, "true").cast, 0.375);
        compare(TL.masterGesture("move", "sink", true, true, 0.5, 0, 0.75, 1).cast, 0.375);
    }

    function test_under_the_listeners_own_mute_the_slider_moves_the_room_and_the_device_stays_silent() {
        var to = TL.masterGesture("move", "sink", true, true, 0.5, 0, 0.75, true);
        compare(to.sink, 50);
        compare(to.cast, 0);
        // Whatever the stream is at: the first frame of a fade does not undo what the listener said.
        compare(TL.masterGesture("move", "sink", true, true, 0.5, 0.3, 0.75, true).cast, 0);
    }

    function test_the_slider_beside_a_device_moves_the_room_and_the_device() {
        var to = TL.masterGesture("move", "sink", true, true, 0.5, 0.75, 0.75);
        compare(to.sink, 50);
        compare(to.cast, 0.375);
        compare(to.player, -1);
        compare(to.sinkMute, false);
        // The same factor for both: twice the room is twice the device.
        compare(TL.masterGesture("move", "sink", true, true, 1, 0.75, 0.75).cast, 0.75);
    }

    function test_the_slider_at_zero_silences_both_and_comes_back_for_both() {
        var down = TL.masterGesture("move", "sink", true, true, 0, 0.75, 0.75);
        compare(down.sink, 0);
        compare(down.cast, 0);
        var up = TL.masterGesture("move", "sink", true, true, 0.4, 0.75, 0.75);
        compare(up.sink, 40);
        compare(up.cast, 0.3);
    }

    function test_the_mute_beside_a_device_is_for_both() {
        var to = TL.masterGesture("mute", "sink", true, true, 0, 0.75, 0.75);
        compare(to.sinkMute, true);
        compare(to.castFollows, true);
        compare(to.sink, -1);
        compare(to.player, -1);
        compare(to.cast, -1);
    }

    function test_this_computer_alone_keeps_the_rooms_knob_to_itself() {
        var move = TL.masterGesture("move", "sink", false, false, 0.5, 0.75, 0.75);
        compare(move.sink, 50);
        compare(move.cast, -1);
        var mute = TL.masterGesture("mute", "sink", false, false, 0, 0.75, 0.75);
        compare(mute.sinkMute, true);
        compare(mute.castFollows, false);
    }

    function test_a_device_that_is_only_ticked_is_told_nothing() {
        // Not casting, whatever the multi-room box was left at.
        compare(TL.masterGesture("move", "sink", false, true, 0.5, 0.75, 0.75).cast, -1);
        compare(TL.masterGesture("mute", "sink", false, true, 0, 0.75, 0.75).castFollows, false);
        // And a drag that began on the room's knob before a device took over alone stays the room's.
        compare(TL.masterGesture("move", "sink", true, false, 0.5, 0.75, 0.75).cast, -1);
        compare(TL.masterGesture("mute", "sink", true, false, 0, 0.75, 0.75).castFollows, false);
    }

    function test_on_the_widgets_own_knob_the_gestures_are_what_they_were() {
        var move = TL.masterGesture("move", "player", true, false, 0.25, 0.75, 0.75);
        compare(move.player, 0.25);
        compare(move.sink, -1);
        compare(move.cast, -1);
        // Mute is the level 0, and the unmute the level before it.
        compare(TL.masterGesture("mute", "player", true, true, 0, 0.6, 0.75).player, 0);
        compare(TL.masterGesture("mute", "player", true, true, 0, 0, 0.75).player, 0.75);
        compare(TL.masterGesture("mute", "player", false, false, 0, 0.6, 0.75).sinkMute, false);
    }

    function test_a_gesture_nobody_can_read_sends_nothing() {
        var none = function(to) { return to.sink === -1 && to.player === -1 && to.cast === -1 && to.sinkMute === false && to.castFollows === false; };
        verify(none(TL.masterGesture()));
        verify(none(TL.masterGesture("wave", "sink", true, true, 0.5, 0.75, 0.75)));
        verify(none(TL.masterGesture("move", "sink", true, true, NaN, 0.75, 0.75)));
        verify(none(TL.masterGesture("move", "sink", true, true, "0.5", 0.75, 0.75)));
        verify(none(TL.masterGesture("move", "sink", true, true, undefined, 0.75, 0.75)));
        verify(none(TL.masterGesture("mute", "player", true, true, 0, 0, NaN)));
        verify(none(TL.masterGesture("move" + new Array(4000).join("e"), "sink", true, true, 0.5, 0.75, 0.75)));
    }

    function test_a_gesture_takes_nothing_but_true_and_a_level_on_the_scale() {
        compare(TL.masterGesture("move", "sink", 1, "yes", 0.5, 0.75, 0.75).cast, -1);
        compare(TL.masterGesture("mute", "sink", true, 1, 0, 0.75, 0.75).castFollows, false);
        compare(TL.masterGesture("move", "sink", true, true, 7, 0.75, 0.75).sink, 100);
        compare(TL.masterGesture("move", "sink", true, true, -3, 0.75, 0.75).sink, 0);
        compare(TL.masterGesture("move", "player", true, true, 9e15, 0.75, 0.75).player, 1);
        compare(TL.masterGesture("mute", "player", false, false, 0, 0, 1.5).player, 1);
        compare(TL.masterGesture("mute", "player", false, false, 0, 0, -0.5).player, 0);
        // The room's knob is whole per cent, the nearest one: 0.29 x 100 is 28.999999999999996.
        compare(TL.masterGesture("move", "sink", false, false, 0.29, 0.75, 0.75).sink, 29);
        // A road nobody knows is the widget's own: that one reaches no further than this widget.
        compare(TL.masterGesture("move", "Sink", true, true, 0.5, 0.75, 0.75).player, 0.5);
        compare(TL.masterGesture("move", undefined, true, true, 0.5, 0.75, 0.75).sink, -1);
    }

    // rebalance(balance, wasRoad, sinkPct, target): "This computer" ticked
    // or unticked beside a device that plays, on the default sink.

    function test_a_device_keeps_its_level_when_this_computer_leaves() {
        // Together it followed 0.75 x 0.40 = 0.30, at half: 0.15. Alone it follows 0.75: the same 0.15 is a fifth.
        compare(TL.rebalance(0.5, "sink", 40, 0.75), 0.2);
        compare(TL.deviceLevel(TL.castMaster("player", 40, false, 1, 0.75), TL.rebalance(0.5, "sink", 40, 0.75)),
                TL.deviceLevel(TL.castMaster("sink", 40, false, 1, 0.75), 0.5));
    }

    function test_a_device_keeps_its_level_when_this_computer_joins() {
        compare(TL.rebalance(0.2, "player", 40, 0.75), 0.5);
        compare(TL.deviceLevel(TL.castMaster("sink", 40, false, 1, 0.75), TL.rebalance(0.2, "player", 40, 0.75)),
                TL.deviceLevel(TL.castMaster("player", 40, false, 1, 0.75), 0.2));
    }

    function test_a_device_above_the_new_master_comes_down_to_it_and_never_goes_up() {
        // At 0.60 of its scale while the pair will play at 0.30: full balance is all there is.
        compare(TL.rebalance(0.8, "player", 40, 0.75), 1);
        // And the other way a balance only gets smaller.
        for (var pct = 0; pct <= 100; pct += 5)
            verify(TL.rebalance(0.8, "sink", pct, 0.75) < 0.8 + 1e-9, "room at " + pct);
    }

    function test_a_round_trip_gives_the_balance_back() {
        var there = TL.rebalance(0.5, "sink", 40, 0.75);
        compare(TL.rebalance(there, "player", 40, 0.75), 0.5);
    }

    function test_a_balance_stays_on_its_scale() {
        compare(TL.rebalance(0.1, "sink", 10, 0.75), 0.01);
        compare(TL.rebalance(0.002, "sink", 10, 0.75), 0.001);
        compare(TL.rebalance(1, "player", 100, 0.75), 1);
        compare(TL.rebalance(0.5, "sink", 100, 0.75), 0.5);
        compare(TL.rebalance(0.5, "sink", 150, 0.75), 0.5);
        compare(TL.rebalance(0.5, "player", 9e15, 0.75), 0.5);
    }

    function test_a_master_nobody_can_read_or_at_zero_leaves_the_balance() {
        // The room unknown is the widget's own volume on both sides.
        compare(TL.rebalance(0.5, "sink", -1, 0.75), 0.5);
        compare(TL.rebalance(0.5, "player", undefined, 0.75), 0.5);
        // The room at zero, the widget's volume at zero: nothing to measure against.
        compare(TL.rebalance(0.5, "player", 0, 0.75), 0.5);
        compare(TL.rebalance(0.5, "sink", 0, 0.75), 0.5);
        compare(TL.rebalance(0.5, "sink", 40, 0), 0.5);
        compare(TL.rebalance(0.5, "sink", 40, NaN), 0.5);
        compare(TL.rebalance(0.5, "sink", 40), 0.5);
    }

    function test_a_balance_or_a_road_nobody_can_read_is_full_level() {
        compare(TL.rebalance(undefined, "sink", 100, 0.75), 1);
        compare(TL.rebalance("0.5", "sink", 100, 0.75), 1);
        compare(TL.rebalance(7, "sink", 40, 0.75), 0.4);
        compare(TL.rebalance(1.5, "sink", 40, 0.75), 0.4);
        compare(TL.rebalance(), 1);
        // A road that is neither knob was no change of knob.
        compare(TL.rebalance(0.5, "Sink", 40, 0.75), 0.5);
        compare(TL.rebalance(0.5, undefined, 40, 0.75), 0.5);
    }

    // skipRoad(p, kept, playerPaused, seekable): where Next, Previous, Seek
    // and SetPosition from the desk go.

    readonly property var epOn: ({ "audible": true, "casting": false, "source": "file:///p/e.mp3", "episode": "file:///p/e.mp3" })
    readonly property var epKept: ({ "episode": true, "local": true, "url": "file:///p/e.mp3", "sec": 120 })
    function epFacts(over) { return Object.assign({}, epOn, over) }

    function test_an_episode_that_plays_is_skipped_inside() {
        compare(TL.skipRoad(epOn, null, false, true), "skip");
    }

    function test_an_episode_a_pause_keeps_in_the_player_is_skipped_inside() {
        compare(TL.skipRoad(epFacts({ "audible": false }), epKept, true, true), "skip");
        // A streamed one sits paused in the player just the same.
        compare(TL.skipRoad(epFacts({ "audible": false, "source": "https://c/e.mp3", "episode": "https://c/e.mp3" }),
                            Object.assign({}, epKept, { "local": false }), true, true), "skip");
    }

    function test_an_episode_held_by_its_record_alone_goes_nowhere() {
        // The player lost it; the episode's key may be gone with it.
        compare(TL.skipRoad(epFacts({ "audible": false }), epKept, false, true), "none");
        compare(TL.skipRoad(epFacts({ "audible": false, "source": "", "episode": "" }), epKept, false, false), "none");
    }

    function test_an_episode_that_cannot_be_sought_goes_nowhere() {
        compare(TL.skipRoad(epOn, null, false, false), "none");
        compare(TL.skipRoad(epFacts({ "audible": false }), epKept, true, false), "none");
    }

    function test_an_episode_a_device_carries_goes_nowhere() {
        compare(TL.skipRoad(epFacts({ "audible": false, "casting": true, "source": "" }), null, false, false), "none");
        // With this computer playing along, its own needle moves as it did.
        compare(TL.skipRoad(epFacts({ "casting": true }), null, false, true), "skip");
    }

    function test_with_no_episode_held_next_and_previous_are_the_stations() {
        compare(TL.skipRoad(epFacts({ "episode": "" }), null, false, true), "station");
        compare(TL.skipRoad(epFacts({ "audible": false, "source": "", "episode": "" }), null, false, false), "station");
        // A My Music file, playing or kept by a pause, is not an episode.
        compare(TL.skipRoad(epFacts({ "episode": "", "source": "file:///m/s.flac" }), null, false, true), "station");
        compare(TL.skipRoad(epFacts({ "audible": false, "episode": "" }), { "episode": false, "local": true }, true, true), "station");
        // An episode's key left standing over another source is not an episode that plays.
        compare(TL.skipRoad(epFacts({ "source": "http://radio.example/live" }), null, false, false), "station");
    }

    function test_a_road_takes_nothing_it_cannot_read() {
        compare(TL.skipRoad(), "station");
        compare(TL.skipRoad(null, null, true, true), "station");
        compare(TL.skipRoad("episode", "kept", "true", "true"), "station");
        compare(TL.skipRoad(epFacts({ "audible": 1 }), null, false, true), "station");
        compare(TL.skipRoad(epFacts({ "audible": false }), epKept, 1, true), "none");
        compare(TL.skipRoad(epOn, null, false, 1), "none");
        compare(TL.skipRoad(epFacts({ "audible": false }), { "episode": "true" }, true, true), "station");
        compare(TL.skipRoad(epFacts({ "audible": false }), [], true, true), "station");
    }

    // deskNeedle(cmd, positionMs, durationMs): where the needle goes, in ms.

    function test_next_and_previous_are_the_skip_buttons() {
        compare(TL.deskNeedle("Next", 120000, 1800000), 150000);
        compare(TL.deskNeedle("Previous", 120000, 1800000), 105000);
    }

    function test_seek_is_relative_and_setposition_absolute_in_microseconds() {
        compare(TL.deskNeedle("Seek 30000000", 120000, 1800000), 150000);
        compare(TL.deskNeedle("Seek -5000000", 120000, 1800000), 115000);
        compare(TL.deskNeedle("SetPos 180000000", 120000, 1800000), 180000);
        compare(TL.deskNeedle("SetPos 0", 120000, 1800000), 0);
    }

    function test_a_needle_parks_at_either_end() {
        compare(TL.deskNeedle("Next", 1790000, 1800000), 1800000);
        compare(TL.deskNeedle("Previous", 5000, 1800000), 0);
        compare(TL.deskNeedle("Seek -900000000000", 120000, 1800000), 0);
        compare(TL.deskNeedle("Seek 900000000000", 120000, 1800000), 1800000);
        compare(TL.deskNeedle("SetPos 9000000000000", 120000, 1800000), 1800000);
        // A length nobody knows yet is no end.
        compare(TL.deskNeedle("Next", 120000, 0), 150000);
        compare(TL.deskNeedle("Next", 120000), 150000);
    }

    function test_a_position_below_zero_is_refused() {
        compare(TL.deskNeedle("SetPos -1", 120000, 1800000), -1);
        compare(TL.deskNeedle("SetPos -1000000", 120000, 1800000), -1);
    }

    function test_a_word_or_a_number_nobody_can_read_moves_no_needle() {
        var words = [undefined, null, "", "Seek", "Seek ", "Seek abc", "SetPos", "SetPos x", "Seek NaN", "SetPos Infinity",
                     "Seek Infinity", "next", "Nextt", "Play", "Stop", "Rate 1.5", "Volume 0.4", 7, "Seek 1e999"];
        for (var i = 0; i < words.length; i++) compare(TL.deskNeedle(words[i], 120000, 1800000), -1, String(words[i]));
        compare(TL.deskNeedle("Next", NaN, 1800000), 30000);
        compare(TL.deskNeedle("Next", "120000", 1800000), 30000);
        compare(TL.deskNeedle("Next", -5, 1800000), 30000);
        compare(TL.deskNeedle("Seek 1" + new Array(400).join("0"), 120000, 1800000), -1);
    }

    // stationStep(cmd, lastPlay, count): the row Next and Previous go to.

    function test_next_and_previous_walk_the_list_and_wrap() {
        compare(TL.stationStep("Next", 0, 3), 1);
        compare(TL.stationStep("Next", 2, 3), 0);
        compare(TL.stationStep("Previous", 1, 3), 0);
        compare(TL.stationStep("Previous", 0, 3), 2);
    }

    function test_from_nothing_played_next_is_the_first_row_and_previous_the_last() {
        compare(TL.stationStep("Next", -1, 3), 0);
        compare(TL.stationStep("Previous", -1, 3), 2);
        compare(TL.stationStep("Next", 0, 1), 0);
        compare(TL.stationStep("Previous", 0, 1), 0);
    }

    function test_an_empty_list_has_no_step_and_a_row_past_its_end_comes_back_into_it() {
        compare(TL.stationStep("Next", 0, 0), -1);
        compare(TL.stationStep("Previous", 0, 0), -1);
        compare(TL.stationStep("Next", 7, 3), 2);
        compare(TL.stationStep("Previous", 7, 3), 2);
    }

    function test_a_step_takes_nothing_it_cannot_read() {
        compare(TL.stationStep(), -1);
        compare(TL.stationStep("Seek 1", 0, 3), -1);
        compare(TL.stationStep("next", 0, 3), -1);
        compare(TL.stationStep("Next", 0, "3"), -1);
        compare(TL.stationStep("Next", 0, NaN), -1);
        compare(TL.stationStep("Next", NaN, 3), 0);
        compare(TL.stationStep("Next", "1", 3), 0);
        compare(TL.stationStep("Next", -9e15, 3), 0);
        var far = TL.stationStep("Next", 9e15, 9e15);
        verify(far >= 0 && far < 9e15);
    }

    // keptAt(kept, positionMs): what a pause keeps, after its needle moved.

    function test_the_kept_second_follows_the_needle() {
        var moved = TL.keptAt(epKept, 150000);
        compare(moved.sec, 150);
        compare(moved.url, epKept.url);
        compare(moved.episode, true);
        compare(epKept.sec, 120, "the record handed in was written over");
        compare(TL.keptAt(epKept, 0).sec, 0);
        compare(TL.keptAt(epKept, 999).sec, 0);
    }

    function test_a_needle_nobody_can_read_leaves_what_was_kept() {
        compare(TL.keptAt(epKept, NaN).sec, 120);
        compare(TL.keptAt(epKept, -5).sec, 120);
        compare(TL.keptAt(epKept, "150000").sec, 120);
        compare(TL.keptAt(epKept).sec, 120);
        compare(TL.keptAt(null, 150000), null);
        compare(TL.keptAt(undefined, 150000), null);
        compare(TL.keptAt("kept", 150000), null);
        compare(TL.keptAt(epKept, 9e15).sec, 2147483647);
    }

    // A balance the widget worked out by itself may be below the 5 % the
    // row's slider starts at, and must never raise a level.

    function test_a_device_is_sent_a_balance_below_the_sliders_five_per_cent() {
        compare(TL.deviceLevel(0.8, 0.01), 0.008);
        compare(TL.deviceLevel(1, 0.001), 0.001);
        // Under the thousandth a device can be told at all it is no balance, like anything else nobody can read.
        compare(TL.deviceLevel(0.8, 0.0005), 0.8);
        compare(TL.deviceLevel(0.8, 0), 0.8);
    }

    function test_leaving_a_quiet_room_does_not_raise_the_device() {
        // Room 10 %, widget 80 %, balance 0.1: the device stands at 0.008. Alone it follows 0.8.
        compare(TL.rebalance(0.1, "sink", 10, 0.8), 0.01);
        verify(TL.deviceLevel(TL.castMaster("player", 10, false, false, 0.8), TL.rebalance(0.1, "sink", 10, 0.8)) <= 0.008 + 1e-12);
    }

    function test_coming_back_finds_the_balance_it_had() {
        compare(TL.rebalance(0.01, "player", 10, 0.8), 0.1);
        compare(TL.rebalance(TL.rebalance(0.1, "sink", 10, 0.8), "player", 10, 0.8), 0.1);
        compare(TL.rebalance(TL.rebalance(0.37, "sink", 23, 0.6), "player", 23, 0.6), 0.37);
        // In a quiet room too: cut at the thousandth a device is told, 0.555 came back as 0.55.
        compare(TL.rebalance(TL.rebalance(0.555, "sink", 10, 0.8), "player", 10, 0.8), 0.555);
    }

    function test_no_tick_raises_a_level_whatever_the_room_and_the_balance() {
        var balances = [0.001, 0.004, 0.01, 0.05, 0.1, 0.37, 0.5, 0.999, 1];
        for (var pct = 1; pct <= 100; pct += 3) {
            for (var i = 0; i < balances.length; i++) {
                var b = balances[i], pair = TL.castMaster("sink", pct, false, false, 0.8), alone = TL.castMaster("player", pct, false, false, 0.8);
                var left = TL.rebalance(b, "sink", pct, 0.8), joined = TL.rebalance(b, "player", pct, 0.8);
                // The thousandth is the smallest step a device is told; below it there is nothing left to keep.
                verify(alone * left <= pair * b + 0.001 * alone + 1e-12, "leaving at " + pct + " % with " + b + ": " + left);
                verify(pair * joined <= alone * b + 1e-12, "joining at " + pct + " % with " + b + ": " + joined);
                verify(left >= 0.001 && left <= 1 && joined >= 0.001 && joined <= 1);
            }
        }
    }

    function test_a_master_at_zero_leaves_a_small_balance_as_it_is() {
        compare(TL.rebalance(0.01, "sink", 0, 0.8), 0.01);
        compare(TL.rebalance(0.01, "player", 0, 0.8), 0.01);
        compare(TL.rebalance(0.01, "sink", 40, 0), 0.01);
    }

    function test_a_balance_worked_out_is_never_stored_above_itself() {
        compare(TL.balanceBelow(0.0149), 0.0149);
        compare(TL.balanceBelow(0.01), 0.01);
        compare(TL.balanceBelow(0.5), 0.5);
        compare(TL.balanceBelow(0.9996), 0.9996);
        compare(TL.balanceBelow(1), 1);
        compare(TL.balanceBelow(0.0123456789), 0.012345);
        // What division leaves a hair under a decimal is that decimal.
        compare(TL.balanceBelow(0.09999999999999999), 0.1);
        for (var i = 1; i <= 1000; i++) {
            var exact = i / 1000 * 0.737;
            verify(TL.balanceBelow(exact) <= Math.max(0.001, exact) + 1e-9, "raised " + exact);
        }
    }

    function test_a_balance_worked_out_stays_on_its_scale() {
        compare(TL.balanceBelow(1.7), 1);
        compare(TL.balanceBelow(9e15), 1);
        compare(TL.balanceBelow(0.0002), 0.001);
        compare(TL.balanceBelow(0), 0.001);
        compare(TL.balanceBelow(-1), 0.001);
        compare(TL.balanceBelow(), 1);
        compare(TL.balanceBelow(NaN), 1);
        compare(TL.balanceBelow("0.5"), 1);
        compare(TL.balanceBelow(null), 1);
    }

    // --- panelAction: the panel icon's right-click menu ----------------------

    function _panel(over) {
        var f = { "face": "play", "canPlay": true, "episode": false, "stations": 3,
                  "muted": false, "sleeping": false, "sounding": false };
        for (var k in over) f[k] = over[k];
        return f;
    }

    function test_the_menus_first_entry_is_the_big_buttons_press() {
        compare(TL.panelAction("key", _panel({})), { word: "play", icon: "media-playback-start", enabled: true, shown: true });
        compare(TL.panelAction("key", _panel({ face: "stop", sounding: true })),
                { word: "stop", icon: "media-playback-stop", enabled: true, shown: true });
        compare(TL.panelAction("key", _panel({ face: "pause", sounding: true })),
                { word: "pause", icon: "media-playback-pause", enabled: true, shown: true });
        // Play with nothing to play is there, greyed, as the big button is.
        compare(TL.panelAction("key", _panel({ canPlay: false })).enabled, false);
        compare(TL.panelAction("key", _panel({ canPlay: false })).shown, true);
        // A Stop or a Pause is never greyed by "nothing to play".
        compare(TL.panelAction("key", _panel({ face: "stop", canPlay: false })).enabled, true);
        compare(TL.panelAction("key", _panel({ face: "pause", canPlay: false })).enabled, true);
        // A face nobody knows is a Play.
        compare(TL.panelAction("key", _panel({ face: "loud" })).word, "play");
        compare(TL.panelAction("key", _panel({ face: undefined })).word, "play");
    }

    function test_next_station_is_offered_where_next_means_a_station() {
        compare(TL.panelAction("next", _panel({})), { word: "next", icon: "media-skip-forward", enabled: true, shown: true });
        // One station, or none, has no next one.
        compare(TL.panelAction("next", _panel({ stations: 1 })).shown, false);
        compare(TL.panelAction("next", _panel({ stations: 0 })).shown, false);
        compare(TL.panelAction("next", _panel({ stations: 2 })).shown, true);
        // Over an episode Next moves inside it, which is not what the words say.
        compare(TL.panelAction("next", _panel({ episode: true })).shown, false);
        compare(TL.panelAction("next", _panel({ stations: "3" })).shown, false);
        compare(TL.panelAction("next", _panel({ stations: NaN })).shown, false);
        compare(TL.panelAction("next", _panel({ stations: 4000 })).shown, true);
    }

    function test_mute_and_the_sleep_timer_are_offered_while_something_sounds() {
        compare(TL.panelAction("mute", _panel({})).shown, false);
        compare(TL.panelAction("sleep", _panel({})).shown, false);
        compare(TL.panelAction("mute", _panel({ sounding: true })),
                { word: "mute", icon: "audio-volume-muted", enabled: true, shown: true });
        compare(TL.panelAction("mute", _panel({ sounding: true, muted: true })),
                { word: "unmute", icon: "audio-volume-high", enabled: true, shown: true });
        // A mute that stands is offered its way back also when nothing sounds.
        compare(TL.panelAction("mute", _panel({ muted: true })).shown, true);
        compare(TL.panelAction("mute", _panel({ muted: true })).word, "unmute");
        compare(TL.panelAction("sleep", _panel({ sounding: true })),
                { word: "sleep", icon: "chronometer", enabled: true, shown: true });
        // A running timer can be cancelled whatever else is true.
        compare(TL.panelAction("sleep", _panel({ sleeping: true })),
                { word: "wake", icon: "dialog-cancel", enabled: true, shown: true });
        compare(TL.panelAction("sleep", _panel({ sleeping: true, sounding: true })).word, "wake");
    }

    function test_a_kind_or_facts_nobody_knows_show_nothing_and_do_not_throw() {
        var none = { word: "", icon: "", enabled: false, shown: false };
        compare(TL.panelAction("record", _panel({ sounding: true })), none);
        compare(TL.panelAction("", _panel({})), none);
        compare(TL.panelAction(undefined, _panel({})), none);
        compare(TL.panelAction(7, _panel({})), none);
        // No facts at all: the idle menu, nothing playable.
        var bare = [undefined, null, 7, "x", []];
        for (var i = 0; i < bare.length; i++) {
            compare(TL.panelAction("key", bare[i]), { word: "play", icon: "media-playback-start", enabled: false, shown: true });
            compare(TL.panelAction("next", bare[i]).shown, false);
            compare(TL.panelAction("mute", bare[i]).shown, false);
            compare(TL.panelAction("sleep", bare[i]).shown, false);
        }
        // Facts that are not exactly true do not count as true.
        compare(TL.panelAction("mute", _panel({ sounding: "yes" })).shown, false);
        compare(TL.panelAction("sleep", _panel({ sleeping: 1 })).word, "sleep");
        compare(TL.panelAction("key", _panel({ canPlay: "true" })).enabled, false);
    }

    // --- volumeName: what the output menu's volume row is called --------------

    function test_the_volume_row_is_named_after_what_it_turns() {
        // The default output, alone or with a device playing along.
        compare(TL.volumeName("sink", false, false), "system");
        compare(TL.volumeName("sink", true, true), "system");
        compare(TL.volumeName("sink", false, true), "system");
        // A device playing alone follows the widget's own level.
        compare(TL.volumeName("player", true, false), "device");
        // An output of the widget's own, with or without a device beside it.
        compare(TL.volumeName("player", false, false), "own");
        compare(TL.volumeName("player", false, true), "own");
        compare(TL.volumeName("player", true, true), "own");
        // The name follows volumeRoad for every state it can answer.
        var bools = [true, false];
        for (var c = 0; c < 2; c++) for (var l = 0; l < 2; l++) for (var k = 0; k < 2; k++) for (var d = 0; d < 2; d++) {
            var road = TL.volumeRoad(bools[c], bools[l], bools[k], bools[d], "");
            var name = TL.volumeName(road, bools[c], bools[l]);
            compare(name === "system", road === "sink", [c, l, k, d].join(""));
            compare(name === "device", road === "player" && bools[c] && !bools[l], [c, l, k, d].join(""));
        }
    }

    function test_a_road_or_facts_nobody_knows_name_the_widgets_own_volume() {
        compare(TL.volumeName("", false, false), "own");
        compare(TL.volumeName(undefined, undefined, undefined), "own");
        compare(TL.volumeName(null, true, false), "own");
        compare(TL.volumeName("SINK", false, false), "own");
        compare(TL.volumeName(7, true, false), "own");
        // What is not exactly true is not true.
        compare(TL.volumeName("player", "yes", false), "own");
        compare(TL.volumeName("player", 1, 0), "own");
        compare(TL.volumeName("player", true, "no"), "device");
        compare(TL.volumeName("player", true, undefined), "device");
        compare(TL.volumeName(new Array(5000).join("sink"), true, false), "own");
    }
}
