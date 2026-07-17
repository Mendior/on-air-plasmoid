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

    // Every key in main.xml is pushed onto EVERY config page as cfg_<key>
    // and cfg_<key>Default initial properties — a page that does not
    // declare them sprays "Setting initial properties failed" into the
    // journal on each dialog open. Declared inert below; only the wired
    // properties above actually drive this page.
    property var cfg_servers
    property var cfg_serversDefault
    property var cfg_speedfactor
    property var cfg_speedfactorDefault
    property var cfg_lastplay
    property var cfg_lastplayDefault
    property var cfg_icon
    property var cfg_iconDefault
    property var cfg_iconFallback
    property var cfg_iconFallbackDefault
    property var cfg_defaultVolume
    property var cfg_defaultVolumeDefault
    property var cfg_fadeEnabled
    property var cfg_fadeEnabledDefault
    property var cfg_fadeDuration
    property var cfg_fadeDurationDefault
    property var cfg_albumArtEnabled
    property var cfg_albumArtEnabledDefault
    property var cfg_blurBackdrop
    property var cfg_blurBackdropDefault
    property var cfg_favorites
    property var cfg_favoritesDefault
    property var cfg_mprisEnabled
    property var cfg_mprisEnabledDefault
    property var cfg_autoBitrate
    property var cfg_autoBitrateDefault
    property var cfg_syncOffsetMap
    property var cfg_syncOffsetMapDefault
    property var cfg_searchHistory
    property var cfg_searchHistoryDefault
    property var cfg_syncVerifiedMs
    property var cfg_syncVerifiedMsDefault
    property var cfg_deviceTrims
    property var cfg_deviceTrimsDefault
    property var cfg_deviceChannels
    property var cfg_deviceChannelsDefault
    property var cfg_syncExcluded
    property var cfg_syncExcludedDefault
    property var cfg_syncOffsetMs
    property var cfg_syncOffsetMsDefault
    property var cfg_combinePrevOutput
    property var cfg_combinePrevOutputDefault
    property var cfg_combinePrevDefault
    property var cfg_combinePrevDefaultDefault
    property var cfg_autoHeal
    property var cfg_autoHealDefault
    property var cfg_downloadFormat
    property var cfg_downloadFormatDefault
    property var cfg_history
    property var cfg_historyDefault
    property var cfg_likedSongs
    property var cfg_likedSongsDefault
    property var cfg_reportClicks
    property var cfg_reportClicksDefault
    property var cfg_downloadDir
    property var cfg_downloadDirDefault
    property var cfg_aiHelperEnabled
    property var cfg_aiHelperEnabledDefault
    property var cfg_followSystemAccent
    property var cfg_followSystemAccentDefault
    property var cfg_recordMaxMinutesDefault
    property var cfg_recordFormatDefault
    property var cfg_recSchedules
    property var cfg_recSchedulesDefault
    property var cfg_alarms
    property var cfg_alarmsDefault
    property var cfg_audioOutputDevice
    property var cfg_audioOutputDeviceDefault

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
