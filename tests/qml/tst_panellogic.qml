// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The now-playing text beside the panel icon (GitHub #14). The setting is off
// unless a listener turns it on, so the first thing held here is that an
// untouched widget asks the panel for exactly what it asked before.
import QtQuick
import QtQuick.Layouts
import QtTest

import "../../package/contents/ui/PanelLogic.js" as PL

Item {
    id: harness
    width: 64
    height: 64

    // An item that sets no width hints at all, to read what "nothing asked"
    // is on this Qt instead of trusting a remembered default.
    Item { id: bare }

    TestCase {
        name: "PanelLogic"

        // --- which lines ---------------------------------------------------

        function test_artist_goes_over_title() {
            var l = PL.lines("Florence + The Machine", "Dog Days Are Over", "Raadio 2");
            compare(l.top, "Florence + The Machine");
            compare(l.bottom, "Dog Days Are Over");
        }

        function test_a_title_alone_sits_over_the_station() {
            var l = PL.lines("", "News at Nine", "Vikerraadio");
            compare(l.top, "News at Nine");
            compare(l.bottom, "Vikerraadio");
        }

        function test_a_silent_stream_names_the_station_alone() {
            var l = PL.lines("", "", "Klassikaraadio");
            compare(l.top, "Klassikaraadio");
            compare(l.bottom, "");
        }

        function test_an_artist_without_a_title_stands_alone() {
            var l = PL.lines("Arvo Pärt", "", "Klassikaraadio");
            compare(l.top, "Arvo Pärt");
            compare(l.bottom, "");
        }

        function test_a_station_that_sends_its_own_name_is_not_written_twice() {
            // Some streams put the station's name in the title field between
            // songs. Two identical lines say nothing the first did not.
            var l = PL.lines("", "retro fm", "Retro FM");
            compare(l.top, "retro fm");
            compare(l.bottom, "");
        }

        function test_nothing_known_gives_nothing() {
            var l = PL.lines("", "", "");
            compare(l.top, "");
            compare(l.bottom, "");
        }

        function test_blank_and_missing_fields_count_as_empty() {
            // A property that is still undefined while the widget loads, and
            // a title of spaces, must not become a line.
            var l = PL.lines(undefined, "   ", null);
            compare(l.top, "");
            compare(l.bottom, "");
            l = PL.lines(42, { "x": 1 }, "Raadio 2");
            compare(l.top, "Raadio 2");
            compare(l.bottom, "");
        }

        function test_one_line_joins_artist_and_title() {
            compare(PL.single("Röyksopp", "Eple", "Raadio 2"), "Röyksopp – Eple");
        }

        function test_one_line_does_not_drag_the_station_along() {
            // On one line there is room for the song or the station, and the
            // tooltip already names the station.
            compare(PL.single("", "News at Nine", "Vikerraadio"), "News at Nine");
            compare(PL.single("", "", "Vikerraadio"), "Vikerraadio");
            compare(PL.single("Arvo Pärt", "", "Klassikaraadio"), "Arvo Pärt");
            compare(PL.single(undefined, null, undefined), "");
        }

        // --- whether to show ------------------------------------------------

        function test_the_text_needs_all_four() {
            verify(PL.shown(true, true, true, "Röyksopp"));
            verify(!PL.shown(false, true, true, "Röyksopp"));   // the setting
            verify(!PL.shown(true, false, true, "Röyksopp"));   // a vertical panel
            verify(!PL.shown(true, true, false, "Röyksopp"));   // nothing held
            verify(!PL.shown(true, true, true, ""));            // nothing to say
            verify(!PL.shown(true, true, true, "   "));
        }

        function test_only_a_real_true_turns_it_on() {
            // An undefined property during load must not put text on a panel.
            verify(!PL.shown(undefined, true, true, "x"));
            verify(!PL.shown("true", true, true, "x"));
            verify(!PL.shown(true, 1, true, "x"));
            verify(!PL.shown(true, true, undefined, "x"));
            verify(!PL.shown(true, true, true, undefined));
        }

        // --- one line or two ------------------------------------------------

        function test_two_lines_need_room_for_two() {
            verify(PL.stacked(30, 15, "Eple"));     // exactly two lines high
            verify(PL.stacked(44, 15, "Eple"));
            verify(!PL.stacked(29, 15, "Eple"));    // one pixel short
            verify(!PL.stacked(24, 15, "Eple"));
        }

        function test_one_thing_to_say_is_one_line() {
            verify(!PL.stacked(44, 15, ""));
            verify(!PL.stacked(44, 15, "  "));
            verify(!PL.stacked(44, 15, undefined));
        }

        function test_a_height_that_is_not_known_yet_is_one_line() {
            // The item is 0 high before the panel lays it out, and a font
            // metric can be 0 for a frame; neither is room for two lines.
            verify(!PL.stacked(0, 15, "Eple"));
            verify(!PL.stacked(44, 0, "Eple"));
            verify(!PL.stacked(-1, 15, "Eple"));
            verify(!PL.stacked(undefined, 15, "Eple"));
            verify(!PL.stacked(44, NaN, "Eple"));
        }

        // --- how wide -------------------------------------------------------

        function test_short_text_takes_only_its_own_width() {
            compare(PL.textWidth(10, 18, 61.2), 62);    // rounded up, no cut glyph
        }

        function test_long_text_stops_at_the_cap() {
            compare(PL.textWidth(10, 18, 900), 180);
            compare(PL.textWidth(4, 18, 73), 72);
            compare(PL.textWidth(10, 18, 180), 180);    // exactly the cap
        }

        function test_no_text_or_no_cap_is_no_width() {
            compare(PL.textWidth(10, 18, 0), 0);
            compare(PL.textWidth(10, 18, -5), 0);
            compare(PL.textWidth(10, 18, undefined), 0);
            compare(PL.textWidth(0, 18, 80), 0);
            compare(PL.textWidth(undefined, 18, 80), 0);
            compare(PL.textWidth(10, NaN, 80), 0);
        }

        // --- what the panel is asked for ------------------------------------

        function test_showing_nothing_asks_for_what_a_bare_item_asks() {
            var h = PL.widthHints(false, 36, 4, 120);
            compare(h.min, bare.Layout.minimumWidth);
            compare(h.pref, bare.Layout.preferredWidth);
            compare(h.max, bare.Layout.maximumWidth);
        }

        function test_showing_text_fixes_the_width_to_icon_gap_and_text() {
            var h = PL.widthHints(true, 36, 4, 120);
            compare(h.min, 160);
            compare(h.pref, 160);
            compare(h.max, 160);
        }

        function test_a_width_that_cannot_be_computed_asks_for_nothing() {
            // Better the plain icon than a widget pinned to NaN pixels.
            var asked = PL.widthHints(false, 36, 4, 120);
            var h = PL.widthHints(true, undefined, 4, 120);
            compare(h.min, asked.min);
            compare(h.pref, asked.pref);
            compare(h.max, asked.max);
            h = PL.widthHints(true, 0, 4, 120);
            compare(h.pref, asked.pref);
            h = PL.widthHints("yes", 36, 4, 120);
            compare(h.pref, asked.pref);
        }
    }
}
