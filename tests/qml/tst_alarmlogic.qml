// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Scheduling math behind the wake-up alarms AND the recording scheduler
// (main.qml delegates _nextOccurrence here). Every shipped release-breaking
// bug so far lived in QML-side logic — this is the first file of the net
// that catches that class.
import QtQuick
import QtTest

import "../../package/contents/ui/AlarmLogic.js" as AL
import "../../package/contents/ui/StandLogic.js" as SL

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

    // ── the clock change itself, in whatever zone the runner lives in ─────
    // QML cannot set TZ for itself, so these find the local zone's own
    // change in 2026 and build the alarm around it. In Europe/Tallinn that
    // is 03:00 -> 04:00 on 29 March and 04:00 -> 03:00 on 25 October. A zone
    // that keeps one offset all year (a UTC container) has no such night,
    // and the tests say so with a skip instead of passing on nothing.

    // The instant the local offset moves and by how many minutes the wall
    // clock jumps. forward=true is the spring change. null when there is none.
    function clockChange(year, forward) {
        var hour = 3600000
        var prev = new Date(Date.UTC(year, 0, 1)).getTimezoneOffset()
        for (var t = Date.UTC(year, 0, 1) + hour; t < Date.UTC(year + 1, 0, 1); t += hour) {
            var off = new Date(t).getTimezoneOffset()
            if (off === prev) continue
            if ((prev - off > 0) === forward) {
                var lo = t - hour, hi = t
                while (hi - lo > 1000) {
                    var mid = Math.floor((lo + hi) / 2000) * 1000
                    if (new Date(mid).getTimezoneOffset() === prev) lo = mid
                    else hi = mid
                }
                return { at: hi, jumpMin: Math.abs(prev - off) }
            }
            prev = off
        }
        return null
    }

    // A daily alarm set for a wall-clock time inside the spring hole, with
    // the instant it has to ring at: as far past the change as it sat past
    // the start of the hole (03:30 rings at 04:30 new time).
    function holeAlarm() {
        var c = clockChange(2026, true)
        if (!c) return null
        var into = Math.min(30, Math.floor(c.jumpMin / 2))
        var lastMinute = new Date(c.at - 60000)
        var wall = lastMinute.getHours() * 60 + lastMinute.getMinutes() + 1 + into
        return { hh: Math.floor(wall / 60) % 24, mm: wall % 60, repeat: "daily", weekday: 0,
                 at: c.at, rings: c.at + into * 60000 }
    }

    // What the engine's tick does to one entry, every 30 s: re-express it
    // when the zone offset moved, ask whether it is due, advance it after.
    // Returns the instants it rang at and how many times it was written off.
    function runTicks(entry, fromMs, toMs) {
        var rang = [], missed = 0
        var tz = new Date(fromMs).getTimezoneOffset()
        for (var now = fromMs; now <= toMs; now += 30000) {
            var z = new Date(now).getTimezoneOffset()
            if (z !== tz) {
                tz = z
                if (AL.shouldRetime(entry, now)) entry.nextRun = AL.retimeForZone(entry, now)
            }
            var dec = AL.fireDecision(entry.nextRun, now, AL.GRACE_MS)
            if (dec === "wait") continue
            if (dec === "fire") rang.push(now)
            else missed++
            entry.nextRun = AL.advance(entry, now)
        }
        return { rang: rang, missed: missed }
    }

    function test_a_retime_at_the_spring_flip_keeps_the_hole_alarm_today() {
        var a = holeAlarm()
        if (!a) skip("this zone has no spring clock change in 2026")
        // The first tick after the change sees a new offset and retimes.
        // The alarm is still ahead, half an hour into the new time.
        a.nextRun = a.rings
        compare(AL.retimeForZone(a, a.at + 30000), a.rings)
    }

    function test_a_hole_alarm_slept_through_is_still_caught_after_the_flip() {
        var a = holeAlarm()
        if (!a) skip("this zone has no spring clock change in 2026")
        // The machine wakes ten minutes late, on the far side of the change.
        // Retimed, the alarm must stay at or before now so the fire scan
        // rings it inside its grace hour.
        a.nextRun = a.rings
        compare(AL.retimeForZone(a, a.rings + 600000), a.rings)
    }

    function test_next_occurrence_counts_a_hole_time_where_it_really_rings() {
        var a = holeAlarm()
        if (!a) skip("this zone has no spring clock change in 2026")
        // Asked the evening before, and asked again just after the change:
        // the same instant both times.
        compare(AL.nextOccurrence(a.hh, a.mm, "daily", 0, a.at - 5 * 3600000), a.rings)
        compare(AL.nextOccurrence(a.hh, a.mm, "daily", 0, a.at + 1000), a.rings)
        // One second before it rings is still today.
        compare(AL.nextOccurrence(a.hh, a.mm, "daily", 0, a.rings - 1000), a.rings)
        // "Strictly after": at the ringing instant the next one is tomorrow,
        // where the asked-for wall clock exists again.
        var d = new Date(a.rings)
        var tomorrow = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1,
                                a.hh, a.mm, 0, 0).getTime()
        compare(AL.nextOccurrence(a.hh, a.mm, "daily", 0, a.rings), tomorrow)
    }

    function test_weekly_hole_alarm_stays_on_its_own_day() {
        var a = holeAlarm()
        if (!a) skip("this zone has no spring clock change in 2026")
        // Where the change is at midnight the hole time resolves back into
        // the evening before, and the alarm still belongs to the new day.
        var weekday = new Date(a.rings).getDay()
        compare(AL.nextOccurrence(a.hh, a.mm, "weekly", weekday, a.at + 1000), a.rings)
        // After it rang, the next one is a week of wall-clock days away.
        var d = new Date(a.rings)
        var nextWeek = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 7,
                                a.hh, a.mm, 0, 0).getTime()
        compare(AL.nextOccurrence(a.hh, a.mm, "weekly", weekday, a.rings), nextWeek)
    }

    function test_hole_alarm_rings_once_on_the_spring_night() {
        var a = holeAlarm()
        if (!a) skip("this zone has no spring clock change in 2026")
        var from = a.at - 5 * 3600000 + 7000
        a.nextRun = AL.nextOccurrence(a.hh, a.mm, "daily", 0, from)
        var night = runTicks(a, from, a.at + 5 * 3600000)
        compare(night.missed, 0)
        compare(night.rang.length, 1)
        // The 30 s tick lands on or just after the instant, never before.
        verify(night.rang[0] >= a.rings && night.rang[0] < a.rings + 30000)
    }

    function test_alarm_in_the_repeated_autumn_hour_rings_once() {
        var c = clockChange(2026, false)
        if (!c) skip("this zone has no autumn clock change in 2026")
        // Half an hour into the hour the wall clock shows twice.
        var w = new Date(c.at + Math.min(30, Math.floor(c.jumpMin / 2)) * 60000)
        var a = { hh: w.getHours(), mm: w.getMinutes(), repeat: "daily", weekday: 0 }
        var from = c.at - 5 * 3600000 + 7000
        a.nextRun = AL.nextOccurrence(a.hh, a.mm, "daily", 0, from)
        var night = runTicks(a, from, c.at + 5 * 3600000)
        compare(night.missed, 0)
        compare(night.rang.length, 1)
    }

    // ── _resolveGap: the spring-forward hole ──────────────────────────────
    // Pure math on already-constructed Dates: no real gap in the test zone
    // is needed, only the "resolved clock reads short of asked-for" shape
    // an engine produces inside one.

    function test_gap_backward_hour_shifts_forward_an_hour() {
        // Qt's road through Tallinn's hole: 03:30 resolved back to 02:30 —
        // the cure is exactly the missing hour.
        var d = new Date(ms(2026, 3, 29, 2, 30))
        compare(AL._resolveGap(d, 3, 30).getTime(), d.getTime() + 3600000)
    }

    function test_gap_is_measured_in_minutes_not_hours() {
        // Lord Howe's DST is 30 min: asked 02:15, resolved back to 01:45 —
        // a fixed one-hour cure would ring half an hour late.
        var d = new Date(ms(2026, 10, 4, 1, 45))
        compare(AL._resolveGap(d, 2, 15).getTime(), d.getTime() + 30 * 60000)
        // Troll's is 2 h: asked 01:00, resolved back across midnight to
        // 23:00 — the modulo keeps the shortfall at 120, never negative.
        var t = new Date(ms(2026, 3, 18, 23, 0))
        compare(AL._resolveGap(t, 1, 0).getTime(), t.getTime() + 120 * 60000)
    }

    function test_gap_forward_resolution_is_left_alone() {
        // An engine that resolved the hole FORWARD is past the gap and
        // correct: its "shortfall" wraps to ~23.5 h, over the cap, so no
        // shift — shifting it too would ring late.
        var d = new Date(ms(2026, 3, 29, 4, 30))
        compare(AL._resolveGap(d, 3, 30).getTime(), d.getTime())
    }

    function test_gap_exact_readback_is_untouched() {
        var d = new Date(ms(2026, 7, 14, 7, 30))
        compare(AL._resolveGap(d, 7, 30).getTime(), d.getTime())
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
        // armed in the UI but could never ring. Sanitize must recompute it
        // from the wall-clock fields instead.
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
            repeat: "weekly", weekday: 1, volumePct: 60, keepAwake: true, nextRun: 123456,
            uuid: "abc-123"
        }]))
        compare(out.length, 1)
        compare(out[0].station, "Radio")
        compare(out[0].nextRun, 123456)
        compare(out[0].keepAwake, true)
        compare(out[0].uuid, "abc-123")
    }

    function test_sanitize_defaults_a_missing_uuid_to_empty() {
        // Entries saved before the uuid field existed must load unchanged —
        // an empty uuid just means the heal takes the name-search road.
        var out = AL.sanitizeAlarms(JSON.stringify([
            { url: "http://r", hh: 7, mm: 0 },
            { url: "http://s", hh: 7, mm: 0, uuid: 42 }
        ]))
        compare(out.length, 2)
        compare(out[0].uuid, "")
        compare(out[1].uuid, "42")   // coerced to string, never a number
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
    // The worst thing 2026.18 turned up: the wake tone trusted the
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

    // ── podcastWake ───────────────────────────────────────────────────────
    // A podcast alarm with nothing on disk said "waking with the chime" and
    // then left last night's radio on at last night's volume: the chime sat
    // behind a check for whether anything was playing.

    function test_a_podcast_alarm_wakes_with_the_episode_it_found() {
        compare(AL.podcastWake("ep1.mp3"), "episode")
        compare(AL.podcastWake("a"), "episode")
        compare(AL.podcastWake(new Array(5001).join("x") + ".mp3"), "episode")
    }

    function test_a_podcast_alarm_with_no_episode_wakes_with_the_chime() {
        compare(AL.podcastWake(""), "chime")
        compare(AL.podcastWake(null), "chime")
        compare(AL.podcastWake(undefined), "chime")
        // Not a file name: nothing the player could be handed.
        compare(AL.podcastWake(0), "chime")
        compare(AL.podcastWake(true), "chime")
        compare(AL.podcastWake({}), "chime")
        compare(AL.podcastWake(["ep1.mp3"]), "chime")
    }

    // ── inhibitSeconds ────────────────────────────────────────────────────
    // The keep-awake holder is capped: a weekly alarm six days out must not
    // pin the machine awake for six days.

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

    // ── a station that falls silent while the alarm rings ────────────────

    function test_the_numbers_the_tones_later_checks_are_built_on() {
        compare(AL.WAKE_GRACE_MS, 8000)
        compare(AL.WAKE_STARTED_MS, 5000)
        compare(AL.WAKE_BACK_MS, 3000)
        // A connection that is let through has to be one the stand watch can watch.
        verify(AL.WAKE_BACK_MS >= SL.ARM_MS)
        // 2.5 s to the first sound and the sound itself fit in the grace.
        verify(2500 + AL.WAKE_BACK_MS < AL.WAKE_GRACE_MS)
    }

    function test_an_alarm_rings_for_half_an_hour_from_its_fire() {
        var fired = ms(2026, 11, 12, 7, 0);
        compare(AL.WAKE_WINDOW_MS, 1800000)
        verify(AL.wakeRings(fired, fired))
        verify(AL.wakeRings(fired, fired + 9000))
        verify(AL.wakeRings(fired, fired + 1799999))
        verify(AL.wakeRings(fired, fired + 1800000))
        verify(!AL.wakeRings(fired, fired + 1800001))
        verify(!AL.wakeRings(fired, fired + 3600000))
        verify(AL.wakeRings(1, 2))
    }

    function test_a_clock_that_jumped_ends_the_ringing_and_cannot_lengthen_it() {
        var fired = ms(2026, 11, 12, 7, 0);
        // Set back behind the fire: an hour, a second, a millisecond.
        verify(!AL.wakeRings(fired, fired - 3600000))
        verify(!AL.wakeRings(fired, fired - 1000))
        verify(!AL.wakeRings(fired, fired - 1))
        verify(!AL.wakeRings(fired, 0))
        verify(!AL.wakeRings(fired, -1))
        // Set forward, or eight hours asleep.
        verify(!AL.wakeRings(fired, fired + 28800000))
        verify(!AL.wakeRings(fired, Number.MAX_VALUE))
    }

    function test_no_fire_and_no_clock_ring_nothing() {
        var noFire = [0, -1, undefined, null, NaN, Infinity, "1794466800000", {}];
        for (var i = 0; i < noFire.length; i++) verify(!AL.wakeRings(noFire[i], 1794466800000), "fired " + String(noFire[i]))
        var noClock = [undefined, null, NaN, Infinity, "1794466800001", {}];
        for (i = 0; i < noClock.length; i++) verify(!AL.wakeRings(1794466800000, noClock[i]), "now " + String(noClock[i]))
        verify(!AL.wakeRings())
    }

    function test_a_knock_has_eight_seconds_before_the_check() {
        compare(AL.wakeGraceLeftMs(100000, 100000), 8000)
        compare(AL.wakeGraceLeftMs(100000, 102400), 5600)
        compare(AL.wakeGraceLeftMs(100000, 107999), 1)
        compare(AL.wakeGraceLeftMs(100000, 108000), 0)
        compare(AL.wakeGraceLeftMs(100000, 3600000), 0)
        compare(AL.wakeGraceLeftMs(1, 2), 7999)
    }

    function test_a_clock_set_back_does_not_lengthen_the_wait() {
        compare(AL.wakeGraceLeftMs(100000, 99999), 8000)
        compare(AL.wakeGraceLeftMs(100000, 0), 8000)
        compare(AL.wakeGraceLeftMs(100000, -7200000), 8000)
    }

    function test_no_fall_is_no_wait() {
        var noFall = [0, -1, undefined, null, NaN, Infinity, "100000", {}];
        for (var i = 0; i < noFall.length; i++) compare(AL.wakeGraceLeftMs(noFall[i], 100000), 0, String(noFall[i]))
        var noClock = [undefined, null, NaN, Infinity, "100001", {}];
        for (i = 0; i < noClock.length; i++) compare(AL.wakeGraceLeftMs(100000, noClock[i]), 0, String(noClock[i]))
        compare(AL.wakeGraceLeftMs(), 0)
    }

    function test_a_station_that_never_fell_sounds_once_it_has_started() {
        // 2026-08-10 23:08:46: playing, Buffering, 24917 ms, and it could be heard.
        verify(AL.wakeSounds(true, false, 24917, false))
        verify(AL.wakeSounds(true, false, 5001, false))
        verify(!AL.wakeSounds(true, false, 5000, false))
        verify(!AL.wakeSounds(true, false, 800, false))
        verify(AL.wakeSounds(true, true, 0, false))
        verify(!AL.wakeSounds(false, true, 24917, false))
        // No word about a fall is no fall.
        verify(AL.wakeSounds(true, false, 24917))
        verify(!AL.wakeSounds(true, false, 3000))
    }

    function test_after_a_fall_it_is_the_new_connection_that_has_to_sound() {
        verify(AL.wakeSounds(true, false, 3000, true))
        verify(AL.wakeSounds(true, false, 6750, true))
        verify(AL.wakeSounds(true, true, 24917, true))
        verify(!AL.wakeSounds(true, false, 2999, true))
        verify(!AL.wakeSounds(true, false, 0, true))
        // A burst fills the buffer at once, and the connection may hold its peace from there.
        verify(!AL.wakeSounds(true, true, 1200, true))
        verify(!AL.wakeSounds(true, true, 0, true))
        verify(!AL.wakeSounds(false, false, 7968, true))
        verify(!AL.wakeSounds(false, true, 7968, true))
    }

    function test_what_is_no_fact_does_not_sound() {
        var notTrue = [undefined, null, 1, "true", {}];
        for (var i = 0; i < notTrue.length; i++) {
            verify(!AL.wakeSounds(notTrue[i], true, 24917, false), "playing " + String(notTrue[i]))
            verify(!AL.wakeSounds(notTrue[i], true, 24917, true), "playing " + String(notTrue[i]))
            // A status that is no plain true leaves it to the position.
            verify(!AL.wakeSounds(true, notTrue[i], 800, false), "buffered " + String(notTrue[i]))
            verify(AL.wakeSounds(true, notTrue[i], 5001, false), "buffered " + String(notTrue[i]))
            // A fall that is no plain true is none.
            verify(AL.wakeSounds(true, true, 0, notTrue[i]), "fell " + String(notTrue[i]))
            verify(!AL.wakeSounds(true, false, 3000, notTrue[i]), "fell " + String(notTrue[i]))
        }
        var noPos = [undefined, null, NaN, Infinity, "24917", {}];
        for (i = 0; i < noPos.length; i++) {
            verify(!AL.wakeSounds(true, false, noPos[i], false), "position " + String(noPos[i]))
            verify(!AL.wakeSounds(true, false, noPos[i], true), "position " + String(noPos[i]))
            verify(!AL.wakeSounds(true, true, noPos[i], true), "position " + String(noPos[i]))
        }
        verify(!AL.wakeSounds())
        verify(AL.wakeSounds(true, false, Number.MAX_VALUE, true))
        verify(AL.wakeSounds(true, false, Number.MAX_VALUE, false))
    }
}
