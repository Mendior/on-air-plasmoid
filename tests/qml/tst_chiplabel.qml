// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The search chips are Plasma tool buttons, and a button reads "&" as the
// mark of its keyboard shortcut. Measured on PlasmaComponents3.ToolButton:
// the text "r&b" is drawn as "rb", "rock&roll&soul" as "rockrollsoul",
// while "drum & bass" stays whole because the button doubles an "&" before
// a space itself. This gives the real button a chip the way the popup's
// genre and history chips are wired and reads back what it draws.
import QtQuick
import QtTest
import org.kde.plasma.components as PlasmaComponents3

import "../../package/contents/ui/ViewLogic.js" as ViewLogic

Item {
    id: page
    width: 400
    height: 200

    property string modelData: ""
    property string searched: ""

    PlasmaComponents3.ToolButton {
        id: chip
        text: ViewLogic.chipLabel(page.modelData)
        Accessible.name: page.modelData
        onClicked: page.searched = page.modelData
    }

    // The text items inside the button: what is on screen.
    function drawn(item) {
        for (var i = 0; i < item.children.length; i++) {
            var c = item.children[i]
            if (c.hasOwnProperty("textFormat") && c.hasOwnProperty("text") && c.text !== "") return c.text
            var deeper = drawn(c)
            if (deeper !== "") return deeper
        }
        return ""
    }

    TestCase {
        name: "ChipLabel"
        when: windowShown

        function test_the_chip_shows_what_was_typed_data() {
            return [
                { tag: "r&b", raw: "r&b" },
                { tag: "drum & bass", raw: "drum & bass" },
                { tag: "at&t", raw: "at&t" },
                { tag: "rock&roll&soul", raw: "rock&roll&soul" },
                { tag: "tom&jerry & co", raw: "tom&jerry & co" },
                { tag: "a pair", raw: "&&" },
                { tag: "a pair inside", raw: "r&&b" },
                { tag: "a pair between spaces", raw: "a && b" },
                { tag: "one at the end", raw: "a&" },
                { tag: "one at the start", raw: "&b" },
                { tag: "one alone", raw: "&" },
                { tag: "before a letter with an accent", raw: "r&\u00e4" },
                { tag: "no ampersand", raw: "jazz" }
            ]
        }
        function test_the_chip_shows_what_was_typed(data) {
            page.modelData = data.raw
            tryCompare(chip, "text", chip.text)
            compare(drawn(chip), data.raw)
        }

        function test_the_chip_is_named_and_searched_as_typed() {
            page.modelData = "r&b"
            compare(chip.Accessible.name, "r&b")
            page.searched = ""
            mouseClick(chip)
            compare(page.searched, "r&b")
        }
    }
}
