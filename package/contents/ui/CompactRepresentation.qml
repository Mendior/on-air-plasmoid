import QtMultimedia
/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

MouseArea {
    id: panelIconWidget

    property int wheelDelta: 0

    function setToolTip() {
        if (isPlaying() && root.title !== Plasmoid.title) {
            tooltip.mainText = root.title;
            tooltip.subText = Plasmoid.title;
        } else {
            tooltip.mainText = Plasmoid.title;
            tooltip.subText = Plasmoid.metaData.description;
        }
        tooltip.icon = "";
    }

    function setVolumeIcon(volume) {
        let suffix;
        if (volume <= 0)
            suffix = "-muted";
        else if (volume <= 0.33)
            suffix = "-low";
        else if (volume <= 0.66)
            suffix = "-medium";
        else
            suffix = "-high";
        return "audio-volume" + suffix;
    }

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    onClicked: (mouse) => {
        if (mouse.button === Qt.MiddleButton) {
            if (Plasmoid.configuration.lastplay)
                refreshServer(lastPlay);

        } else {
            root.expanded = !root.expanded;
        }
    }
    onWheel: (wheel) => {
        volumeTimer.restart();
        const delta = wheel.angleDelta.y || wheel.angleDelta.x;
        wheelDelta += delta;
        while (wheelDelta >= 120) {
            wheelDelta -= 120;
            playMusicOutput.volume = Math.min(1.0, playMusicOutput.volume + 0.05);
        }
        while (wheelDelta <= -120) {
            wheelDelta += 120;
            playMusicOutput.volume = Math.max(0.0, playMusicOutput.volume - 0.05);
        }
        tooltip.mainText = playMusicOutput.volume === 0 ? i18n("Audio") : i18n("Volume");
        tooltip.subText = playMusicOutput.volume === 0 ? i18n("Muted") : Math.round(playMusicOutput.volume * 100) + "%";
        tooltip.icon = setVolumeIcon(playMusicOutput.volume);
    }
    onEntered: {
        tooltip.showToolTip();
    }

    Kirigami.Icon {
        source: Plasmoid.configuration.icon
        fallback: Plasmoid.configuration.iconFallback
        anchors.fill: parent
        isMask: true
        color: isPlaying() ? root.accent : Kirigami.Theme.textColor

        Behavior on color { ColorAnimation { duration: 400 } }
    }

    // 2026: mini-equalizer in the corner of the panel icon while music is playing
    EqBars {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 1
        visible: isPlaying()
        bars: 3
        barWidth: Math.max(2, Math.round(parent.width * 0.07))
        minHeight: Math.max(2, parent.height * 0.1)
        maxHeight: parent.height * 0.38
        baseDuration: 300
        barColor: root.accentBright
    }

    // Pulsing red dot while a recording is running — visible even when the
    // popup is closed, so a recording is never forgotten.
    Rectangle {
        id: recDot
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 1
        width: Math.max(4, Math.round(parent.width * 0.22))
        height: width
        radius: width / 2
        color: "#E0463C"
        visible: root.recording

        SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: recDot.visible
            NumberAnimation { from: 1.0; to: 0.35; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.35; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
        }
    }

    PlasmaCore.ToolTipArea {
        id: tooltip

        anchors.horizontalCenter: parent.horizontalCenter
        onAboutToShow: {
            setToolTip();
        }
    }

    Timer {
        id: volumeTimer

        running: false
        repeat: false
        interval: Kirigami.Units.humanMoment
        onTriggered: {
            setToolTip();
        }
    }

}
