// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The played / in-progress / unplayed state machine and its filter.
import QtQuick
import QtTest

import "../../package/contents/ui/EpisodeState.js" as ES

TestCase {
    name: "EpisodeState"

    function test_state_reads_played_over_a_leftover_position() {
        var played = { "a": 100 }
        var pos = { "a": { sec: 30, dur: 600, at: 1 }, "b": { sec: 45, dur: 600, at: 2 } }
        // "a" is played even though a stray position lingers.
        compare(ES.stateOf(played, pos, "a"), "played")
        // "b" has a position, no played mark -> in-progress.
        compare(ES.stateOf(played, pos, "b"), "in-progress")
        // "c" is unknown to both -> unplayed.
        compare(ES.stateOf(played, pos, "c"), "unplayed")
        // A zero-second position does not count as started.
        compare(ES.stateOf({}, { "d": { sec: 0, dur: 600, at: 1 } }, "d"), "unplayed")
    }

    function test_filter_hides_what_is_heard() {
        // Unplayed filter keeps fresh AND in-progress (so you can finish).
        verify(ES.matchesFilter("unplayed", 1))
        verify(ES.matchesFilter("in-progress", 1))
        verify(!ES.matchesFilter("played", 1))
        // In-progress filter is only the half-heard ones.
        verify(ES.matchesFilter("in-progress", 2))
        verify(!ES.matchesFilter("unplayed", 2))
        verify(!ES.matchesFilter("played", 2))
        // All shows everything.
        verify(ES.matchesFilter("played", 0))
        verify(ES.matchesFilter("unplayed", 0))
    }

    function test_mark_and_unmark() {
        var m = {}
        ES.markPlayed(m, "x", 500)
        compare(m.x, 500)
        compare(ES.stateOf(m, {}, "x"), "played")
        ES.markUnplayed(m, "x")
        compare(m.x, undefined)
        compare(ES.stateOf(m, {}, "x"), "unplayed")
        // An empty key is a no-op, never an "" entry.
        ES.markPlayed(m, "", 1)
        compare(m[""], undefined)
    }

    function test_prune_keeps_the_newest() {
        var m = {}
        for (var i = 0; i < 10; i++) m["k" + i] = i    // k9 newest
        var out = ES.prunePlayed(m, 3)
        compare(Object.keys(out).length, 3)
        verify(out.k9 !== undefined)
        verify(out.k7 !== undefined)
        verify(out.k0 === undefined)
        // Under the cap the map is returned untouched.
        compare(Object.keys(ES.prunePlayed(m, 50)).length, 10)
    }

    function test_near_end_detection() {
        verify(ES.isNearEnd(595, 600))    // 5 s from the end
        verify(ES.isNearEnd(600, 600))    // exactly the end
        verify(!ES.isNearEnd(300, 600))   // halfway
        verify(!ES.isNearEnd(100, 0))     // unknown duration never "near end"
    }
}
