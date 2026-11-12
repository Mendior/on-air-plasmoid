// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// One living face and two seats. The window builds the face once, and it and
// the popup's seat take it in turn; a second face, or a face rebuilt on the
// way, was measured to lose the list position, close an open menu and ask
// the network everything again.
import QtQuick
import QtQuick.Layouts
import QtTest
import org.kde.kirigami as Kirigami

import "../../package/contents/ui" as Ui

Item {
    id: shell
    width: 400
    height: 600

    // The components' labels call i18n(); qmltestrunner has no KLocalizedContext.
    function i18n(s) { return s }

    property int born: 0
    property int died: 0

    Component {
        id: faceMaker
        FocusScope {
            property var keys: []
            anchors.fill: parent
            focus: true
            Layout.minimumWidth: 256
            Layout.minimumHeight: 320
            Layout.preferredWidth: 336
            Layout.preferredHeight: 512
            Keys.onPressed: (event) => {
                keys.push(event.key)
                if (event.key === Qt.Key_Space) event.accepted = true
            }
            Component.onCompleted: shell.born++
            Component.onDestruction: shell.died++
        }
    }

    Component {
        id: cfgMaker
        QtObject {
            property bool detached: false
            property int windowWidth: 0
            property int windowHeight: 0
            property int sizeWrites: 0
            onWindowWidthChanged: sizeWrites++
        }
    }

    // A config whose key holds something a hand edit could leave there.
    Component {
        id: oddCfgMaker
        QtObject {
            property var detached: "true"
            property var windowWidth: "wide"
            property var windowHeight: null
        }
    }

    Component {
        id: windowMaker
        Ui.PlayerWindow { }
    }

    Component {
        id: popupMaker
        Ui.PopupFace { anchors.fill: parent }
    }

    SignalSpy {
        id: shownSpy
        signalName: "faceShownChanged"
    }

    SignalSpy {
        id: arrivedSpy
        signalName: "arrived"
    }

    TestCase {
        name: "PlayerWindow"
        when: windowShown

        function init() {
            failOnWarning(/.?/)
            shell.born = 0
            shell.died = 0
        }

        // The house as main.qml builds it, and Plasma's popup beside it.
        function house(props) {
            var cfg = createTemporaryObject(cfgMaker, shell)
            var win = createTemporaryObject(windowMaker, shell, Object.assign({ face: faceMaker, cfg: cfg }, props || {}))
            return win
        }
        function popupFor(win) {
            return createTemporaryObject(popupMaker, shell, { house: win })
        }

        // The placeholder's button, found by the action it carries.
        function buttonOf(item, action) {
            if (item.action === action) return item
            for (var i = 0; i < item.children.length; i++) {
                var hit = buttonOf(item.children[i], action)
                if (hit) return hit
            }
            return null
        }

        function holders(win, popup) {
            var n = 0
            if (win.faceItem.parent === win.windowSeat) n++
            if (win.faceItem.parent === popup.seat) n++
            return n
        }

        function test_no_face_is_built_before_a_seat_asks_for_one() {
            var win = house()
            compare(win.faceItem, null)
            compare(shell.born, 0)
            compare(win.visible, false)
        }

        function test_the_popup_asks_and_gets_the_face_in_its_own_seat() {
            var win = house()
            var popup = popupFor(win)
            compare(shell.born, 1)
            compare(popup.face, win.faceItem)
            compare(win.faceItem.parent, popup.seat)
            compare(win.faceItem.width, 400)
            compare(popup.Layout.minimumWidth, 256)
            compare(popup.away, false)
            compare(win.seat, "popup")
            compare(win.visible, false)
        }

        function test_sent_to_the_window_the_same_face_sits_there_and_the_window_is_up() {
            var win = house()
            var popup = popupFor(win)
            var face = win.faceItem
            win.detached = true
            compare(win.seat, "window")
            compare(win.faceItem, face)
            compare(face.parent, win.windowSeat)
            compare(win.visible, true)
            compare(popup.away, true)
            compare(shell.born, 1)
            compare(shell.died, 0)
            tryCompare(face, "width", win.width)
            compare(face.height, win.height)
        }

        function test_exactly_one_seat_holds_the_face_for_either_wish() {
            var win = house()
            var popup = popupFor(win)
            compare(holders(win, popup), 1)
            win.detached = true
            compare(holders(win, popup), 1)
            win.detached = false
            compare(holders(win, popup), 1)
            compare(win.faceItem.parent, popup.seat)
            compare(win.visible, false)
        }

        function test_fast_toggling_never_builds_a_second_face_or_leaves_it_between_seats() {
            var win = house()
            var popup = popupFor(win)
            for (var i = 0; i < 200; i++) {
                win.detached = !win.detached
                compare(holders(win, popup), 1)
                compare(win.faceItem.parent, win.detached ? win.windowSeat : popup.seat)
            }
            compare(shell.born, 1)
            compare(shell.died, 0)
            compare(win.visible, false)
        }

        function test_a_window_asked_for_before_any_popup_exists_builds_the_face_itself() {
            var win = house()
            win.detached = true
            compare(shell.born, 1)
            compare(win.faceItem.parent, win.windowSeat)
            var popup = popupFor(win)
            compare(shell.born, 1)
            compare(win.faceItem.parent, win.windowSeat)
            compare(popup.away, true)
        }

        function test_a_desktop_widget_never_gets_the_window() {
            var win = house({ planar: true })
            var popup = popupFor(win)
            win.detached = true
            compare(win.seat, "popup")
            compare(win.visible, false)
            compare(win.faceItem.parent, popup.seat)
        }

        function test_the_wish_is_written_to_the_config_as_it_changes() {
            var win = house()
            popupFor(win)
            win.detached = true
            compare(win.cfg.detached, true)
            win.detached = false
            compare(win.cfg.detached, false)
        }

        // Under KWin a Window declared inside an item is that item's window's
        // child: it would stay above the panel and go down with it.
        function test_the_window_is_nobodys_child_and_carries_the_players_name() {
            var win = house()
            compare(win.transientParent, null)
            compare(win.title, "On Air")
        }

        // Plasma paints the popup's background; a bare window is white, and
        // on a dark scheme that was white text on white.
        function test_the_window_paints_the_schemes_window_colour_behind_the_face() {
            var win = house()
            popupFor(win)
            win.detached = true
            tryCompare(win.backdrop, "width", win.width)
            compare(win.backdrop.height, win.height)
            compare(win.contentItem.children[0], win.backdrop)
            compare(win.contentItem.children[1], win.windowSeat)
            compare(win.backdrop.Kirigami.Theme.colorSet, Kirigami.Theme.Window)
            compare(win.backdrop.Kirigami.Theme.inherit, false)
            verify(Qt.colorEqual(win.backdrop.color, win.backdrop.Kirigami.Theme.backgroundColor))
            compare(win.backdrop.color.a, 1)
        }

        // The popup opens at the size the face asks for, and so does the window.
        function test_the_window_opens_at_the_size_the_face_asks_for() {
            var win = house()
            popupFor(win)
            win.detached = true
            compare(win.width, 336)
            compare(win.height, 512)
        }

        function test_the_window_is_never_smaller_than_the_face_can_be() {
            var win = house()
            popupFor(win)
            win.detached = true
            compare(win.minimumWidth, 256)
            compare(win.minimumHeight, 320)
            // The test platform's own complaint about a floor that moves under a shown window.
            ignoreWarning(/does not support propagateSizeHints/)
            win.faceItem.Layout.minimumWidth = 300
            compare(win.minimumWidth, 300)
        }

        // After the move the keyboard was left on the window's root, and
        // Space, M and typing were dead until the face was clicked. The face
        // is put at the head of the window's focus at the move itself, before
        // the window is active, and has the keyboard as soon as it is.
        function test_the_face_has_the_keyboard_after_every_move_to_the_window() {
            var win = house()
            popupFor(win)
            for (var i = 0; i < 3; i++) {
                win.faceItem.focus = false
                win.detached = true
                compare(win.faceItem.focus, true)
                tryCompare(win, "active", true)
                compare(win.activeFocusItem, win.faceItem)
                win.detached = false
                shell.Window.window.requestActivate()
                tryCompare(shell.Window.window, "active", true)
            }
        }

        function test_a_window_that_becomes_active_hands_the_keyboard_to_the_face() {
            var win = house()
            popupFor(win)
            win.detached = true
            win.faceItem.focus = false
            verify(win.activeFocusItem !== win.faceItem)
            win.requestActivate()
            tryCompare(win, "active", true)
            shell.Window.window.requestActivate()
            tryCompare(win, "active", false)
            win.requestActivate()
            tryCompare(win, "active", true)
            compare(win.activeFocusItem, win.faceItem)
        }

        function test_the_close_button_brings_the_face_back_to_the_popup() {
            var win = house()
            var popup = popupFor(win)
            win.detached = true
            win.close()
            compare(win.detached, false)
            compare(win.visible, false)
            compare(win.faceItem.parent, popup.seat)
            compare(win.cfg.detached, false)
            compare(shell.born, 1)
            compare(shell.died, 0)
            win.detached = true
            compare(win.visible, true)
            compare(win.faceItem.parent, win.windowSeat)
        }

        // main.qml flushes the history and the podcast positions when the
        // face leaves the screen. Closing the window is that moment, once.
        function test_closing_the_window_takes_the_face_off_screen_exactly_once() {
            var win = house()
            popupFor(win)
            win.detached = true
            compare(win.faceShown, true)
            shownSpy.target = win
            shownSpy.clear()
            win.close()
            compare(win.faceShown, false)
            compare(shownSpy.count, 1)
        }

        function test_a_move_under_an_open_popup_never_reads_as_off_screen() {
            var win = house({ popupOpen: true })
            popupFor(win)
            shownSpy.target = win
            shownSpy.clear()
            win.detached = true
            win.detached = false
            win.detached = true
            win.close()
            compare(shownSpy.count, 0)
            compare(win.faceShown, true)
        }

        function test_the_face_counts_as_shown_while_the_window_is_up_with_the_popup_closed() {
            var win = house()
            popupFor(win)
            compare(win.faceShown, false)
            win.detached = true
            compare(win.faceShown, true)
            win.popupOpen = true
            compare(win.faceShown, true)
            win.popupOpen = false
            compare(win.faceShown, true)
            win.detached = false
            compare(win.faceShown, false)
        }

        function test_with_the_face_away_the_popup_says_where_it_is_and_brings_it_back() {
            var win = house({ popupOpen: true })
            var popup = popupFor(win)
            var note = findChild(popup, "awayNote")
            verify(note !== null)
            compare(note.visible, false)
            win.detached = true
            compare(note.visible, true)
            compare(note.text, "The player is open in its own window")
            var back = buttonOf(note, note.helpfulAction)
            verify(back !== null)
            compare(back.text, "Bring it back")
            mouseClick(back)
            compare(win.detached, false)
            compare(win.faceItem.parent, popup.seat)
            compare(note.visible, false)
            compare(win.visible, false)
        }

        function test_a_face_that_came_back_under_a_focused_popup_has_the_keyboard() {
            var win = house({ popupOpen: true })
            var popup = popupFor(win)
            popup.forceActiveFocus()
            win.detached = true
            shell.Window.window.requestActivate()
            tryCompare(shell.Window.window, "active", true)
            var note = findChild(popup, "awayNote")
            buttonOf(note, note.helpfulAction).forceActiveFocus()
            win.detached = false
            verify(win.faceItem.activeFocus)
            keyClick(Qt.Key_Space)
            compare(win.faceItem.keys, [Qt.Key_Space])
        }

        function test_a_house_without_a_face_to_build_opens_an_empty_window_quietly() {
            var win = createTemporaryObject(windowMaker, shell)
            compare(win.wake(), null)
            win.detached = true
            compare(win.faceItem, null)
            compare(win.visible, true)
            win.close()
            compare(win.detached, false)
        }

        function test_a_popup_seat_without_a_house_is_the_plain_seat_it_was() {
            var popup = createTemporaryObject(popupMaker, shell)
            compare(popup.away, false)
            compare(popup.face, null)
            compare(findChild(popup, "awayNote").visible, false)
        }

        // ---- the life cycle: a restart, the remembered size, the panel icon

        function started(cfgProps, props) {
            var cfg = createTemporaryObject(cfgMaker, shell, cfgProps || {})
            return createTemporaryObject(windowMaker, shell, Object.assign({ face: faceMaker, cfg: cfg }, props || {}))
        }

        // The window is plasmashell's and goes down with it. The config key
        // is what brings the face back to it after a restart or a login.
        function test_a_face_that_was_in_the_window_is_there_again_after_a_start() {
            var win = started({ detached: true })
            compare(win.detached, true)
            compare(win.seat, "window")
            compare(win.visible, true)
            compare(shell.born, 1)
            compare(win.faceItem.parent, win.windowSeat)
            var popup = popupFor(win)
            compare(shell.born, 1)
            compare(popup.away, true)
            compare(win.faceItem.parent, win.windowSeat)
        }

        // Bound to the key instead, the wish and the key wrote each other in
        // a loop. The key is the memory between sessions, not a remote control.
        function test_the_key_is_read_once_at_start_and_not_followed_after() {
            var win = started()
            popupFor(win)
            win.cfg.detached = true
            compare(win.detached, false)
            compare(win.visible, false)
            win.detached = true
            win.cfg.detached = false
            compare(win.detached, true)
            compare(win.visible, true)
        }

        function test_a_desktop_widget_opens_no_window_at_start_whatever_the_key_says() {
            var win = started({ detached: true }, { planar: true })
            compare(win.seat, "popup")
            compare(win.visible, false)
            compare(shell.born, 0)
        }

        function test_a_start_without_a_config_is_a_start_in_the_popup_data() {
            return [{ tag: "null", cfg: null }, { tag: "nothing", cfg: undefined }]
        }
        function test_a_start_without_a_config_is_a_start_in_the_popup(data) {
            var win = createTemporaryObject(windowMaker, shell, { face: faceMaker, cfg: data.cfg })
            compare(win.detached, false)
            compare(win.visible, false)
            win.detached = true
            compare(win.width, 336)
            win.width = 400
            wait(500)
            compare(win.visible, true)
        }

        function test_a_key_that_is_no_plain_true_and_a_size_that_is_no_size_are_not_believed() {
            var cfg = createTemporaryObject(oddCfgMaker, shell)
            var win = createTemporaryObject(windowMaker, shell, { face: faceMaker, cfg: cfg })
            compare(win.detached, false)
            compare(win.visible, false)
            win.detached = true
            compare(win.width, 336)
            compare(win.height, 512)
        }

        function test_a_resized_window_opens_at_that_size_the_next_time() {
            var win = started()
            popupFor(win)
            win.detached = true
            win.width = 420
            win.height = 610
            tryCompare(win.cfg, "windowWidth", 420)
            compare(win.cfg.windowHeight, 610)
            win.close()
            win.width = 300
            win.detached = true
            compare(win.width, 420)
            compare(win.height, 610)
            // The same config under a new start, as after a restart.
            var again = createTemporaryObject(windowMaker, shell, { face: faceMaker, cfg: win.cfg })
            compare(again.visible, true)
            compare(again.width, 420)
            compare(again.height, 610)
        }

        function test_a_window_made_only_taller_is_remembered_too() {
            var win = started()
            popupFor(win)
            win.detached = true
            win.height = 700
            tryCompare(win.cfg, "windowHeight", 700)
            compare(win.cfg.windowWidth, 336)
        }

        function test_a_window_that_only_opened_writes_no_size() {
            var win = started()
            popupFor(win)
            win.detached = true
            wait(500)
            compare(win.cfg.windowWidth, 0)
            compare(win.cfg.windowHeight, 0)
            compare(win.cfg.sizeWrites, 0)
        }

        // A drag is dozens of sizes a second, and each write of a config key
        // goes to disk.
        function test_a_drag_is_written_once_when_it_has_come_to_rest() {
            var win = started()
            popupFor(win)
            win.detached = true
            // The events are let through between two sizes, as between two
            // moves of a hand: asked for in one breath, the sizes are all
            // announced afterwards, each one reading as the last.
            for (var w = 340; w <= 440; w += 4) {
                win.width = w
                wait(1)
            }
            compare(win.cfg.sizeWrites, 0)
            tryCompare(win.cfg, "windowWidth", 440)
            wait(500)
            compare(win.cfg.sizeWrites, 1)
        }

        function test_a_remembered_size_stops_at_the_faces_floor_and_at_the_screen() {
            var small = started({ detached: true, windowWidth: 10, windowHeight: 10 })
            compare(small.width, 256)
            compare(small.height, 320)
            var big = started({ detached: true, windowWidth: 100000, windowHeight: 100000 })
            compare(big.width, shell.Screen.width)
            compare(big.height, shell.Screen.height)
            verify(shell.Screen.width > 256 && shell.Screen.height > 320)
        }

        // Maximised, the window is the size of the screen. Remembered, the
        // next plain window would open that large with no way to tell why.
        function test_a_maximised_window_keeps_the_size_it_had_before() {
            var win = started()
            popupFor(win)
            win.detached = true
            win.width = 420
            win.height = 610
            tryCompare(win.cfg, "windowWidth", 420)
            win.showMaximized()
            tryCompare(win, "visibility", Window.Maximized)
            tryVerify(function() { return win.width > 700 })
            wait(500)
            compare(win.cfg.windowWidth, 420)
            compare(win.cfg.windowHeight, 610)
        }

        // The popup cannot be kept shut, so the panel icon is made the way to
        // the window: a popup that gets the keyboard and finds its face away
        // asks for the window. Asked earlier, as the popup opened, the
        // window stayed behind under KWin 6.8.
        function test_a_popup_that_gets_the_keyboard_with_its_face_away_asks_the_window_forward() {
            var win = started()
            var popup = popupFor(win)
            win.detached = true
            tryCompare(win, "active", true)
            shell.Window.window.requestActivate()
            tryCompare(win, "active", false)
            popup.forceActiveFocus()
            tryCompare(win, "active", true)
        }

        function test_the_popups_opening_alone_asks_for_nothing() {
            var win = started()
            popupFor(win)
            win.detached = true
            tryCompare(win, "active", true)
            shell.Window.window.requestActivate()
            tryCompare(win, "active", false)
            win.popupOpen = true
            wait(100)
            compare(win.active, false)
        }

        function test_a_popup_with_its_face_in_it_asks_for_no_window() {
            var win = started()
            var popup = popupFor(win)
            popup.forceActiveFocus()
            wait(100)
            compare(win.visible, false)
            compare(win.active, false)
            verify(win.faceItem.activeFocus)
        }

        // ---- somebody is at the face: the level poll's fast rate

        function away(win) {
            shell.Window.window.requestActivate()
            tryCompare(win, "active", false)
        }

        function test_a_window_beside_other_work_is_nobody_at_the_face() {
            var win = started()
            popupFor(win)
            win.detached = true
            tryCompare(win, "active", true)
            compare(win.faceWatched, false)
            win.hovered = true
            compare(win.faceWatched, true)
            // The listener goes back to typing elsewhere; the pointer stays.
            away(win)
            compare(win.faceWatched, false)
            win.requestActivate()
            tryCompare(win, "active", true)
            compare(win.faceWatched, true)
            win.hovered = false
            compare(win.faceWatched, false)
        }

        // Minimised from the keyboard, the window kept its last "the pointer
        // is here" (measured under KWin). It no longer has the keyboard.
        function test_a_window_put_down_under_the_pointer_is_nobody_at_the_face() {
            var win = started()
            popupFor(win)
            win.detached = true
            win.hovered = true
            tryCompare(win, "faceWatched", true)
            win.showMinimized()
            away(win)
            compare(win.hovered, true)
            compare(win.faceWatched, false)
        }

        function test_in_the_popup_seat_the_open_popup_is_somebody_at_the_face() {
            var win = started()
            popupFor(win)
            compare(win.faceWatched, false)
            win.popupOpen = true
            compare(win.faceWatched, true)
            win.popupOpen = false
            compare(win.faceWatched, false)
            win.hovered = true
            compare(win.faceWatched, false)
        }

        function test_on_the_desktop_the_pointer_alone_is_somebody_at_the_face() {
            var win = started({}, { planar: true, popupOpen: true })
            popupFor(win)
            compare(win.faceWatched, false)
            win.hovered = true
            compare(win.faceWatched, true)
            win.hovered = false
            compare(win.faceWatched, false)
        }

        // The poll's next look can be half a minute away. Somebody arriving
        // at a face that is always on screen is told at once, so the slider
        // does not catch up under their eyes; a popup that opens starts its
        // own poll and needs no second word.
        function test_arriving_at_a_window_or_a_desktop_face_is_told_once_each_time() {
            var win = started()
            popupFor(win)
            arrivedSpy.target = win
            arrivedSpy.clear()
            win.detached = true
            tryCompare(win, "active", true)
            compare(arrivedSpy.count, 0)
            win.hovered = true
            compare(arrivedSpy.count, 1)
            win.hovered = false
            compare(arrivedSpy.count, 1)
            away(win)
            win.hovered = true
            compare(arrivedSpy.count, 1)
            win.requestActivate()
            tryCompare(win, "active", true)
            compare(arrivedSpy.count, 2)
            var desk = started({}, { planar: true, popupOpen: true })
            arrivedSpy.target = desk
            arrivedSpy.clear()
            desk.hovered = true
            desk.hovered = false
            desk.hovered = true
            compare(arrivedSpy.count, 2)
        }

        function test_a_popup_that_opens_is_not_an_arrival() {
            var win = started()
            popupFor(win)
            arrivedSpy.target = win
            arrivedSpy.clear()
            win.popupOpen = true
            win.popupOpen = false
            win.popupOpen = true
            compare(win.faceWatched, true)
            compare(arrivedSpy.count, 0)
        }

        // Plasma may throw the full representation away and build another;
        // the face outlives it because the window's seat owns it.
        function test_the_face_outlives_a_popup_seat_and_sits_in_the_next_one() {
            var win = house()
            var first = popupMaker.createObject(shell, { house: win })
            var face = win.faceItem
            first.destroy()
            wait(0)
            compare(shell.died, 0)
            var second = popupFor(win)
            compare(win.faceItem, face)
            compare(face.parent, second.seat)
            compare(shell.born, 1)
        }
    }
}
