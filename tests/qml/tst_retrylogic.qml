// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// How long a quiet station keeps being knocked at. The widget cannot tell a
// dropped connection from a station that has gone away — most stream deaths
// arrive with no error at all — so the budget decides instead of a
// diagnosis, and the numbers below ARE the promise made in the settings
// text. The alarm's exemption is the one rule here that must never bend.
import QtQuick
import QtTest

import "../../package/contents/ui/RetryLogic.js" as RL

TestCase {
    name: "RetryLogic"

    function test_the_ladder_widens_and_then_stays_at_ten_minutes() {
        compare(RL.nextRetryMs(0), 30000);
        compare(RL.nextRetryMs(1), 60000);
        compare(RL.nextRetryMs(2), 120000);
        compare(RL.nextRetryMs(3), 240000);
        compare(RL.nextRetryMs(4), 480000);
        // Past here the doubling would outrun the cap, and an outage is not
        // worth knocking at once an hour.
        compare(RL.nextRetryMs(5), 600000);
        compare(RL.nextRetryMs(9), 600000);
    }

    function test_a_stray_attempt_count_cannot_produce_a_silly_interval() {
        compare(RL.nextRetryMs(-3), 30000);
        compare(RL.nextRetryMs(undefined), 30000);
    }

    function test_the_budget_ends_the_knocking_after_its_last_round() {
        // Three knocks: armed at 0, 1 and 2, refused at 3. This is what the
        // default promises and what issue #13 asked for.
        verify(RL.shouldKnock(true, false, 0, 3));
        verify(RL.shouldKnock(true, false, 2, 3));
        verify(!RL.shouldKnock(true, false, 3, 3));
        verify(!RL.shouldKnock(true, false, 40, 3));
    }

    function test_three_knocks_span_three_and_a_half_minutes() {
        // Derived from the ladder, not written down beside it: 30 s + 1 min
        // + 2 min. A stream that really dropped answers well inside this.
        compare(RL.budgetMs(3), 210000);
        compare(RL.budgetMs(1), 30000);
        compare(RL.budgetMs(5), 930000);
    }

    function test_zero_still_means_knock_until_it_comes_back() {
        // The behaviour before the budget existed stays reachable — someone
        // whose station is simply slow to return can ask for it.
        verify(RL.shouldKnock(true, false, 0, 0));
        verify(RL.shouldKnock(true, false, 500, 0));
        compare(RL.budgetMs(0), 0);
    }

    function test_the_switch_off_means_no_knock_at_any_count() {
        verify(!RL.shouldKnock(false, false, 0, 3));
        verify(!RL.shouldKnock(false, false, 0, 0));
    }

    function test_an_alarm_is_bound_by_neither_the_switch_nor_the_budget() {
        // A wake-up was promised in advance. Neither a setting about
        // ordinary listening nor a budget meant to stop pointless knocking
        // may end one in silence.
        verify(RL.shouldKnock(false, true, 0, 3));
        verify(RL.shouldKnock(false, true, 99, 3));
        verify(RL.shouldKnock(true, true, 99, 1));
    }

    // ── the order has a deadline the wall clock keeps ─────────────────────
    //
    // The budget is counted in knocks, and the knocks ride QML timers, which
    // stand still while the machine sleeps. A stream that dies at eleven
    // with the lid closed a minute later still had knocks left at eight the
    // next morning, and the network coming back handed it one: a radio that
    // starts on its own nine hours after it went quiet. The order therefore
    // carries the moment it went quiet, and the wall clock ends it.

    function test_an_order_inside_its_window_is_still_good() {
        var died = 1000000;
        verify(!RL.orderExpired(died, died + 30000, false, 3));
        // The three knocks and the connects between them take longer than
        // the sum of the waits; the window leaves them room.
        verify(!RL.orderExpired(died, died + 7 * 60000, false, 3));
    }

    function test_an_order_that_slept_through_the_night_is_over() {
        var died = 1000000;
        verify(RL.orderExpired(died, died + 9 * 3600000, false, 3));
        // The default: twice the budget and five minutes, twelve in all.
        verify(!RL.orderExpired(died, died + 12 * 60000, false, 3));
        verify(RL.orderExpired(died, died + 12 * 60000 + 1, false, 3));
        // One knock is half a minute; its order is over after six.
        verify(RL.orderExpired(died, died + 6 * 60000 + 1, false, 1));
    }

    function test_an_alarm_never_expires_and_neither_does_keep_trying_forever() {
        var died = 1000000;
        verify(!RL.orderExpired(died, died + 9 * 3600000, true, 3));    // a wake-up was promised
        verify(!RL.orderExpired(died, died + 9 * 3600000, false, 0));   // the listener chose forever
    }

    function test_an_order_with_no_stamp_cannot_expire() {
        verify(!RL.orderExpired(0, 9 * 3600000, false, 3));
        verify(!RL.orderExpired(undefined, 9 * 3600000, false, 3));
    }

    // ── what the footer says while the ladder waits ───────────────────────
    //
    // Between knocks the player is idle, and the footer read "Choose station
    // and enjoy…" under the station's own name for the whole wait (bench,
    // 2026-09-23: a station at a dead address, 30 s of it before knock #1).

    function test_a_station_waiting_for_its_next_knock_is_between_knocks() {
        verify(RL.betweenKnocks(true, 1));
        verify(RL.betweenKnocks(true, 3));
    }

    function test_no_order_or_no_knock_yet_is_not_waiting() {
        // A stop and a spent budget both end the order; the first connect
        // has not knocked at all and says "Connecting…" on its own road.
        verify(!RL.betweenKnocks(false, 2));
        verify(!RL.betweenKnocks(true, 0));
        verify(!RL.betweenKnocks(false, 0));
        verify(!RL.betweenKnocks(undefined, undefined));
    }

    // ── the moment the deadline counts from ───────────────────────────────
    // Measured on HEAD 2026-09-27: main.qml:6612 clears the quiet stamp on
    // every BufferedMedia, so a playing station has none, and main.qml:4018
    // then stamped "now" and walked straight through orderExpired.

    function test_an_armed_ladder_keeps_its_own_moment() {
        compare(RL.orderSince(1000, 500, 9999), 1000);
    }

    function test_a_playing_station_is_dated_by_when_it_was_last_heard() {
        // No quiet stamp, because audio was flowing. The night belongs to
        // the heard-at moment, not to the instant of asking.
        compare(RL.orderSince(0, 1000, 9999), 1000);
    }

    function test_an_order_with_neither_gets_its_first_try() {
        compare(RL.orderSince(0, 0, 9999), 9999);
    }

    function test_a_night_asleep_ends_the_order_the_morning_after() {
        // Eleven at night to eight in the morning, the default three knocks.
        var night = 9 * 60 * 60 * 1000;
        var since = RL.orderSince(0, 0 + 1, 1 + night);
        verify(RL.orderExpired(since, 1 + night, false, 3));
    }

    function test_a_short_nap_does_not_end_it() {
        // A minute with the lid shut must still come back — the deadline is
        // for orders hours old, not for every gap.
        var nap = 60 * 1000;
        var since = RL.orderSince(0, 1, 1 + nap);
        verify(!RL.orderExpired(since, 1 + nap, false, 3));
    }

    function test_garbage_dates_nothing_older_than_now() {
        compare(RL.orderSince(undefined, undefined, 4242), 4242);
        compare(RL.orderSince(-5, -5, 4242), 4242);
    }

    // orderLapsed: every automatic road that can put sound back asks it.
    readonly property double hour: 3600000

    function test_a_night_asleep_lapses_the_order() {
        verify(RL.orderLapsed(true, 0, 1000, 1000 + 9 * hour, false, 3));
    }

    function test_the_ladder_armed_after_waking_still_lapses() {
        // The ladder stamps its first knock from the last moment it was heard,
        // so arming it in the morning cannot make last night look fresh.
        var heard = 1000, wake = 1000 + 9 * hour;
        var stamp = RL.orderSince(0, heard, wake);
        verify(RL.orderLapsed(true, stamp, heard, wake + 30000, false, 3));
    }

    function test_a_short_nap_does_not_lapse_it() {
        verify(!RL.orderLapsed(true, 0, 1000, 1000 + 5 * 60000, false, 3));
    }

    function test_the_deadline_boundary_is_the_same_as_orderExpired() {
        var edge = RL.budgetMs(3) * 2 + 300000;
        verify(!RL.orderLapsed(true, 0, 1000, 1000 + edge, false, 3));
        verify(RL.orderLapsed(true, 0, 1000, 1000 + edge + 1, false, 3));
    }

    function test_no_standing_order_is_never_lapsed() {
        // A preview or a file played after a stop is nobody's order, even with
        // a stamp left over from last night.
        verify(!RL.orderLapsed(false, 0, 1000, 1000 + 9 * hour, false, 3));
        verify(!RL.orderLapsed(undefined, 5, 1000, 1000 + 9 * hour, false, 3));
    }

    function test_an_alarm_is_never_lapsed() {
        verify(!RL.orderLapsed(true, 0, 1000, 1000 + 9 * hour, true, 3));
    }

    function test_knocking_off_keeps_the_old_semantics() {
        verify(!RL.orderLapsed(true, 0, 1000, 1000 + 9 * hour, false, 0));
    }

    function test_a_person_pressing_play_after_waking_is_fresh() {
        // Their press dates the order as heard that moment, whatever last
        // night left behind.
        var wake = 1000 + 9 * hour;
        verify(!RL.orderLapsed(true, 0, wake, wake + 30000, false, 3));
    }

    function test_garbage_stamps_lapse_nothing() {
        verify(!RL.orderLapsed(true, NaN, undefined, 1000, false, 3));
        verify(!RL.orderLapsed(true, -1, -1, 1000, false, 3));
    }

    // beatOnTime: did the heartbeat tick come on time, or after a sleep?
    function test_an_on_time_tick_is_on_time() {
        verify(RL.beatOnTime(1000, 61000, 60000));
    }

    function test_a_tick_after_the_machine_slept_is_late() {
        verify(!RL.beatOnTime(1000, 1000 + 9 * hour, 60000));
    }

    function test_the_first_tick_has_nothing_to_compare() {
        verify(!RL.beatOnTime(0, 61000, 60000));
    }

    function test_the_beat_boundary_is_two_intervals() {
        verify(RL.beatOnTime(1000, 1000 + 120000, 60000));
        verify(!RL.beatOnTime(1000, 1000 + 120001, 60000));
    }

    function test_garbage_beats_are_never_on_time() {
        verify(!RL.beatOnTime(undefined, 61000, 60000));
        verify(!RL.beatOnTime(1000, NaN, 60000));
        verify(!RL.beatOnTime(-5, 61000, 60000));
    }
}
