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

    // The notice text. Nothing is taken out of it, unlike above: the three
    // characters are spelled so that the notification shows them.
    function test_a_station_name_is_shown_in_a_notice_as_written() {
        compare(NG.escapeMarkup("<3 & co"), "&lt;3 &amp; co")
        compare(NG.escapeMarkup("Rock & Pop"), "Rock &amp; Pop")
        compare(NG.escapeMarkup("R&B > Soul"), "R&amp;B &gt; Soul")
        compare(NG.escapeMarkup("Radio Tallinn"), "Radio Tallinn")
        compare(NG.escapeMarkup("Öö Raadio 100.5"), "Öö Raadio 100.5")
    }

    function test_a_tag_in_a_name_cannot_open_in_a_notice() {
        compare(NG.escapeMarkup("<a href=\"http://x.example\">tap</a>"),
                "&lt;a href=\"http://x.example\"&gt;tap&lt;/a&gt;")
        compare(NG.escapeMarkup("<b>Kino</b>"), "&lt;b&gt;Kino&lt;/b&gt;")
        compare(NG.escapeMarkup("<img src=x>"), "&lt;img src=x&gt;")
        var out = NG.escapeMarkup("a<b>c&d<<>>&&")
        compare(out.indexOf("<"), -1)
        compare(out.indexOf(">"), -1)
        // Every & left is the start of one of the three spellings.
        compare(out.replace(/&(amp|lt|gt);/g, "").indexOf("&"), -1)
    }

    function test_a_text_already_spelled_out_is_spelled_again() {
        // Applied exactly once, by notify(): what arrives is what is shown.
        compare(NG.escapeMarkup("&amp;"), "&amp;amp;")
        compare(NG.escapeMarkup("&lt;3"), "&amp;lt;3")
        compare(NG.escapeMarkup(NG.escapeMarkup("<3 & co")), "&amp;lt;3 &amp;amp; co")
    }

    function test_the_three_characters_alone_and_at_the_edges() {
        compare(NG.escapeMarkup("&"), "&amp;")
        compare(NG.escapeMarkup("<"), "&lt;")
        compare(NG.escapeMarkup(">"), "&gt;")
        compare(NG.escapeMarkup("&x"), "&amp;x")
        compare(NG.escapeMarkup("x&"), "x&amp;")
        compare(NG.escapeMarkup("<>"), "&lt;&gt;")
    }

    function test_what_is_not_markup_is_left_alone() {
        compare(NG.escapeMarkup("\"quoted\" 'name'"), "\"quoted\" 'name'")
        compare(NG.escapeMarkup("two\nlines"), "two\nlines")
        compare(NG.escapeMarkup("a ; # / = b"), "a ; # / = b")
    }

    function test_no_notice_text_reads_as_empty() {
        compare(NG.escapeMarkup(""), "")
        compare(NG.escapeMarkup(null), "")
        compare(NG.escapeMarkup(undefined), "")
    }

    function test_a_text_that_is_not_a_string_is_shown_as_it_prints() {
        compare(NG.escapeMarkup(5), "5")
        compare(NG.escapeMarkup(0), "0")
        compare(NG.escapeMarkup(false), "false")
    }

    function test_a_very_long_notice_text_is_escaped_whole() {
        var raw = new Array(4001).join("<&>")              // 12000 characters
        var out = NG.escapeMarkup(raw)
        compare(out.length, 4000 * 13)
        compare(out.substring(0, 13), "&lt;&amp;&gt;")
        compare(out.indexOf("<"), -1)
    }
}
