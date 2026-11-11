// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// A station row cuts a long name with "…" and is meant to carry the whole
// name past while the pointer rests on it. The marquee waited for
// contentWidth to exceed the row, and contentWidth is what is left AFTER
// the cut: measured on a 120 px row, contentWidth 117.48 against an
// implicitWidth of 462.56. So it had not run since the label learned to
// elide, and a long name stayed cut with no way to read it. This hosts the
// row's label and its animator as MediaListItem.qml has them.
import QtQuick
import QtQuick.Controls as QQC2
import QtTest
import org.kde.kirigami as Kirigami

Item {
    id: listItem
    width: 300
    height: 100

    property bool hovered: false
    property real speedfactor: 1
    property string name: ""
    readonly property string longName: "Radio Paradise Main Mix with a very long station name indeed"

    Item {
        id: trackRect
        width: 120
        height: trackName.implicitHeight
        clip: true

        QQC2.Label {
            id: trackName
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool passing: listItem.hovered && implicitWidth > trackRect.width
                                            && Kirigami.Units.longDuration > 0
            width: passing ? implicitWidth : parent.width
            text: listItem.name
            textFormat: Text.PlainText
            maximumLineCount: 1
            elide: Text.ElideRight

            XAnimator {
                id: nameSlide
                target: trackName
                from: 0
                to: -trackName.implicitWidth
                duration: Math.round(Math.abs(to - from) / Kirigami.Units.gridUnit * 300
                                     * Math.max(0.1, Math.min(8, (listItem.speedfactor || 1))))
                running: trackName.passing
                loops: 1
                onFinished: {
                    from = trackRect.width
                    if (listItem.hovered) start()
                }
                onStopped: {
                    from = 0
                    trackName.x = 0
                }
            }
        }
    }

    TestCase {
        name: "RowMarquee"
        when: windowShown

        function init() {
            listItem.hovered = false
            listItem.speedfactor = 1
            listItem.name = listItem.longName
            tryVerify(function() { return !nameSlide.running })
        }

        function test_a_cut_name_can_never_be_wider_than_its_row() {
            // Why contentWidth could not be the trigger.
            verify(trackName.truncated)
            verify(trackName.contentWidth <= trackRect.width,
                   "contentWidth " + trackName.contentWidth + " in a row of " + trackRect.width)
            verify(trackName.implicitWidth > trackRect.width,
                   "implicitWidth " + trackName.implicitWidth)
        }

        function test_hovering_a_cut_name_starts_the_marquee() {
            if (Kirigami.Units.longDuration <= 0) skip("animations are switched off on this machine")
            listItem.hovered = true
            tryVerify(function() { return nameSlide.running }, 1000, "the marquee did not start")
        }

        function test_the_whole_name_passes_and_not_the_cut_one() {
            if (Kirigami.Units.longDuration <= 0) skip("animations are switched off on this machine")
            listItem.hovered = true
            tryVerify(function() { return nameSlide.running }, 1000, "the marquee did not start")
            verify(!trackName.truncated, "the marquee carries a name that is still cut")
            fuzzyCompare(trackName.width, trackName.implicitWidth, 0.5)
            fuzzyCompare(-nameSlide.to, trackName.implicitWidth, 0.5)
        }

        function test_the_pointer_leaving_puts_the_cut_name_back() {
            if (Kirigami.Units.longDuration <= 0) skip("animations are switched off on this machine")
            listItem.hovered = true
            tryVerify(function() { return nameSlide.running }, 1000, "the marquee did not start")
            listItem.hovered = false
            tryVerify(function() { return !nameSlide.running })
            compare(trackName.x, 0)
            compare(trackName.width, trackRect.width)
            verify(trackName.truncated)
        }

        function test_a_name_that_fits_stays_where_it_is() {
            listItem.name = "FIP"
            listItem.hovered = true
            wait(50)
            verify(!nameSlide.running)
            compare(trackName.width, trackRect.width)
            compare(trackName.x, 0)
        }

        function test_no_name_at_all_stays_still() {
            listItem.name = ""
            listItem.hovered = true
            wait(50)
            verify(!nameSlide.running)
        }

        function test_the_marquee_speed_setting_scales_the_pass() {
            if (Kirigami.Units.longDuration <= 0) skip("animations are switched off on this machine")
            // 300 ms a grid unit at factor 1, over the whole name.
            var one = Math.round(trackName.implicitWidth / Kirigami.Units.gridUnit * 300)
            listItem.hovered = true
            tryVerify(function() { return nameSlide.running }, 1000, "the marquee did not start")
            compare(nameSlide.duration, one)
            listItem.hovered = false
            tryVerify(function() { return !nameSlide.running })
            listItem.speedfactor = 2
            listItem.hovered = true
            tryVerify(function() { return nameSlide.running }, 1000, "the marquee did not start")
            verify(Math.abs(nameSlide.duration - 2 * one) <= 1,
                   "factor 2 gives " + nameSlide.duration + " ms against " + one + " at factor 1")
        }

        function test_a_second_pass_comes_in_from_the_rows_right_edge() {
            if (Kirigami.Units.longDuration <= 0) skip("animations are switched off on this machine")
            listItem.speedfactor = 0.1
            listItem.hovered = true
            tryVerify(function() { return nameSlide.running }, 1000, "the marquee did not start")
            tryCompare(nameSlide, "from", trackRect.width, 5000)
            tryVerify(function() { return nameSlide.running }, 1000, "the second pass did not start")
            verify(!trackName.truncated)
        }
    }
}
