/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import Qt.labs.folderlistmodel
import QtMultimedia
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Effects
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

PlasmaExtras.Representation {
    id: fullRepresentation

    readonly property var appletInterface: Plasmoid.self

    Layout.minimumWidth: Kirigami.Units.gridUnit * 16
    Layout.minimumHeight: Kirigami.Units.gridUnit * 20
    Layout.maximumWidth: Kirigami.Units.gridUnit * 32
    Layout.maximumHeight: Kirigami.Units.gridUnit * 36
    Layout.preferredHeight: Layout.minimumHeight
    collapseMarginsHint: true

    readonly property string _bestArtUrl: {
        if (root.albumArtUrl) return root.albumArtUrl
        if (root.imageurl) return root.imageurl
        if (root.currentStationFavicon) return root.currentStationFavicon
        return ""
    }

    readonly property bool _streamActive: isPlaying()
                                          && (playMusic.mediaStatus === MediaPlayer.BufferedMedia
                                              || playMusic.mediaStatus === MediaPlayer.BufferingMedia)

    readonly property int _nowBitrate: {
        if (!_streamActive) return 0
        var br = playMusic.metaData.value(MediaMetaData.AudioBitRate)
        return br && br > 0 ? Math.round(br / 1000) : 0
    }

    // ── Global search: radio-browser.info catalog (~50,000 stations) ────
    // Type a country name ("Finland") → the country's most popular stations;
    // any other text → search by name. Results appear at the end of the list.
    property bool webSearching: false
    property int _webSearchSeq: 0
    readonly property var _countryMap: ({
        "soome": "FI", "finland": "FI",
        "eesti": "EE", "estonia": "EE",
        "rootsi": "SE", "sweden": "SE",
        "norra": "NO", "norway": "NO",
        "läti": "LV", "latvia": "LV",
        "leedu": "LT", "lithuania": "LT",
        "saksamaa": "DE", "germany": "DE",
        "inglismaa": "GB", "suurbritannia": "GB", "uk": "GB",
        "iirimaa": "IE", "usa": "US", "ameerika": "US",
        "venemaa": "RU", "russia": "RU",
        "prantsusmaa": "FR", "france": "FR",
        "hispaania": "ES", "spain": "ES",
        "itaalia": "IT", "italy": "IT",
        "taani": "DK", "denmark": "DK",
        "poola": "PL", "poland": "PL",
        "holland": "NL", "madalmaad": "NL",
        "ukraina": "UA", "ungari": "HU",
        "šveits": "CH", "austria": "AT",
        "jaapan": "JP", "hiina": "CN",
        "kanada": "CA", "austraalia": "AU",
        "brasiilia": "BR", "türgi": "TR"
    })

    function runWebSearch(q) {
        q = (q || "").trim()
        webResultsModel.clear()
        const seq = ++fullRepresentation._webSearchSeq
        if (q.length < 3) {
            fullRepresentation.webSearching = false
            return
        }
        fullRepresentation.webSearching = true
        _webSearchAttempt(q, seq, 0)
    }

    // Try the API mirrors IN SEQUENCE — some mirrors are occasionally down, and
    // a single random pick made the search unreliable ("works sometimes").
    function _webSearchAttempt(q, seq, serverIdx) {
        const apiServers = ["de1", "nl1", "de2", "at1", "fi1"]
        if (serverIdx >= apiServers.length) {
            if (seq === fullRepresentation._webSearchSeq)
                fullRepresentation.webSearching = false
            return
        }
        const cc = _countryMap[q.toLowerCase()] || ""
        const qs = cc !== ""
            ? "search?countrycode=" + cc
            : "search?name=" + encodeURIComponent(q)
        const xhr = new XMLHttpRequest()
        var guard = null
        xhr.open("GET", "https://" + apiServers[serverIdx] + ".api.radio-browser.info/json/stations/"
                 + qs + "&hidebroken=true&order=votes&reverse=true&limit=50")
        xhr.setRequestHeader("User-Agent", "OnAir/2026.1")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return
            root._clearXhrTimeout(guard)
            if (seq !== fullRepresentation._webSearchSeq) return // stale request
            if (xhr.status !== 200) {
                // This mirror is down → try the next one right away
                _webSearchAttempt(q, seq, serverIdx + 1)
                return
            }
            fullRepresentation.webSearching = false
            try {
                const results = JSON.parse(xhr.responseText) || []
                const existing = {}
                for (var i = 0; i < stationsModel.count; i++)
                    existing[stationsModel.get(i).hostname] = true
                const seen = {}
                for (const r of results) {
                    const u = (r.url_resolved || r.url || "").toString()
                    if (!u || existing[u] || seen[u]) continue
                    seen[u] = true
                    var br = parseInt(r.bitrate) || 0
                    if (br > 1000) br = Math.round(br / 1000)
                    webResultsModel.append({
                        "name": (r.name || "").replace(/\s+/g, " ").trim() || u,
                        "url": u,
                        "favicon": r.favicon || "",
                        "country": r.country || "",
                        "bitrate": br,
                        "codec": (r.codec || "").toUpperCase()
                    })
                    if (webResultsModel.count >= 30) break
                }
            } catch (e) {
                console.log("[ARP] webSearch parse: " + e)
                _webSearchAttempt(q, seq, serverIdx + 1)
            }
        }
        guard = root._armXhrTimeout(xhr, 4000)
        xhr.send()
    }

    Timer {
        id: webSearchDebounce
        interval: 600
        repeat: false
        onTriggered: runWebSearch(root.searchFilter)
    }

    ListModel {
        id: webResultsModel
    }

    // ── 2026 aurora background: two slowly drifting light blobs ──────────
    // NB: all animations are paused when the popup is closed (root.expanded) —
    // otherwise plasmashell would burn CPU 24/7 (a standard KDE reviewer requirement).
    Item {
        id: aurora
        anchors.fill: parent
        clip: true
        opacity: fullRepresentation._streamActive ? 0.7 : 0.42
        Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.InOutQuad } }

        Canvas {
            id: blobA
            width: Kirigami.Units.gridUnit * 16
            height: width
            x: -width * 0.3
            y: -height * 0.25
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var g = ctx.createRadialGradient(width / 2, height / 2, 0, width / 2, height / 2, width / 2)
                g.addColorStop(0, "rgba(111, 207, 151, 0.30)")
                g.addColorStop(0.55, "rgba(111, 207, 151, 0.10)")
                g.addColorStop(1, "rgba(111, 207, 151, 0)")
                ctx.fillStyle = g
                ctx.fillRect(0, 0, width, height)
            }

            SequentialAnimation on x {
                loops: Animation.Infinite
                paused: running && !root.expanded
                NumberAnimation { to: fullRepresentation.width * 0.35; duration: 26000; easing.type: Easing.InOutSine }
                NumberAnimation { to: -blobA.width * 0.3; duration: 26000; easing.type: Easing.InOutSine }
            }
            SequentialAnimation on y {
                loops: Animation.Infinite
                paused: running && !root.expanded
                NumberAnimation { to: fullRepresentation.height * 0.2; duration: 19000; easing.type: Easing.InOutSine }
                NumberAnimation { to: -blobA.height * 0.25; duration: 19000; easing.type: Easing.InOutSine }
            }
        }

        Canvas {
            id: blobB
            width: Kirigami.Units.gridUnit * 13
            height: width
            x: fullRepresentation.width - width * 0.4
            y: fullRepresentation.height - height * 0.35
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var g = ctx.createRadialGradient(width / 2, height / 2, 0, width / 2, height / 2, width / 2)
                g.addColorStop(0, "rgba(43, 179, 163, 0.26)")
                g.addColorStop(0.55, "rgba(43, 179, 163, 0.09)")
                g.addColorStop(1, "rgba(43, 179, 163, 0)")
                ctx.fillStyle = g
                ctx.fillRect(0, 0, width, height)
            }

            SequentialAnimation on x {
                loops: Animation.Infinite
                paused: running && !root.expanded
                NumberAnimation { to: fullRepresentation.width * 0.1; duration: 31000; easing.type: Easing.InOutSine }
                NumberAnimation { to: fullRepresentation.width - blobB.width * 0.4; duration: 31000; easing.type: Easing.InOutSine }
            }
            SequentialAnimation on y {
                loops: Animation.Infinite
                paused: running && !root.expanded
                NumberAnimation { to: fullRepresentation.height * 0.35; duration: 23000; easing.type: Easing.InOutSine }
                NumberAnimation { to: fullRepresentation.height - blobB.height * 0.35; duration: 23000; easing.type: Easing.InOutSine }
            }
        }
    }

    Image {
        id: backdropImage
        anchors.fill: parent
        source: fullRepresentation._bestArtUrl
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: false
    }

    MultiEffect {
        anchors.fill: parent
        source: backdropImage
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        brightness: -0.25
        saturation: 0.2
        opacity: backdropImage.status === Image.Ready
                 && Plasmoid.configuration.blurBackdrop
                 && root.view === 1 ? 0.55 : 0.0

        Behavior on opacity {
            NumberAnimation { duration: Kirigami.Units.veryLongDuration; easing.type: Easing.InOutQuad }
        }
    }

    PlasmaComponents3.SwipeView {
        id: swipeView

        anchors.fill: parent
        clip: true

        // Two-way sync with root.view — a declarative binding would break permanently
        // on the first user swipe (imperative currentIndex write).
        Component.onCompleted: currentIndex = root.view
        onCurrentIndexChanged: {
            if (root.view !== currentIndex) root.view = currentIndex
        }
        Connections {
            target: root
            function onViewChanged() {
                if (swipeView.currentIndex !== root.view) swipeView.currentIndex = root.view
            }
        }

        // ── PAGE 1: station list ─────────────────────────────────────────
        ColumnLayout {
            id: listPage
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Kirigami.SearchField {
                    id: filterField
                    Layout.fillWidth: true
                    autoAccept: true
                    onTextChanged: root.searchFilter = text
                    placeholderText: i18n("Search station or country… (e.g. Finland, jazz)")
                    Keys.onDownPressed: stationView.forceActiveFocus()
                    Keys.onReturnPressed: {
                        if (stationView.count > 0) {
                            stationView.currentIndex = 0
                            stationView.forceActiveFocus()
                        }
                    }
                }

                CircleButton {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 2.4
                    implicitHeight: implicitWidth
                    iconName: root.favoritesOnly ? "favorite" : "non-starred-symbolic"
                    iconScale: 0.55
                    checked: root.favoritesOnly
                    tooltipText: root.favoritesOnly ? i18n("Show all stations") : i18n("Show only favorites")
                    onClicked: root.favoritesOnly = !root.favoritesOnly
                }
            }

            PlasmaComponents3.ScrollView {
                id: scrollView
                Layout.fillWidth: true
                Layout.fillHeight: true
                topPadding: Kirigami.Units.smallSpacing
                bottomPadding: Kirigami.Units.smallSpacing
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff
                PlasmaComponents3.ScrollBar.vertical.policy: Plasmoid.userBackgroundHints !== PlasmaCore.Types.ShadowBackground
                                                             || Plasmoid.formFactor !== PlasmaCore.Types.Planar
                                                             ? PlasmaComponents3.ScrollBar.AsNeeded
                                                             : PlasmaComponents3.ScrollBar.AlwaysOff

                contentItem: ListView {
                    id: stationView

                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    model: filteredStationsModel
                    enabled: isConnected
                    focus: true
                    currentIndex: 0
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    spacing: 2
                    keyNavigationEnabled: true
                    highlightMoveDuration: 150
                    highlightMoveVelocity: -1

                    Keys.onReturnPressed: {
                        if (currentIndex >= 0 && currentItem) {
                            isError = false
                            errorTimer.stop()
                            lastPlay = currentItem.targetIndex
                            refreshServer(currentItem.targetIndex)
                        }
                    }
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Slash) {
                            filterField.forceActiveFocus()
                            event.accepted = true
                        }
                    }

                    // 2026: rows entering in a cascade
                    populate: Transition {
                        id: popTrans
                        SequentialAnimation {
                            PropertyAction { property: "opacity"; value: 0 }
                            PauseAnimation { duration: Math.min(popTrans.ViewTransition.index, 14) * 26 }
                            ParallelAnimation {
                                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
                                NumberAnimation { property: "y"; from: popTrans.ViewTransition.destination.y + Kirigami.Units.gridUnit; to: popTrans.ViewTransition.destination.y; duration: 260; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                    add: Transition {
                        id: addTrans
                        SequentialAnimation {
                            PropertyAction { property: "opacity"; value: 0 }
                            PauseAnimation { duration: Math.min(addTrans.ViewTransition.index, 10) * 20 }
                            ParallelAnimation {
                                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
                                NumberAnimation { property: "y"; from: addTrans.ViewTransition.destination.y + Kirigami.Units.smallSpacing * 2; to: addTrans.ViewTransition.destination.y; duration: 200; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                    displaced: Transition {
                        NumberAnimation { properties: "y"; duration: Kirigami.Units.shortDuration }
                        NumberAnimation { properties: "opacity"; to: 1; duration: Kirigami.Units.shortDuration }
                    }

                    Connections {
                        function onErrorOccurred() {
                            stationView.currentIndex = -1
                        }
                        target: playMusic
                    }

                    delegate: MediaListItem {
                    }

                    // ── Global search results at the end of the list ─────────
                    footer: Column {
                        width: stationView.width - stationView.leftMargin - stationView.rightMargin
                        spacing: 2
                        visible: webResultsModel.count > 0 || fullRepresentation.webSearching
                        height: visible ? implicitHeight : 0

                        Item { width: 1; height: Kirigami.Units.smallSpacing }

                        Row {
                            spacing: Kirigami.Units.smallSpacing
                            leftPadding: Kirigami.Units.smallSpacing

                            Kirigami.Icon {
                                source: "globe"
                                width: Kirigami.Units.iconSizes.small
                                height: width
                                color: root.accent
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            PlasmaComponents3.Label {
                                anchors.verticalCenter: parent.verticalCenter
                                text: fullRepresentation.webSearching
                                      ? i18n("Searching the web…")
                                      : i18n("From the web") + " (" + webResultsModel.count + ")"
                                font.weight: Font.DemiBold
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                color: root.accent
                                opacity: 0.9
                            }
                            PlasmaComponents3.BusyIndicator {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Kirigami.Units.iconSizes.small
                                height: width
                                running: fullRepresentation.webSearching
                                visible: running
                            }
                        }

                        Repeater {
                            model: webResultsModel

                            delegate: Item {
                                id: webItem
                                required property var model
                                required property int index
                                readonly property bool isPreviewing: root._previewUrl === model.url && isPlaying()
                                width: parent.width
                                height: Kirigami.Units.gridUnit * 3

                                Rectangle {
                                    id: webBg
                                    anchors.fill: parent
                                    anchors.margins: Kirigami.Units.smallSpacing / 2
                                    radius: Kirigami.Units.smallSpacing * 1.5
                                    color: webHover.hovered
                                           ? Qt.alpha(root.accent, 0.09)
                                           : Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                    border.width: 1
                                    border.color: webHover.hovered
                                                  ? Qt.alpha(root.accent, 0.35)
                                                  : Qt.alpha(Kirigami.Theme.textColor, 0.05)

                                    Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
                                    Behavior on border.color { ColorAnimation { duration: Kirigami.Units.shortDuration } }

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
                                        anchors.rightMargin: Kirigami.Units.smallSpacing * 1.5
                                        spacing: Kirigami.Units.smallSpacing * 1.5

                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Kirigami.Units.gridUnit * 2
                                            height: width
                                            radius: width * 0.32
                                            color: Qt.alpha(root.accentTeal, 0.15)
                                            border.width: 1
                                            border.color: Qt.alpha(root.accentTeal, 0.3)
                                            clip: true

                                            Image {
                                                anchors.fill: parent
                                                anchors.margins: 1
                                                source: webItem.model.favicon || ""
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                smooth: true
                                                visible: status === Image.Ready
                                            }
                                            Kirigami.Icon {
                                                anchors.centerIn: parent
                                                width: parent.width * 0.5
                                                height: width
                                                source: "globe"
                                                color: root.accentTeal
                                                visible: !parent.children[0].visible
                                            }
                                        }

                                        Column {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - Kirigami.Units.gridUnit * 6.5
                                            spacing: 1

                                            PlasmaComponents3.Label {
                                                width: parent.width
                                                text: webItem.model.name
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                            }
                                            PlasmaComponents3.Label {
                                                width: parent.width
                                                text: {
                                                    var bits = []
                                                    if (webItem.model.country) bits.push(webItem.model.country)
                                                    if (webItem.model.bitrate > 0) bits.push(webItem.model.bitrate + " kb/s")
                                                    if (webItem.model.codec) bits.push(webItem.model.codec)
                                                    return bits.join(" · ")
                                                }
                                                visible: text !== ""
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                                opacity: 0.55
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                            }
                                        }

                                        EqBars {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: webItem.isPreviewing
                                            animating: visible && root.expanded
                                            bars: 3
                                            barWidth: 3
                                            minHeight: 4
                                            maxHeight: Kirigami.Units.gridUnit
                                            barColor: root.accentBright
                                        }

                                        Kirigami.Icon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Kirigami.Units.iconSizes.smallMedium
                                            height: width
                                            source: webItem.isPreviewing ? "media-playback-stop" : "media-playback-start"
                                            color: webHover.hovered ? root.accentBright : Kirigami.Theme.textColor
                                            opacity: webHover.hovered || webItem.isPreviewing ? 1.0 : 0.45
                                            visible: !webItem.isPreviewing || webHover.hovered
                                        }
                                    }
                                }

                                // ⭐ = add PERMANENTLY to my stations + favorites
                                CircleButton {
                                    anchors.right: parent.right
                                    anchors.rightMargin: Kirigami.Units.smallSpacing * 1.5
                                    anchors.verticalCenter: parent.verticalCenter
                                    implicitWidth: Kirigami.Units.gridUnit * 1.8
                                    implicitHeight: implicitWidth
                                    iconName: "non-starred-symbolic"
                                    iconScale: 0.55
                                    opacity: webHover.hovered ? 1.0 : 0.55
                                    tooltipText: i18n("Add to my stations + favorites")
                                    onClicked: {
                                        root.addStationToList(webItem.model.name, webItem.model.url, webItem.model.favicon, true)
                                        webResultsModel.remove(webItem.index)
                                    }
                                }

                                HoverHandler { id: webHover }
                                TapHandler {
                                    onTapped: root.previewStation(webItem.model.name, webItem.model.url, webItem.model.favicon)
                                }

                                PlasmaCore.ToolTipArea {
                                    anchors.fill: parent
                                    mainText: webItem.isPreviewing
                                              ? i18n("Click = stop preview")
                                              : i18n("Click = preview · ⭐ = add to my stations")
                                }
                            }
                        }

                        Item { width: 1; height: Kirigami.Units.smallSpacing }
                    }

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.largeSpacing * 2
                        visible: stationView.count === 0 && webResultsModel.count === 0 && !fullRepresentation.webSearching
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            source: root.favoritesOnly ? "favorite" : "search"
                            width: Kirigami.Units.iconSizes.huge
                            height: width
                            opacity: 0.4
                        }
                        PlasmaComponents3.Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            horizontalAlignment: Text.AlignHCenter
                            text: root.favoritesOnly
                                  ? i18n("No favorite stations yet")
                                  : (root.searchFilter !== "" ? i18n("No matching stations") : i18n("No stations"))
                            font.weight: Font.DemiBold
                            opacity: 0.7
                        }
                        PlasmaComponents3.Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                            wrapMode: Text.Wrap
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: 0.55
                            visible: text !== ""
                            text: root.favoritesOnly
                                  ? i18n("Tap the heart on a station to add it here")
                                  : (root.searchFilter !== "" ? i18n("Try a different search term") : "")
                        }
                    }
                }
            }
        }

        // ── PAGE 2: now playing ──────────────────────────────────────────
        ColumnLayout {
            id: nowPlayingPage
            spacing: Kirigami.Units.smallSpacing

            Item { Layout.preferredHeight: Kirigami.Units.smallSpacing; Layout.fillWidth: true }

            Item {
                id: artContainer
                Layout.alignment: Qt.AlignHCenter
                // Slightly smaller than before, so the favorite button doesn't get
                // clipped off the bottom by the popup's fixed height (popupHeight).
                Layout.preferredWidth: Math.min(fullRepresentation.width - Kirigami.Units.largeSpacing * 4, Kirigami.Units.gridUnit * 10.5)
                Layout.preferredHeight: Layout.preferredWidth

                // Soft emerald glow behind the cover art
                Rectangle {
                    id: artGlowSrc
                    anchors.fill: parent
                    anchors.margins: -Kirigami.Units.smallSpacing
                    radius: Kirigami.Units.smallSpacing * 3
                    color: Qt.alpha(root.accent, 0.45)
                    visible: false
                }
                MultiEffect {
                    anchors.fill: artGlowSrc
                    source: artGlowSrc
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 48
                    opacity: fullRepresentation._streamActive ? 0.6 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
                }

                Rectangle {
                    id: artFrame
                    anchors.fill: parent
                    radius: Kirigami.Units.smallSpacing * 2
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.06)
                    border.width: 1
                    border.color: Qt.alpha(Kirigami.Theme.textColor, 0.1)
                    clip: true
                    // Breathing effect while playing (only with the popup open)
                    SequentialAnimation on scale {
                        loops: Animation.Infinite
                        running: fullRepresentation._streamActive && root.view === 1 && root.expanded
                        NumberAnimation { from: 1.0; to: 1.011; duration: 2600; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.011; to: 1.0; duration: 2600; easing.type: Easing.InOutSine }
                    }

                    Image {
                        id: artImage
                        anchors.fill: parent
                        anchors.margins: 1
                        source: fullRepresentation._bestArtUrl
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                        smooth: true

                        Behavior on opacity { NumberAnimation { duration: Kirigami.Units.longDuration } }
                    }

                    // 2026: spinning vinyl when there's no cover art
                    Item {
                        id: vinyl
                        anchors.centerIn: parent
                        width: parent.width * 0.78
                        height: width
                        visible: artImage.status !== Image.Ready && root.currentStation !== ""

                        RotationAnimator on rotation {
                            from: 0
                            to: 360
                            duration: 9000
                            loops: Animation.Infinite
                            running: vinyl.visible && fullRepresentation._streamActive && root.view === 1 && root.expanded
                        }

                        Canvas {
                            anchors.fill: parent
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.reset()
                                var c = width / 2
                                // Record
                                ctx.beginPath()
                                ctx.arc(c, c, c - 1, 0, Math.PI * 2)
                                ctx.fillStyle = "#151515"
                                ctx.fill()
                                // Grooves
                                ctx.strokeStyle = "rgba(255,255,255,0.07)"
                                ctx.lineWidth = 1
                                for (var r = c * 0.45; r < c * 0.94; r += c * 0.055) {
                                    ctx.beginPath()
                                    ctx.arc(c, c, r, 0, Math.PI * 2)
                                    ctx.stroke()
                                }
                                // Light glint
                                var g = ctx.createLinearGradient(0, 0, width, height)
                                g.addColorStop(0, "rgba(111,207,151,0.14)")
                                g.addColorStop(0.5, "rgba(111,207,151,0)")
                                g.addColorStop(1, "rgba(43,179,163,0.10)")
                                ctx.beginPath()
                                ctx.arc(c, c, c - 1, 0, Math.PI * 2)
                                ctx.fillStyle = g
                                ctx.fill()
                                // Center hole
                                ctx.beginPath()
                                ctx.arc(c, c, c * 0.3, 0, Math.PI * 2)
                                ctx.fillStyle = "#1f1f1f"
                                ctx.fill()
                                ctx.beginPath()
                                ctx.arc(c, c, c * 0.045, 0, Math.PI * 2)
                                ctx.fillStyle = "#0a0a0a"
                                ctx.fill()
                            }
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width * 0.56
                            height: width
                            radius: width / 2
                            color: "transparent"
                            clip: true
                            Image {
                                anchors.fill: parent
                                source: root.currentStationFavicon || ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                smooth: true
                                visible: status === Image.Ready
                                layer.enabled: true
                                layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: ShaderEffectSource {
                                        sourceItem: Rectangle {
                                            width: 64; height: 64; radius: 32; color: "white"
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        width: parent.width * 0.4
                        height: parent.height * 0.4
                        source: "radio"
                        opacity: 0.45
                        visible: artImage.status !== Image.Ready && !vinyl.visible
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Kirigami.Units.gridUnit * 3.5
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 1.0; color: Qt.alpha("black", 0.7) }
                        }
                        visible: artImage.status === Image.Ready && playingEq.visible
                    }

                    EqBars {
                        id: playingEq
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Kirigami.Units.smallSpacing * 1.5
                        visible: fullRepresentation._streamActive
                        animating: visible && root.expanded
                        bars: 4
                        barWidth: 4
                        minHeight: 6
                        maxHeight: Kirigami.Units.gridUnit
                        barColor: artImage.status === Image.Ready ? "white" : root.accentBright
                    }
                }
            }

            // LIVE + bitrate pills
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: fullRepresentation._streamActive

                Rectangle {
                    implicitHeight: liveRow.implicitHeight + Kirigami.Units.smallSpacing
                    implicitWidth: liveRow.implicitWidth + Kirigami.Units.largeSpacing
                    radius: height / 2
                    color: Qt.alpha("#e0463c", 0.16)
                    border.width: 1
                    border.color: Qt.alpha("#e0463c", 0.4)

                    RowLayout {
                        id: liveRow
                        anchors.centerIn: parent
                        spacing: Kirigami.Units.smallSpacing / 1.5

                        Rectangle {
                            id: liveDot
                            width: 7
                            height: 7
                            radius: 3.5
                            color: "#ff5c52"
                            SequentialAnimation on opacity {
                                loops: Animation.Infinite
                                running: fullRepresentation._streamActive && root.view === 1 && root.expanded
                                NumberAnimation { from: 1.0; to: 0.25; duration: 800; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 0.25; to: 1.0; duration: 800; easing.type: Easing.InOutSine }
                            }
                        }
                        PlasmaComponents3.Label {
                            text: i18n("LIVE")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.weight: Font.Bold
                            font.letterSpacing: 1.2
                            color: "#ff8a80"
                        }
                    }
                }

                Rectangle {
                    visible: fullRepresentation._nowBitrate > 0
                    implicitHeight: brLabel.implicitHeight + Kirigami.Units.smallSpacing
                    implicitWidth: brLabel.implicitWidth + Kirigami.Units.largeSpacing
                    radius: height / 2
                    color: Qt.alpha(root.accent, 0.12)
                    border.width: 1
                    border.color: Qt.alpha(root.accent, 0.4)

                    PlasmaComponents3.Label {
                        id: brLabel
                        anchors.centerIn: parent
                        text: fullRepresentation._nowBitrate + " kb/s"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        color: root.accentBright
                    }
                }
            }

            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing / 2
                spacing: Kirigami.Units.smallSpacing / 2

                PlasmaComponents3.Label {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.currentStation
                    visible: text !== ""
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.1
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                Kirigami.Heading {
                    id: titleHeading
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    level: 2
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                    text: {
                        if (root.trackTitle) return root.trackTitle
                        if (root.currentStation) return root.currentStation
                        return ""
                    }
                    transform: Translate { id: titleShift; y: 0 }
                    onTextChanged: titleReveal.restart()

                    ParallelAnimation {
                        id: titleReveal
                        NumberAnimation { target: titleHeading; property: "opacity"; from: 0; to: 1; duration: 380; easing.type: Easing.OutCubic }
                        NumberAnimation { target: titleShift; property: "y"; from: Kirigami.Units.smallSpacing * 1.5; to: 0; duration: 380; easing.type: Easing.OutCubic }
                    }
                }

                PlasmaComponents3.Label {
                    id: artistLabel
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    opacity: 0.8
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    text: root.trackArtist
                    visible: text !== ""
                    transform: Translate { id: artistShift; y: 0 }
                    onTextChanged: artistReveal.restart()

                    ParallelAnimation {
                        id: artistReveal
                        NumberAnimation { target: artistLabel; property: "opacity"; from: 0; to: 0.8; duration: 420; easing.type: Easing.OutCubic }
                        NumberAnimation { target: artistShift; property: "y"; from: Kirigami.Units.smallSpacing; to: 0; duration: 420; easing.type: Easing.OutCubic }
                    }
                }

                PlasmaComponents3.Label {
                    Layout.alignment: Qt.AlignHCenter
                    horizontalAlignment: Text.AlignHCenter
                    opacity: 0.55
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    font.italic: true
                    text: i18n("Nothing playing")
                    visible: !isPlaying() && root.currentStation === ""
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing * 1.5

                CircleButton {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 3
                    implicitHeight: implicitWidth
                    iconName: "media-skip-backward"
                    iconScale: 0.5
                    enabledState: stationsModel.count > 1
                    tooltipText: i18n("Previous station")
                    onClicked: {
                        let idx = lastPlay - 1
                        if (idx < 0) idx = stationsModel.count - 1
                        lastPlay = idx
                        refreshServer(idx)
                    }
                }

                CircleButton {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 4.5
                    implicitHeight: implicitWidth
                    iconName: isPlaying() ? "media-playback-stop" : "media-playback-start"
                    iconScale: 0.45
                    primary: true
                    glowPulse: fullRepresentation._streamActive && root.view === 1 && root.expanded
                    enabledState: stationsModel.count > 0 || isPlaying()
                    tooltipText: isPlaying() ? i18n("Stop") : i18n("Play")
                    onClicked: {
                        // While playing = ALWAYS stop (including preview);
                        // otherwise play the last / first station.
                        if (isPlaying()) {
                            stopWithFade()
                        } else {
                            const idx = lastPlay >= 0 && lastPlay < stationsModel.count ? lastPlay : 0
                            refreshServer(idx)
                        }
                    }
                }

                CircleButton {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 3
                    implicitHeight: implicitWidth
                    iconName: "media-skip-forward"
                    iconScale: 0.5
                    enabledState: stationsModel.count > 1
                    tooltipText: i18n("Next station")
                    onClicked: {
                        let idx = lastPlay + 1
                        if (idx >= stationsModel.count) idx = 0
                        lastPlay = idx
                        refreshServer(idx)
                    }
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                visible: root.currentStation !== ""
                spacing: Kirigami.Units.largeSpacing

                // Search the currently playing track on YouTube
                CircleButton {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 2.4
                    implicitHeight: implicitWidth
                    iconName: "globe"
                    iconScale: 0.55
                    enabledState: root.trackTitle !== "" || (root.title !== Plasmoid.title && root.title !== "")
                    tooltipText: i18n("Search this track on YouTube")
                    onClicked: root.youtubeOpenSearch()
                }

                CircleButton {
                    readonly property bool previewing: root._previewUrl !== ""
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 2.4
                    implicitHeight: implicitWidth
                    iconName: !previewing && root.isFavorite(root.currentStation) ? "favorite" : "non-starred-symbolic"
                    iconScale: 0.55
                    checked: !previewing && root.isFavorite(root.currentStation)
                    tooltipText: {
                        if (previewing) return i18n("Add to my stations + favorites")
                        return root.isFavorite(root.currentStation) ? i18n("Remove from favorites") : i18n("Add to favorites")
                    }
                    onClicked: {
                        if (previewing) {
                            root.addStationToList(root.currentStation, root._previewUrl, root.currentStationFavicon, true)
                        } else {
                            root.toggleFavorite(root.currentStation)
                        }
                    }
                }

                // Download the currently playing track (yt-dlp, format from settings)
                CircleButton {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 2.4
                    implicitHeight: implicitWidth
                    iconName: root.downloading ? "view-refresh" : "download"
                    iconScale: 0.55
                    checked: root.downloading
                    glowPulse: root.downloading
                    enabledState: !root.downloading && (root.trackTitle !== "" || (root.title !== Plasmoid.title && root.title !== ""))
                    tooltipText: root.downloading
                                 ? i18n("Downloading…")
                                 : i18n("Download this track (for offline listening)")
                    onClicked: root.downloadCurrentTrack()
                }
            }

            Item { Layout.fillHeight: true }
        }

        // ── PAGE 3: My Music — downloaded tracks for offline use ────────
        ColumnLayout {
            id: libraryPage
            spacing: 0

            FolderListModel {
                id: musicFolder
                folder: "file://" + root.downloadDirPath
                nameFilters: ["*.mp3", "*.opus", "*.m4a", "*.ogg", "*.flac", "*.mp4", "*.webm"]
                showDirs: false
                sortField: FolderListModel.Time
                sortReversed: true
            }

            // In-progress download bar
            Rectangle {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: root.downloading
                implicitHeight: dlRow.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.smallSpacing * 1.5
                color: Qt.alpha(root.accent, 0.1)
                border.width: 1
                border.color: Qt.alpha(root.accent, 0.4)

                RowLayout {
                    id: dlRow
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    EqBars {
                        Layout.alignment: Qt.AlignVCenter
                        visible: root.downloading
                        animating: visible && root.expanded
                        bars: 3
                        barWidth: 3
                        minHeight: 4
                        maxHeight: Kirigami.Units.gridUnit * 0.9
                        barColor: root.accentBright
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: i18n("Downloading: ") + (root._dlCurrentQuery || "…")
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: root.accent
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            // Recently played tracks — can be downloaded AFTER THE FACT
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: historyModel.count > 0

                Kirigami.Icon {
                    source: "view-history"
                    width: Kirigami.Units.iconSizes.small
                    height: width
                    color: root.accent
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: i18n("Recently played") + " (" + historyModel.count + ")"
                    font.weight: Font.DemiBold
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    color: root.accent
                }
                CircleButton {
                    implicitWidth: Kirigami.Units.gridUnit * 1.8
                    implicitHeight: implicitWidth
                    iconName: "edit-clear-history"
                    iconScale: 0.55
                    opacity: 0.6
                    tooltipText: i18n("Clear history")
                    onClicked: root.clearHistory()
                }
            }

            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(historyModel.count, 4) * Kirigami.Units.gridUnit * 2.3
                visible: historyModel.count > 0
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

                contentItem: ListView {
                    id: historyView
                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    model: historyModel
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    spacing: 2

                    delegate: Item {
                        id: histItem
                        required property var model
                        width: historyView.width - historyView.leftMargin - historyView.rightMargin
                        height: Kirigami.Units.gridUnit * 2.2

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: Kirigami.Units.smallSpacing
                            color: histHover.hovered ? Qt.alpha(root.accent, 0.07) : Qt.alpha(Kirigami.Theme.textColor, 0.03)
                            Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Kirigami.Units.smallSpacing
                                anchors.rightMargin: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing

                                PlasmaComponents3.Label {
                                    text: histItem.model.when
                                    opacity: 0.5
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    PlasmaComponents3.Label {
                                        Layout.fillWidth: true
                                        text: (histItem.model.artist ? histItem.model.artist + " — " : "") + histItem.model.trackName
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    PlasmaComponents3.Label {
                                        Layout.fillWidth: true
                                        text: histItem.model.station
                                        visible: text !== ""
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        opacity: 0.45
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    }
                                }
                                CircleButton {
                                    implicitWidth: Kirigami.Units.gridUnit * 1.7
                                    implicitHeight: implicitWidth
                                    iconName: "download"
                                    iconScale: 0.55
                                    enabledState: !root.downloading
                                    opacity: histHover.hovered ? 1.0 : 0.5
                                    tooltipText: i18n("Download this track")
                                    onClicked: root.downloadTrack((histItem.model.artist ? histItem.model.artist + " - " : "") + histItem.model.trackName)
                                }
                            }
                        }

                        HoverHandler { id: histHover }
                        TapHandler {
                            onTapped: root.youtubeSearchFor((histItem.model.artist ? histItem.model.artist + " " : "") + histItem.model.trackName)
                        }

                        PlasmaCore.ToolTipArea {
                            anchors.fill: parent
                            mainText: i18n("Click = search on YouTube · ⬇ = download")
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: "folder-music"
                    width: Kirigami.Units.iconSizes.small
                    height: width
                    color: root.accent
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: i18n("My Music") + " (" + musicFolder.count + ")"
                    font.weight: Font.DemiBold
                    color: root.accent
                }
                CircleButton {
                    implicitWidth: Kirigami.Units.gridUnit * 2
                    implicitHeight: implicitWidth
                    iconName: "folder-open"
                    iconScale: 0.55
                    tooltipText: i18n("Open folder in file manager")
                    onClicked: executable.exec("xdg-open '" + root.downloadDirPath.replace(/'/g, "'\\''") + "'")
                }
            }

            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

                contentItem: ListView {
                    id: libraryView
                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    model: musicFolder
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    spacing: 2

                    delegate: Item {
                        id: fileItem
                        required property string fileName
                        required property string fileBaseName
                        required property string filePath
                        readonly property string localUrl: "file://" + filePath
                        readonly property bool isThisPlaying: isPlaying() && playMusic.source.toString() === localUrl
                        readonly property bool isVideo: fileName.endsWith(".mp4") || fileName.endsWith(".webm")
                        width: libraryView.width - libraryView.leftMargin - libraryView.rightMargin
                        height: Kirigami.Units.gridUnit * 3

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing / 2
                            radius: Kirigami.Units.smallSpacing * 1.5
                            color: {
                                if (fileItem.isThisPlaying) return Qt.alpha(root.accent, 0.15)
                                if (fileHover.hovered) return Qt.alpha(root.accent, 0.07)
                                return Qt.alpha(Kirigami.Theme.textColor, 0.045)
                            }
                            border.width: 1
                            border.color: fileItem.isThisPlaying
                                          ? Qt.alpha(root.accent, 0.55)
                                          : (fileHover.hovered ? Qt.alpha(root.accent, 0.25) : Qt.alpha(Kirigami.Theme.textColor, 0.06))

                            Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
                                anchors.rightMargin: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing * 1.5

                                Rectangle {
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                                    Layout.preferredHeight: Kirigami.Units.gridUnit * 2
                                    radius: width * 0.32
                                    color: fileItem.isThisPlaying ? root.accent : Qt.alpha(Kirigami.Theme.textColor, 0.1)

                                    EqBars {
                                        anchors.centerIn: parent
                                        visible: fileItem.isThisPlaying
                                        animating: visible && root.expanded
                                        bars: 3
                                        barWidth: 3
                                        minHeight: 4
                                        maxHeight: parent.height * 0.55
                                        barColor: root.accentTextOn
                                    }
                                    Kirigami.Icon {
                                        anchors.centerIn: parent
                                        width: parent.width * 0.55
                                        height: width
                                        source: fileItem.isVideo ? "video-x-generic" : "audio-x-generic"
                                        visible: !fileItem.isThisPlaying
                                    }
                                }

                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    text: fileItem.fileBaseName
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    color: fileItem.isThisPlaying ? root.accent : Kirigami.Theme.textColor
                                    font.weight: fileItem.isThisPlaying ? Font.DemiBold : Font.Normal
                                }

                                CircleButton {
                                    id: fileRemoveBtn
                                    property bool armed: false
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
                                    Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
                                    iconName: "edit-delete"
                                    iconScale: 0.55
                                    checked: armed
                                    checkedColor: "#E0463C"
                                    checkedIconColor: "#FFFFFF"
                                    opacity: armed ? 1.0 : (fileHover.hovered ? 0.6 : 0.0)
                                    visible: opacity > 0.0
                                    tooltipText: armed ? i18n("Click again to confirm delete") : i18n("Delete file")
                                    onClicked: {
                                        if (!armed) {
                                            armed = true
                                            fileDisarmTimer.restart()
                                        } else {
                                            armed = false
                                            if (fileItem.isThisPlaying) stopWithFade()
                                            executable.exec("rm -f '" + fileItem.filePath.replace(/'/g, "'\\''") + "'")
                                        }
                                    }
                                    Timer {
                                        id: fileDisarmTimer
                                        interval: 2500
                                        repeat: false
                                        onTriggered: fileRemoveBtn.armed = false
                                    }
                                    Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                                }
                            }
                        }

                        HoverHandler { id: fileHover }
                        TapHandler {
                            onTapped: root.playLocalFile(fileItem.localUrl, fileItem.fileBaseName)
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.largeSpacing * 2
                        visible: musicFolder.count === 0
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            source: "folder-music"
                            width: Kirigami.Units.iconSizes.huge
                            height: width
                            opacity: 0.4
                        }
                        PlasmaComponents3.Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: i18n("Nothing here yet")
                            font.weight: Font.DemiBold
                            opacity: 0.7
                        }
                        PlasmaComponents3.Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                            wrapMode: Text.Wrap
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: 0.55
                            text: i18n("When a good song plays on the radio, press ⬇ — it will be saved here for offline listening")
                        }
                    }
                }
            }
        }
    }

    ListModel {
        id: filteredStationsModel
    }

    function rebuildFilteredModel() {
        const filter = (root.searchFilter || "").toLowerCase().trim()
        const favOnly = root.favoritesOnly
        filteredStationsModel.clear()
        for (var i = 0; i < stationsModel.count; i++) {
            const s = stationsModel.get(i)
            if (favOnly && !root.isFavorite(s.name)) continue
            if (filter !== "" && s.name.toLowerCase().indexOf(filter) === -1) continue
            const item = {
                "name": s.name || "",
                "hostname": s.hostname || "",
                "favicon": s.favicon || "",
                "active": s.active !== false,
                "originalIndex": i
            }
            filteredStationsModel.append(item)
        }
    }

    Connections {
        target: stationsModel
        function onCountChanged() { rebuildFilteredModel() }
        function onDataChanged() { rebuildFilteredModel() }
    }

    Connections {
        target: root
        function onSearchFilterChanged() {
            rebuildFilteredModel()
            webSearchDebounce.restart()
        }
        function onFavoritesOnlyChanged() { rebuildFilteredModel() }
        function onFavoriteNamesChanged() { rebuildFilteredModel() }
    }

    Component.onCompleted: rebuildFilteredModel()

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            if (root.view === 1) {
                root.view = 0
                event.accepted = true
            } else if (filterField.text !== "") {
                filterField.text = ""
                event.accepted = true
            }
        } else if (event.key === Qt.Key_Space && !filterField.activeFocus) {
            const idx = lastPlay >= 0 && lastPlay < stationsModel.count ? lastPlay : 0
            if (stationsModel.count > 0) refreshServer(idx)
            event.accepted = true
        } else if (event.key === Qt.Key_M && !filterField.activeFocus) {
            playMusicOutput.volume = playMusicOutput.volume > 0 ? 0 : root.targetVolume()
            event.accepted = true
        }
    }

    header: PlasmaExtras.PlasmoidHeading {
        id: headerArea

        focus: true
        height: Kirigami.Units.gridUnit * 4.5
        background.visible: Plasmoid.userBackgroundHints !== PlasmaCore.Types.ShadowBackground

        Heading {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
            anchors.rightMargin: Kirigami.Units.smallSpacing * 1.5
        }
    }

    footer: PlasmaExtras.PlasmoidHeading {
        background.visible: Plasmoid.userBackgroundHints !== PlasmaCore.Types.ShadowBackground

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // My Music (downloaded tracks)
            CircleButton {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: Kirigami.Units.gridUnit * 2.2
                implicitHeight: implicitWidth
                iconName: "folder-music"
                iconScale: 0.55
                checked: root.view === 2
                tooltipText: i18n("My Music (downloaded tracks)")
                onClicked: root.view = root.view === 2 ? 0 : 2
            }

            CircleButton {
                id: sleepBtn
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: Kirigami.Units.gridUnit * 2.2
                implicitHeight: implicitWidth
                iconName: root.sleepRemainingSec > 0 ? "chronometer" : "clock"
                iconScale: 0.55
                checked: root.sleepRemainingSec > 0
                tooltipText: root.sleepRemainingSec > 0
                             ? i18n("Sleep timer: ") + sleepFormatted()
                             : i18n("Sleep timer")
                onClicked: sleepMenu.open()

                // Sleep timer progress ring
                Canvas {
                    id: sleepRing
                    anchors.fill: parent
                    anchors.margins: -2
                    visible: root.sleepRemainingSec > 0 && root.sleepTotalSec > 0
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        if (root.sleepTotalSec <= 0) return
                        var frac = root.sleepRemainingSec / root.sleepTotalSec
                        var c = width / 2
                        ctx.beginPath()
                        ctx.arc(c, c, c - 1.5, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac)
                        ctx.strokeStyle = Qt.alpha(root.accentBright, 0.9)
                        ctx.lineWidth = 2.5
                        ctx.lineCap = "round"
                        ctx.stroke()
                    }

                    Connections {
                        target: root
                        function onSleepRemainingSecChanged() { sleepRing.requestPaint() }
                        function onSleepTotalSecChanged() { sleepRing.requestPaint() }
                    }
                }

                QQC2.Menu {
                    id: sleepMenu
                    QQC2.MenuItem { text: i18n("Sleep in 15 minutes"); icon.name: "chronometer"; onTriggered: root.startSleepTimer(15 * 60) }
                    QQC2.MenuItem { text: i18n("Sleep in 30 minutes"); icon.name: "chronometer"; onTriggered: root.startSleepTimer(30 * 60) }
                    QQC2.MenuItem { text: i18n("Sleep in 60 minutes"); icon.name: "chronometer"; onTriggered: root.startSleepTimer(60 * 60) }
                    QQC2.MenuItem { text: i18n("Sleep in 90 minutes"); icon.name: "chronometer"; onTriggered: root.startSleepTimer(90 * 60) }
                    QQC2.MenuSeparator { }
                    QQC2.MenuItem {
                        text: i18n("Cancel timer")
                        icon.name: "dialog-cancel"
                        enabled: root.sleepRemainingSec > 0
                        onTriggered: root.cancelSleepTimer()
                    }
                }
            }

            PlasmaComponents3.Label {
                id: subtext

                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                elide: Text.ElideRight
                clip: true
                color: {
                    if (isError || !isConnected)
                        return Kirigami.Theme.negativeTextColor
                    else if (fullRepresentation._streamActive)
                        return root.accent
                    else if (Plasmoid.userBackgroundHints === PlasmaCore.Types.ShadowBackground)
                        return Kirigami.Theme.highlightedTextColor
                    else
                        return Kirigami.Theme.textColor
                }
                text: {
                    if (root.sleepRemainingSec > 0) {
                        return i18n("Sleeping in ") + sleepFormatted()
                    }
                    if (root.downloading) {
                        return "⬇ " + i18n("Downloading…")
                    }
                    if (!isConnected)
                        return i18n("Check internet connection…")
                    else if (root.isError)
                        return i18n("Error: ") + playMusic.errorString
                    else if (fullRepresentation._streamActive) {
                        if (fullRepresentation._nowBitrate > 0)
                            return i18n("Bitrate: ") + fullRepresentation._nowBitrate + 'Kb/s'
                        else
                            return root.title !== Plasmoid.title ? "♪ " + i18n("Playing") : i18n("Connecting…")
                    } else if (playMusic.mediaStatus === MediaPlayer.LoadingMedia
                               || playMusic.mediaStatus === MediaPlayer.LoadedMedia)
                        return i18n("Connecting…")
                    else
                        return i18n("Choose station and enjoy…")
                }
            }

            CircleButton {
                id: volumeBtn
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: Kirigami.Units.gridUnit * 2.2
                implicitHeight: implicitWidth
                iconName: {
                    if (playMusicOutput.volume <= 0) return "audio-volume-muted"
                    if (playMusicOutput.volume <= 0.33) return "audio-volume-low"
                    if (playMusicOutput.volume <= 0.66) return "audio-volume-medium"
                    return "audio-volume-high"
                }
                iconScale: 0.55
                tooltipText: i18n("Volume: ") + Math.round(playMusicOutput.volume * 100) + "% " + i18n("(scroll to adjust)")
                onClicked: volumePopup.open()

                // Scroll wheel over the button = volume
                WheelHandler {
                    onWheel: (event) => {
                        const step = event.angleDelta.y > 0 ? 0.05 : -0.05
                        playMusicOutput.volume = Math.max(0, Math.min(1, playMusicOutput.volume + step))
                    }
                }

                QQC2.Popup {
                    id: volumePopup
                    y: -height - Kirigami.Units.smallSpacing
                    x: -width + parent.width
                    padding: Kirigami.Units.smallSpacing * 1.5
                    modal: false

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            source: "audio-volume-low"
                            width: Kirigami.Units.iconSizes.small
                            height: width
                        }
                        QQC2.Slider {
                            id: volumeSlider
                            implicitWidth: Kirigami.Units.gridUnit * 8
                            from: 0
                            to: 1
                            value: playMusicOutput.volume
                            onMoved: playMusicOutput.volume = value
                        }
                        PlasmaComponents3.Label {
                            text: Math.round(playMusicOutput.volume * 100) + "%"
                            opacity: 0.7
                            Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        }
                    }
                }
            }
        }
    }

    function sleepFormatted() {
        const total = root.sleepRemainingSec
        if (total <= 0) return ""
        const m = Math.floor(total / 60)
        const s = total % 60
        return (m < 10 ? "0" + m : m) + ":" + (s < 10 ? "0" + s : s)
    }
}
