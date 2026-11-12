// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// A key held down repeats some 25 times a second. This stands the popup's
// key handler (FullRepresentation.qml), from Space down, up around a volume
// and a transport that only write down what they are asked, and hands it
// presses and their repeats as the toolkit does. It proves this copy;
// test_invariants holds the file to the same lines.
import QtQuick
import QtTest

Item {
    id: root
    width: 100
    height: 100

    property int view: 1
    property bool inInput: false
    property var asked: []
    property var typed: []
    QtObject { id: playMusicOutput; property real volume: 0.8 }
    function targetVolume() { return 0.8 }
    function setUserVolume(v) { asked.push("volume " + v); playMusicOutput.volume = v }
    function transport(cmd) { asked.push(cmd) }
    function _inputFocused() { return inInput }
    function typeToSearch(event) { typed.push(event.key); return true }

    // ── FullRepresentation.qml's own lines ───────────────────────────────
    function pressed(event) {
        if (event.key === Qt.Key_Escape) {
            event.accepted = false
        } else if (event.key === Qt.Key_Space && !_inputFocused() && !event.isAutoRepeat) {
            root.transport("PlayPause")
            event.accepted = true
        } else if (event.key === Qt.Key_M && !_inputFocused() && root.view !== 0) {
            if (!event.isAutoRepeat) root.setUserVolume(playMusicOutput.volume > 0 ? 0 : root.targetVolume())
            event.accepted = true
        } else if (root.view === 0 && !_inputFocused() && typeToSearch(event)) {
            event.accepted = true
        }
    }

    TestCase {
        name: "HeldKey"

        function init() { root.view = 1; root.inInput = false; root.asked = []; root.typed = []; playMusicOutput.volume = 0.8 }
        function key(k, repeat) { var e = { "key": k, "isAutoRepeat": repeat === true, "accepted": false }; root.pressed(e); return e }
        // One physical press, held: the press and then its repeats.
        function hold(k, repeats) { var all = [key(k, false)]; for (var i = 0; i < repeats; i++) all.push(key(k, true)); return all }

        function test_m_held_down_mutes_once() {
            hold(Qt.Key_M, 2)
            compare(root.asked, ["volume 0"])
            compare(playMusicOutput.volume, 0)
        }

        function test_m_held_for_a_second_is_still_one_mute() {
            hold(Qt.Key_M, 25)
            compare(root.asked.length, 1)
            compare(playMusicOutput.volume, 0)
        }

        function test_m_released_and_pressed_again_unmutes() {
            hold(Qt.Key_M, 3)
            hold(Qt.Key_M, 3)
            compare(root.asked, ["volume 0", "volume 0.8"])
            compare(playMusicOutput.volume, 0.8)
        }

        function test_the_repeats_of_a_held_m_go_no_further() {
            // The press was the mute's, so its repeats are too: none of them is left for whatever sits above the popup.
            var all = hold(Qt.Key_M, 4)
            for (var i = 0; i < all.length; i++) verify(all[i].accepted, "event " + i + " was passed on")
            compare(root.typed, [])
        }

        function test_on_the_stations_page_m_is_a_letter_also_while_it_is_held() {
            root.view = 0
            var all = hold(Qt.Key_M, 3)
            compare(root.asked, [])
            compare(root.typed.length, 4)
            verify(all[3].accepted)
        }

        function test_in_a_text_field_m_is_left_to_the_field() {
            root.inInput = true
            var all = hold(Qt.Key_M, 2)
            compare(root.asked, [])
            compare(root.typed, [])
            verify(!all[0].accepted && !all[2].accepted)
        }

        function test_a_repeat_with_no_press_before_it_does_nothing() {
            // The popup opened while the key was already down.
            var e = key(Qt.Key_M, true)
            compare(root.asked, [])
            verify(e.accepted)
        }

        function test_space_held_down_is_one_press_as_it_was() {
            hold(Qt.Key_Space, 5)
            compare(root.asked, ["PlayPause"])
        }
    }
}
