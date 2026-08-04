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
        var long = RecLogic.sanitizeStationName(new Array(30).join("abc "))
        verify(long.length <= 60)
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

    function test_only_plain_http_streams_are_recordable() {
        verify(RecLogic.canRecordUrl("http://s1.radio.ee/live.mp3"))
        verify(RecLogic.canRecordUrl("https://s1.radio.ee/live"))
        verify(!RecLogic.canRecordUrl("http://s1.radio.ee/live.m3u8"))
        verify(!RecLogic.canRecordUrl("http://s1.radio.ee/list.pls"))
        verify(!RecLogic.canRecordUrl("file:///home/egon/song.mp3"))
        verify(!RecLogic.canRecordUrl(""))
    }
}
