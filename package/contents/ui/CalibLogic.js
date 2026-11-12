/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The shell around a microphone measurement, and how a cancel reaches it.
//
// A measurement is one shell command: it asks every speaker for its level,
// parks it, raises the balance-trimmed loopbacks, starts calibrate.py and
// writes the pid down, waits, and puts everything back. Cancel used to read
// that pid file once. Driven with stand-in commands and the first level
// query held back: at Cancel there was no pid file, nothing was signalled,
// and the shell went on to park three speakers at 55 % and start the
// measurement that had been called off.
//
// So a cancel now leaves a mark first: the token of the run it calls off, in
// a file of its own. The run's shell asks `off` before every step that
// changes the room and once more after the pid is written, which closes the
// last gap: a cancel that came too late for the look before the start finds
// the pid, and one that came too early for the pid is seen by the look after
// it.
.pragma library

// Names one run, in the mark and in its own shell, so a mark an earlier run
// left behind stops nothing. The counter starts over with the panel; the
// time the engine came up tells two sessions apart. Digits and a dot only:
// it is written into single quotes.
function token(bornMs, seq) {
    return _count(seq) + "." + _count(bornMs);
}

// A whole number as text, 0 for whatever is not one a double holds exactly.
function _count(n) {
    var v = Math.floor(Number(n));
    return v >= 0 && v < 1e15 ? String(v) : "0";
}

function _clean(tok) {
    return String(tok).replace(/[^0-9.]/g, "");
}

// The shell function a measurement asks whether it has been called off: the
// mark holds its own token. Another run's token or a mark that cannot be
// read is "no", and with no runtime folder there is none to read. Without a
// token nothing is ever called off: an empty one would match the empty
// answer of a missing file.
function offDef(markFile, tok) {
    var t = _clean(tok);
    if (t === "") return " off() { false; };";
    return " off() { [ \"$(cat " + markFile + " 2>/dev/null)\" = '" + t + "' ]; };";
}

// What a cancel hands the shell. The mark goes down before the pid is looked
// for: a run still at its level queries has no pid yet and reads the mark
// when it gets to its next step.
// By pid, from the run's own file: OUR run, not every calibrate.py this user
// happens to have, and not the shell that still owes the room its volume
// restore. A missing or unreadable file is a no-op, which is what makes this
// safe to call from every road.
function cancelCmd(pidFile, markFile, tok) {
    var t = _clean(tok);
    return (t === "" ? "" : " [ -n \"$XDG_RUNTIME_DIR\" ] && printf '%s' '" + t + "' > " + markFile + ";")
         + " f=" + pidFile + ";"
         + " if [ -n \"$XDG_RUNTIME_DIR\" ] && [ -r \"$f\" ]; then"
         + " p=$(cat \"$f\" 2>/dev/null);"
         + " case \"$p\" in ''|*[!0-9]*) ;; *) kill \"$p\" 2>/dev/null;; esac;"
         + " fi;";
}

// The one way calibrate.py is launched. The python goes to the
// BACKGROUND so its pid can be written down, and the shell then waits
// for it exactly as if it had run in front — the restore lines that
// follow are unchanged and still only reachable through this wait.
// Why the bookkeeping: cancelling used to `pgrep -f 'python3
// .*calibrate\.py'`, which matches the sh and the timeout wrappers too
// (their command line CARRIES that text), so the cancel killed the very
// shell holding the saved sink levels and left the room parked at 55%
// with the loopbacks at full. Measured on this machine: killing the
// timeout pid alone ends the python (wait → 143) and the shell runs its
// restore to the end.
// ONAIR_LEASH_PID is this shell's own pid: the script watches it and
// ends itself when the session that asked for the measurement is gone.
// Its old test (getppid()==1) could never fire — `timeout` sits between
// the two, so the shell is what gets reparented, never the python.
// `guarded` is for a command that defined `off` above: the start is skipped
// when the run was called off, and asked about again once the pid is down.
function runCmd(budgetSec, script, argvStr, pidFile, guarded) {
    var run = " ONAIR_LEASH_PID=$$ timeout " + budgetSec + " python3 '" + script + "'" + argvStr + " &"
            + " cp=$!;"
            + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then echo \"$cp\" > " + pidFile + "; fi;"
            + (guarded === true ? " off && kill \"$cp\" 2>/dev/null;" : "")
            + " wait \"$cp\";"
            + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then rm -f " + pidFile + "; fi;";
    return guarded === true ? " if ! off; then" + run + " fi;" : run;
}

// The park file's opening line. The file holds what every speaker was at
// before the measurement, for a session that ends with the room still
// parked, and it is insurance: not being able to write it must cost nothing
// else. It used to be emptied with `: > file`. `:` is a special builtin, and
// a POSIX shell whose redirection fails on one of those exits on the spot.
// Driven with the runtime folder gone: the shell ended at that line with
// every speaker parked at 55 %, nothing measured and nothing put back.
// `true` is an ordinary command. It fails, the shell goes on, and `pk` stays
// empty, so nothing more is written to a file that could not be started.
function parkOpen(parkFile) {
    return " [ -n \"$XDG_RUNTIME_DIR\" ] && true > " + parkFile + " && pk=1;";
}

// One line more for the park file: printf's own arguments go in, and come
// out as an append that only happens to a file parkOpen could start.
function parkAdd(parkFile, printfArgs) {
    return " [ -n \"$pk\" ] && printf " + printfArgs + " >> " + parkFile + ";";
}

// Every speaker's part of a calibration: its level read and echoed for the
// loudness math, the park, the way back, and its place in calibrate.py's
// arguments (the microphone sits between the timing pair and the rest).
// A speaker is parked only while the run is still wanted, and only a parked
// one is put back: a level that was never read falls back to the park, and
// that is no level to hand a speaker nobody touched.
function parkShell(sinks, park, micArg) {
    var setup = "", restore = "", argv = "";
    for (var si = 0; sinks && si < sinks.length; si++) {
        var esc = String(sinks[si]).replace(/'/g, "'\\''");
        setup += " s" + si + "='" + esc + "';"
              + " off || { v" + si + "=$(pactl get-sink-volume \"$s" + si + "\" | grep -o '[0-9]*%' | tr '\\n' ' ');"
              // The restored volume rides along for the loudness math:
              // the clicks are measured at the park level, but playback
              // happens at THIS level — the handler folds it back in.
              + " echo \"CALIBVOL $s" + si + " ${v" + si + ":-" + park + "%}\";"
              + " off || { pactl set-sink-volume \"$s" + si + "\" " + park + "%; k" + si + "=1; }; };";
        // Unquoted on purpose: $vN holds one %-value PER CHANNEL and
        // word-splitting hands pactl each as its own argument, so a
        // left/right balance survives the round-trip. An unreadable
        // volume falls back to the park the calibration itself used.
        restore += " [ -n \"$k" + si + "\" ] && pactl set-sink-volume \"$s" + si + "\" ${v" + si + ":-" + park + "%};";
        argv += " \"$s" + si + "\"";
        // The microphone the last calibration MEASURED as the best ear
        // in this machine, asked for again by name. Empty on the first
        // run (or after the device left), and calibrate.py then picks —
        // the desktop's default source is a routing preference, not a
        // judgement about which microphone hears the room.
        if (si === 1) argv += " " + micArg;
    }
    return { setup: setup, restore: restore, argv: argv };
}
