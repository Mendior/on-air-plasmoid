/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: root
    property alias cfg_lastplay: middleLastPlay.checked
    property alias cfg_speedfactor: slider.speedFactor
    property alias cfg_defaultVolume: volumeSlider.value
    property alias cfg_fadeEnabled: fadeCheck.checked
    property alias cfg_fadeDuration: fadeDurationSpin.value
    property alias cfg_albumArtEnabled: albumArtCheck.checked
    property alias cfg_blurBackdrop: blurCheck.checked
    property alias cfg_mprisEnabled: mprisCheck.checked
    property alias cfg_autoBitrate: autoBitrateCheck.checked
    property alias cfg_autoHeal: autoHealCheck.checked
    property alias cfg_reportClicks: reportClicksCheck.checked
    property alias cfg_followSystemAccent: accentCheck.checked
    property alias cfg_aiHelperEnabled: aiCheck.checked
    property alias cfg_downloadDir: dirField.text
    property string cfg_downloadFormat


    Kirigami.FormLayout {
        Item {
            Kirigami.FormData.label: i18n("Audio")
            Kirigami.FormData.isSection: true
        }

        ColumnLayout {
            Kirigami.FormData.label: i18n("Default volume:")
            Kirigami.FormData.buddyFor: volumeSlider

            QQC2.Slider {
                id: volumeSlider
                Layout.fillWidth: true
                from: 0
                to: 100
                stepSize: 1
                snapMode: QQC2.Slider.SnapAlways
            }
            QQC2.Label {
                text: Math.round(volumeSlider.value) + "%"
                opacity: 0.7
            }
        }

        QQC2.CheckBox {
            id: fadeCheck
            Kirigami.FormData.label: i18n("Smooth fade:")
            text: i18n("Fade volume when changing stations")
        }

        QQC2.SpinBox {
            id: fadeDurationSpin
            Kirigami.FormData.label: i18n("Fade duration (ms):")
            from: 0
            to: 2000
            stepSize: 50
            enabled: fadeCheck.checked
        }

        QQC2.CheckBox {
            id: autoBitrateCheck
            Kirigami.FormData.label: i18n("Stream quality:")
            text: i18n("Automatically switch to the highest-bitrate variant of a station")

            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.text: i18n("Looks the station up on radio-browser.info and picks the best-quality stream URL")
        }

        QQC2.CheckBox {
            id: autoHealCheck
            text: i18n("Find a station's new address when its stream dies")

            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.text: i18n("Stations move servers; when playback fails, the station is looked up on radio-browser.info and the address it is reachable at now is saved to your list")
        }

        QQC2.CheckBox {
            id: reportClicksCheck
            text: i18n("Count my listening in the worldwide station catalog")

            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.text: i18n("When a station starts playing, an anonymous click is reported to radio-browser.info (station id only, nothing about you) — popular stations become easier to find for everyone")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        Item {
            Kirigami.FormData.label: i18n("Visuals")
            Kirigami.FormData.isSection: true
        }

        QQC2.CheckBox {
            id: albumArtCheck
            Kirigami.FormData.label: i18n("Album art:")
            text: i18n("Look up cover art via iTunes")
        }

        QQC2.CheckBox {
            id: blurCheck
            Kirigami.FormData.label: i18n("Backdrop:")
            text: i18n("Blurred album art behind now playing")
            enabled: albumArtCheck.checked
        }

        QQC2.CheckBox {
            id: accentCheck
            Kirigami.FormData.label: i18n("Accent color:")
            text: i18n("Follow the system accent color instead of the built-in emerald")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        Item {
            Kirigami.FormData.label: i18n("Integration")
            Kirigami.FormData.isSection: true
        }

        QQC2.CheckBox {
            id: mprisCheck
            Kirigami.FormData.label: i18n("System integration:")
            text: i18n("Allow control via media keys (MPRIS)")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        Item {
            Kirigami.FormData.label: i18n("Downloads")
            Kirigami.FormData.isSection: true
        }

        QQC2.ComboBox {
            id: formatCombo
            Kirigami.FormData.label: i18n("Format:")
            model: [
                { value: "best", text: i18n("Best quality (no re-encode)") },
                { value: "mp3",  text: i18n("MP3") },
                { value: "opus", text: i18n("Opus") },
                { value: "mp4",  text: i18n("MP4 (video)") }
            ]
            textRole: "text"
            valueRole: "value"
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(root.cfg_downloadFormat))
            onActivated: root.cfg_downloadFormat = currentValue
        }

        QQC2.TextField {
            id: dirField
            Kirigami.FormData.label: i18n("Save to folder:")
            placeholderText: "~/Music/OnAir"
            Layout.fillWidth: true
        }

        QQC2.CheckBox {
            id: aiCheck
            Kirigami.FormData.label: i18n("Title cleanup:")
            text: i18n("Use Claude CLI to clean up messy titles before download (optional)")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
        }

        Item {
            Kirigami.FormData.label: i18n("Behavior")
            Kirigami.FormData.isSection: true
        }

        ColumnLayout {
            Kirigami.FormData.label: i18n("Marquee speed:")
            Kirigami.FormData.buddyFor: slider

            QQC2.Slider {
                id: slider
                property double speedFactor
                Layout.fillWidth: true
                from: -1.5
                to: 1.5
                stepSize: 0.25
                snapMode: QQC2.Slider.SnapAlways
                value: -(Math.log(speedFactor) / Math.log(2))
                onMoved: {
                    speedFactor = 1.0 / Math.pow(2, value)
                }
            }

            RowLayout {
                QQC2.Label { text: i18n("Slower") }
                Item { Layout.fillWidth: true }
                QQC2.Label { text: i18n("Faster") }
            }
        }

        QQC2.CheckBox {
            id: middleLastPlay
            Kirigami.FormData.label: i18n("Panel click:")
            text: i18n("Middle click to toggle last station")
            enabled: plasmoid.formFactor !== PlasmaCore.Types.Planar

            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.text: i18n("Middle-click the panel icon to play or stop the last station")
        }
    }
}
