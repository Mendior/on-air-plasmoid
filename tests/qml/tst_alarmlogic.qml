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

    // ── retimeForZone: the tz-change recompute ────────────────────────────

    function test_retime_catches_an_entry_missed_across_the_change() {
        // 07:00 daily whose stored instant is already in the past (machine
        // was asleep/off across its moment); now is 07:10. Anchored a grace
        // window back, it recomputes to today 07:00 so the fire scan still
        // catches it — not forward to tomorrow.
        var now = ms(2026, 7, 14, 7, 10)
        var entry = { hh: 7, mm: 0, repeat: "daily", weekday: 0,
                      nextRun: ms(2026, 7, 14, 7, 0) }
        compare(AL.retimeForZone(entry, now), ms(2026, 7, 14, 7, 0))
    }

    function test_retime_never_pulls_an_already_advanced_entry_back() {
        // The double-fire guard: an alarm that fired at 07:00 has nextRun
        // advanced to tomorrow. A tz change at 07:30 must NOT recompute it
        // back onto today 07:00 (which the fire scan would ring a second
        // time) — a future entry anchors at now and stays in the future.
        var now = ms(2026, 7, 14, 7, 30)
        var entry = { hh: 7, mm: 0, repeat: "daily", weekday: 0,
                      nextRun: ms(2026, 7, 15, 7, 0) }
        compare(AL.retimeForZone(entry, now), ms(2026, 7, 15, 7, 0))
    }

    function test_retime_moves_a_future_entry_to_the_new_wall_clock() {
        // 08:00 alarm, now 07:00, still ahead today: recompute keeps it at
        // today 08:00 (the wall-clock promise), never earlier.
        var now = ms(2026, 7, 14, 7, 0)
        var entry = { hh: 8, mm: 0, repeat: "daily", weekday: 0,
                      nextRun: ms(2026, 7, 14, 8, 0) }
        compare(AL.retimeForZone(entry, now), ms(2026, 7, 14, 8, 0))
    }

    function test_retime_gate_skips_an_entry_missed_under_every_zone() {
        // A once-alarm four days past its moment is missed no matter which
        // zone's wall clock tells the story — retiming would resurrect it
        // on whatever day the offset happened to move (a Saturday alarm
        // ringing on Wednesday). The fire scan's missed road owns it.
        var now = ms(2026, 7, 18, 12, 0)
        verify(!AL.shouldRetime({ nextRun: ms(2026, 7, 14, 7, 0) }, now))
    }

    function test_retime_gate_keeps_an_entry_a_zone_shift_could_save() {
        // 90 min stale in the old zone: westward travel of two hours means
        // the wall-clock promise is still genuinely ahead where the machine
        // now lives — this entry must stay retimeable.
        verify(AL.shouldRetime({ nextRun: ms(2026, 7, 14, 7, 0) },
                               ms(2026, 7, 14, 8, 30)))
        // A future entry is always retimeable.
        verify(AL.shouldRetime({ nextRun: ms(2026, 7, 15, 7, 0) },
                               ms(2026, 7, 14, 7, 0)))
        // A malformed instant keeps the old road: sanitize revives it.
        verify(AL.shouldRetime({ nextRun: 0 }, ms(2026, 7, 14, 7, 0)))
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

    function test_sanitize_revives_a_dead_nextrun() {
        // fireDecision treats 0 as "wait" forever — a zeroed entry looked
        // armed in the UI but could never ring (audit finding 0.7). Sanitize
        // must recompute it from the wall-clock fields instead.
        var now = ms(2026, 7, 14, 6, 0)
        var out = AL.sanitizeAlarms(JSON.stringify([
            { url: "http://x", hh: 7, mm: 30, repeat: "daily", nextRun: 0 },
            { url: "http://y", hh: 7, mm: 30, repeat: "daily" },
            { url: "http://z", hh: 7, mm: 30, repeat: "daily", nextRun: "junk" }
        ]), now)
        compare(out.length, 3)
        compare(out[0].nextRun, ms(2026, 7, 14, 7, 30))
        compare(out[1].nextRun, ms(2026, 7, 14, 7, 30))
        compare(out[2].nextRun, ms(2026, 7, 14, 7, 30))
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

    // ── sanitizeRecSchedules ──────────────────────────────────────────────

    function test_rec_sanitize_mirrors_the_alarm_rules() {
        var now = ms(2026, 7, 14, 6, 0)
        var out = AL.sanitizeRecSchedules(JSON.stringify([
            { url: "http://x", hh: 99, mm: -3, durationMin: 0, repeat: "hourly", weekday: 12 },
            { url: "http://y", hh: 7, mm: 30, repeat: "daily", nextRun: 0 },
            { station: "no-url" }, 42, null
        ]), now)
        compare(out.length, 2)
        compare(out[0].hh, 23)
        compare(out[0].mm, 0)
        compare(out[0].durationMin, 1)      // the floor: never a 0-minute recording
        compare(out[0].repeat, "once")
        compare(out[0].weekday, 6)
        verify(out[0].nextRun > now)        // revived, not left inert at 0
        compare(out[1].nextRun, ms(2026, 7, 14, 7, 30))
    }

    function test_rec_sanitize_rejects_garbage_wholesale() {
        compare(AL.sanitizeRecSchedules("not json").length, 0)
        compare(AL.sanitizeRecSchedules(undefined).length, 0)
        compare(AL.sanitizeRecSchedules("{\"a\":1}").length, 0)
    }

    // ── castSilencesWakeTone ──────────────────────────────────────────────
    // The 2026.18 audit's worst finding: the wake tone trusted the
    // optimistic _casting flag, so a speaker unplugged overnight silenced
    // the alarm entirely. The gate must demand an actual acknowledgement.

    function test_unconfirmed_cast_never_silences_the_tone() {
        compare(AL.castSilencesWakeTone(true, false, false), false)
    }

    function test_confirmed_cast_only_stands_down_without_local_play() {
        compare(AL.castSilencesWakeTone(true, true, false), true)
        // Multi-room: the local side must still pass the audibility check.
        compare(AL.castSilencesWakeTone(true, true, true), false)
    }

    function test_not_casting_never_silences_the_tone() {
        compare(AL.castSilencesWakeTone(false, true, false), false)
        compare(AL.castSilencesWakeTone(false, false, false), false)
    }

    function test_gate_rejects_truthy_junk() {
        // Only strict booleans count — an undefined property mid-startup or
        // a stale string must fail closed (tone plays).
        compare(AL.castSilencesWakeTone(undefined, true, false), false)
        compare(AL.castSilencesWakeTone(true, undefined, false), false)
        compare(AL.castSilencesWakeTone(1, 1, 0), false)
    }

    // ── inhibitSeconds ────────────────────────────────────────────────────
    // The keep-awake holder is capped: a weekly alarm six days out must not
    // pin the machine awake for six days (audit finding 0.3).

    function test_inhibit_normal_window_gets_the_two_minute_tail() {
        compare(AL.inhibitSeconds(1000 * 1000 + 3600 * 1000, 1000 * 1000), 3720)
    }

    function test_inhibit_is_capped_at_twelve_hours() {
        var sixDaysMs = 6 * 24 * 3600 * 1000
        compare(AL.inhibitSeconds(sixDaysMs, 0), AL.INHIBIT_MAX_S)
        compare(AL.INHIBIT_MAX_S, 12 * 3600)
    }

    function test_inhibit_floors_at_a_minute_and_zeroes_when_idle() {
        compare(AL.inhibitSeconds(1000, 900), 120)     // due now: just the tail
        compare(AL.inhibitSeconds(1000, 200000), 60)   // already past: the floor
        compare(AL.inhibitSeconds(0, 5000), 0)         // nothing keep-awake
        compare(AL.inhibitSeconds(-1, 5000), 0)
        compare(AL.inhibitSeconds(undefined, 5000), 0)
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
