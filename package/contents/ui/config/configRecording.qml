/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: root
    property alias cfg_recordMaxMinutes: recMaxSpin.value
    property string cfg_recordFormat

    Kirigami.FormLayout {
        Item {
            Kirigami.FormData.label: i18n("Stream recording")
            Kirigami.FormData.isSection: true
        }

        QQC2.ComboBox {
            id: recFormatCombo
            Kirigami.FormData.label: i18n("Format:")
            model: [
                { value: "original", text: i18n("Original stream (bit-exact copy, recommended)") },
                { value: "mp3",      text: i18n("MP3 (re-encode — max compatibility)") },
                { value: "wav",      text: i18n("WAV (uncompressed — very large files)") }
            ]
            textRole: "text"
            valueRole: "value"
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(root.cfg_recordFormat))
            onActivated: root.cfg_recordFormat = currentValue
        }

        QQC2.Label {
            text: i18n("Radio streams are already compressed — the bit-exact copy IS the maximum quality. Re-encoding (MP3) or unpacking (WAV) can never add quality; choose them only for device compatibility or editing.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        QQC2.SpinBox {
            id: recMaxSpin
            Kirigami.FormData.label: i18n("Max length:")
            from: 10
            to: 24 * 60
            stepSize: 30
            textFromValue: function(v) { return i18n("%1 min", v) }
            valueFromText: function(t) { return parseInt(t) || 180 }
        }

        QQC2.Label {
            text: i18n("A hard safety cap for one recording — protects the disk if you forget to stop.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        Item {
            Kirigami.FormData.label: i18n("Scheduled recordings")
            Kirigami.FormData.isSection: true
        }

        QQC2.Label {
            text: i18n("Schedules are managed in the widget itself: open the popup, press the music-note button in the footer to open My Music, then press the stopwatch button next to \"My Music\". Pick a station, start time, duration and repeat (once / daily / weekly) — the widget records in the background, even while nothing is playing.")
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
            wrapMode: Text.Wrap
        }

        QQC2.Label {
            text: i18n("Recordings are saved to your music folder and are for personal use only — do not redistribute them.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
    }
}
