/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Everything the widget does BY ITSELF, each behind its own switch — the
// automations live here so nobody has to discover a checkbox inside a
// popup to find out why episodes appear (or disappear) on their disk.

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: root

    // A plain property, not an alias: currentValue is read-only, and the
    // dialog host must be able to SET the stored value on load.
    property int cfg_podcastAutoRefreshHours: 12
    property alias cfg_podcastAutoDownload: autoDownload.checked
    property alias cfg_podcastAutoClean: autoClean.checked
    property alias cfg_podcastContinuous: continuous.checked
    property alias cfg_podcastSkipSilence: skipSilence.checked
    property alias cfg_syncAutoCare: autoCare.checked

    Kirigami.Separator {
        Kirigami.FormData.label: i18n("Podcasts")
        Kirigami.FormData.isSection: true
    }

    QQC2.ComboBox {
        id: refreshHours
        Kirigami.FormData.label: i18n("Check the shows for new episodes:")
        textRole: "text"
        valueRole: "value"
        model: [
            { text: i18n("Never"), value: 0 },
            { text: i18n("Every 6 hours"), value: 6 },
            { text: i18n("Every 12 hours"), value: 12 },
            { text: i18n("Once a day"), value: 24 }
        ]
        currentIndex: {
            for (var i = 0; i < model.length; i++)
                if (model[i].value === root.cfg_podcastAutoRefreshHours) return i
            return 2
        }
        onActivated: root.cfg_podcastAutoRefreshHours = currentValue
    }

    QQC2.CheckBox {
        id: autoDownload
        Kirigami.FormData.label: i18n("New episodes:")
        text: i18n("Download the newest one automatically")
    }
    QQC2.Label {
        text: i18n("When a check finds a show has something new, its newest episode is queued for download — ready before the commute, no taps needed.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        wrapMode: Text.WordWrap
        Layout.maximumWidth: Kirigami.Units.gridUnit * 24
    }

    QQC2.CheckBox {
        id: autoClean
        Kirigami.FormData.label: i18n("Storage:")
        text: i18n("Quietly remove old played downloads")
    }
    QQC2.Label {
        text: i18n("Played episodes older than three days go, and past ten files per show the oldest played go. An unheard episode is never touched.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        wrapMode: Text.WordWrap
        Layout.maximumWidth: Kirigami.Units.gridUnit * 24
    }

    QQC2.CheckBox {
        id: continuous
        Kirigami.FormData.label: i18n("Listening:")
        text: i18n("Continue the show when an episode ends")
    }

    QQC2.CheckBox {
        id: skipSilence
        text: i18n("Skip stretches of dead air in episodes")
    }

    Kirigami.Separator {
        Kirigami.FormData.label: i18n("Speaker sync")
        Kirigami.FormData.isSection: true
    }

    QQC2.CheckBox {
        id: autoCare
        Kirigami.FormData.label: i18n("Auto-care:")
        text: i18n("Keep sync tuned automatically")
    }
    QQC2.Label {
        text: i18n("Listens to the playing audio with the microphone every few minutes and re-checks the sync when the speakers drift apart. The check clicks audibly and pauses music for about a minute — the popup shows a Stop button whenever one runs. Audio never leaves this computer.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        wrapMode: Text.WordWrap
        Layout.maximumWidth: Kirigami.Units.gridUnit * 24
    }
}
