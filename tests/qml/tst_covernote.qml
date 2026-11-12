// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The line that says what a picture is when it is not the cover of the song
// on air. It has to be readable on any picture and to stay inside the
// smallest cover the Playing page draws, in a language longer than English.
import QtQuick
import QtTest
import org.kde.kirigami as Kirigami

import "../../package/contents/ui"
import "../../package/contents/ui/ColorLogic.js" as ColorLogic

Item {
    id: root
    width: 420
    height: 420

    // The smallest cover the Playing page draws is seven grid units a side,
    // and its level bars keep the lower right corner.
    readonly property real smallest: Kirigami.Units.gridUnit * 7
    readonly property real bars: 25 + Kirigami.Units.smallSpacing * 3

    Rectangle {
        id: cover
        width: root.smallest
        height: root.smallest
        color: "white"

        CoverNote {
            id: note
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Kirigami.Units.smallSpacing * 1.5
            room: cover.width - Kirigami.Units.smallSpacing * 3 - root.bars
        }
    }

    TestCase {
        name: "CoverNote"
        when: windowShown

        function init() {
            cover.width = root.smallest;
            note.text = "";
        }

        function _inside() {
            verify(note.x >= 0 && note.y >= 0, "starts outside the cover");
            verify(note.x + note.width <= cover.width - root.bars + 0.5,
                   "reaches into the corner the bars keep: " + (note.x + note.width) + " of " + cover.width);
            verify(note.y + note.height <= cover.height + 0.5, "hangs below the cover");
            verify(note._label.width <= note.width, "the words are wider than their ground");
            verify(note._label.height <= note.height, "the words are taller than their ground");
        }

        function test_nothing_to_say_draws_nothing() {
            verify(!note.visible);
            note.text = "Artist picture";
            verify(note.visible);
            note.text = "";
            verify(!note.visible);
        }

        // The two lines the widget has, on the smallest cover: whole, on at
        // most three lines, inside the cover and clear of the bars' corner.
        function test_both_lines_fit_the_smallest_cover_whole_data() {
            return [{ tag: "Artist picture" }, { tag: "From another release" }];
        }
        function test_both_lines_fit_the_smallest_cover_whole(data) {
            note.text = data.tag;
            verify(note.visible);
            verify(!note._label.truncated, "cut short on the smallest cover");
            verify(note._label.lineCount <= 3);
            verify(note.height <= cover.height * 0.4, "covers too much of the smallest cover: " + note.height);
            _inside();
            // On a cover with room it is one line and no wider than its words.
            cover.width = Kirigami.Units.gridUnit * 18;
            compare(note._label.lineCount, 1);
            verify(note.width < cover.width / 2, "a short line stretched over the cover: " + note.width);
            _inside();
        }

        // A translation three times as long, with a word no line can hold:
        // three lines, the rest cut with an ellipsis, and still inside.
        function test_a_long_translation_is_cut_and_stays_inside() {
            note.text = "Aus einer anderen Veröffentlichung desselben Interpreten und Donaudampfschifffahrtsgesellschaft";
            verify(note.visible);
            compare(note._label.lineCount, 3);
            verify(note._label.truncated);
            _inside();
            // One word wider than the cover is broken, not left hanging out.
            note.text = "Donaudampfschifffahrtsgesellschaftskapitänsmütze";
            verify(note._label.lineCount >= 2, "the word was cut where a line ended instead of going on below");
            verify(note._label.lineCount <= 3);
            _inside();
            var lots = "";
            for (var i = 0; i < 2000; i++) lots += "word ";
            note.text = lots;
            compare(note._label.lineCount, 3);
            _inside();
        }

        // Light letters on a dark ground of their own, whatever is under it.
        // The worst picture is a white one: the ground lets some of it through.
        function test_the_words_read_on_any_picture() {
            note.text = "Artist picture";
            var ground = note.color, ink = note._label.color;
            verify(ground.a < 1, "the ground is solid: the test below measures a see-through one");
            var solid = function(c) { return ColorLogic.hex({ r: c.r, g: c.g, b: c.b }); };
            var pictures = ["#ffffff", "#000000", "#ff0000", "#00ff00", "#0000ff", "#ffff00", "#808080", "#3bee96"];
            for (var i = 0; i < pictures.length; i++) {
                var under = ColorLogic.washed(pictures[i], solid(ground), ground.a);
                var c = ColorLogic.contrast(solid(ink), under);
                verify(c >= 7, "on " + pictures[i] + " the words read " + c.toFixed(2) + " to 1");
            }
            compare(note._label.textFormat, Text.PlainText);
        }

        function test_a_screen_reader_is_told_the_same_words() {
            note.text = "From another release";
            compare(note.Accessible.role, Accessible.StaticText);
            compare(note.Accessible.name, "From another release");
        }

        // No room at all: nothing is drawn rather than a sliver.
        function test_no_room_draws_nothing() {
            note.text = "Artist picture";
            cover.width = root.bars + Kirigami.Units.smallSpacing * 3;
            verify(!note.visible);
            cover.width = 0;
            verify(!note.visible);
        }
    }
}
