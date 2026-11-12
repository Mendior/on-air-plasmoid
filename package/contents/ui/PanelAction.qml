/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// One entry of the panel icon's right-click menu: what it shows is
// TransportLogic.panelAction's answer for the widget's facts, and a click
// takes the road the same control takes everywhere else. The listener who
// only wants the radio to stop does not have to open the popup for it.
import QtQuick
import org.kde.plasma.core as PlasmaCore

import "TransportLogic.js" as TransportLogic

PlasmaCore.Action {
    id: entry

    // "key", "next", "mute" or "sleep".
    property string kind: ""
    // main.qml: bigFace, canPlay, _podPlayingKey, _ownMuted, sleepRemainingSec,
    // _casting, isPlaying(), transport(), _mprisDispatch(), setUserVolume(),
    // targetVolume(), startSleepTimer() and cancelSleepTimer().
    property var app
    // Rows in the station list.
    property int stations: 0

    // Half an hour is the timer's middle preset; the popup has the others.
    readonly property int sleepSeconds: 1800

    readonly property var look: TransportLogic.panelAction(kind, app ? {
        "face": app.bigFace, "canPlay": app.canPlay, "episode": app._podPlayingKey !== "", "stations": stations,
        "muted": app._ownMuted, "sleeping": app.sleepRemainingSec > 0, "sounding": app.isPlaying() || app._casting
    } : null)

    text: {
        switch (look.word) {
        case "play": return i18n("Play");
        case "pause": return i18n("Pause");
        case "stop": return i18n("Stop");
        case "next": return i18n("Next station");
        case "mute": return i18n("Mute");
        case "unmute": return i18n("Unmute");
        case "sleep": return i18n("Sleep in %1 minutes", sleepSeconds / 60);
        case "wake": return i18n("Cancel sleep timer");
        }
        return "";
    }
    icon.name: look.icon
    enabled: look.enabled
    visible: look.shown

    onTriggered: {
        switch (look.word) {
        case "play":
        case "pause":
        case "stop":
            // Whatever the face, the press is the big button's.
            app.transport("PlayPause");
            break;
        case "next":
            app._mprisDispatch("Next");
            break;
        case "mute":
            app.setUserVolume(0);
            break;
        case "unmute":
            app.setUserVolume(app.targetVolume());
            break;
        case "sleep":
            app.startSleepTimer(sleepSeconds);
            break;
        case "wake":
            app.cancelSleepTimer();
            break;
        }
    }
}
