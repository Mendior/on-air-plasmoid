// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The Appearance page's Accent list, on the page itself. A config can hold
// two keys for one answer: accentMode, and followSystemAccent from before
// the list existed. The player read both, the list showed accentMode alone:
// with accentMode 0 and the old key on, the widget wore the system accent
// under a list that said "On Air green", next to a ticked "Follow the
// system accent" box. Both controls show ColorLogic.accentMode of the two
// keys now, the reading the player uses, and a choice in either writes both.
import QtQuick
import QtTest

import "../../package/contents/ui/ColorLogic.js" as ColorLogic

TestCase {
    id: tc
    name: "AppearancePage"
    when: windowShown
    width: 900
    height: 900
    visible: true

    property QtObject plasmoid: QtObject {
        property int formFactor: 0
        property QtObject configuration: QtObject {
            property real defaultVolume: 0.5
        }
    }
    function i18n(s) {
        var out = s
        for (var i = 1; i < arguments.length; i++) out = out.replace("%" + i, arguments[i])
        return out
    }
    function i18nc(c, s) { return s }
    function i18np(one, many, n) { return (n === 1 ? one : many).replace("%1", n) }

    function find(item, wanted) {
        if (wanted(item)) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var hit = find(kids[i], wanted)
            if (hit) return hit
        }
        return null
    }

    property var page: null
    property var list: null
    property var oldBox: null
    // The stored pair, as the dialog reads it on load and writes it on Apply.
    property var stored: ({})
    property int edits: 0

    function open(pair) {
        stored = pair
        var c = Qt.createComponent(Qt.resolvedUrl("../../package/contents/ui/config/configAppearance.qml"))
        compare(c.status, Component.Ready, c.errorString())
        // Only the keys the config holds are handed over; a missing one
        // leaves the page's own default.
        var given = { width: 800, height: 850 }
        if (pair.mode !== undefined) given.cfg_accentMode = pair.mode
        if (pair.follow !== undefined) given.cfg_followSystemAccent = pair.follow
        page = c.createObject(tc, given)
        verify(page !== null)
        list = find(page, function(it) {
            return it.hasOwnProperty("currentIndex") && it.hasOwnProperty("displayText")
                   && it.model && it.model.length === 3 && it.model[0] === "On Air green"
        })
        verify(list !== null, "the Accent list was not found on the page")
        oldBox = find(page, function(it) {
            return it.hasOwnProperty("checkState")
                   && it.text === "Follow the system accent color instead of the built-in emerald"
        })
        verify(oldBox !== null, "the old accent box was not found on the page")
        edits = 0
        page.cfg_accentModeChanged.connect(function() { tc.edits++ })
        page.cfg_followSystemAccentChanged.connect(function() { tc.edits++ })
    }
    function apply() {
        stored = { mode: page.cfg_accentMode, follow: page.cfg_followSystemAccent }
    }
    function reopen() {
        apply()
        var pair = stored
        cleanup()
        open(pair)
    }
    // What the player wears for the stored pair: main.qml asks the same function.
    function worn() { return ColorLogic.accentMode(stored.mode, stored.follow) }
    // A choice the way a listener makes it: the list has the focus and the
    // arrows move it, each step a choice of its own.
    function choose(index) {
        list.forceActiveFocus()
        for (var i = 0; i < 4 && list.currentIndex !== index; i++)
            keyClick(list.currentIndex < index ? Qt.Key_Down : Qt.Key_Up)
        compare(list.currentIndex, index)
    }

    // The box is far down the page, so it is pressed with the keyboard.
    function press(box) {
        box.forceActiveFocus()
        keyClick(Qt.Key_Space)
    }

    function cleanup() {
        if (page) page.destroy()
        page = null
        list = null
        oldBox = null
    }

    function test_the_list_shows_what_the_player_wears_data() {
        return [
            { tag: "green", mode: 0, follow: false, want: 0 },
            { tag: "an old config: green with the old key on", mode: 0, follow: true, want: 1 },
            { tag: "system accent", mode: 1, follow: true, want: 1 },
            { tag: "system accent, the old key off", mode: 1, follow: false, want: 1 },
            { tag: "plain", mode: 2, follow: false, want: 2 },
            { tag: "plain over an old yes", mode: 2, follow: true, want: 2 },
            { tag: "no mode key, old yes", mode: undefined, follow: true, want: 1 },
            { tag: "no mode key, old no", mode: undefined, follow: false, want: 0 },
            { tag: "neither key", mode: undefined, follow: undefined, want: 0 },
            { tag: "a mode from a newer version", mode: 3, follow: false, want: 0 },
            { tag: "a mode from a newer version over an old yes", mode: 3, follow: true, want: 1 },
        ]
    }
    function test_the_list_shows_what_the_player_wears(data) {
        open({ mode: data.mode, follow: data.follow })
        compare(list.currentIndex, data.want)
        compare(oldBox.checked, data.want === 1, "the old box and the list say two things")
        compare(edits, 0, "opening the page counted as an edit")
    }

    function test_looking_at_an_old_config_does_not_rewrite_it() {
        open({ mode: 0, follow: true })
        compare(list.currentIndex, 1)
        apply()
        compare(JSON.stringify(stored), JSON.stringify({ mode: 0, follow: true }))
        compare(worn(), 1)
        // Nor a newer version's mode this one cannot name.
        cleanup()
        open({ mode: 3, follow: false })
        apply()
        compare(stored.mode, 3)
    }

    function test_green_chosen_over_an_old_config_is_green() {
        open({ mode: 0, follow: true })
        choose(0)
        compare(page.cfg_accentMode, 0)
        compare(page.cfg_followSystemAccent, false, "the old key still says system accent")
        compare(oldBox.checked, false)
        apply()
        compare(worn(), 0)
        reopen()
        compare(list.currentIndex, 0)
    }

    function test_every_choice_takes_in_both_directions() {
        open({ mode: 0, follow: true })
        var walk = [0, 1, 2, 1, 0, 2, 0]
        for (var i = 0; i < walk.length; i++) {
            choose(walk[i])
            compare(page.cfg_accentMode, walk[i])
            compare(page.cfg_followSystemAccent, walk[i] === 1)
            compare(oldBox.checked, walk[i] === 1)
            apply()
            compare(worn(), walk[i], "the player does not wear what was chosen")
        }
        reopen()
        compare(list.currentIndex, 0)
        compare(oldBox.checked, false)
    }

    function test_the_old_box_and_the_list_move_together() {
        open({ mode: 2, follow: false })
        press(oldBox)
        compare(page.cfg_accentMode, 1)
        compare(page.cfg_followSystemAccent, true)
        compare(list.currentIndex, 1)
        press(oldBox)
        compare(page.cfg_accentMode, 0)
        compare(page.cfg_followSystemAccent, false)
        compare(list.currentIndex, 0)
        compare(oldBox.checked, false)
        // And after the list was used, the box still follows it and it the box.
        choose(2)
        compare(oldBox.checked, false)
        choose(1)
        compare(oldBox.checked, true)
        press(oldBox)
        compare(list.currentIndex, 0)
        apply()
        compare(worn(), 0)
    }

    function test_defaults_reach_the_list_after_a_choice() {
        // The dialog's Defaults sets the cfg_ keys; a list that kept the
        // number it was last given would go on showing the old choice.
        open({ mode: 1, follow: true })
        choose(2)
        page.cfg_accentMode = 0
        page.cfg_followSystemAccent = false
        compare(list.currentIndex, 0)
        compare(oldBox.checked, false)
        press(oldBox)
        page.cfg_accentMode = 0
        page.cfg_followSystemAccent = false
        compare(oldBox.checked, false)
        compare(list.currentIndex, 0)
    }

    function test_choosing_what_is_already_shown_settles_an_old_config() {
        // An old config shows "System accent colour"; picked again there, it
        // is written the way this version writes it.
        open({ mode: 0, follow: true })
        choose(2)
        choose(1)
        apply()
        compare(JSON.stringify(stored), JSON.stringify({ mode: 1, follow: true }))
        compare(worn(), 1)
    }

    function test_cancel_leaves_the_stored_pair_alone() {
        open({ mode: 0, follow: true })
        choose(2)
        // Cancel: the page goes and nobody applies.
        cleanup()
        compare(JSON.stringify(stored), JSON.stringify({ mode: 0, follow: true }))
        compare(worn(), 1)
    }
}
