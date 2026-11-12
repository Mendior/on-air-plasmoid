// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Which rebuild an answer belongs to, and how the loopbacks of one that was
// overtaken are taken down. The engine's own tests drive the two shells
// against each other; here are the edges of the address itself.
import QtQuick
import QtTest

import "../../package/contents/ui/ReloopLogic.js" as RL

TestCase {
    name: "ReloopLogic"

    function test_the_stamp_is_the_enable_and_then_the_job() {
        compare(RL.stamp(3, 7), "3 7");
        compare(RL.stamp(1, 0), "1 0");
    }

    function test_an_answer_with_both_numbers_right_is_the_live_one() {
        verify(RL.owns(": PW_RELOOP 3 7; pactl load-module x # 41", 3, 7));
        verify(RL.owns(": PW_LBSWAP 3 7; true # 42", 3, 7));
        verify(RL.owns(": PW_RELOOP " + RL.stamp(12, 340) + "; true", 12, 340));
    }

    function test_an_older_job_or_another_enable_is_not() {
        verify(!RL.owns(": PW_RELOOP 3 6; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 8; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 2 7; x", 3, 7));
        verify(!RL.owns(": PW_LBSWAP 3 6; x", 3, 7));
        // The two numbers do not trade places.
        verify(!RL.owns(": PW_RELOOP 7 3; x", 3, 7));
    }

    function test_the_first_job_of_the_first_enable_counts() {
        verify(RL.owns(": PW_RELOOP 1 1; x", 1, 1));
        verify(RL.owns(": PW_RELOOP 0 0; x", 0, 0));
        verify(!RL.owns(": PW_RELOOP 1 1; x", 1, 0));
    }

    function test_an_answer_that_lost_a_number_is_nobodys() {
        verify(!RL.owns(": PW_RELOOP 3; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 ; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP  7; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 7 x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 x; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 -7; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 7.0; x", 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 07; x", 3, 7));
        // Only at the head of the command, and only these two tags.
        verify(!RL.owns("x: PW_RELOOP 3 7; x", 3, 7));
        verify(!RL.owns(": PW_COMBINE 3 7; x", 3, 7));
        verify(!RL.owns(": PW_RELOOPS 3 7; x", 3, 7));
    }

    function test_nothing_at_all_is_nobodys() {
        verify(!RL.owns("", 3, 7));
        verify(!RL.owns(null, 3, 7));
        verify(!RL.owns(undefined, 3, 7));
        verify(!RL.owns(": PW_RELOOP 3 7; x", undefined, 7));
        verify(!RL.owns(": PW_RELOOP 3 7; x", 3, null));
        verify(!RL.owns(": PW_RELOOP 3 7; x", "", ""));
    }

    function test_a_number_past_what_a_double_holds_is_not_its_neighbour() {
        // 2^53 + 1 parses to 2^53. Read as numbers the two would be one job.
        verify(!RL.owns(": PW_RELOOP 1 9007199254740993; x", 1, 9007199254740992));
        verify(RL.owns(": PW_RELOOP 1 9007199254740992; x", 1, 9007199254740992));
        verify(!RL.owns(": PW_RELOOP 1 " + "9".repeat(400) + "; x", 1, 7));
    }

    function test_unload_names_every_module_once_and_stays_quiet_about_the_gone() {
        compare(RL.unload(["301", "302"]),
                "pactl unload-module 301 2>/dev/null; pactl unload-module 302 2>/dev/null; ");
        compare(RL.unload([301]), "pactl unload-module 301 2>/dev/null; ");
    }

    function test_unload_reads_the_swaps_records_too() {
        compare(RL.unload([{ id: "401", sink: "alsa_output.x", old: "101" }]),
                "pactl unload-module 401 2>/dev/null; ");
    }

    function test_unload_of_nothing_is_no_shell_at_all() {
        compare(RL.unload([]), "");
        compare(RL.unload(null), "");
        compare(RL.unload(undefined), "");
        compare(RL.unload([null, undefined, "", {}]), "");
    }

    function test_unload_leaves_out_what_is_not_a_plain_number() {
        compare(RL.unload(["301; rm -rf ~", "30 1", "-3", "3.5", "$(id)", "302"]),
                "pactl unload-module 302 2>/dev/null; ");
        compare(RL.unload([{ id: "x" }, { id: "9" }]), "pactl unload-module 9 2>/dev/null; ");
    }

    function test_unload_of_a_long_list_keeps_every_one() {
        var ids = [];
        for (var i = 0; i < 500; i++) ids.push(String(1000 + i));
        var sh = RL.unload(ids);
        compare(sh.split("pactl unload-module ").length - 1, 500);
        verify(sh.indexOf("pactl unload-module 1499 2>/dev/null; ") !== -1);
    }
}
