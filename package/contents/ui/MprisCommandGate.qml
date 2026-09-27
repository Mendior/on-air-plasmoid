/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
import QtQuick
import "PodcastLogic.js" as PodcastLogic

// Which lines of the MPRIS command file are new. mpris.py appends one
// "<number>\t<command>" line per media-key press and the widget re-reads the
// whole file every time (the 1.5 s poll, or the inotify wake-up plus its
// safety read 250 ms later), so the same line comes past many times and only
// the first sighting may reach the dispatch.
QtObject {
    // The number of the last command handed on. A double, never an int: the
    // number is a moment in milliseconds (about 1.79e12) and a QML int is 32
    // bits, so it wrapped on the way in (measured: stored as -824362432),
    // every line looked new again, and one Next on the rig walked through six
    // stations until the line turned ten seconds old.
    property double lastSeq: 0

    // A bridge is being started (widget start, re-enable, revive). What was
    // obeyed stays obeyed: the poll runs on through a revive and can read the
    // old file once more before the start has emptied it. The new daemon
    // numbers from the clock, so its first line is above anything here,
    // unless the clock was set back; then the mark comes down to the clock
    // too, or the keys would stay dead until the clock caught up.
    function arm(nowMs) {
        if (lastSeq > nowMs)
            lastSeq = nowMs;
    }

    // Every line of stdout that is new and at most ten seconds old goes to
    // obey(command), in file order. Each is marked before it is handed on, so
    // a dispatch that throws cannot get the same key obeyed twice.
    function take(stdout, nowMs, obey) {
        const lines = (stdout || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line) continue;
            const tabIdx = line.indexOf("\t");
            if (tabIdx < 0) continue;
            const seq = parseInt(line.substring(0, tabIdx), 10);
            if (isNaN(seq) || seq <= lastSeq || nowMs - seq > 10000) continue;
            lastSeq = seq;
            obey(line.substring(tabIdx + 1));
        }
    }

    // The shell line that starts the bridge. --ms-seq asks mpris.py for the
    // moments take() and arm() are written for; without it the bridge counts
    // 1, 2, 3, which is what a 2026.39 widget starting the same file needs.
    function startLine(launcher, stateFile, cmdFile) {
        return ": MPRIS_START; bash " + PodcastLogic.shQuote(launcher) + " "
               + PodcastLogic.shQuote(stateFile) + " " + PodcastLogic.shQuote(cmdFile) + " --ms-seq";
    }
}
