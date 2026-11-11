// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The popup's tabs can be switched off, and two things assumed they were
// all there. Escape went to page 0 and closed the popup only from there:
// with Stations off the guard walked it on to Playing, so four presses
// left the view at 1, 1, 1, 1 and the popup open. And the guard looked
// forward first whichever way the listener was going: with Playing off, a
// step back from My Music landed on My Music. This hosts the guard and the
// Escape handler as main.qml and FullRepresentation.qml wire them, inside
// an outer scope that counts the Escapes nobody accepted.
import QtQuick
import QtTest

import "../../package/contents/ui/ViewLogic.js" as ViewLogic

FocusScope {
    id: popup
    width: 300
    height: 200
    focus: true
    property int closes: 0
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) popup.closes++
    }

    FocusScope {
        id: root
        anchors.fill: parent
        focus: true

        property var wanted: [true, true, true, true, true]
        property int view: 0
        property string podcastEpisodesFor: ""
        property string filterText: ""

        function viewVisible(i) { return wanted[i] === true }
        function hide(i) {
            var w = wanted.slice()
            w[i] = false
            wanted = w
            _ensureViewVisible()
        }

        property int _viewWas: 0
        function shownViews() { return [0, 1, 2, 3, 4].map(function(i) { return viewVisible(i); }); }
        function _ensureViewVisible() {
            var to = ViewLogic.nextVisibleView(view, view < _viewWas ? -1 : 1, shownViews());
            _viewWas = to;
            view = to;
        }
        onViewChanged: _ensureViewVisible()

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                var home = ViewLogic.firstVisibleView(root.shownViews())
                if (root.view === 3 && root.podcastEpisodesFor !== "") {
                    root.podcastEpisodesFor = ""
                    event.accepted = true
                } else if (root.view !== home) {
                    root.view = home
                    event.accepted = true
                } else if (root.view === 0 && root.filterText !== "") {
                    root.filterText = ""
                    event.accepted = true
                }
            }
        }
    }

    TestCase {
        name: "TabWalk"
        when: windowShown

        function init() {
            root.wanted = [true, true, true, true, true]
            root.view = 0
            root.podcastEpisodesFor = ""
            root.filterText = ""
            root._viewWas = 0
            popup.closes = 0
            root.forceActiveFocus()
        }

        function test_escape_on_the_first_tab_closes_the_popup_with_stations_off() {
            root.hide(0)
            compare(root.view, 1)
            keyClick(Qt.Key_Escape)
            compare(popup.closes, 1)
            compare(root.view, 1)
        }

        function test_escape_from_a_later_page_goes_home_first_with_stations_off() {
            root.hide(0)
            root.view = 4
            keyClick(Qt.Key_Escape)
            compare(root.view, 1)
            compare(popup.closes, 0)
            keyClick(Qt.Key_Escape)
            compare(popup.closes, 1)
        }

        function test_a_filter_on_a_hidden_station_page_does_not_hold_escape_back() {
            root.filterText = "jazz"
            root.hide(0)
            keyClick(Qt.Key_Escape)
            compare(popup.closes, 1)
        }

        function test_escape_with_every_tab_shown_is_what_it_was() {
            root.view = 2
            keyClick(Qt.Key_Escape)
            compare(root.view, 0)
            compare(popup.closes, 0)
            root.filterText = "jazz"
            keyClick(Qt.Key_Escape)
            compare(root.filterText, "")
            compare(popup.closes, 0)
            keyClick(Qt.Key_Escape)
            compare(popup.closes, 1)
        }

        function test_escape_steps_out_of_an_open_feed_before_it_leaves_the_page() {
            root.view = 3
            root.podcastEpisodesFor = "https://feed.example/rss"
            keyClick(Qt.Key_Escape)
            compare(root.podcastEpisodesFor, "")
            compare(root.view, 3)
            keyClick(Qt.Key_Escape)
            compare(root.view, 0)
            compare(popup.closes, 0)
        }

        function test_a_step_back_over_a_hidden_tab_lands_before_it() {
            root.view = 2
            root.hide(1)
            root.view = 1
            compare(root.view, 0)
        }

        function test_a_step_forward_over_a_hidden_tab_lands_after_it() {
            root.hide(1)
            root.view = 1
            compare(root.view, 2)
        }

        function test_a_step_back_with_nothing_behind_stays_on_this_side() {
            root.view = 2
            root.hide(0)
            root.hide(1)
            root.view = 1
            compare(root.view, 2)
        }

        function test_a_tab_switched_off_under_the_listener_walks_forward() {
            root.view = 2
            root.hide(2)
            compare(root.view, 3)
        }

        function test_two_steps_back_in_a_row_both_count_as_back() {
            root.view = 4
            root.hide(3)
            root.hide(1)
            root.view = 3
            compare(root.view, 2)
            root.view = 1
            compare(root.view, 0)
        }
    }
}
