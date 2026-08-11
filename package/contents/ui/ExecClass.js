// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
//
// A finished external command's exit code, read as a cause rather than a
// number. The widget runs ~40 little shell commands — pactl, bluetoothctl,
// curl, ffmpeg, the sync helpers — and most of them, when they fail, fail
// in silence: the room just does not combine, the title just does not
// arrive, with nothing in the journal to say why. Two codes carry a single
// reliable meaning and are worth a word:
//
//   127  the shell could not find the program. A tool the listener's machine
//        does not have — pactl on a box without PipeWire, bluetoothctl, a
//        missing ffmpeg. This is the silent-failure class itself: the widget
//        asked the system to do something the system had no way to do.
//   124  timeout(1) killed the command at its deadline. The work did not
//        finish, and repeating it the same way will hang the same way.
//
// 0 is success; 1 is almost always a tool's own "no match / nothing to do"
// (grep, pgrep) and means nothing on its own. So everything but 127 and 124
// classifies as "" and the caller stays quiet.
//
// One honest limit, written down rather than glossed: a pipeline reports its
// LAST command's code (`a | b` is b's), so a 127 here is a reliable positive
// but not a complete one — a tool missing mid-pipe is masked by whatever ran
// after it. That is why the caller uses this for a journal line, not yet for
// a verdict shown to the listener.
.pragma library

function classify(exitCode) {
    if (exitCode === 127) return "missing";
    if (exitCode === 124) return "timeout";
    return "";
}

// The shortest honest name for a command in a log line: the ": SENTINEL;"
// tag the widget prefixes onto its own commands, else the first bare word.
// NEVER anything past that first token — the command line carries station
// names, URLs and file paths that have no place in a journal.
//
// Both the sentinel and the bare word are read from the START, after the
// exec facade's optional `export LC_ALL=C LANGUAGE=C;` prefix is stripped.
// The anchor is the whole point: an earlier version matched the first
// ":UPPERCASE" ANYWHERE, so `curl -H 'X-Auth: SECRETTOKEN'` labelled itself
// "SECRETTOKEN" — an argument fragment in the log, and a different key on
// every call so the once-a-session dedup never held. Measured 2026-08-09.
function label(cmd) {
    if (typeof cmd !== "string")
        return "";
    var body = cmd.replace(/^\s*(?:export\b[^;]*;\s*)*/, "");
    var tag = body.match(/^:\s*([A-Z][A-Z0-9_]+)/);
    if (tag)
        return tag[1];
    var bare = body.match(/(\S+)/);
    return bare ? bare[1] : "";
}
