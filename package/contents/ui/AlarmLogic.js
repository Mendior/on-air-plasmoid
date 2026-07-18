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
//
// The spring-forward hole needs its own word: on the night the clock jumps
// 03:00→04:00, a 03:30 simply does not exist — and Qt's JS engine resolves
// the nonexistent time BACKWARD (03:30 becomes wall-clock 02:30, measured
// on Qt 6.11 under Europe/Tallinn), so a 03:30 alarm rang an hour EARLY
// and a scheduled recording captured the hour before the show. V8 resolves
// the same hole forward; relying on either is a coin toss. When the
// resolved wall clock does not read back the asked-for hour, the moment
// fell into the hole — push one hour forward, which lands on the first
// instant that actually exists (03:30 → 04:30 new time).
function _resolveGap(d, hh) {
    if (d.getHours() !== hh) {
        var fixed = new Date(d.getTime() + 3600 * 1000);
        // Only accept the push when it lands sanely past the hole — a
        // double-shift zone oddity must not loop or overshoot silently.
        if (fixed.getDate() === d.getDate() || fixed.getHours() >= hh) return fixed;
    }
    return d;
}

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
    d = _resolveGap(d, hh);
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
// A missing or mangled nextRun is RECOMPUTED from the wall-clock fields
// rather than zeroed: fireDecision treats 0 as "wait" forever, so a zeroed
// entry would sit armed-looking in the UI and never ring.
function sanitizeAlarms(raw, nowMs) {
    var now = (nowMs === undefined) ? Date.now() : nowMs;
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
        var hh = clampInt(a.hh, 0, 23, 7);
        var mm = clampInt(a.mm, 0, 59, 0);
        var weekday = clampInt(a.weekday, 0, 6, 0);
        out.push({
            station: (a.station || url).toString(),
            url: url,
            favicon: (a.favicon || "").toString(),
            hh: hh,
            mm: mm,
            repeat: repeat,
            weekday: weekday,
            volumePct: clampInt(a.volumePct, 15, 100, 40),
            keepAwake: a.keepAwake === true,
            nextRun: (typeof a.nextRun === "number" && isFinite(a.nextRun) && a.nextRun > 0)
                     ? a.nextRun
                     : nextOccurrence(hh, mm, repeat, weekday, now)
        });
    }
    return out;
}

// The recording scheduler's persisted list, same treatment as the alarms:
// validated field by field, entries without a URL dropped whole, a missing
// or mangled nextRun recomputed instead of zeroed (a zeroed entry sits in
// the list looking armed and never records).
function sanitizeRecSchedules(raw, nowMs) {
    var now = (nowMs === undefined) ? Date.now() : nowMs;
    var arr;
    try {
        arr = JSON.parse(raw || "[]");
    } catch (e) {
        return [];
    }
    if (!Array.isArray(arr)) return [];
    var out = [];
    for (var i = 0; i < arr.length; i++) {
        var s = arr[i];
        if (!s || typeof s !== "object") continue;
        var url = (s.url || "").toString();
        if (url === "") continue;
        var repeat = (s.repeat === "daily" || s.repeat === "weekly") ? s.repeat : "once";
        var hh = clampInt(s.hh, 0, 23, 7);
        var mm = clampInt(s.mm, 0, 59, 0);
        var weekday = clampInt(s.weekday, 0, 6, 0);
        out.push({
            station: (s.station || url).toString(),
            url: url,
            hh: hh,
            mm: mm,
            durationMin: clampInt(s.durationMin, 1, 24 * 60, 60),
            repeat: repeat,
            weekday: weekday,
            nextRun: (typeof s.nextRun === "number" && isFinite(s.nextRun) && s.nextRun > 0)
                     ? s.nextRun
                     : nextOccurrence(hh, mm, repeat, weekday, now)
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

// Re-express one schedule entry's nextRun in the CURRENT time zone after the
// system offset moved (travel, VPN, DST, a tzdata update mid-session or
// across downtime). Stored instants belong to the OLD zone's wall clock; an
// alarm's promise is the wall clock, so 07:00 must stay 07:00 where the
// machine now lives.
//
// The anchor is per-entry, and this is the whole subtlety:
//   * An entry already WAITING to fire (nextRun <= now — the machine was
//     asleep or off across its moment) is anchored a grace window into the
//     past, so the recomputed instant still lands at-or-before now and the
//     fire scan catches it exactly once instead of skipping it to tomorrow.
//   * An entry NOT yet due (already advanced past its last fire, or simply
//     in the future) is anchored at now, so a backward offset shift can
//     never pull it into the past and make it fire a second time.
// Idempotent: re-running with an unchanged offset returns the same instants.
function retimeForZone(entry, nowMs) {
    var anchor = (entry.nextRun <= nowMs) ? nowMs - GRACE_MS : nowMs;
    return nextOccurrence(entry.hh, entry.mm, entry.repeat, entry.weekday, anchor);
}

// Whether the casting route is proven well enough for the wake tone to
// stand down. `casting` alone is an optimistic flag set the moment the play
// command LEAVES — a speaker unplugged overnight still looks "casting".
// Only a device's actual CAST_PLAY acknowledgement (`confirmed`) counts,
// and a multi-room setup (localPlay) must still pass the local audibility
// check regardless.
function castSilencesWakeTone(casting, confirmed, localPlay) {
    return casting === true && confirmed === true && localPlay !== true;
}

// How long one systemd-inhibit holder should hold, in seconds — 0 when
// nothing wants the machine awake. Capped at 12 hours: a weekly alarm must
// not pin the machine awake for six days. The scheduler tick re-arms a
// fresh holder as the current one nears expiry, so a due alarm is still
// covered right up to firing; the +120 s tail keeps the fire moment itself
// inside the hold.
var INHIBIT_MAX_S = 12 * 3600;

function inhibitSeconds(untilMs, nowMs) {
    if (!(untilMs > 0)) return 0;
    return Math.max(60, Math.min(INHIBIT_MAX_S,
                                 Math.round((untilMs - nowMs) / 1000) + 120));
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
