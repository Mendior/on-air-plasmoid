// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The text a measurement and its cancel hand the shell. What that text does
// when it runs is tests/test_calibrate_cancel.py's business; here it is
// held to the letter, because a quote out of place is a different command.
import QtQuick
import QtTest

import "../../package/contents/ui/CalibLogic.js" as CL

TestCase {
    name: "CalibLogic"

    readonly property string mark: "\"$XDG_RUNTIME_DIR/onair_calib_7.off\""
    readonly property string pid: "\"$XDG_RUNTIME_DIR/onair_calib_7.pid\""

    function test_a_token_is_the_run_and_the_engines_birth() {
        compare(CL.token(1731359000123, 4), "4.1731359000123");
        compare(CL.token(1731359000123, 5), "5.1731359000123");
        verify(CL.token(1731359000123, 4) !== CL.token(1731359000124, 4));
    }

    function test_a_token_is_only_ever_digits_and_a_dot() {
        compare(CL.token(0, 0), "0.0");
        compare(CL.token(undefined, undefined), "0.0");
        compare(CL.token(null, null), "0.0");
        compare(CL.token("x'; rm -rf ~; '", "1; true"), "0.0");
        compare(CL.token(12.9, 3.9), "3.12");
        compare(CL.token(-5, -2), "0.0");
        var shapes = [CL.token(1e21, 7), CL.token(Infinity, 7), CL.token(NaN, NaN),
                      CL.token(1731359000123, 2147483647), CL.token(Number.MAX_VALUE, 1e308)];
        for (var i = 0; i < shapes.length; i++)
            verify(/^[0-9]+\.[0-9]+$/.test(shapes[i]), shapes[i]);
    }

    function test_off_reads_the_mark_and_compares_it_with_the_runs_own_token() {
        compare(CL.offDef(mark, "4.1731359000123"),
                " off() { [ \"$(cat \"$XDG_RUNTIME_DIR/onair_calib_7.off\" 2>/dev/null)\" = '4.1731359000123' ]; };");
    }

    function test_off_without_a_token_calls_nothing_off() {
        // "" would equal what cat says about a file that is not there.
        compare(CL.offDef(mark, ""), " off() { false; };");
        compare(CL.offDef(mark, undefined), " off() { false; };");
        compare(CL.offDef(mark, null), " off() { false; };");
        compare(CL.offDef(mark, "'; '"), " off() { false; };");
    }

    function test_off_never_lets_a_token_out_of_its_quotes() {
        compare(CL.offDef(mark, "4.17'; kill 1; '"),
                " off() { [ \"$(cat \"$XDG_RUNTIME_DIR/onair_calib_7.off\" 2>/dev/null)\" = '4.171' ]; };");
    }

    function test_a_cancel_writes_the_mark_and_then_looks_for_the_pid() {
        var sh = CL.cancelCmd(pid, mark, "4.1731359000123");
        compare(sh, " [ -n \"$XDG_RUNTIME_DIR\" ] && printf '%s' '4.1731359000123' > \"$XDG_RUNTIME_DIR/onair_calib_7.off\";"
                    + " f=\"$XDG_RUNTIME_DIR/onair_calib_7.pid\";"
                    + " if [ -n \"$XDG_RUNTIME_DIR\" ] && [ -r \"$f\" ]; then"
                    + " p=$(cat \"$f\" 2>/dev/null);"
                    + " case \"$p\" in ''|*[!0-9]*) ;; *) kill \"$p\" 2>/dev/null;; esac;"
                    + " fi;");
        verify(sh.indexOf("printf") < sh.indexOf("p=$(cat"));
    }

    function test_a_cancel_without_a_token_still_ends_the_process() {
        var bare = " f=\"$XDG_RUNTIME_DIR/onair_calib_7.pid\";"
                 + " if [ -n \"$XDG_RUNTIME_DIR\" ] && [ -r \"$f\" ]; then"
                 + " p=$(cat \"$f\" 2>/dev/null);"
                 + " case \"$p\" in ''|*[!0-9]*) ;; *) kill \"$p\" 2>/dev/null;; esac;"
                 + " fi;";
        compare(CL.cancelCmd(pid, mark, ""), bare);
        compare(CL.cancelCmd(pid, mark, undefined), bare);
        compare(CL.cancelCmd(pid, mark, "';'"), bare);
    }

    function test_the_plain_launch_is_the_one_the_drift_probe_always_had() {
        compare(CL.runCmd(78, "/usr/share/x/calibrate.py", " drift sink ''", pid, false),
                " ONAIR_LEASH_PID=$$ timeout 78 python3 '/usr/share/x/calibrate.py' drift sink '' &"
                + " cp=$!;"
                + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then echo \"$cp\" > \"$XDG_RUNTIME_DIR/onair_calib_7.pid\"; fi;"
                + " wait \"$cp\";"
                + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then rm -f \"$XDG_RUNTIME_DIR/onair_calib_7.pid\"; fi;");
        compare(CL.runCmd(78, "/x/calibrate.py", " a", pid), CL.runCmd(78, "/x/calibrate.py", " a", pid, false));
    }

    function test_the_guarded_launch_asks_before_the_start_and_again_after_the_pid() {
        var sh = CL.runCmd(80, "/usr/share/x/calibrate.py", " \"$s0\" \"$s1\" ''", pid, true);
        compare(sh, " if ! off; then"
                    + " ONAIR_LEASH_PID=$$ timeout 80 python3 '/usr/share/x/calibrate.py' \"$s0\" \"$s1\" '' &"
                    + " cp=$!;"
                    + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then echo \"$cp\" > \"$XDG_RUNTIME_DIR/onair_calib_7.pid\"; fi;"
                    + " off && kill \"$cp\" 2>/dev/null;"
                    + " wait \"$cp\";"
                    + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then rm -f \"$XDG_RUNTIME_DIR/onair_calib_7.pid\"; fi;"
                    + " fi;");
        // The second look comes after the pid is on disk and before the wait.
        verify(sh.indexOf("echo \"$cp\" >") < sh.indexOf("off && kill"));
        verify(sh.indexOf("off && kill") < sh.indexOf("wait \"$cp\""));
    }

    readonly property string park: "\"$XDG_RUNTIME_DIR/onair_park_7.sh\""

    function test_the_park_file_is_started_by_a_command_that_cannot_end_the_shell() {
        // `: > file` is the usual way to empty a file, and `:` is a special
        // builtin: when the file cannot be opened a POSIX shell exits there.
        var sh = CL.parkOpen(park);
        compare(sh, " [ -n \"$XDG_RUNTIME_DIR\" ] && true > \"$XDG_RUNTIME_DIR/onair_park_7.sh\" && pk=1;");
        compare(sh.indexOf(": >"), -1);
    }

    function test_a_line_for_the_park_file_is_written_only_to_a_file_that_was_started() {
        compare(CL.parkAdd(park, "'pactl set-sink-mute '\\''%s'\\'' 0\\n' \"$w0\""),
                " [ -n \"$pk\" ] && printf 'pactl set-sink-mute '\\''%s'\\'' 0\\n' \"$w0\""
                + " >> \"$XDG_RUNTIME_DIR/onair_park_7.sh\";");
    }

    function test_a_line_with_nothing_to_say_is_still_one_whole_statement() {
        compare(CL.parkAdd(park, "''"), " [ -n \"$pk\" ] && printf '' >> \"$XDG_RUNTIME_DIR/onair_park_7.sh\";");
    }

    function test_two_speakers_are_read_parked_and_put_back_each_under_its_own_flag() {
        var ps = CL.parkShell(["alsa_output.a", "bluez_output.b"], 55, "'mic'");
        compare(ps.setup,
                " s0='alsa_output.a';"
                + " off || { v0=$(pactl get-sink-volume \"$s0\" | grep -o '[0-9]*%' | tr '\\n' ' ');"
                + " echo \"CALIBVOL $s0 ${v0:-55%}\";"
                + " off || { pactl set-sink-volume \"$s0\" 55%; k0=1; }; };"
                + " s1='bluez_output.b';"
                + " off || { v1=$(pactl get-sink-volume \"$s1\" | grep -o '[0-9]*%' | tr '\\n' ' ');"
                + " echo \"CALIBVOL $s1 ${v1:-55%}\";"
                + " off || { pactl set-sink-volume \"$s1\" 55%; k1=1; }; };");
        compare(ps.restore,
                " [ -n \"$k0\" ] && pactl set-sink-volume \"$s0\" ${v0:-55%};"
                + " [ -n \"$k1\" ] && pactl set-sink-volume \"$s1\" ${v1:-55%};");
        compare(ps.argv, " \"$s0\" \"$s1\" 'mic'");
    }

    function test_the_microphone_sits_after_the_timing_pair_and_before_the_rest() {
        var ps = CL.parkShell(["a", "b", "c", "d"], 85, "''");
        compare(ps.argv, " \"$s0\" \"$s1\" '' \"$s2\" \"$s3\"");
        verify(ps.setup.indexOf("pactl set-sink-volume \"$s3\" 85%; k3=1;") !== -1);
        verify(ps.restore.indexOf(" [ -n \"$k3\" ] && pactl set-sink-volume \"$s3\" ${v3:-85%};") !== -1);
    }

    function test_a_quote_in_a_sink_name_stays_inside_its_word() {
        var ps = CL.parkShell(["it's; reboot"], 55, "''");
        verify(ps.setup.indexOf(" s0='it'\\''s; reboot';") === 0);
    }

    function test_no_speakers_is_no_shell() {
        var none = [[], null, undefined];
        for (var i = 0; i < none.length; i++) {
            var ps = CL.parkShell(none[i], 55, "''");
            compare(ps.setup, "");
            compare(ps.restore, "");
            compare(ps.argv, "");
        }
    }

    function test_eight_speakers_each_keep_their_own_number() {
        var sinks = [];
        for (var i = 0; i < 8; i++) sinks.push("sink" + i);
        var ps = CL.parkShell(sinks, 55, "''");
        for (var j = 0; j < 8; j++) {
            verify(ps.setup.indexOf(" s" + j + "='sink" + j + "';") !== -1);
            verify(ps.setup.indexOf("k" + j + "=1;") !== -1);
            compare(ps.setup.split("k" + j + "=1;").length, 2);
        }
        compare(ps.restore.split("pactl set-sink-volume").length - 1, 8);
    }
}
