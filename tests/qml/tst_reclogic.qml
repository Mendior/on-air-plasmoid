// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The recorder's judgments. The sanitizer matters most: a station name from
// an external catalogue ends up in a shell command and a file path, so the
// quote and separator stripping is a security boundary, not cosmetics.
import QtQuick
import QtTest

import "../../package/contents/ui/RecLogic.js" as RecLogic

TestCase {
    name: "RecLogic"

    function test_hostile_names_come_out_harmless() {
        compare(RecLogic.sanitizeStationName("Sky/Radio: *best*?"),
                "Sky-Radio- -best--")
        // Quotes go — the name rides inside single-quoted shell arguments.
        verify(RecLogic.sanitizeStationName("O'Brien \"FM\"").indexOf("'") === -1)
        verify(RecLogic.sanitizeStationName("O'Brien \"FM\"").indexOf("\"") === -1)
        // Tabs and newlines cannot reach a file name either.
        compare(RecLogic.sanitizeStationName("A\tB\nC"), "A-B-C")
    }

    function test_names_fold_cap_and_never_vanish() {
        compare(RecLogic.sanitizeStationName("  Raadio   Elmar  "), "Raadio Elmar")
        var capped = RecLogic.sanitizeStationName(new Array(30).join("abc "))
        verify(capped.length <= 60)
        compare(RecLogic.sanitizeStationName(""), "Radio")
        compare(RecLogic.sanitizeStationName("'''"), "---")
    }

    function test_elapsed_reads_like_a_clock() {
        compare(RecLogic.elapsedText(0), "0:00")
        compare(RecLogic.elapsedText(59), "0:59")
        compare(RecLogic.elapsedText(61), "1:01")
        compare(RecLogic.elapsedText(3600), "1:00:00")
        compare(RecLogic.elapsedText(3661), "1:01:01")
    }

    // ── a scheduled capture and the end of its window ─────────────────────

    readonly property double windowEnd: 1790000000000

    function test_a_capture_long_past_its_window_has_overrun() {
        // Asleep through the end, awake two and a half hours later.
        verify(RecLogic.captureOverran(windowEnd + 150 * 60000, windowEnd))
        verify(RecLogic.captureOverran(windowEnd + 6 * 60000, windowEnd))
        verify(RecLogic.captureOverran(windowEnd + 400 * 86400000, windowEnd))
    }

    function test_a_capture_inside_its_window_or_just_leaving_has_not() {
        verify(!RecLogic.captureOverran(windowEnd - 30 * 60000, windowEnd))
        verify(!RecLogic.captureOverran(windowEnd, windowEnd))
        // ffmpeg's own exit comes a few seconds after the end.
        verify(!RecLogic.captureOverran(windowEnd + 5000, windowEnd))
        // A clock set back a day stops nothing.
        verify(!RecLogic.captureOverran(windowEnd - 86400000, windowEnd))
    }

    function test_the_overrun_grace_is_five_minutes_to_the_millisecond() {
        compare(RecLogic.OVERRUN_GRACE_MS, 300000)
        verify(!RecLogic.captureOverran(windowEnd + 300000, windowEnd))
        verify(RecLogic.captureOverran(windowEnd + 300001, windowEnd))
        // A capture that connected late runs its own length and ends that
        // much after the window: 141 s was measured on a slow station.
        verify(!RecLogic.captureOverran(windowEnd + 141000, windowEnd))
        // The caller may bring its own.
        verify(RecLogic.captureOverran(windowEnd + 11, windowEnd, 10))
        verify(!RecLogic.captureOverran(windowEnd + 10, windowEnd, 10))
    }

    function test_a_window_that_cannot_be_read_stops_nothing() {
        var now = windowEnd + 150 * 60000
        verify(!RecLogic.captureOverran(now, undefined))
        verify(!RecLogic.captureOverran(now, null))
        verify(!RecLogic.captureOverran(now, NaN))
        verify(!RecLogic.captureOverran(now, 0))
        verify(!RecLogic.captureOverran(now, -5))
        verify(!RecLogic.captureOverran(now, "soon"))
        verify(!RecLogic.captureOverran(undefined, windowEnd))
        verify(!RecLogic.captureOverran(NaN, windowEnd))
        verify(!RecLogic.captureOverran(undefined, undefined))
        verify(!RecLogic.captureOverran(now, windowEnd, NaN))
    }

    // ── a stop that left nothing on disk ──────────────────────────────────

    function test_a_stop_the_listener_asked_for_with_nothing_on_disk_is_called_off() {
        verify(RecLogic.calledOff(true, false, false))
    }

    function test_a_file_on_disk_or_no_stop_at_all_is_not_called_off() {
        // Something was captured: that has its own verdict.
        verify(!RecLogic.calledOff(true, false, true))
        // Nobody asked: nothing on disk is a failure.
        verify(!RecLogic.calledOff(false, false, false))
        verify(!RecLogic.calledOff(false, false, true))
    }

    function test_the_ticks_own_stop_is_never_called_off() {
        verify(!RecLogic.calledOff(true, true, false))
        verify(!RecLogic.calledOff(true, true, true))
        verify(!RecLogic.calledOff(false, true, false))
    }

    function test_what_is_not_known_is_not_called_off() {
        verify(!RecLogic.calledOff(undefined, undefined, undefined))
        verify(!RecLogic.calledOff(null, false, false))
        verify(!RecLogic.calledOff("yes", false, false))
        verify(!RecLogic.calledOff(1, false, false))
        verify(!RecLogic.calledOff(true, undefined, false))
        verify(!RecLogic.calledOff(true, false, undefined))
        verify(!RecLogic.calledOff(true, "", 0))
        verify(!RecLogic.calledOff())
    }

    // ── how much audio a finished capture holds ───────────────────────────

    function test_the_shells_answer_names_the_seconds_in_the_file() {
        compare(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=160172 secs=10"), 10)
        compare(RecLogic.mediaSeconds("__REC_DONE__ rc=255 bytes=53484 secs=3\n"), 3)
        compare(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=172403690 secs=10799"), 10799)
        compare(RecLogic.mediaSeconds("__REC_DONE__ rc=-1 bytes=1 secs=0"), 0)
        // Whatever else the shell printed around it.
        compare(RecLogic.mediaSeconds("noise\n__REC_DONE__ rc=0 bytes=9 secs=42\nmore"), 42)
    }

    function test_an_answer_without_its_seconds_is_not_a_number() {
        // No ffprobe on the machine, and a container that cannot say.
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=160172 secs=")))
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=160172 secs=N/A")))
        // The answer as it was before the shell asked at all.
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=160172")))
        verify(isNaN(RecLogic.mediaSeconds("__REC_EMPTY__ rc=1")))
        verify(isNaN(RecLogic.mediaSeconds("")))
        verify(isNaN(RecLogic.mediaSeconds(null)))
        verify(isNaN(RecLogic.mediaSeconds(undefined)))
        verify(isNaN(RecLogic.mediaSeconds(42)))
    }

    function test_seconds_of_another_shape_are_not_read() {
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=1 secs=-5")))
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=1 secs=12abc")))
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=1 secs=1e9")))
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=1 secs= 12")))
        // Seconds that belong to no finished capture.
        verify(isNaN(RecLogic.mediaSeconds("secs=12")))
        verify(isNaN(RecLogic.mediaSeconds("__REC_EMPTY__ rc=0 secs=12")))
        // Nine digits is thirty years; more than that is not a length.
        compare(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=1 secs=999999999"), 999999999)
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=1 secs=1000000000")))
        verify(isNaN(RecLogic.mediaSeconds("__REC_DONE__ rc=0 bytes=1 secs="
                                           + new Array(5001).join("9"))))
    }

    function test_the_files_own_word_is_heard_before_the_clock() {
        compare(RecLogic.heardSeconds(10, 598), 10)
        compare(RecLogic.heardSeconds(0, 598), 0)
        compare(RecLogic.heardSeconds(3600, 0), 3600)
        // No word from the file: the clock, as before.
        compare(RecLogic.heardSeconds(NaN, 65), 65)
        compare(RecLogic.heardSeconds(undefined, 65), 65)
        compare(RecLogic.heardSeconds(null, 0), 0)
        compare(RecLogic.heardSeconds(-1, 65), 65)
        compare(RecLogic.heardSeconds("10", 65), 65)
        compare(RecLogic.heardSeconds(Infinity, 65), 65)
    }

    function test_a_capture_with_a_fraction_of_its_audio_falls_short() {
        // Connected late and the stream ended at once: 7 s of 300.
        verify(RecLogic.fallsShort(300, 7, 7))
        // Ten seconds, then a silent socket for the rest of the cap. The
        // clock went on counting; the file says ten.
        verify(RecLogic.fallsShort(300, 10, 598))
        verify(RecLogic.fallsShort(3600, 1800, 3590))
        verify(RecLogic.fallsShort(60, 7, 58))
        verify(RecLogic.fallsShort(300, 0, 0))
    }

    function test_a_whole_capture_does_not_fall_short() {
        verify(!RecLogic.fallsShort(300, 300, 296))
        verify(!RecLogic.fallsShort(3600, 3600, 3590))
        // Raw AAC is an estimate: 295.4 s was read off a 300.0 s file.
        verify(!RecLogic.fallsShort(300, 295, 296))
        // A re-encode can come out a frame longer than asked.
        verify(!RecLogic.fallsShort(60, 61, 58))
        // The file's word counts, whatever the clock made of it.
        verify(!RecLogic.fallsShort(300, 300, 3))
    }

    function test_the_files_word_may_be_a_tenth_short_and_ten_seconds_at_least() {
        compare(RecLogic.SHORT_SHARE, 0.1)
        compare(RecLogic.MEDIA_SLACK_SEC, 10)
        verify(!RecLogic.fallsShort(300, 270, NaN))
        verify(RecLogic.fallsShort(300, 269, NaN))
        verify(!RecLogic.fallsShort(3600, 3240, NaN))
        verify(RecLogic.fallsShort(3600, 3239, NaN))
        // Under 100 s a tenth is less than ten seconds, and ten it is.
        verify(!RecLogic.fallsShort(60, 50, NaN))
        verify(RecLogic.fallsShort(60, 49, NaN))
    }

    function test_the_clock_may_be_a_tenth_short_and_a_minute_at_least() {
        compare(RecLogic.CLOCK_SLACK_SEC, 60)
        verify(!RecLogic.fallsShort(300, NaN, 240))
        verify(RecLogic.fallsShort(300, NaN, 239))
        verify(!RecLogic.fallsShort(3600, NaN, 3240))
        verify(RecLogic.fallsShort(3600, NaN, 3239))
        // A one-minute capture is all slack: the clock cannot judge it.
        verify(!RecLogic.fallsShort(60, NaN, 0))
        verify(!RecLogic.fallsShort(120, NaN, 60))
        verify(RecLogic.fallsShort(120, NaN, 59))
    }

    function test_with_no_witness_nothing_falls_short() {
        // The file could not say and was never seen: as it always was.
        verify(!RecLogic.fallsShort(300, NaN, NaN))
        verify(!RecLogic.fallsShort(300, undefined, undefined))
        verify(!RecLogic.fallsShort(300, null, null))
        verify(!RecLogic.fallsShort(300, "7", "7"))
        verify(!RecLogic.fallsShort(300, -7, -7))
        verify(!RecLogic.fallsShort(300, Infinity, Infinity))
        verify(!RecLogic.fallsShort(300))
        // A witness that cannot be read gives way to one that can.
        verify(RecLogic.fallsShort(300, NaN, 7))
        verify(RecLogic.fallsShort(300, -1, 7))
        verify(RecLogic.fallsShort(300, "300", 7))
    }

    function test_without_an_asked_length_nothing_falls_short() {
        verify(!RecLogic.fallsShort(0, 0, 0))
        verify(!RecLogic.fallsShort(-300, 7, 7))
        verify(!RecLogic.fallsShort(NaN, 7, 7))
        verify(!RecLogic.fallsShort(undefined, 7, 7))
        verify(!RecLogic.fallsShort(null, 7, 7))
        verify(!RecLogic.fallsShort("300", 7, 7))
        verify(!RecLogic.fallsShort(Infinity, 7, 7))
        verify(!RecLogic.fallsShort())
    }

    function test_a_very_long_capture_is_judged_like_any_other() {
        // A month, asked for and held.
        verify(!RecLogic.fallsShort(2592000, 2592000, NaN))
        verify(RecLogic.fallsShort(2592000, 2000000, NaN))
        verify(!RecLogic.fallsShort(2592000, 999999999, NaN))
    }

    // ── the start time in a recording's name ──────────────────────────────

    readonly property double born: 1794300000000

    function test_the_stamp_is_the_clock_when_the_clock_runs_forward() {
        compare(RecLogic.startStamp(born + 5000, born, 0), born + 5000)
        compare(RecLogic.startStamp(born + 9000, born, born + 5000), born + 9000)
    }

    function test_two_recordings_in_one_millisecond_are_a_millisecond_apart() {
        compare(RecLogic.startStamp(born + 5000, born, born + 5000), born + 5001)
        compare(RecLogic.startStamp(born + 5000, born, born + 5001), born + 5002)
        // The session's own first millisecond is not before the session.
        compare(RecLogic.startStamp(born, born, 0), born)
    }

    function test_a_clock_set_back_makes_no_recording_older_than_the_one_before() {
        // An hour back since the last recording, and since the panel came up.
        compare(RecLogic.startStamp(born - 3600000, born, born + 5000), born + 5001)
        compare(RecLogic.startStamp(born - 3600000, born, 0), born)
    }

    function test_what_is_no_time_counts_as_zero() {
        compare(RecLogic.startStamp(NaN, born, 0), born)
        compare(RecLogic.startStamp(undefined, born, 7), born)
        compare(RecLogic.startStamp(null, born, born), born + 1)
        compare(RecLogic.startStamp("1794300009000", born, 0), born)
        compare(RecLogic.startStamp(-5, born, 0), born)
        compare(RecLogic.startStamp(Infinity, born, 0), born)
        compare(RecLogic.startStamp(born + 5000, NaN, undefined), born + 5000)
        compare(RecLogic.startStamp(born + 5000, "x", -3), born + 5000)
        compare(RecLogic.startStamp(born + 5000, born, Infinity), born + 5000)
        // Nothing known at all is still a whole number, and not zero.
        compare(RecLogic.startStamp(), 1)
        compare(RecLogic.startStamp(NaN, NaN, NaN), 1)
        compare(RecLogic.startStamp(-5, -7, -3), 1)
    }

    function test_the_stamp_is_always_a_whole_number() {
        compare(RecLogic.startStamp(born + 0.75, born, 0), born)
        compare(RecLogic.startStamp(born + 5000.9, born + 0.5, born + 4999.5), born + 5000)
        // The far end of what a date can be.
        compare(RecLogic.startStamp(8640000000000000, born, 0), 8640000000000000)
    }

    // ── the address files of older recordings ─────────────────────────────

    readonly property string urlFiles: "'/run/user/1000/arp-rec-url-42-'"

    function test_older_files_are_taken_by_the_time_in_their_name() {
        compare(RecLogic.olderFilesLine(urlFiles, 1794300000000),
                "for f in '/run/user/1000/arp-rec-url-42-'*; do t=${f##*.};"
                + " [ \"$t\" -lt 1794300000000 ] 2>/dev/null && rm -f \"$f\"; done; ")
        // A folder with a quote and a space in its name, quoted as shQuote does.
        compare(RecLogic.olderFilesLine("'/run/o'\\''neil x/arp-rec-url-42-'", 5),
                "for f in '/run/o'\\''neil x/arp-rec-url-42-'*; do t=${f##*.};"
                + " [ \"$t\" -lt 5 ] 2>/dev/null && rm -f \"$f\"; done; ")
    }

    function test_the_edges_of_a_time_that_can_stand_in_a_command() {
        // Before zero there is nothing, and the line says so harmlessly.
        verify(RecLogic.olderFilesLine(urlFiles, 0).indexOf(" -lt 0 ]") !== -1)
        verify(RecLogic.olderFilesLine(urlFiles, 1).indexOf(" -lt 1 ]") !== -1)
        // The largest whole number a double holds exactly, digit for digit.
        verify(RecLogic.olderFilesLine(urlFiles, 9007199254740991).indexOf(" -lt 9007199254740991 ]") !== -1)
    }

    function test_a_time_that_is_no_whole_number_takes_nothing() {
        // No line at all: nothing half-meant goes to the shell.
        compare(RecLogic.olderFilesLine(urlFiles, NaN), "")
        compare(RecLogic.olderFilesLine(urlFiles, -1), "")
        compare(RecLogic.olderFilesLine(urlFiles, 1.5), "")
        compare(RecLogic.olderFilesLine(urlFiles, Infinity), "")
        compare(RecLogic.olderFilesLine(urlFiles, "1794300000000"), "")
        compare(RecLogic.olderFilesLine(urlFiles, "0; rm -rf ~"), "")
        compare(RecLogic.olderFilesLine(urlFiles, null), "")
        compare(RecLogic.olderFilesLine(urlFiles, undefined), "")
        compare(RecLogic.olderFilesLine(urlFiles), "")
    }

    function test_without_a_quoted_beginning_nothing_is_taken() {
        // A bare * would run through whatever folder the shell stands in.
        compare(RecLogic.olderFilesLine("", 5), "")
        compare(RecLogic.olderFilesLine("''", 5), "")
        compare(RecLogic.olderFilesLine(null, 5), "")
        compare(RecLogic.olderFilesLine(undefined, 5), "")
        compare(RecLogic.olderFilesLine(42, 5), "")
        compare(RecLogic.olderFilesLine("/run/user/1000/arp-rec-url-42-", 5), "")
        compare(RecLogic.olderFilesLine("'/run/user/1000/arp-rec-url-42-", 5), "")
        compare(RecLogic.olderFilesLine("/run/user/1000/arp-rec-url-42-'", 5), "")
        compare(RecLogic.olderFilesLine("  ", 5), "")
    }

    function test_a_time_too_large_to_be_written_out_takes_nothing() {
        // From 1e21 a number prints as 1e+21, and past 2^53 its last
        // digits are not the ones that were meant.
        compare(RecLogic.olderFilesLine(urlFiles, 1e21), "")
        compare(RecLogic.olderFilesLine(urlFiles, 9007199254740993), "")
        compare(RecLogic.olderFilesLine(urlFiles, Number.MAX_VALUE), "")
        // A very long folder name is only a long line.
        var deep = "'/" + new Array(5001).join("d") + "/arp-rec-url-42-'"
        var line = RecLogic.olderFilesLine(deep, 5)
        compare(line.indexOf("for f in " + deep + "*; do "), 0)
        verify(line.length > deep.length && line.length < deep.length + 100)
    }

    function test_only_plain_http_streams_are_recordable() {
        verify(RecLogic.canRecordUrl("http://s1.radio.ee/live.mp3"))
        verify(RecLogic.canRecordUrl("https://s1.radio.ee/live"))
        verify(!RecLogic.canRecordUrl("http://s1.radio.ee/live.m3u8"))
        verify(!RecLogic.canRecordUrl("http://s1.radio.ee/list.pls"))
        verify(!RecLogic.canRecordUrl("file:///home/egon/song.mp3"))
        verify(!RecLogic.canRecordUrl(""))
    }

    // The "Max length" box in the settings, read back from its own text.
    function test_typed_minutes_are_read_with_or_without_their_unit() {
        compare(RecLogic.typedMinutes("45", 180), 45)
        compare(RecLogic.typedMinutes("180 min", 180), 180)
        compare(RecLogic.typedMinutes("45 Min.", 180), 45)
        compare(RecLogic.typedMinutes("90 хв", 180), 90)
        compare(RecLogic.typedMinutes("  60  ", 180), 60)
    }

    function test_a_grouped_number_is_one_number() {
        // What KDE shows for 1440 by language; parseInt made 1 of each.
        compare(RecLogic.typedMinutes("1,440 min", 180), 1440)
        compare(RecLogic.typedMinutes("1 440 min", 180), 1440)
        compare(RecLogic.typedMinutes("1" + String.fromCharCode(0xa0) + "440 min", 180), 1440)
        compare(RecLogic.typedMinutes("1" + String.fromCharCode(0x202f) + "440 min", 180), 1440)
        compare(RecLogic.typedMinutes("1.440 Min.", 180), 1440)
        compare(RecLogic.typedMinutes("1,000 min", 180), 1000)
    }

    function test_a_text_without_a_digit_is_the_fallback() {
        compare(RecLogic.typedMinutes("", 180), 180)
        compare(RecLogic.typedMinutes(" min", 180), 180)
        compare(RecLogic.typedMinutes("abc", 180), 180)
        compare(RecLogic.typedMinutes(null, 180), 180)
        compare(RecLogic.typedMinutes(undefined, 180), 180)
        compare(RecLogic.typedMinutes("", 240), 240)
    }

    function test_the_edges_of_what_can_be_typed() {
        compare(RecLogic.typedMinutes("0", 180), 0)
        compare(RecLogic.typedMinutes("000030", 180), 30)
        compare(RecLogic.typedMinutes("999999", 180), 999999)
        compare(RecLogic.typedMinutes("1234567", 180), 123456)
        compare(RecLogic.typedMinutes("-45", 180), 45)
        compare(RecLogic.typedMinutes(45, 180), 45)
    }

    function test_a_very_long_run_of_digits_is_still_a_number() {
        var out = RecLogic.typedMinutes(new Array(5001).join("9"), 180)
        compare(out, 999999)
    }

    // --- startsWithin: a start that will not wait for the regular look -------

    function test_a_start_inside_the_coming_period_gets_its_own_wait() {
        var T = 1794400200000;   // a start on the clock, 18:30:00.000
        // The look comes round 20 s before the start: the start is 20 s off,
        // not left to the look after it, which would be 10 s late.
        compare(RecLogic.startsWithin([{ nextRun: T }], T - 20000, 30000), 20000);
        compare(RecLogic.startsWithin([{ nextRun: T }], T - 1, 30000), 1);
        compare(RecLogic.startsWithin([{ nextRun: T }], T - 30000, 30000), 30000);
        // The nearest of several, wherever it stands in the list.
        compare(RecLogic.startsWithin([{ nextRun: T + 9000 }, { nextRun: T + 4000 }, { nextRun: T + 25000 }], T, 30000), 4000);
        // A fraction of a ms is not waited for twice.
        compare(RecLogic.startsWithin([{ nextRun: T + 0.4 }], T, 30000), 1);
        compare(RecLogic.startsWithin([{ nextRun: T + 1500.7 }], T, 30000), 1501);
    }

    function test_a_start_that_is_due_or_far_off_is_left_to_the_regular_look() {
        var T = 1794400200000;
        // Due now, or overdue: the look that is running deals with it, and a
        // wait of nothing would only call the look again and again.
        compare(RecLogic.startsWithin([{ nextRun: T }], T, 30000), -1);
        compare(RecLogic.startsWithin([{ nextRun: T }], T + 5000, 30000), -1);
        // Further off than the period: a later look finds it.
        compare(RecLogic.startsWithin([{ nextRun: T }], T - 30001, 30000), -1);
        compare(RecLogic.startsWithin([{ nextRun: T }], T - 86400000, 30000), -1);
        // An overdue entry does not hide one that is coming.
        compare(RecLogic.startsWithin([{ nextRun: T - 60000 }, { nextRun: T + 7000 }], T, 30000), 7000);
        compare(RecLogic.startsWithin([], T, 30000), -1);
    }

    function test_what_is_no_schedule_no_clock_or_no_period_waits_for_nothing() {
        var T = 1794400200000;
        var noList = [undefined, null, 7, "x", {}];
        for (var i = 0; i < noList.length; i++) compare(RecLogic.startsWithin(noList[i], T, 30000), -1);
        // Entries nobody can read are passed over, and do not hide a good one.
        var odd = [null, 7, "x", {}, { nextRun: "soon" }, { nextRun: NaN }, { nextRun: Infinity }, { nextRun: -5 }, { nextRun: T + 3000 }];
        compare(RecLogic.startsWithin(odd, T, 30000), 3000);
        compare(RecLogic.startsWithin(odd.slice(0, 8), T, 30000), -1);
        // A start written as text is not a start, though it would count as one.
        compare(RecLogic.startsWithin([{ nextRun: String(T + 3000) }], T, 30000), -1);
        // No clock, no period.
        compare(RecLogic.startsWithin([{ nextRun: T + 3000 }], NaN, 30000), -1);
        compare(RecLogic.startsWithin([{ nextRun: T + 3000 }], undefined, 30000), -1);
        compare(RecLogic.startsWithin([{ nextRun: T + 3000 }], T, 0), -1);
        compare(RecLogic.startsWithin([{ nextRun: T + 3000 }], T, -30000), -1);
        compare(RecLogic.startsWithin([{ nextRun: T + 3000 }], T, NaN), -1);
        compare(RecLogic.startsWithin([{ nextRun: T + 3000 }], T, "30000"), -1);
        // A list as long as a list may get.
        var many = [];
        for (var k = 0; k < 5000; k++) many.push({ nextRun: T + 86400000 + k });
        many.push({ nextRun: T + 12 });
        compare(RecLogic.startsWithin(many, T, 30000), 12);
    }
}
