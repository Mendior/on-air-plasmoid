// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The Automation settings page's Auto-care box, on the page itself. With
// "Set the delay by ear" switched on in the output menu the engine runs no
// automatic check at all (SyncEngine asks syncManualOnly first), and the
// menu does not even offer the box. The settings page still did: it could
// be ticked there and nothing happened. The page reads the menu's switch
// live, because the menu can flip it while the dialog is open, and it must
// leave the stored choice alone: the box is a view of cfg_syncAutoCare,
// which the dialog writes back on Apply.
import QtQuick
import QtTest

TestCase {
    id: tc
    name: "AutomationPage"
    when: windowShown
    width: 800
    height: 700
    visible: true

    property QtObject plasmoid: QtObject {
        property QtObject configuration: QtObject {
            property bool syncAutoCare: false
            // var: an old config may not have the key at all.
            property var syncManualOnly: false
        }
    }
    function i18n(s) {
        var out = s
        for (var i = 1; i < arguments.length; i++) out = out.replace("%" + i, arguments[i])
        return out
    }

    readonly property string byEar: "Set the delay by ear (no microphone)"

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

    // The dialog's side: the stored value handed in as cfg_, as on load.
    function open(stored, manual) {
        plasmoid.configuration.syncAutoCare = stored
        plasmoid.configuration.syncManualOnly = manual
        var c = Qt.createComponent(Qt.resolvedUrl("../../package/contents/ui/config/configAutomation.qml"))
        compare(c.status, Component.Ready, c.errorString())
        page = c.createObject(tc, { cfg_syncAutoCare: stored, width: 700, height: 650 })
        verify(page !== null)
        box = find(page, function(it) {
            return it.hasOwnProperty("checkState") && it.text === "Keep sync tuned automatically"
        })
        verify(box !== null, "the Auto-care box was not found on the page")
    }
    function reason() {
        return find(page, function(it) {
            return it.hasOwnProperty("wrapMode") && it.text === tc.byEar && it.visible
        })
    }
    // What the dialog does on Apply: every cfg_ key back into the store.
    function apply() { plasmoid.configuration.syncAutoCare = page.cfg_syncAutoCare }

    function cleanup() {
        if (page) page.destroy()
        page = null
        box = null
    }

    function test_without_tuning_by_ear_the_box_is_a_box() {
        open(false, false)
        verify(box.enabled)
        verify(reason() === null)
        compare(box.Accessible.description, "")
        mouseClick(box)
        compare(page.cfg_syncAutoCare, true)
        box.forceActiveFocus()
        keyClick(Qt.Key_Space)
        compare(page.cfg_syncAutoCare, false)
    }

    function test_tuning_by_ear_switches_the_box_off_and_says_why() {
        open(false, true)
        compare(box.enabled, false)
        verify(reason() !== null, "the box is greyed and nothing says why")
        compare(box.Accessible.description, byEar)
        // Neither the pointer nor the keyboard ticks it.
        mouseClick(box)
        box.forceActiveFocus()
        keyClick(Qt.Key_Space)
        compare(page.cfg_syncAutoCare, false)
        compare(box.checked, false)
    }

    function test_a_choice_made_before_is_shown_and_kept() {
        // Stored as on while the delay is set by ear: ticked on this page in
        // an older version, where nothing stopped it.
        open(true, true)
        compare(box.enabled, false)
        compare(box.checked, true)
        compare(page.cfg_syncAutoCare, true)
        apply()
        compare(plasmoid.configuration.syncAutoCare, true, "Apply wrote the choice away")
        // By ear switched off again in the menu: the box is back as it was left.
        plasmoid.configuration.syncManualOnly = false
        compare(box.enabled, true)
        compare(box.checked, true)
        verify(reason() === null)
    }

    function test_by_ear_switched_on_and_off_in_the_menu_changes_nothing_stored_data() {
        return [
            { tag: "ticked before", stored: true },
            { tag: "not ticked before", stored: false },
        ]
    }
    function test_by_ear_switched_on_and_off_in_the_menu_changes_nothing_stored(data) {
        open(data.stored, false)
        for (var i = 0; i < 6; i++) {
            plasmoid.configuration.syncManualOnly = (i % 2 === 0)
            compare(box.enabled, i % 2 !== 0)
            compare(reason() !== null, i % 2 === 0)
            compare(box.checked, data.stored)
            compare(page.cfg_syncAutoCare, data.stored)
            apply()
            compare(plasmoid.configuration.syncAutoCare, data.stored)
        }
    }

    function test_an_edit_made_before_by_ear_came_on_is_kept_for_apply() {
        open(false, false)
        mouseClick(box)
        compare(page.cfg_syncAutoCare, true)
        plasmoid.configuration.syncManualOnly = true
        compare(box.enabled, false)
        compare(page.cfg_syncAutoCare, true, "the edit was dropped when the box was greyed")
        plasmoid.configuration.syncManualOnly = false
        compare(box.checked, true)
    }

    function test_defaults_reach_the_box_while_it_is_greyed() {
        // The dialog's Defaults button sets every cfg_ key, greyed or not.
        open(true, true)
        page.cfg_syncAutoCare = false
        compare(box.checked, false)
        compare(box.enabled, false)
        verify(reason() !== null)
        page.cfg_syncAutoCare = true
        compare(box.checked, true)
    }

    function test_the_menus_own_write_is_followed_while_the_box_is_greyed() {
        // The menu's by-ear switch also sets syncAutoCare to off, live. An
        // untouched box follows the live value, as it did before.
        open(true, false)
        plasmoid.configuration.syncManualOnly = true
        plasmoid.configuration.syncAutoCare = false
        compare(box.enabled, false)
        compare(page.cfg_syncAutoCare, false)
        compare(box.checked, false)
    }

    function test_cancel_writes_nothing() {
        open(true, true)
        plasmoid.configuration.syncManualOnly = false
        mouseClick(box)
        compare(page.cfg_syncAutoCare, false)
        // Cancel: the page goes and nobody calls apply().
        page.destroy()
        page = null
        compare(plasmoid.configuration.syncAutoCare, true)
        compare(plasmoid.configuration.syncManualOnly, false)
    }

    function test_only_a_plain_yes_is_tuning_by_ear() {
        // The engine asks syncManualOnly === true; anything else runs the checks.
        var odd = [undefined, null, 0, 1, "true", "", "false"]
        for (var i = 0; i < odd.length; i++) {
            open(false, odd[i])
            compare(box.enabled, true, String(odd[i]))
            verify(reason() === null, String(odd[i]))
            cleanup()
        }
    }

    function test_the_other_boxes_on_the_page_stay_as_they_are() {
        open(false, true)
        var retry = find(page, function(it) {
            return it.hasOwnProperty("checkState") && it.text === "Try to get it back"
        })
        var timeshift = find(page, function(it) {
            return it.hasOwnProperty("checkState") && it.text === "Pause live radio"
        })
        verify(retry !== null && timeshift !== null)
        verify(retry.enabled)
        verify(timeshift.enabled)
    }
}
