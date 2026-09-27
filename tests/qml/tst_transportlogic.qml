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
}
