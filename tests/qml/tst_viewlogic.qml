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
    }
}
