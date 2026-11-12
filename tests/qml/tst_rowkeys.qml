// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The podcast page's show rows and found-episode rows with real key presses.
// Both are item delegates, and an item delegate takes no focus unless it is
// told to (measured on PlasmaComponents3.ItemDelegate: focusPolicy 0), so Tab
// went from one row's star to the next row's star and the row itself could
// not be reached. Given the focus anyway, Return, Enter and Space did
// nothing: the row acted on a TapHandler and nothing else. This hosts both
// delegates the way FullRepresentation.qml wires them, with the real
// CircleButton inside, under the popup's own Space, M and Escape handler.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtTest
import org.kde.plasma.components as PlasmaComponents3

import "../../package/contents/ui" as Ui
import "../../package/contents/ui/ViewLogic.js" as ViewLogic

FocusScope {
    // CircleButton reads root.accent and root.accentTextOn.
    id: root
    width: 360
    height: 460
    focus: true

    property color accent: "#6FCF97"
    property color accentTextOn: "#04140B"

    property var opened: []
    property var played: []
    property string playing: ""
    property int stars: 0
    property int doors: 0
    property int toggles: 0
    property int mutes: 0
    property string podcastEpisodesFor: ""

    function loadPodcastFeed(feedUrl, title, art) {
        opened = opened.concat([feedUrl])
        podcastEpisodesFor = feedUrl
    }
    // The episode that is playing stops when it is asked for again.
    function playPodcastEpisode(url) {
        played = played.concat([url])
        playing = playing === url ? "" : url
    }

    function _inputFocused() { return searchField.activeFocus }
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            if (root.podcastEpisodesFor !== "") {
                root.podcastEpisodesFor = ""
                event.accepted = true
            }
        } else if (event.key === Qt.Key_Space && !_inputFocused()) {
            root.toggles++
            event.accepted = true
        } else if (event.key === Qt.Key_M && !_inputFocused()) {
            root.mutes++
            event.accepted = true
        }
    }

    ListModel { id: shows }
    ListModel { id: episodes }

    ColumnLayout {
        anchors.fill: parent

        QQC2.TextField {
            id: searchField
            Layout.fillWidth: true
        }

        PlasmaComponents3.ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 170
            visible: root.podcastEpisodesFor === ""

            contentItem: ListView {
                id: showsView
                model: shows
                clip: true

                delegate: PlasmaComponents3.ItemDelegate {
                    id: showRow

                    required property int index
                    required property string title
                    required property string feedUrl
                    property alias star: showStar

                    width: showsView.width
                    height: 40
                    padding: 0
                    hoverEnabled: true
                    Accessible.name: title
                    Accessible.role: Accessible.Button
                    focusPolicy: Qt.TabFocus
                    onClicked: root.loadPodcastFeed(showRow.feedUrl, showRow.title, "")
                    Keys.onPressed: (event) => ViewLogic.pressRow(event, showRow)

                    contentItem: RowLayout {
                        anchors.fill: parent
                        Text {
                            Layout.fillWidth: true
                            text: showRow.title
                        }
                        Ui.CircleButton {
                            id: showStar
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            checkable: true
                            onClicked: root.stars++
                        }
                    }
                }
            }
        }

        PlasmaComponents3.ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 130

            contentItem: ListView {
                id: epSearchView
                model: episodes
                clip: true

                delegate: PlasmaComponents3.ItemDelegate {
                    id: epsRow

                    required property int index
                    required property string title
                    required property string url
                    required property string feed
                    property alias door: epsDoor

                    width: epSearchView.width
                    height: 40
                    padding: 0
                    hoverEnabled: true
                    Accessible.name: title
                    Accessible.role: Accessible.Button
                    focusPolicy: Qt.TabFocus
                    onClicked: root.playPodcastEpisode(epsRow.url, epsRow.title)
                    Keys.onPressed: (event) => ViewLogic.pressRow(event, epsRow)

                    contentItem: RowLayout {
                        anchors.fill: parent
                        Text {
                            Layout.fillWidth: true
                            text: epsRow.title
                        }
                        Ui.CircleButton {
                            id: epsDoor
                            visible: epsRow.feed !== ""
                            implicitWidth: 30
                            implicitHeight: 30
                            onClicked: root.doors++
                        }
                    }
                }
            }
        }

        QQC2.Button {
            id: afterLists
            text: "after"
        }
        Item { id: elsewhere }
    }

    TestCase {
        name: "RowKeys"
        when: windowShown

        function init() {
            root.podcastEpisodesFor = ""
            root.opened = []
            root.played = []
            root.playing = ""
            root.stars = 0
            root.doors = 0
            root.toggles = 0
            root.mutes = 0
            searchField.text = ""
            shows.clear()
            episodes.clear()
            var names = ["Alpha", "Beta", "Gamma"]
            for (var i = 0; i < names.length; i++) {
                shows.append({ "title": names[i], "feedUrl": "https://" + names[i].toLowerCase() + ".example/feed" })
                episodes.append({ "title": names[i] + " 1", "url": "https://" + names[i].toLowerCase() + ".example/1.mp3",
                                  "feed": i === 2 ? "" : "https://" + names[i].toLowerCase() + ".example/feed" })
            }
            showsView.positionViewAtBeginning()
            waitForRendering(showsView)
            searchField.forceActiveFocus()
        }

        function show(i) {
            showsView.forceLayout()
            return showsView.itemAtIndex(i)
        }
        function episode(i) {
            epSearchView.forceLayout()
            return epSearchView.itemAtIndex(i)
        }
        // The way a listener gets there: Tab, from the search field.
        function tabTo(item) {
            searchField.forceActiveFocus()
            for (var i = 0; i < 40 && !item.activeFocus; i++) keyClick(Qt.Key_Tab)
            verify(item.activeFocus, "Tab never reached the row")
        }

        function test_tab_walks_a_row_then_its_star_then_the_next_row() {
            keyClick(Qt.Key_Tab)
            verify(show(0).activeFocus, "the first Tab from the search field is not on the first show")
            keyClick(Qt.Key_Tab)
            verify(show(0).star.activeFocus)
            keyClick(Qt.Key_Tab)
            verify(show(1).activeFocus)
            keyClick(Qt.Key_Backtab)
            verify(show(0).star.activeFocus)
            keyClick(Qt.Key_Backtab)
            verify(show(0).activeFocus)
            keyClick(Qt.Key_Backtab)
            verify(searchField.activeFocus)
        }

        function test_a_key_opens_the_show_once_data() {
            return [
                { tag: "Return", key: Qt.Key_Return, mods: Qt.NoModifier },
                { tag: "Enter", key: Qt.Key_Enter, mods: Qt.NoModifier },
                { tag: "Enter on the number pad", key: Qt.Key_Enter, mods: Qt.KeypadModifier },
                { tag: "Space", key: Qt.Key_Space, mods: Qt.NoModifier },
                { tag: "Shift+Return", key: Qt.Key_Return, mods: Qt.ShiftModifier },
            ]
        }
        function test_a_key_opens_the_show_once(data) {
            tabTo(show(1))
            keyClick(data.key, data.mods)
            compare(JSON.stringify(root.opened), JSON.stringify(["https://beta.example/feed"]))
            compare(root.toggles, 0, "the popup's Space took the key as well")
            compare(root.stars, 0)
        }

        function test_a_click_on_the_row_opens_the_show_once() {
            elsewhere.forceActiveFocus()
            mouseClick(show(2), 20, 20)
            compare(JSON.stringify(root.opened), JSON.stringify(["https://gamma.example/feed"]))
            // A click does not take the focus along, so with the pointer the
            // popup's Space is still play and stop over the open show.
            verify(!show(2).activeFocus)
            keyClick(Qt.Key_Space)
            compare(root.toggles, 1)
            compare(root.opened.length, 1)
        }

        function test_the_arrow_keys_leave_the_focus_where_tab_put_it() {
            // The list moves its own current row on Up and Down; the focus,
            // and with it the border and what Return opens, stays put.
            var row = show(1)
            tabTo(row)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Up)
            verify(row.activeFocus)
            keyClick(Qt.Key_Return)
            compare(JSON.stringify(root.opened), JSON.stringify(["https://beta.example/feed"]))
        }

        function test_a_screen_readers_press_opens_the_show_once() {
            // What Qt's accessibility bridge calls on a button for "Press".
            show(0).accessiblePressAction()
            compare(JSON.stringify(root.opened), JSON.stringify(["https://alpha.example/feed"]))
        }

        function test_the_star_is_its_own_button() {
            mouseClick(show(0).star, 10, 10)
            compare(root.stars, 1)
            tabTo(show(0).star)
            keyClick(Qt.Key_Space)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Enter)
            compare(root.stars, 4)
            compare(root.opened.length, 0, "a press on the star opened the show too")
            compare(root.toggles, 0)
        }

        function test_a_key_held_down_opens_the_show_once() {
            // QtTest sends no repeated key, so the repeats are handed to the
            // handler's own function with the real row.
            var row = show(0)
            tabTo(row)
            keyClick(Qt.Key_Space)
            for (var i = 0; i < 30; i++) {
                var ev = { key: Qt.Key_Space, isAutoRepeat: true, accepted: false }
                ViewLogic.pressRow(ev, row)
                compare(ev.accepted, true)
            }
            compare(root.opened.length, 1)
        }

        function test_an_open_show_is_not_fetched_again_from_its_hidden_row() {
            var row = show(0)
            tabTo(row)
            keyClick(Qt.Key_Return)
            compare(root.opened.length, 1)
            compare(row.visible, false)
            // Measured: the row keeps the focus while its list is hidden.
            verify(row.activeFocus)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Enter)
            keyClick(Qt.Key_Space)
            compare(root.opened.length, 1, "a key under the episode list fetched the feed again")
            compare(root.toggles, 0)
        }

        function test_escape_comes_back_to_the_row_that_was_opened() {
            var row = show(1)
            tabTo(row)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Escape)
            compare(root.podcastEpisodesFor, "")
            verify(row.visible)
            verify(row.activeFocus)
            keyClick(Qt.Key_Return)
            compare(JSON.stringify(root.opened),
                    JSON.stringify(["https://beta.example/feed", "https://beta.example/feed"]))
        }

        function test_tab_leaves_an_opened_show_for_what_is_on_screen() {
            tabTo(show(2))
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Tab)
            verify(episode(0).activeFocus, "Tab from the hidden row is not on the first thing shown after it")
        }

        function test_space_in_the_search_field_is_a_space() {
            searchField.forceActiveFocus()
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_Space)
            keyClick(Qt.Key_B)
            compare(searchField.text, "a b")
            compare(root.opened.length, 0)
            compare(root.played.length, 0)
            compare(root.toggles, 0)
        }

        function test_the_popups_own_keys_still_arrive_from_a_row() {
            tabTo(show(0))
            keyClick(Qt.Key_M)
            compare(root.mutes, 1)
            compare(root.opened.length, 0)
            keyClick(Qt.Key_Escape)
            compare(root.opened.length, 0)
            // And Space is the popup's when the focus is on nothing that takes it.
            elsewhere.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(root.toggles, 1)
            compare(root.opened.length, 0)
        }

        function test_a_row_switched_off_takes_no_press() {
            var row = show(0)
            row.enabled = false
            mouseClick(row, 20, 20)
            row.accessiblePressAction()
            keyClick(Qt.Key_Tab)
            verify(!row.activeFocus)
            verify(show(1).activeFocus, "Tab does not step over a row that is switched off")
            compare(root.opened.length, 0)
            row.enabled = true
        }

        function test_an_empty_list_is_stepped_over() {
            shows.clear()
            episodes.clear()
            // The rows of a cleared model are still there until the lists lay out.
            showsView.forceLayout()
            epSearchView.forceLayout()
            compare(showsView.contentItem.visibleChildren.length, 0)
            keyClick(Qt.Key_Tab)
            verify(afterLists.activeFocus)
            keyClick(Qt.Key_Return)
            compare(root.opened.length, 0)
            compare(root.played.length, 0)
        }

        function test_a_row_far_down_a_long_list_opens_itself() {
            shows.clear()
            for (var i = 0; i < 300; i++)
                shows.append({ "title": "Show " + i, "feedUrl": "https://s" + i + ".example/feed" })
            showsView.positionViewAtIndex(250, ListView.Beginning)
            var row = show(250)
            verify(row !== null)
            tabTo(row)
            keyClick(Qt.Key_Return)
            compare(JSON.stringify(root.opened), JSON.stringify(["https://s250.example/feed"]))
            // Back to the top with the list on screen: emptied where it was left
            // scrolled, the view warns about a row it was still making.
            root.podcastEpisodesFor = ""
            showsView.positionViewAtBeginning()
            waitForRendering(showsView)
        }

        function test_a_key_plays_the_found_episode_and_the_next_press_stops_it_data() {
            return [
                { tag: "Return", key: Qt.Key_Return },
                { tag: "Enter", key: Qt.Key_Enter },
                { tag: "Space", key: Qt.Key_Space },
            ]
        }
        function test_a_key_plays_the_found_episode_and_the_next_press_stops_it(data) {
            tabTo(episode(1))
            keyClick(data.key)
            compare(JSON.stringify(root.played), JSON.stringify(["https://beta.example/1.mp3"]))
            compare(root.playing, "https://beta.example/1.mp3")
            compare(root.toggles, 0, "the popup's Space took the key as well")
            keyClick(data.key)
            compare(root.played.length, 2)
            compare(root.playing, "")
        }

        function test_a_key_held_down_on_an_episode_leaves_it_playing() {
            var row = episode(0)
            tabTo(row)
            keyClick(Qt.Key_Space)
            for (var i = 0; i < 30; i++)
                ViewLogic.pressRow({ key: Qt.Key_Space, isAutoRepeat: true, accepted: false }, row)
            compare(root.played.length, 1)
            compare(root.playing, "https://alpha.example/1.mp3")
        }

        function test_a_click_on_the_episode_row_plays_it_once() {
            mouseClick(episode(2), 20, 20)
            compare(JSON.stringify(root.played), JSON.stringify(["https://gamma.example/1.mp3"]))
        }

        function test_a_screen_readers_press_plays_the_episode_once() {
            episode(0).accessiblePressAction()
            compare(JSON.stringify(root.played), JSON.stringify(["https://alpha.example/1.mp3"]))
        }

        function test_the_door_to_the_show_is_its_own_button() {
            mouseClick(episode(0).door, 10, 10)
            compare(root.doors, 1)
            tabTo(episode(0).door)
            keyClick(Qt.Key_Space)
            keyClick(Qt.Key_Return)
            compare(root.doors, 3)
            compare(root.played.length, 0, "the door to the show played the episode too")
            compare(root.toggles, 0)
            // An episode without a feed has no door, and Tab goes on to what follows.
            verify(!episode(2).door.visible)
            tabTo(episode(2))
            keyClick(Qt.Key_Tab)
            verify(afterLists.activeFocus)
        }
    }
}
