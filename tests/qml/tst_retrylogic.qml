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
}
