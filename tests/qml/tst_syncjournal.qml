// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The two lines the sync writes for things it used to do in silence, to the
// letter. That the engine says them when it should, once, and that the
// other writers of the map keep their own words is what
// tests/test_sync_journal.py reads out of a run of the engine.
import QtQuick
import QtTest

import "../../package/contents/ui/SyncJournal.js" as SJ

TestCase {
    name: "SyncJournal"

    readonly property string a181: "{\"24:C4:06:9F:13:C6\":181}"
    readonly property string a161: "{\"24:C4:06:9F:13:C6\":161}"

    function test_a_delay_set_by_hand_is_said_with_the_map_before_and_after() {
        compare(SJ.handSet(a181, a161),
                "[ARP] sync: fine-tune set by hand (slider, wheel or ms field) — map "
                + "{\"24:C4:06:9F:13:C6\":181} -> {\"24:C4:06:9F:13:C6\":161}");
    }

    function test_the_first_entry_of_an_empty_map_is_a_change() {
        compare(SJ.handSet("{}", a161),
                "[ARP] sync: fine-tune set by hand (slider, wheel or ms field) — map {} -> " + a161);
    }

    function test_a_map_that_holds_what_it_held_is_not_said() {
        compare(SJ.handSet(a161, a161), "");
        compare(SJ.handSet("{}", "{}"), "");
    }

    function test_the_same_entries_laid_out_differently_are_the_same_map() {
        compare(SJ.handSet("{ \"a\": 181,\n \"b\": 0 }", "{\"b\":0,\"a\":181}"), "");
        compare(SJ.handSet("{\"a\":181.0}", "{\"a\":181}"), "");
    }

    function test_one_entry_more_or_less_is_a_change() {
        verify(SJ.handSet("{\"a\":181}", "{\"a\":181,\"b\":0}") !== "");
        verify(SJ.handSet("{\"a\":181,\"b\":0}", "{\"a\":181}") !== "");
        verify(SJ.handSet("{\"a\":181}", "{\"b\":181}") !== "");
    }

    function test_a_map_that_cannot_be_read_is_compared_as_it_is_written() {
        // Nothing to take apart, so the text is all there is to go by.
        compare(SJ.handSet("{", "{"), "");
        compare(SJ.handSet("not a map", "not a map"), "");
        verify(SJ.handSet("{", a161) !== "");
        verify(SJ.handSet(a161, "{") !== "");
        compare(SJ.handSet("[1,2]", "[1,2]"), "");
        verify(SJ.handSet("181", "161") !== "");
    }

    function test_no_map_at_all_is_an_empty_one() {
        compare(SJ.handSet("", "{}"), "");
        compare(SJ.handSet(undefined, "{}"), "");
        compare(SJ.handSet(null, null), "");
        compare(SJ.handSet(undefined, a161),
                "[ARP] sync: fine-tune set by hand (slider, wheel or ms field) — map {} -> " + a161);
    }

    function test_one_number_among_many_speakers_is_found() {
        var m = {};
        for (var i = 0; i < 200; i++) m["AA:BB:CC:DD:EE:" + i] = i;
        var before = JSON.stringify(m);
        compare(SJ.handSet(before, JSON.stringify(m)), "");
        m["AA:BB:CC:DD:EE:137"] = 138;
        verify(SJ.handSet(before, JSON.stringify(m)).indexOf("fine-tune set by hand") !== -1);
    }

    function test_a_settle_round_over_without_a_verdict_says_what_it_had() {
        compare(SJ.settleOver(0), "[ARP] sync: settle gave up its window — no reads left, 0 of three readings in hand");
        compare(SJ.settleOver(1), "[ARP] sync: settle gave up its window — no reads left, 1 of three readings in hand");
        compare(SJ.settleOver(2), "[ARP] sync: settle gave up its window — no reads left, 2 of three readings in hand");
        compare(SJ.settleOver(3), "[ARP] sync: settle gave up its window — no reads left, 3 of three readings in hand");
    }

    function test_a_count_that_is_no_count_is_kept_between_none_and_three() {
        var none = "[ARP] sync: settle gave up its window — no reads left, 0 of three readings in hand";
        compare(SJ.settleOver(undefined), none);
        compare(SJ.settleOver(null), none);
        compare(SJ.settleOver(-4), none);
        compare(SJ.settleOver("x"), none);
        compare(SJ.settleOver(2.9), "[ARP] sync: settle gave up its window — no reads left, 2 of three readings in hand");
        compare(SJ.settleOver(40), "[ARP] sync: settle gave up its window — no reads left, 3 of three readings in hand");
    }
}
