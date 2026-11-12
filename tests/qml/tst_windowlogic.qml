// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Which of its two seats the face sits in, and when it counts as on screen.
import QtQuick
import QtTest

import "../../package/contents/ui/WindowLogic.js" as WL

TestCase {
    name: "WindowLogic"

    function test_the_face_sits_in_the_window_when_the_listener_sent_it_there() {
        compare(WL.seatOf(true, false), "window")
        compare(WL.seatOf(false, false), "popup")
    }

    // A desktop widget shows the face inline and is offered no window: there
    // the window cut six pixels off each side of the face. A wish left in
    // the config from the widget's days in a panel must not put it there.
    function test_a_desktop_widget_keeps_its_face_whatever_the_config_says() {
        compare(WL.seatOf(true, true), "popup")
        compare(WL.seatOf(false, true), "popup")
    }

    function test_only_a_plain_true_sends_the_face_to_the_window_data() {
        return [
            { tag: "nothing", detached: undefined },
            { tag: "null", detached: null },
            { tag: "the word true", detached: "true" },
            { tag: "one", detached: 1 },
            { tag: "an object", detached: {} },
            { tag: "a long word", detached: new Array(5000).join("true") },
        ]
    }
    function test_only_a_plain_true_sends_the_face_to_the_window(data) {
        compare(WL.seatOf(data.detached, false), "popup")
    }

    // Only a plain true is the desktop form. Anything else leaves the
    // listener's wish standing.
    function test_a_form_that_is_not_plainly_the_desktop_does_not_take_the_window_away() {
        compare(WL.seatOf(true, undefined), "window")
        compare(WL.seatOf(true, null), "window")
        compare(WL.seatOf(true, 1), "window")
    }

    function test_the_face_is_on_screen_while_either_seat_is_data() {
        return [
            { tag: "popup closed, no window", popup: false, win: false, shown: false },
            { tag: "popup open", popup: true, win: false, shown: true },
            { tag: "window up, popup closed", popup: false, win: true, shown: true },
            // The popup is open over a placeholder; the face is in the window.
            { tag: "both", popup: true, win: true, shown: true },
        ]
    }
    function test_the_face_is_on_screen_while_either_seat_is(data) {
        compare(WL.faceShown(data.popup, data.win), data.shown)
    }

    function test_a_fact_that_is_not_a_plain_true_shows_nothing_data() {
        return [
            { tag: "nothing at all", popup: undefined, win: undefined },
            { tag: "nulls", popup: null, win: null },
            { tag: "words", popup: "true", win: "yes" },
            { tag: "numbers", popup: 1, win: 2 },
        ]
    }
    function test_a_fact_that_is_not_a_plain_true_shows_nothing(data) {
        compare(WL.faceShown(data.popup, data.win), false)
    }

    // One side of the window: what the config remembers, between what the
    // face needs (256) and what the screen has (1920); 336 is the size the
    // face asks for when nothing is remembered.
    function side(stored) { return WL.sizeFor(stored, 256, 1920, 336) }

    function test_a_remembered_size_is_the_size_the_window_opens_at() {
        compare(side(500), 500)
        compare(side(500.6), 501)
    }

    function test_nothing_remembered_opens_at_the_size_the_face_asks_for() {
        compare(side(0), 336)
    }

    function test_the_size_stops_at_what_the_face_needs_and_at_the_screen() {
        compare(side(256), 256)
        compare(side(255), 256)
        compare(side(1), 256)
        compare(side(1920), 1920)
        compare(side(1921), 1920)
        compare(side(1e12), 1920)
    }

    function test_a_remembered_size_that_is_no_size_is_forgotten_data() {
        return [
            { tag: "not a number", stored: NaN },
            { tag: "a word", stored: "wide" },
            { tag: "digits in a string", stored: "500" },
            { tag: "nothing", stored: undefined },
            { tag: "null", stored: null },
            { tag: "negative", stored: -500 },
            { tag: "endless", stored: Infinity },
            { tag: "an object", stored: {} },
        ]
    }
    function test_a_remembered_size_that_is_no_size_is_forgotten(data) {
        compare(side(data.stored), 336)
    }

    // The face's own wish is a Layout hint, and an unset hint reads -1.
    function test_a_face_that_asks_for_no_size_gets_the_least_it_needs() {
        compare(WL.sizeFor(0, 256, 1920, -1), 256)
        compare(WL.sizeFor(0, 256, 1920, NaN), 256)
        compare(WL.sizeFor(0, 256, 1920, undefined), 256)
        compare(WL.sizeFor(0, 256, 1920, 5000), 1920)
    }

    // No screen to ask, or one narrower than the face: the face's floor
    // still holds, and a remembered size stops at 8192, past any one screen.
    function test_without_a_screen_to_ask_the_size_still_has_an_end() {
        compare(WL.sizeFor(700, 256, 0, 336), 700)
        compare(WL.sizeFor(700, 256, undefined, 336), 700)
        compare(WL.sizeFor(700, 256, NaN, 336), 700)
        compare(WL.sizeFor(1e12, 256, 0, 336), 8192)
        compare(WL.sizeFor(700, 256, 200, 336), 256)
        compare(WL.sizeFor(100, 256, 200, 336), 256)
    }

    function test_a_floor_that_is_no_size_leaves_one_pixel_as_the_least() {
        compare(WL.sizeFor(0, 0, 1920, -1), 1)
        compare(WL.sizeFor(0, -40, 1920, -1), 1)
        compare(WL.sizeFor(0, NaN, 1920, -1), 1)
        compare(WL.sizeFor(300, undefined, 1920, -1), 300)
    }

    // ---- somebody is at the face: what the level poll's fast rate goes by

    function test_in_the_popup_an_open_popup_is_somebody_looking_data() {
        return [
            { tag: "open", open: true, hovered: false, active: false, at: true },
            { tag: "open, pointer on it", open: true, hovered: true, active: true, at: true },
            { tag: "shut", open: false, hovered: false, active: false, at: false },
            // A pointer cannot be on a popup that is shut; a word that says so is stale.
            { tag: "shut, stale pointer", open: false, hovered: true, active: true, at: false },
        ]
    }
    function test_in_the_popup_an_open_popup_is_somebody_looking(data) {
        compare(WL.watched("popup", false, data.open, data.hovered, data.active), data.at)
    }

    // A desktop face is always on screen, so being on screen says nothing.
    function test_on_the_desktop_the_pointer_on_the_face_is_data() {
        return [
            { tag: "pointer away", hovered: false, active: false, at: false },
            { tag: "pointer on it", hovered: true, active: false, at: true },
            // There is no window of the widget's to have the keyboard.
            { tag: "pointer away, keyboard said to be there", hovered: false, active: true, at: false },
        ]
    }
    function test_on_the_desktop_the_pointer_on_the_face_is(data) {
        compare(WL.watched("popup", true, true, data.hovered, data.active), data.at)
    }

    // A window stays up beside other work for a day. With the pointer alone,
    // a listener who clicked a station and went back to typing elsewhere
    // left the fast poll running under a parked pointer, and a window
    // minimised from the keyboard kept its last "pointer is here" for good
    // (measured). With the keyboard alone, a radio started and left was
    // "watched" all night. Both together is somebody at the window.
    function test_in_the_window_it_takes_the_pointer_and_the_keyboard_data() {
        return [
            { tag: "neither", hovered: false, active: false, at: false },
            { tag: "pointer parked on it, typing elsewhere", hovered: true, active: false, at: false },
            { tag: "has the keyboard, pointer elsewhere", hovered: false, active: true, at: false },
            { tag: "both", hovered: true, active: true, at: true },
        ]
    }
    function test_in_the_window_it_takes_the_pointer_and_the_keyboard(data) {
        compare(WL.watched("window", false, false, data.hovered, data.active), data.at)
        // The popup open over its placeholder is nobody looking at the face.
        compare(WL.watched("window", false, true, data.hovered, data.active), data.at)
    }

    function test_a_fact_that_is_not_a_plain_true_is_nobody_there_data() {
        return [
            { tag: "nothing", v: undefined }, { tag: "null", v: null }, { tag: "a word", v: "true" },
            { tag: "one", v: 1 }, { tag: "an object", v: {} },
        ]
    }
    function test_a_fact_that_is_not_a_plain_true_is_nobody_there(data) {
        compare(WL.watched("popup", false, data.v, true, true), false)
        compare(WL.watched("popup", true, true, data.v, true), false)
        compare(WL.watched("window", false, true, data.v, true), false)
        compare(WL.watched("window", false, true, true, data.v), false)
    }

    function test_a_seat_nobody_knows_goes_by_the_popups_rule() {
        compare(WL.watched("", false, true, false, false), true)
        compare(WL.watched(undefined, false, false, true, true), false)
        compare(WL.watched(new Array(3000).join("window"), false, true, false, false), true)
    }

    function test_a_form_that_is_not_plainly_the_desktop_goes_by_the_popups_rule() {
        compare(WL.watched("popup", 1, true, false, false), true)
        compare(WL.watched("popup", "true", true, false, false), true)
        compare(WL.watched("popup", undefined, false, true, true), false)
    }

    // "Standing": a seat that is on screen whether or not anybody looks.
    function test_the_window_and_the_desktop_are_seats_that_never_close() {
        compare(WL.standing("window", false), true)
        compare(WL.standing("popup", true), true)
        compare(WL.standing("popup", false), false)
        compare(WL.standing("popup", undefined), false)
        compare(WL.standing("popup", 1), false)
        compare(WL.standing(undefined, false), false)
        compare(WL.standing("", null), false)
    }
}
