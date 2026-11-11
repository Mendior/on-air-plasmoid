// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The podcast page's "Wake up with this show" popup hangs from a button in
// the right half of the episodes header and opens leftward from it. It is
// wider than the room to the button's left: measured on a copy at a grid
// unit of 18, its left edge sat at -38 px on the default 21 gu popup and at
// -128 px on the 16 gu floor, where the hour box was outside the window.
// This hosts the same header and the same popup and asks where they land.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtTest
import org.kde.kirigami as Kirigami

Item {
    id: fullRepresentation
    width: Kirigami.Units.gridUnit * 21
    height: Kirigami.Units.gridUnit * 20

    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Kirigami.Units.smallSpacing
        // Back, the show's title, the alarm button, then filter and subscribe.
        Item { implicitWidth: Kirigami.Units.gridUnit * 2.4; implicitHeight: implicitWidth }
        QQC2.Label { Layout.fillWidth: true; text: "A show"; elide: Text.ElideRight }
        Item {
            id: podAlarmBtn
            implicitWidth: Kirigami.Units.gridUnit * 2.4
            implicitHeight: implicitWidth
        }
        QQC2.Popup {
            id: podAlarmPopup
            parent: podAlarmBtn
            y: podAlarmBtn.height + Kirigami.Units.smallSpacing
            x: -width + podAlarmBtn.width
            margins: Kirigami.Units.smallSpacing
            width: Math.min(implicitWidth, fullRepresentation.width - 2 * Kirigami.Units.smallSpacing)
            padding: Kirigami.Units.largeSpacing
            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    text: "Wake up with this show, daily"
                    font.weight: Font.DemiBold
                }
                RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.SpinBox {
                        id: podAlarmHH
                        from: 0; to: 23; value: 7; Layout.fillWidth: true; Layout.maximumWidth: implicitWidth
                    }
                    QQC2.Label { text: ":" }
                    QQC2.SpinBox {
                        id: podAlarmMM
                        from: 0; to: 55; value: 0; stepSize: 5; Layout.fillWidth: true; Layout.maximumWidth: implicitWidth
                    }
                    QQC2.Button { id: podAlarmSet; text: "Set" }
                }
                QQC2.Label {
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                    text: "Plays the newest unheard downloaded episode — works with no network at all."
                    wrapMode: Text.WordWrap
                }
            }
        }
        Item { implicitWidth: Kirigami.Units.gridUnit * 2.4; implicitHeight: implicitWidth }
        Item { implicitWidth: Kirigami.Units.gridUnit * 2.4; implicitHeight: implicitWidth }
    }

    TestCase {
        name: "AlarmPopup"
        when: windowShown

        function cleanup() {
            podAlarmPopup.close()
            tryVerify(function() { return !podAlarmPopup.visible })
        }

        function sceneLeft(item) { return item.mapToItem(null, 0, 0).x }
        function sceneRight(item) { return item.mapToItem(null, item.width, 0).x }

        function test_the_popup_opens_inside_the_window_data() {
            return [
                { tag: "the 16 gu floor", gu: 16 },
                { tag: "the default 21 gu", gu: 21 },
                { tag: "a wide desktop face", gu: 40 }
            ]
        }
        function test_the_popup_opens_inside_the_window(data) {
            fullRepresentation.width = Kirigami.Units.gridUnit * data.gu
            podAlarmPopup.open()
            tryVerify(function() { return podAlarmPopup.opened })
            var frame = podAlarmPopup.contentItem.parent
            verify(sceneLeft(frame) >= 0,
                   "the popup's left edge is at " + sceneLeft(frame))
            verify(sceneRight(frame) <= fullRepresentation.width,
                   "the popup's right edge is at " + sceneRight(frame)
                   + " in a window of " + fullRepresentation.width)
            verify(sceneLeft(podAlarmHH) >= 0,
                   "the hour box starts at " + sceneLeft(podAlarmHH))
            verify(sceneRight(podAlarmSet) <= sceneRight(frame),
                   "Set ends at " + sceneRight(podAlarmSet)
                   + ", past the popup's own edge at " + sceneRight(frame))
        }
    }
}
