// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The stripper every device- and feed-supplied name goes through, tested by
// CALLING it. The guard this replaces read main.qml as text and asserted the
// character class was present — measured 2026-08-09, two separate mutations
// walked past it: one renamed the function and left the class sitting there,
// one returned before the class was ever reached. Both left the grep happy.
//
// Every codepoint below is built with String.fromCharCode rather than pasted.
// A pasted bidi override is invisible in an editor, survives a copy wrong, and
// an assertion on the wrong byte passes for the wrong reason — which is the
// exact failure this file exists to stop.
import QtQuick
import QtTest

import "../../package/contents/ui/NameGuard.js" as NG

TestCase {
    name: "NameGuard"

    function ch(code) { return String.fromCharCode(code) }

    function test_an_ordinary_name_comes_back_untouched() {
        compare(NG.sanitize("Radio Tallinn"), "Radio Tallinn")
        compare(NG.sanitize("Jazz FM 100.5"), "Jazz FM 100.5")
        // Non-ASCII letters are names, not attacks.
        compare(NG.sanitize("Öö Raadio"), "Öö Raadio")
    }

    function test_markup_characters_cannot_reach_a_label() {
        // The three that turn a display string into rich text. The letters
        // between them stay — this strips the metacharacters, it does not
        // try to be an HTML parser.
        compare(NG.sanitize("<b>Kino</b> & Co"), "bKino/b  Co")
        compare(NG.sanitize("<img src=x>"), "img src=x")
    }

    function test_the_bidi_overrides_are_stripped() {
        // The group that matters most: an override makes a name display as
        // something other than what it is, which is how a crafted station
        // pretends to be another one.
        compare(NG.sanitize("Jazz" + ch(0x202e) + "FM"), "JazzFM")   // RLO
        compare(NG.sanitize("A" + ch(0x202a) + "B"), "AB")           // LRE
        compare(NG.sanitize("A" + ch(0x202d) + "B"), "AB")           // LRO
        compare(NG.sanitize("A" + ch(0x200e) + "B"), "AB")           // LRM
        compare(NG.sanitize("A" + ch(0x200f) + "B"), "AB")           // RLM
        // The isolates — the same trick in newer clothes.
        compare(NG.sanitize("A" + ch(0x2066) + "B" + ch(0x2069) + "C"), "ABC")
        compare(NG.sanitize("A" + ch(0x2068) + "B"), "AB")           // FSI
    }

    function test_control_characters_are_stripped() {
        // C0, including the ones that would split a line of shell or a label.
        compare(NG.sanitize("Bell" + ch(0x07) + "FM"), "BellFM")
        compare(NG.sanitize("A" + ch(0x09) + "B"), "AB")             // tab
        compare(NG.sanitize("A" + ch(0x0a) + "B"), "AB")             // LF
        compare(NG.sanitize("A" + ch(0x0d) + "B"), "AB")             // CR
        compare(NG.sanitize("A" + ch(0x00) + "B"), "AB")             // NUL
        // DEL and C1.
        compare(NG.sanitize("A" + ch(0x7f) + "B"), "AB")
        compare(NG.sanitize("C1" + ch(0x9b) + "FM"), "C1FM")
        compare(NG.sanitize("A" + ch(0x80) + "B"), "AB")
    }

    function test_a_very_long_name_is_cut_to_120() {
        var padded200 = new Array(201).join("x")               // 200 characters
        compare(padded200.length, 200)
        compare(NG.sanitize(padded200).length, 120)
        // The cut happens AFTER stripping, so a name padded with invisible
        // characters cannot smuggle its visible part past the limit.
        var padded = new Array(51).join(ch(0x202e)) + new Array(101).join("y")
        compare(NG.sanitize(padded), new Array(101).join("y"))
    }

    function test_nothing_in_reads_as_empty_out() {
        compare(NG.sanitize(""), "")
        compare(NG.sanitize(null), "")
        compare(NG.sanitize(undefined), "")
    }

    function test_the_boundary_this_does_not_cover() {
        // U+2028 LINE SEPARATOR is NOT in the class (measured 2026-08-09).
        // Written down as a test rather than a comment so that adding it
        // later is a deliberate change with a red line to fix, instead of a
        // silent widening nobody reviews. It is a display concern, not a
        // security one — no caller splits on it.
        compare(NG.sanitize("A" + ch(0x2028) + "B"), "A" + ch(0x2028) + "B")
    }
}
