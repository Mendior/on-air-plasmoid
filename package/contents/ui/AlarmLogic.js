/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Pure scheduling math for the wake-up alarms — and for the recording
// scheduler, which shares nextOccurrence(). No QML types, no I/O, no
// side effects: everything in this file runs under qmltestrunner
// (tests/qml/), where the logic bugs that actually ship have
// historically lived.
.pragma library

// A missed alarm still fires if the machine comes back within this window;
// beyond it the moment has clearly passed (a 07:00 alarm firing at noon
// helps nobody) and the alarm advances to its next occurrence instead.
var GRACE_MS = 60 * 60 * 1000;

// Next occurrence of hh:mm strictly after fromMs. Recomputed from the wall
// clock each time (not "+24h") so DST changes don't drift the start time.
function nextOccurrence(hh, mm, repeat, weekday, fromMs) {
    var d = new Date(fromMs);
    d.setHours(hh, mm, 0, 0);
    if (repeat === "weekly") {
        var delta = (weekday - d.getDay() + 7) % 7;
        d.setDate(d.getDate() + delta);
        if (d.getTime() <= fromMs) d.setDate(d.getDate() + 7);
    } else if (d.getTime() <= fromMs) {
        d.setDate(d.getDate() + 1);
    }
    return d.getTime();
}

// What a scheduler tick should do about one occurrence: nothing yet, fire
// it, or write it off as missed. A malformed nextRun never fires.
function fireDecision(nextRun, nowMs, graceMs) {
    var grace = (graceMs === undefined) ? GRACE_MS : graceMs;
    if (!(nextRun > 0)) return "wait";
    if (nowMs < nextRun) return "wait";
    return (nowMs - nextRun) <= grace ? "fire" : "missed";
}

function clampInt(v, lo, hi, dflt) {
    var n = parseInt(v, 10);
    if (isNaN(n)) return dflt;
    return Math.max(lo, Math.min(hi, n));
}

// The persisted alarm list, validated field by field — configs survive old
// versions and hand edits. Returns [] for anything that is not a
// well-formed array; entries without a stream URL are dropped whole.
// volumePct has a floor of 15: an alarm is never allowed to be silent.
function sanitizeAlarms(raw) {
    var arr;
    try {
        arr = JSON.parse(raw || "[]");
    } catch (e) {
        return [];
    }
    if (!Array.isArray(arr)) return [];
    var out = [];
    for (var i = 0; i < arr.length; i++) {
        var a = arr[i];
        if (!a || typeof a !== "object") continue;
        var url = (a.url || "").toString();
        if (url === "") continue;
        var repeat = (a.repeat === "daily" || a.repeat === "weekly") ? a.repeat : "once";
        out.push({
            station: (a.station || url).toString(),
            url: url,
            favicon: (a.favicon || "").toString(),
            hh: clampInt(a.hh, 0, 23, 7),
            mm: clampInt(a.mm, 0, 59, 0),
            repeat: repeat,
            weekday: clampInt(a.weekday, 0, 6, 0),
            volumePct: clampInt(a.volumePct, 15, 100, 40),
            keepAwake: a.keepAwake === true,
            nextRun: (typeof a.nextRun === "number" && isFinite(a.nextRun) && a.nextRun > 0)
                     ? a.nextRun : 0
        });
    }
    return out;
}

// The alarm's life after one occurrence has been dealt with:
// -1 = remove the entry (one-shots are spent), otherwise the new nextRun.
function advance(alarm, nowMs) {
    if (alarm.repeat === "once") return -1;
    return nextOccurrence(alarm.hh, alarm.mm, alarm.repeat, alarm.weekday, nowMs);
}

// The soonest keep-awake deadline, or 0 when no alarm wants the machine
// held awake — the QML side turns this into one systemd-inhibit holder.
function earliestKeepAwake(alarms) {
    var best = 0;
    for (var i = 0; i < alarms.length; i++) {
        var a = alarms[i];
        if (!a.keepAwake || !(a.nextRun > 0)) continue;
        if (best === 0 || a.nextRun < best) best = a.nextRun;
    }
    return best;
}
