// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The gate between the MPRIS command file and the dispatch. The file only
// ever grows (mpris.py appends), and the widget reads all of it again on
// every poll tick, every inotify wake-up and every safety read, so a line
// that gets through twice is a media key pressed twice. Measured on the rig
// on 2026-09-23 with the number held in an int: one Next walked through six
// stations 1.5 s apart, one PlayPause started and stopped the stream three
// times. The numbers below are real moments in milliseconds, as mpris.py
// writes them; small ones would fit in any int and hide exactly that.
import QtQuick
import QtTest
import "../../package/contents/ui"

TestCase {
    id: tc
    name: "MprisCommandGate"

    Component {
        id: gateComp
        MprisCommandGate {}
    }

    // 2026-09-24 00:00 UTC, the size mpris.py next_seq hands out.
    readonly property double t0: 1790208000000

    function makeGate() {
        return createTemporaryObject(gateComp, tc);
    }

    function line(seq, cmd) {
        return seq + "\t" + cmd + "\n";
    }

    // What one read of the file would have dispatched.
    function read(gate, stdout, nowMs) {
        var got = [];
        gate.take(stdout, nowMs, function(cmd) { got.push(cmd); });
        return got;
    }

    function test_a_line_read_twice_is_obeyed_once() {
        var g = makeGate();
        var file = line(t0, "Next");
        compare(read(g, file, t0 + 40), ["Next"]);
        // The inotify road's safety read, 250 ms after the wake-up.
        compare(read(g, file, t0 + 290), [], "the safety read obeyed the key again");
        // And the poll, which reads the same file every 1.5 s for ten seconds.
        compare(read(g, file, t0 + 1540), [], "the poll obeyed the key again");
        compare(read(g, file, t0 + 9040), []);
    }

    function test_the_poll_obeys_each_line_of_a_growing_file_once() {
        var g = makeGate();
        var file = line(t0, "Next");
        compare(read(g, file, t0 + 500), ["Next"]);
        file += line(t0 + 2000, "PlayPause");
        compare(read(g, file, t0 + 2500), ["PlayPause"]);
        compare(read(g, file, t0 + 4000), []);
    }

    function test_two_presses_in_one_millisecond_are_both_obeyed_in_order() {
        // next_seq gives the second press last + 1 when the clock has not moved.
        var g = makeGate();
        var file = line(t0, "Next") + line(t0 + 1, "Previous");
        compare(read(g, file, t0 + 100), ["Next", "Previous"]);
        compare(read(g, file, t0 + 350), []);
    }

    function test_a_line_older_than_ten_seconds_is_never_obeyed() {
        var g = makeGate();
        compare(read(g, line(t0, "Stop"), t0 + 10001), []);
        var h = makeGate();
        compare(read(h, line(t0, "Stop"), t0 + 10000), ["Stop"]);
    }

    function test_lines_that_are_not_commands_are_passed_over() {
        var g = makeGate();
        var file = "\n" + "garbage\n" + "abc\tNext\n" + "\tPlay\n"
                 + t0 + "\tPause\r\n";
        compare(read(g, file, t0 + 100), ["Pause"]);
        compare(read(g, file, t0 + 350), []);
    }

    function test_a_dispatch_that_throws_does_not_get_its_key_obeyed_again() {
        var g = makeGate();
        var file = line(t0, "Next") + line(t0 + 700, "Play");
        var threw = false;
        try {
            g.take(file, t0 + 800, function(cmd) { throw new Error("dispatch broke on " + cmd); });
        } catch (e) {
            threw = true;
        }
        verify(threw);
        // Next was marked before it was handed on; Play was never reached.
        compare(read(g, file, t0 + 2300), ["Play"]);
    }

    // The widget starts the bridge again with the same gate when it finds it
    // gone (at most once a minute) and when media keys are switched back on.
    // The poll keeps running through that, so a read can land on the old
    // file before the start has emptied it.
    function test_a_new_bridge_does_not_replay_what_the_old_one_said() {
        var g = makeGate();
        var file = line(t0, "Next");
        compare(read(g, file, t0 + 100), ["Next"]);
        g.arm(t0 + 2000);
        compare(read(g, file, t0 + 2100), [], "a Next obeyed before the restart was obeyed again");
    }

    function test_a_new_bridge_is_heard_from_its_first_command() {
        var g = makeGate();
        compare(read(g, line(t0, "Next"), t0 + 100), ["Next"]);
        g.arm(t0 + 2000);
        // The launcher sleeps 0.3 s before the daemon exists at all.
        compare(read(g, line(t0 + 2400, "PlayPause"), t0 + 2500), ["PlayPause"]);
    }

    function test_a_clock_set_back_cannot_deafen_the_next_bridge() {
        // An hour back, the way a dual-boot clock is corrected after login.
        var g = makeGate();
        compare(read(g, line(t0, "Next"), t0 + 100), ["Next"]);
        var back = t0 - 3600000;
        g.arm(back + 5000);
        compare(read(g, line(back + 5400, "Play"), back + 5500), ["Play"],
                "the first key after the restart waits for the clock to catch up");
    }

    function test_a_clock_set_back_mid_session_keeps_the_keys_alive() {
        // One bridge's numbers keep climbing whatever the clock does
        // (next_seq takes last + 1), and a line from "the future" is not old.
        var g = makeGate();
        compare(read(g, line(t0, "Next"), t0 + 100), ["Next"]);
        var file = line(t0, "Next") + line(t0 + 1, "Previous");
        compare(read(g, file, t0 - 3600000), ["Previous"]);
    }

    // The bridge counts 1, 2, 3 unless it is told otherwise, because a
    // 2026.39 widget can still be the one starting it (mpris.py next_seq).
    // Everything above reads the number as a moment, so the start line has
    // to ask for moments or the ten-second rule drops every key.
    function test_the_bridge_is_started_asking_for_moments() {
        var g = makeGate();
        compare(g.startLine("/pkg/ui/start-mpris.sh", "/run/user/1000/arp-mpris-state-2.json",
                            "/run/user/1000/arp-mpris-cmd-2.txt"),
                ": MPRIS_START; bash '/pkg/ui/start-mpris.sh' '/run/user/1000/arp-mpris-state-2.json'"
                + " '/run/user/1000/arp-mpris-cmd-2.txt' --ms-seq");
    }

    function test_a_quote_in_a_path_stays_inside_its_word() {
        var g = makeGate();
        compare(g.startLine("/home/o'neil/start-mpris.sh", "/s.json", "/c.txt"),
                ": MPRIS_START; bash '/home/o'\\''neil/start-mpris.sh' '/s.json' '/c.txt' --ms-seq");
    }
}
