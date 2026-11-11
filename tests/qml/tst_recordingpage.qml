// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The Recording settings page's "Max length" box, on the page itself. It
// stepped by thirty from a floor of ten, so one press down to the floor
// and the box walked 40, 70, 100 for good: the default of 180 could not be
// reached with the arrows again. It also carried a way to read a typed
// value and was never editable. The numbers it shows are grouped the way
// KDE groups them, because that is what the read-back has to survive.
import QtQuick
import QtTest

TestCase {
    id: tc
    name: "RecordingPage"
    when: windowShown
    width: 800
    height: 600
    visible: true

    // qmltestrunner has no KLocalizedContext. KDE's own writes an integer
    // grouped ("1,440 min"; measured with KI18n), and so does this.
    function i18n(s) {
        var out = s
        for (var i = 1; i < arguments.length; i++) {
            var a = arguments[i]
            if (typeof a === "number") a = Number(a).toLocaleString(Qt.locale("en_US"), "f", 0)
            out = out.replace("%" + i, a)
        }
        return out
    }

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
    property var box: null

    function open(minutes) {
        var c = Qt.createComponent(Qt.resolvedUrl("../../package/contents/ui/config/configRecording.qml"))
        compare(c.status, Component.Ready, c.errorString())
        page = c.createObject(tc, { cfg_recordMaxMinutes: minutes, cfg_recordFormat: "copy",
                                    width: 700, height: 500 })
        verify(page !== null)
        box = find(page, function(it) {
            return it.hasOwnProperty("stepSize") && it.hasOwnProperty("valueFromText")
        })
        verify(box !== null, "the Max length box was not found on the page")
    }

    function cleanup() {
        if (page) page.destroy()
        page = null
        box = null
    }

    function type(text) {
        box.contentItem.forceActiveFocus()
        box.contentItem.selectAll()
        for (var i = 0; i < text.length; i++) keyClick(text.charAt(i))
        keyClick(Qt.Key_Return)
    }

    function test_the_arrows_come_back_to_the_grid_after_the_floor() {
        open(180)
        var walk = []
        for (var d = 0; d < 7; d++) { box.decrease(); walk.push(box.value) }
        for (var u = 0; u < 8; u++) { box.increase(); walk.push(box.value) }
        compare(JSON.stringify(walk),
                JSON.stringify([150, 120, 90, 60, 30, 30, 30, 60, 90, 120, 150, 180, 210, 240, 270]))
        compare(page.cfg_recordMaxMinutes, 270)
    }

    function test_the_ceiling_is_on_the_grid_too() {
        open(1410)
        box.increase()
        compare(box.value, 1440)
        box.increase()
        compare(box.value, 1440)
        box.decrease()
        compare(box.value, 1410)
    }

    function test_a_value_left_off_the_grid_finds_it_again_at_the_floor() {
        // 70 is where the old walk left people.
        open(70)
        box.decrease()
        compare(box.value, 40)
        box.decrease()
        compare(box.value, 30)
        box.increase()
        compare(box.value, 60)
    }

    function test_the_old_floor_of_ten_opens_at_the_new_one() {
        // 10 was the floor before and nothing else below 30 could be set.
        open(10)
        compare(box.value, 30)
        compare(page.cfg_recordMaxMinutes, 30)
    }

    function test_a_typed_length_is_taken() {
        open(180)
        type("45")
        compare(page.cfg_recordMaxMinutes, 45)
        type("1200")
        compare(page.cfg_recordMaxMinutes, 1200)
    }

    function test_a_typed_length_outside_the_range_stops_at_its_edge() {
        open(180)
        type("5")
        compare(page.cfg_recordMaxMinutes, 30)
        type("99999")
        compare(page.cfg_recordMaxMinutes, 1440)
    }

    function test_looking_at_a_grouped_number_does_not_change_it() {
        open(1440)
        compare(box.displayText, "1,440 min")
        box.contentItem.forceActiveFocus()
        keyClick(Qt.Key_Tab)
        compare(page.cfg_recordMaxMinutes, 1440)
        box.contentItem.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(page.cfg_recordMaxMinutes, 1440)
    }
}
