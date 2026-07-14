// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Scheduling math behind the wake-up alarms AND the recording scheduler
// (main.qml delegates _nextOccurrence here). Every shipped release-breaking
// bug so far lived in QML-side logic — this is the first file of the net
// that catches that class.
import QtQuick
import QtTest

import "../../package/contents/ui/AlarmLogic.js" as AL

TestCase {
    name: "AlarmLogic"

    function ms(y, mo, d, h, mi) {
        return new Date(y, mo - 1, d, h, mi, 0, 0).getTime()
    }

    // ── nextOccurrence ────────────────────────────────────────────────────

    function test_daily_later_today() {
        compare(AL.nextOccurrence(7, 30, "daily", 0, ms(2026, 7, 14, 6, 0)),
                ms(2026, 7, 14, 7, 30))
    }

    function test_daily_rolls_to_tomorrow() {
        compare(AL.nextOccurrence(7, 30, "daily", 0, ms(2026, 7, 14, 8, 0)),
                ms(2026, 7, 15, 7, 30))
    }

    function test_exactly_now_means_tomorrow() {
        // "Strictly after": setting an alarm for the current minute must not
        // fire this very tick.
        compare(AL.nextOccurrence(7, 30, "daily", 0, ms(2026, 7, 14, 7, 30)),
                ms(2026, 7, 15, 7, 30))
    }

    function test_weekly_later_this_week() {
        // 2026-07-14 is a Tuesday (day 2); Friday is day 5.
        compare(AL.nextOccurrence(9, 0, "weekly", 5, ms(2026, 7, 14, 12, 0)),
                ms(2026, 7, 17, 9, 0))
    }

    function test_weekly_same_day_past_time_wraps_a_week() {
        compare(AL.nextOccurrence(9, 0, "weekly", 2, ms(2026, 7, 14, 12, 0)),
                ms(2026, 7, 21, 9, 0))
    }

    function test_dst_transition_keeps_the_wall_clock() {
        // EU DST starts 2026-03-29 (02:00 -> 03:00 in Europe/Tallinn): the
        // wall-clock construction must keep "07:00" at 07:00, where a naive
        // "+24h" would land at 08:00. In a UTC CI container this reduces to
        // the plain daily case and still passes.
        var next = new Date(AL.nextOccurrence(7, 0, "daily", 0, ms(2026, 3, 28, 22, 0)))
        compare(next.getHours(), 7)
        compare(next.getMinutes(), 0)
        compare(next.getDate(), 29)
    }

    // ── fireDecision ──────────────────────────────────────────────────────

    function test_fire_decisions() {
        compare(AL.fireDecision(1000, 999, 100), "wait")
        compare(AL.fireDecision(1000, 1000, 100), "fire")
        compare(AL.fireDecision(1000, 1100, 100), "fire")   // inside grace
        compare(AL.fireDecision(1000, 1101, 100), "missed") // beyond grace
    }

    function test_malformed_nextrun_never_fires() {
        compare(AL.fireDecision(0, 5000, 100), "wait")
        compare(AL.fireDecision(-5, 5000, 100), "wait")
        compare(AL.fireDecision(undefined, 5000, 100), "wait")
    }

    function test_default_grace_is_one_hour() {
        compare(AL.GRACE_MS, 3600000)
        compare(AL.fireDecision(1000, 1000 + AL.GRACE_MS, undefined), "fire")
        compare(AL.fireDecision(1000, 1001 + AL.GRACE_MS, undefined), "missed")
    }

    // ── advance ───────────────────────────────────────────────────────────

    function test_once_is_spent_after_firing() {
        compare(AL.advance({ repeat: "once", hh: 7, mm: 0, weekday: 0 },
                           ms(2026, 7, 14, 7, 0)), -1)
    }

    function test_daily_advances_one_wall_clock_day() {
        compare(AL.advance({ repeat: "daily", hh: 7, mm: 0, weekday: 0 },
                           ms(2026, 7, 14, 7, 0)),
                ms(2026, 7, 15, 7, 0))
    }

    function test_weekly_advances_to_same_weekday() {
        compare(AL.advance({ repeat: "weekly", hh: 9, mm: 0, weekday: 2 },
                           ms(2026, 7, 14, 9, 0)),
                ms(2026, 7, 21, 9, 0))
    }

    // ── sanitizeAlarms ────────────────────────────────────────────────────

    function test_sanitize_rejects_garbage() {
        compare(AL.sanitizeAlarms("not json").length, 0)
        compare(AL.sanitizeAlarms("{\"a\":1}").length, 0)
        compare(AL.sanitizeAlarms("").length, 0)
        compare(AL.sanitizeAlarms(undefined).length, 0)
    }

    function test_sanitize_clamps_fields() {
        var out = AL.sanitizeAlarms(JSON.stringify([
            { url: "http://x", hh: 99, mm: -3, volumePct: 5, repeat: "hourly", weekday: 12 }
        ]))
        compare(out.length, 1)
        compare(out[0].hh, 23)
        compare(out[0].mm, 0)
        compare(out[0].volumePct, 15)   // the floor: an alarm is never silent
        compare(out[0].repeat, "once")
        compare(out[0].weekday, 6)
        compare(out[0].keepAwake, false)
    }

    function test_sanitize_drops_entries_without_url() {
        compare(AL.sanitizeAlarms(JSON.stringify([{ station: "x" }, 42, null])).length, 0)
    }

    function test_sanitize_keeps_a_good_entry_whole() {
        var out = AL.sanitizeAlarms(JSON.stringify([{
            station: "Radio", url: "http://r", favicon: "http://f", hh: 6, mm: 45,
            repeat: "weekly", weekday: 1, volumePct: 60, keepAwake: true, nextRun: 123456
        }]))
        compare(out.length, 1)
        compare(out[0].station, "Radio")
        compare(out[0].nextRun, 123456)
        compare(out[0].keepAwake, true)
    }

    // ── earliestKeepAwake ─────────────────────────────────────────────────

    function test_earliest_keep_awake() {
        compare(AL.earliestKeepAwake([]), 0)
        compare(AL.earliestKeepAwake([{ keepAwake: false, nextRun: 5 }]), 0)
        compare(AL.earliestKeepAwake([
            { keepAwake: true, nextRun: 9 },
            { keepAwake: true, nextRun: 4 },
            { keepAwake: true, nextRun: 0 }   // malformed: never counts
        ]), 4)
    }
}
