// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The station list keeps the web results in its footer, under the saved
// stations. An answer the listener asked for from the rail has to land in
// sight: on 2026-09-23, seven seconds after "Trending now" the popup still
// showed the saved list and nothing else, with thirty results below the fold.
import QtQuick
import QtTest

import "../../package/contents/ui/ViewLogic.js" as VL

Item {
    id: root
    width: 300
    height: 200
    property bool searching: false

    ListModel { id: saved }
    ListModel { id: web }

    ListView {
        id: view
        anchors.fill: parent
        clip: true
        model: saved
        delegate: Rectangle { width: view.width; height: 40 }
        // The shape FullRepresentation's footer has: a Column that is as
        // tall as its rows, a heading line, and a Repeater over the results.
        footer: Column {
            width: view.width
            visible: web.count > 0 || root.searching
            height: visible ? implicitHeight : 0
            Rectangle { width: 10; height: 24 }
            Repeater {
                model: web
                delegate: Rectangle { width: 10; height: 40 }
            }
        }
    }

    TestCase {
        name: "ViewLogic"
        when: windowShown

        function init() {
            root.searching = false
            web.clear()
            saved.clear()
            view.positionViewAtBeginning()
            waitForRendering(view)
        }

        function fill(model, n) {
            for (var i = 0; i < n; i++) model.append({ "n": i })
        }

        function headingInSight() {
            var f = view.footerItem
            return f.y >= view.contentY - 0.5 && f.y + 24 <= view.contentY + view.height + 0.5
        }

        function footerWhollyInSight() {
            var f = view.footerItem
            return f.y >= view.contentY - 0.5 && f.y + f.height <= view.contentY + view.height + 0.5
        }

        function test_a_long_answer_shows_its_heading_at_the_top() {
            fill(saved, 40)
            waitForRendering(view)
            root.searching = true
            fill(web, 30)
            // No wait on purpose: the rows are in the model, but a Column lays
            // its children out once a frame, and the answer's callback is not
            // one frame later.
            var moved = VL.revealFooter(view)
            fuzzyCompare(view.contentY, view.footerItem.y, 0.5)
            verify(moved)
            waitForRendering(view)
            verify(headingInSight(), "footer at " + view.footerItem.y + ", view at " + view.contentY)
        }

        function test_a_short_answer_is_shown_whole() {
            fill(saved, 40)
            waitForRendering(view)
            fill(web, 2)
            var moved = VL.revealFooter(view)
            verify(footerWhollyInSight(), "footer at " + view.footerItem.y + ", view at " + view.contentY)
            verify(moved)
            waitForRendering(view)
            verify(footerWhollyInSight())
        }

        function test_the_searching_line_is_shown_before_the_answer() {
            // At the tap only the heading line is there; the spinner in it
            // is the listener's sign that something is on the way.
            fill(saved, 40)
            waitForRendering(view)
            root.searching = true
            var moved = VL.revealFooter(view)
            verify(footerWhollyInSight(), "footer at " + view.footerItem.y + ", view at " + view.contentY)
            verify(moved)
        }

        function test_an_answer_reaches_a_list_scrolled_halfway() {
            fill(saved, 40)
            waitForRendering(view)
            view.contentY = 600
            waitForRendering(view)
            fill(web, 30)
            var moved = VL.revealFooter(view)
            waitForRendering(view)
            verify(headingInSight(), "footer at " + view.footerItem.y + ", view at " + view.contentY)
            verify(moved)
        }

        function test_a_list_that_fits_is_not_moved() {
            fill(saved, 2)
            fill(web, 1)
            waitForRendering(view)
            var moved = VL.revealFooter(view)
            fuzzyCompare(view.contentY, view.originY, 0.5)
            verify(footerWhollyInSight())
            verify(moved)
        }

        function test_no_footer_on_screen_moves_nothing() {
            fill(saved, 40)
            waitForRendering(view)
            view.contentY = 80
            verify(!VL.revealFooter(view))
            compare(view.contentY, 80)
            verify(!VL.revealFooter(null))
            verify(!VL.revealFooter({}))
        }

        // ── the footer's word for a network that is gone ─────────────────
        // Read from the footer's own bindings with a downloaded episode
        // playing and the network down: "Check internet connection…", in
        // the error red, over sound that needs no network at all.

        function test_a_file_playing_from_disk_is_not_told_to_check_the_network() {
            compare(VL.offlineWord(false, true, true), false)
        }

        function test_a_station_with_the_network_gone_is_told() {
            compare(VL.offlineWord(false, false, false), true, "nothing playing")
            // A stream still draining what it buffered before the link went.
            compare(VL.offlineWord(false, false, true), true, "a station still sounding")
        }

        function test_a_silent_file_does_not_hide_a_dead_network() {
            // Paused, ended or not started: the next pick may be a station.
            compare(VL.offlineWord(false, true, false), true)
        }

        function test_with_the_network_up_the_word_stays_away() {
            compare(VL.offlineWord(true, false, false), false)
            compare(VL.offlineWord(true, false, true), false)
            compare(VL.offlineWord(true, true, false), false)
            compare(VL.offlineWord(true, true, true), false)
        }

        function test_only_a_plain_answer_counts() {
            // Only a definite "disconnected" is offline: a value that has
            // not arrived yet is not a dead network.
            compare(VL.offlineWord(undefined, false, false), false)
            compare(VL.offlineWord(null, false, false), false)
            compare(VL.offlineWord(0, false, false), false)
            compare(VL.offlineWord("", false, false), false)
            compare(VL.offlineWord(), false)
            // And only a plain yes is a file playing.
            compare(VL.offlineWord(false, 1, 1), true)
            compare(VL.offlineWord(false, "file", "playing"), true)
            compare(VL.offlineWord(false, true, undefined), true)
            compare(VL.offlineWord(false, undefined, true), true)
            compare(VL.offlineWord(false), true)
        }

        // ── The footer's word over a stream with no bitrate ─────────────────────

        function test_a_stream_whose_position_moved_sounds_data() {
            return [
                { tag: "buffer played back, no title", titled: false, local: false, pos: 12000, want: true },
                { tag: "live, no titles, no bitrate", titled: false, local: false, pos: 300, want: true },
                { tag: "the frozen 278 ms of a live Ogg FLAC", titled: false, local: false, pos: 278, want: true },
                { tag: "one millisecond in", titled: false, local: false, pos: 1, want: true },
                { tag: "before the first sound", titled: false, local: false, pos: 0, want: false },
                { tag: "a title before any position", titled: true, local: false, pos: 0, want: true },
                { tag: "a file of the listener's at its start", titled: false, local: true, pos: 0, want: true },
                { tag: "a title and a position", titled: true, local: false, pos: 5000, want: true }
            ];
        }
        function test_a_stream_whose_position_moved_sounds(data) {
            compare(VL.streamSounds(data.titled, data.local, data.pos), data.want);
        }

        function test_a_position_that_is_no_place_proves_no_sound_data() {
            return [
                { tag: "negative", pos: -1 }, { tag: "not a number", pos: NaN }, { tag: "undefined", pos: undefined },
                { tag: "null", pos: null }, { tag: "text", pos: "12000" }, { tag: "infinite", pos: Infinity },
                { tag: "an object", pos: ({}) }
            ];
        }
        function test_a_position_that_is_no_place_proves_no_sound(data) {
            compare(VL.streamSounds(false, false, data.pos), false);
        }

        function test_only_a_plain_true_is_a_title_or_a_file() {
            compare(VL.streamSounds("yes", false, 0), false, "a truthy title flag is not a title");
            compare(VL.streamSounds(false, 1, 0), false, "a truthy file flag is not a file");
            compare(VL.streamSounds(undefined, undefined, 0), false);
            compare(VL.streamSounds(), false, "nothing handed in");
            compare(VL.streamSounds(false, false, Number.MAX_SAFE_INTEGER), true, "a station left on for days");
        }
    }
}
