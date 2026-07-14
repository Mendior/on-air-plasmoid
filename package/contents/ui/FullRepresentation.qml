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
    // No Layout.maximum*: a hard cap makes user resizing snap back (issue #1) —
    // AppletPopup already clamps popups to 95% of the screen on its own.
    Layout.preferredWidth: Kirigami.Units.gridUnit * 21
    // The default popup must be tall enough for the FULL Now Playing page
    // (art + title + controls + action row) — at the 20 gu minimum the button
    // rows would be clipped on a fresh install until the user resizes.
    Layout.preferredHeight: Kirigami.Units.gridUnit * 32
    collapseMarginsHint: true

    // Urls whose image failed to LOAD (404, broken file) — _bestArtUrl skips
    // them so the chain falls through to the next candidate instead of
    // showing the placeholder forever. Keyed by exact url, so a new track's
    // fresh albumArtUrl self-heals; reset on station change. Always replaced
    // as a whole object — QML var bindings don't see in-place mutation.
    property var _brokenArtUrls: ({})

    readonly property string _bestArtUrl: {
        var broken = _brokenArtUrls
        if (root.albumArtUrl && !broken[root.albumArtUrl]) return root.albumArtUrl
        if (root.imageurl && !broken[root.imageurl]) return root.imageurl
        if (root.currentStationFavicon) {
            var fav = root.faviconSrc(root.currentStationFavicon)
            if (!broken[fav]) return fav
        }
        return ""
    }

    Connections {
        target: root
        function onCurrentStationChanged() { fullRepresentation._brokenArtUrls = {} }
    }

    readonly property bool _streamActive: root._casting
                                          || (isPlaying()
                                              && (playMusic.mediaStatus === MediaPlayer.BufferedMedia
                                                  || playMusic.mediaStatus === MediaPlayer.BufferingMedia))

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
        // Short queries are noise — EXCEPT exact country-map keys ("uk").
        if (q.length < 3 && !(q.toLowerCase() in _countryMap)) {
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
        xhr.setRequestHeader("User-Agent", "OnAir/2026.17")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return
            root._clearXhrTimeout(guard)
            if (seq !== fullRepresentation._webSearchSeq) return // stale request
            if (xhr.status !== 200) {
                // This mirror is down → try the next one right away
                _webSearchAttempt(q, seq, serverIdx + 1)
                return
            }
            try {
                const results = JSON.parse(xhr.responseText) || []
                const existing = {}
                for (var i = 0; i < stationsModel.count; i++)
                    existing[stationsModel.get(i).hostname] = true
                const seen = {}
                for (const r of results) {
                    const u = (r.url_resolved || r.url || "").toString()
                    // http(s) only — catalogue data is untrusted and these URLs
                    // reach playMusic.source, the config and ffmpeg (same rule
                    // as _favUrls in main.qml).
                    if (!u || !/^https?:\/\//i.test(u) || existing[u] || seen[u]) continue
                    seen[u] = true
                    var br = parseInt(r.bitrate) || 0
                    if (br > 1000) br = Math.round(br / 1000)
                    webResultsModel.append({
                        "name": (r.name || "").replace(/\s+/g, " ").trim() || u,
                        "url": u,
                        "favicon": r.favicon || "",
                        "country": r.country || "",
                        "bitrate": br,
                        "codec": (r.codec || "").toUpperCase(),
                        "rbUuid": r.stationuuid || ""
                    })
                    if (webResultsModel.count >= 30) break
                }
                // Only now — a parse failure above keeps the "Searching…"
                // indicator alive while the next mirror is tried.
                fullRepresentation.webSearching = false
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
                    // Both Return AND the numpad Enter (same pattern as CircleButton)
                    function jumpToList() {
                        if (stationView.count > 0) {
                            stationView.currentIndex = 0
                            stationView.forceActiveFocus()
                        }
                    }
                    Keys.onDownPressed: stationView.forceActiveFocus()
                    Keys.onReturnPressed: jumpToList()
                    Keys.onEnterPressed: jumpToList()
                }

                CircleButton {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Kirigami.Units.gridUnit * 2.4
                    implicitHeight: implicitWidth
                    iconName: root.favoritesOnly ? "favorite" : "non-starred-symbolic"
                    iconScale: 0.55
                    checkable: true
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

                    // Both Return AND the numpad Enter (same pattern as CircleButton)
                    function activateCurrent() {
                        if (currentIndex >= 0 && currentItem) {
                            isError = false
                            errorTimer.stop()
                            lastPlay = currentItem.targetIndex
                            refreshServer(currentItem.targetIndex)
                        }
                    }
                    Keys.onReturnPressed: activateCurrent()
                    Keys.onEnterPressed: activateCurrent()
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Slash) {
                            filterField.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                        // Ctrl+Up/Down = move the current row (same as the
                        // hover arrows, reachable without a mouse)
                        if (event.modifiers & Qt.ControlModifier
                            && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)
                            && currentIndex >= 0 && currentItem
                            && root.searchFilter === "") {
                            const delta = event.key === Qt.Key_Up ? -1 : 1
                            const next = currentIndex + delta
                            if (next >= 0 && next < count) {
                                const it = filteredStationsModel.get(currentIndex)
                                if (root.favoritesOnly)
                                    root.moveFavorite(it.name, delta)
                                else
                                    root.moveStation(currentItem.targetIndex, it.name, it.hostname, delta)
                                currentIndex = next
                            }
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

                    // (A stream error used to reset currentIndex to -1 here,
                    // throwing away the keyboard position — the playing-row
                    // highlight is driven by lastPlay, not currentIndex, so
                    // there is nothing to clear.)

                    delegate: MediaListItem {
                    }

                    // ── Global search results at the end of the list ─────────
                    footer: Column {
                        // Bind to the ScrollView, not the ListView: the footer's height feeds
                        // contentHeight -> scrollbar -> ListView width, which would loop.
                        width: scrollView.width - stationView.leftMargin - stationView.rightMargin
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

                                // Keyboard + screen-reader access — the row is otherwise
                                // reachable only with a pointer (TapHandler).
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: webItem.isPreviewing
                                                 ? i18n("Stop preview: %1", model.name)
                                                 : i18n("Preview: %1", model.name)
                                Accessible.onPressAction: root.previewStation(webItem.model.name, webItem.model.url, webItem.model.favicon)
                                Keys.onPressed: (event) => {
                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                        root.previewStation(webItem.model.name, webItem.model.url, webItem.model.favicon)
                                        event.accepted = true
                                    }
                                }

                                Rectangle {
                                    id: webBg
                                    anchors.fill: parent
                                    anchors.margins: Kirigami.Units.smallSpacing / 2
                                    radius: Kirigami.Units.smallSpacing * 1.5
                                    color: webHover.hovered
                                           ? Qt.alpha(root.accent, 0.09)
                                           : Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                    border.width: webItem.activeFocus ? 2 : 1
                                    border.color: webItem.activeFocus
                                                  ? root.accent
                                                  : (webHover.hovered
                                                     ? Qt.alpha(root.accent, 0.35)
                                                     : Qt.alpha(Kirigami.Theme.textColor, 0.05))

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
                                                // Untrusted catalogue data — never interpret as HTML
                                                textFormat: Text.PlainText
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
                                                textFormat: Text.PlainText
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
                                        root.addStationToList(webItem.model.name, webItem.model.url, webItem.model.favicon, true, webItem.model.rbUuid)
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
        // Wrapped in a Flickable so the controls stay reachable when the
        // popup is resized below the page's natural height (min is 20 gu).
        Flickable {
            id: nowPlayingFlick
            clip: true
            contentWidth: width
            contentHeight: nowPlayingPage.implicitHeight
            interactive: contentHeight > height
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: nowPlayingPage
                width: nowPlayingFlick.width
                height: Math.max(implicitHeight, nowPlayingFlick.height)
                spacing: Kirigami.Units.smallSpacing

                Item { Layout.preferredHeight: Kirigami.Units.smallSpacing; Layout.fillWidth: true }

                Item {
                    id: artContainer
                    Layout.alignment: Qt.AlignHCenter
                    // 10.5 gu at the default popup height (32 gu); extra height the
                    // user drags out goes into the art — it never shrinks below that,
                    // so the button rows can't get clipped at the default size.
                    Layout.preferredWidth: Math.min(fullRepresentation.width - Kirigami.Units.largeSpacing * 4,
                                                    Kirigami.Units.gridUnit * 10.5
                                                    + Math.max(0, fullRepresentation.height - Kirigami.Units.gridUnit * 32))
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

                            // A url that 404s would otherwise pin the vinyl
                            // placeholder even when the next chain link
                            // (station image, favicon) would have loaded fine.
                            onStatusChanged: {
                                if (status === Image.Error && source.toString() !== "") {
                                    var m = {}
                                    for (var k in fullRepresentation._brokenArtUrls)
                                        m[k] = true
                                    m[source.toString()] = true
                                    fullRepresentation._brokenArtUrls = m
                                }
                            }

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
                                    // Disk-cached copy when available. The self-heal must not
                                    // assign source imperatively — that destroys the binding
                                    // and pins this logo until the popup is rebuilt.
                                    property string brokenCacheFor: ""
                                    source: {
                                        var fav = root.currentStationFavicon
                                        return (fav && fav === brokenCacheFor) ? fav : root.faviconSrc(fav)
                                    }
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    smooth: true
                                    visible: status === Image.Ready
                                    // Self-healing: corrupted cache → retry remote once
                                    // (flag flips the binding to the remote URL, so it
                                    // stays declarative and station changes keep working)
                                    onStatusChanged: {
                                        if (status === Image.Error && root.currentStationFavicon
                                            && source.toString().indexOf("file://") === 0) {
                                            brokenCacheFor = root.currentStationFavicon
                                        }
                                    }
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
                        // Untrusted (station-controlled) — never interpret as HTML
                        textFormat: Text.PlainText
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
                        // Untrusted (ICY title / station name) — never interpret as HTML
                        textFormat: Text.PlainText
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
                        // Untrusted (ICY title) — never interpret as HTML
                        textFormat: Text.PlainText
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
                        checkable: true
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

                    // ❤️ — like the current song (local list on the My Music page)
                    CircleButton {
                        readonly property bool liked: root.isCurrentTrackLiked()
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Kirigami.Units.gridUnit * 2.4
                        implicitHeight: implicitWidth
                        iconName: "love"
                        iconScale: 0.55
                        checkable: true
                        checked: liked
                        enabledState: root.trackTitle !== ""
                        tooltipText: liked ? i18n("Remove from liked songs")
                                           : i18n("Like this song (saved to My Music)")
                        onClicked: root.toggleLikeCurrent()
                    }

                    // 👍 — vote for the station on radio-browser.info: raises
                    // its ranking in the worldwide catalog every app searches.
                    CircleButton {
                        readonly property bool voted: root._voteStatus === "voted"
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Kirigami.Units.gridUnit * 2.4
                        implicitHeight: implicitWidth
                        iconName: "arrow-up-double"
                        iconScale: 0.55
                        checkable: true
                        checked: voted
                        enabledState: root._voteStatus === "" && root._previewUrl === ""
                                      && root._currentOrigUrl !== ""
                        tooltipText: {
                            if (voted) return i18n("Vote sent — thank you for supporting the station!")
                            if (root._voteStatus === "busy") return i18n("Sending the vote…")
                            return i18n("Vote for this station in the worldwide catalog")
                        }
                        onClicked: root.voteCurrentStation()
                    }

                    // Download the currently playing track (yt-dlp, format from settings)
                    CircleButton {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Kirigami.Units.gridUnit * 2.4
                        implicitHeight: implicitWidth
                        iconName: root.downloading ? "view-refresh" : "download"
                        iconScale: 0.55
                        // Not checkable: one-shot action button; checked only drives the
                        // "downloading" visual, it is not a user-togglable state.
                        checked: root.downloading
                        // && expanded: the infinite pulse ring must not tick in a hidden popup
                        glowPulse: root.downloading && root.expanded
                        enabledState: !root.downloading && (root.trackTitle !== "" || (root.title !== Plasmoid.title && root.title !== ""))
                        tooltipText: root.downloading
                                     ? i18n("Downloading…")
                                     : i18n("Download this track (for offline listening)")
                        onClicked: root.downloadCurrentTrack()
                    }

                    // ● REC — capture the live stream to ~/Music/OnAir (bit-exact copy)
                    CircleButton {
                        // !fadeOutAnimation.running: during a stop fade the stream is
                        // still "playing" — starting a REC there would outlive the stop
                        readonly property bool canRec: isPlaying() && !fadeOutAnimation.running
                                                       && root.canRecordUrl(playMusic.source.toString())
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Kirigami.Units.gridUnit * 2.4
                        implicitHeight: implicitWidth
                        iconName: "media-record"
                        iconScale: 0.55
                        checkable: true
                        checked: root.recording
                        checkedColor: "#E0463C"
                        checkedIconColor: "#FFFFFF"
                        // && expanded: recordings run for hours — the pulse ring must
                        // not keep plasmashell's animation timer alive popup-closed
                        glowPulse: root.recording && root.expanded
                        enabledState: root.recording ? !root._recScheduled : canRec
                        tooltipText: {
                            if (root.recording && root._recScheduled)
                                return i18n("A scheduled recording is running (%1)", root._recStationName)
                            if (root.recording)
                                return i18n("Recording %1 — click to stop", root.recElapsedText())
                            if (!canRec && isPlaying())
                                return i18n("This source cannot be recorded")
                            return i18n("Record this station (personal use only)")
                        }
                        onClicked: root.recording ? root.recStop() : root.recStartCurrent()
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        // ── PAGE 3: My Music — downloaded tracks for offline use ────────
        ColumnLayout {
            id: libraryPage
            // Scheduled-recordings panel visibility (toggled from the header row)
            property bool showSchedules: false
            // Wake-up alarms panel visibility (its own toggle, same header row)
            property bool showAlarms: false
            // History header shows either the play history or the liked songs
            property bool showLiked: false
            spacing: 0

            FolderListModel {
                id: musicFolder
                // NOT bound to downloadDirPath directly: FolderListModel
                // silently falls back to the working directory (the user's
                // HOME under plasmashell) when its folder doesn't exist — or
                // isn't set — so on a fresh install My Music listed the whole
                // home directory (issue #3). The folder is applied only after
                // main.qml's mkdir -p confirms it exists; until then the
                // match-nothing filter keeps the model empty.
                // .aac/.mka are what stream recordings produce (-c copy keeps
                // the original codec; unknown codecs land in a Matroska file)
                readonly property var libraryFilters: ["*.mp3", "*.opus", "*.m4a", "*.ogg", "*.flac", "*.aac", "*.mka", "*.wav", "*.mp4", "*.webm"]
                nameFilters: ["#pending#"]
                showDirs: false
                sortField: FolderListModel.Time
                sortReversed: true

                function pointAtLibrary() {
                    nameFilters = libraryFilters;
                    folder = "file://" + root.downloadDirPath;
                }

                // The popup (and this model) is created lazily on first open —
                // the ready signal may have fired long before, hence the latch.
                Component.onCompleted: if (root._musicDirEnsured) pointAtLibrary()
            }

            // Sibling, not a child: FolderListModel has no default property,
            // so nesting anything inside it fails to load at parse time.
            Connections {
                target: root
                function onMusicDirReady() { musicFolder.pointAtLibrary() }
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
                        // Untrusted (derived from the ICY title) — never interpret as HTML
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: root.accent
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            // In-progress recording bar — same pattern as the download bar,
            // in the signature REC red
            Rectangle {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: root.recording
                implicitHeight: recRow.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.smallSpacing * 1.5
                color: Qt.alpha("#E0463C", 0.1)
                border.width: 1
                border.color: Qt.alpha("#E0463C", 0.45)

                RowLayout {
                    id: recRow
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    EqBars {
                        Layout.alignment: Qt.AlignVCenter
                        visible: root.recording
                        animating: visible && root.expanded
                        bars: 3
                        barWidth: 3
                        minHeight: 4
                        maxHeight: Kirigami.Units.gridUnit * 0.9
                        barColor: "#E0463C"
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: "● REC " + root.recElapsedText() + " · " + root._recStationName
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: "#E0463C"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    CircleButton {
                        implicitWidth: Kirigami.Units.gridUnit * 1.7
                        implicitHeight: implicitWidth
                        iconName: "media-playback-stop"
                        iconScale: 0.5
                        tooltipText: i18n("Stop recording")
                        onClicked: root.recStop()
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
                visible: historyModel.count > 0 || likedModel.count > 0

                Kirigami.Icon {
                    source: libraryPage.showLiked ? "love" : "view-history"
                    width: Kirigami.Units.iconSizes.small
                    height: width
                    color: root.accent
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: (libraryPage.showLiked ? i18n("Liked songs") : i18n("Recently played"))
                          + " (" + (libraryPage.showLiked ? likedModel.count : historyModel.count) + ")"
                    font.weight: Font.DemiBold
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    color: root.accent
                }
                // ❤️/🕐 — flip between the play history and the liked songs
                CircleButton {
                    implicitWidth: Kirigami.Units.gridUnit * 1.8
                    implicitHeight: implicitWidth
                    iconName: libraryPage.showLiked ? "view-history" : "love"
                    iconScale: 0.55
                    checkable: true
                    checked: libraryPage.showLiked
                    opacity: 0.7
                    tooltipText: libraryPage.showLiked ? i18n("Show play history")
                                                       : i18n("Show liked songs")
                    onClicked: libraryPage.showLiked = !libraryPage.showLiked
                }
                CircleButton {
                    implicitWidth: Kirigami.Units.gridUnit * 1.8
                    implicitHeight: implicitWidth
                    visible: !libraryPage.showLiked
                    iconName: "edit-clear-history"
                    iconScale: 0.55
                    opacity: 0.6
                    tooltipText: i18n("Clear history")
                    onClicked: root.clearHistory()
                }
            }

            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min((libraryPage.showLiked ? likedModel.count : historyModel.count), 4)
                                        * Kirigami.Units.gridUnit * 2.3
                visible: (libraryPage.showLiked ? likedModel.count : historyModel.count) > 0
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

                contentItem: ListView {
                    id: historyView
                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    model: libraryPage.showLiked ? likedModel : historyModel
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    spacing: 2

                    delegate: Item {
                        id: histItem
                        required property var model
                        width: historyView.width - historyView.leftMargin - historyView.rightMargin
                        height: Kirigami.Units.gridUnit * 2.2

                        // Keyboard + screen-reader access — the row is otherwise
                        // reachable only with a pointer (same pattern as web rows)
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: i18n("Search YouTube for %1", (histItem.model.artist ? histItem.model.artist + " " : "") + histItem.model.trackName)
                        Accessible.onPressAction: root.youtubeSearchFor((histItem.model.artist ? histItem.model.artist + " " : "") + histItem.model.trackName)
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                root.youtubeSearchFor((histItem.model.artist ? histItem.model.artist + " " : "") + histItem.model.trackName)
                                event.accepted = true
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: Kirigami.Units.smallSpacing
                            color: histHover.hovered ? Qt.alpha(root.accent, 0.07) : Qt.alpha(Kirigami.Theme.textColor, 0.03)
                            border.width: histItem.activeFocus ? 2 : 0
                            border.color: histItem.activeFocus ? root.accent : "transparent"
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
                                        // Untrusted (ICY title) — never interpret as HTML
                                        textFormat: Text.PlainText
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    PlasmaComponents3.Label {
                                        Layout.fillWidth: true
                                        text: histItem.model.station
                                        textFormat: Text.PlainText
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
                                // Un-like straight from the list (liked view only)
                                CircleButton {
                                    implicitWidth: Kirigami.Units.gridUnit * 1.7
                                    implicitHeight: implicitWidth
                                    visible: libraryPage.showLiked
                                    iconName: "edit-delete-remove"
                                    iconScale: 0.55
                                    opacity: histHover.hovered ? 1.0 : 0.5
                                    tooltipText: i18n("Remove from liked songs")
                                    onClicked: root.removeLiked(histItem.model.index)
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
                    iconName: "chronometer"
                    iconScale: 0.55
                    checkable: true
                    checked: libraryPage.showSchedules
                    tooltipText: i18n("Scheduled recordings")
                    onClicked: libraryPage.showSchedules = !libraryPage.showSchedules

                    // Badge with the number of scheduled recordings
                    Rectangle {
                        visible: root.recSchedules.length > 0
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: -2
                        anchors.rightMargin: -2
                        width: Kirigami.Units.gridUnit * 0.85
                        height: width
                        radius: width / 2
                        color: "#E0463C"
                        PlasmaComponents3.Label {
                            anchors.centerIn: parent
                            text: root.recSchedules.length
                            color: "#FFFFFF"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 2
                            font.weight: Font.Bold
                        }
                    }
                }
                CircleButton {
                    implicitWidth: Kirigami.Units.gridUnit * 2
                    implicitHeight: implicitWidth
                    iconName: "clock"
                    iconScale: 0.55
                    checkable: true
                    checked: libraryPage.showAlarms
                    tooltipText: i18n("Wake-up alarms")
                    onClicked: libraryPage.showAlarms = !libraryPage.showAlarms

                    // Badge with the number of set alarms
                    Rectangle {
                        visible: root.alarms.length > 0
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: -2
                        anchors.rightMargin: -2
                        width: Kirigami.Units.gridUnit * 0.85
                        height: width
                        radius: width / 2
                        color: root.accent
                        PlasmaComponents3.Label {
                            anchors.centerIn: parent
                            text: root.alarms.length
                            color: "#0B0F0D"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 2
                            font.weight: Font.Bold
                        }
                    }
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

            // ── Scheduled recordings panel ───────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: libraryPage.showSchedules
                implicitHeight: schedCol.implicitHeight + Kirigami.Units.smallSpacing * 3
                radius: Kirigami.Units.smallSpacing * 1.5
                color: Qt.alpha(Kirigami.Theme.textColor, 0.03)
                border.width: 1
                border.color: Qt.alpha(root.accent, 0.25)

                ColumnLayout {
                    id: schedCol
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing * 1.5
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            source: "media-record"
                            width: Kirigami.Units.iconSizes.small
                            height: width
                            color: "#E0463C"
                        }
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: i18n("Scheduled recordings")
                            font.weight: Font.DemiBold
                            color: root.accent
                        }
                    }

                    // Existing schedules
                    Repeater {
                        model: root.recSchedules

                        RowLayout {
                            id: schedItem
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: {
                                    var s = schedItem.modelData
                                    var when = root._pad2(s.hh) + ":" + root._pad2(s.mm)
                                    // Fixed English day names — the UI language is
                                    // English by design, Qt.locale() would leak the
                                    // system locale here.
                                    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                                    var d = new Date(s.nextRun)
                                    var rep = s.repeat === "daily" ? i18n("Daily")
                                            : s.repeat === "weekly" ? i18n("Every %1", days[s.weekday])
                                            : days[d.getDay()] + " " + d.getDate() + "." + (d.getMonth() + 1) + "."
                                    return "⏺ " + rep + " " + when + " · " + s.durationMin + " min · " + s.station
                                }
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            CircleButton {
                                implicitWidth: Kirigami.Units.gridUnit * 1.6
                                implicitHeight: implicitWidth
                                iconName: "edit-delete"
                                iconScale: 0.5
                                opacity: 0.7
                                tooltipText: i18n("Remove this schedule")
                                onClicked: root.removeRecSchedule(schedItem.index)
                            }
                        }
                    }

                    PlasmaComponents3.Label {
                        visible: root.recSchedules.length === 0
                        text: i18n("No scheduled recordings yet — add one below.")
                        opacity: 0.55
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }

                    Kirigami.Separator { Layout.fillWidth: true; opacity: 0.4 }

                    // Add form: station · time · duration · repeat · [+]
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: Kirigami.Units.smallSpacing
                        rowSpacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            text: i18n("Station:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.ComboBox {
                            id: schedStation
                            Layout.fillWidth: true
                            model: stationsModel
                            textRole: "name"
                            Accessible.name: i18n("Station")
                        }

                        PlasmaComponents3.Label {
                            text: i18n("Start:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.SpinBox {
                                id: schedHH
                                from: 0; to: 23
                                value: 20
                                textFromValue: function(v) { return root._pad2(v) }
                                wrap: true
                                Accessible.name: i18n("Start hour")
                            }
                            PlasmaComponents3.Label { text: ":" }
                            QQC2.SpinBox {
                                id: schedMM
                                from: 0; to: 59
                                stepSize: 5
                                value: 0
                                textFromValue: function(v) { return root._pad2(v) }
                                wrap: true
                                Accessible.name: i18n("Start minute")
                            }
                        }

                        PlasmaComponents3.Label {
                            text: i18n("Duration:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.SpinBox {
                            id: schedDuration
                            from: 5; to: 600
                            stepSize: 5
                            value: 60
                            textFromValue: function(v) { return v + " min" }
                            valueFromText: function(t) { return parseInt(t) || 60 }
                            Accessible.name: i18n("Duration in minutes")
                        }

                        PlasmaComponents3.Label {
                            text: i18n("Repeat:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.ComboBox {
                                id: schedRepeat
                                model: [i18n("Once"), i18n("Daily"), i18n("Weekly")]
                                Accessible.name: i18n("Repeat")
                            }
                            QQC2.ComboBox {
                                id: schedWeekday
                                visible: schedRepeat.currentIndex === 2
                                // Fixed English day names (UI language is English by design)
                                model: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                                currentIndex: new Date().getDay()
                                Accessible.name: i18n("Weekday")
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: i18n("Recordings are for personal use only.")
                            visible: addSchedButton.selRecordable || schedStation.currentIndex < 0
                            opacity: 0.5
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            font.italic: true
                            elide: Text.ElideRight
                        }
                        // Shown instead of the hint when the selected station's
                        // stream type can't be captured (HLS/playlist/local) —
                        // a disabled button alone would be a silent no-op.
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            visible: !addSchedButton.selRecordable && schedStation.currentIndex >= 0 && stationsModel.count > 0
                            text: i18n("This source cannot be recorded")
                            opacity: 0.7
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            elide: Text.ElideRight
                        }
                        QQC2.Button {
                            id: addSchedButton
                            readonly property bool selRecordable:
                                schedStation.currentIndex >= 0
                                && schedStation.currentIndex < stationsModel.count
                                && root.canRecordUrl(stationsModel.get(schedStation.currentIndex).hostname || "")
                            icon.name: "list-add"
                            text: i18n("Add")
                            enabled: selRecordable
                            onClicked: {
                                var st = stationsModel.get(schedStation.currentIndex)
                                if (!st || !st.hostname) return
                                var repeats = ["once", "daily", "weekly"]
                                root.addRecSchedule(st.name, st.hostname,
                                                    schedHH.value, schedMM.value,
                                                    schedDuration.value,
                                                    repeats[schedRepeat.currentIndex],
                                                    schedWeekday.currentIndex)
                            }
                        }
                    }
                }
            }

            // ── Wake-up alarms panel ─────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: libraryPage.showAlarms
                implicitHeight: alarmCol.implicitHeight + Kirigami.Units.smallSpacing * 3
                radius: Kirigami.Units.smallSpacing * 1.5
                color: Qt.alpha(Kirigami.Theme.textColor, 0.03)
                border.width: 1
                border.color: Qt.alpha(root.accent, 0.25)

                ColumnLayout {
                    id: alarmCol
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing * 1.5
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            source: "clock"
                            width: Kirigami.Units.iconSizes.small
                            height: width
                            color: root.accent
                        }
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: i18n("Wake-up alarms")
                            font.weight: Font.DemiBold
                            color: root.accent
                        }
                    }

                    // Existing alarms
                    Repeater {
                        model: root.alarms

                        RowLayout {
                            id: alarmItem
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: {
                                    var a = alarmItem.modelData
                                    var when = root._pad2(a.hh) + ":" + root._pad2(a.mm)
                                    // Fixed English day names — the UI language is
                                    // English by design, Qt.locale() would leak the
                                    // system locale here.
                                    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                                    var d = new Date(a.nextRun)
                                    var rep = a.repeat === "daily" ? i18n("Daily")
                                            : a.repeat === "weekly" ? i18n("Every %1", days[a.weekday])
                                            : days[d.getDay()] + " " + d.getDate() + "." + (d.getMonth() + 1) + "."
                                    return "⏰ " + rep + " " + when + " · " + a.volumePct + "% · " + a.station
                                }
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            CircleButton {
                                implicitWidth: Kirigami.Units.gridUnit * 1.6
                                implicitHeight: implicitWidth
                                iconName: "edit-delete"
                                iconScale: 0.5
                                opacity: 0.7
                                tooltipText: i18n("Remove this alarm")
                                onClicked: root.removeAlarm(alarmItem.index)
                            }
                        }
                    }

                    PlasmaComponents3.Label {
                        visible: root.alarms.length === 0
                        text: i18n("No alarms yet — add one below.")
                        opacity: 0.55
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }

                    Kirigami.Separator { Layout.fillWidth: true; opacity: 0.4 }

                    // Add form: station · time · repeat · volume · [+]
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: Kirigami.Units.smallSpacing
                        rowSpacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            text: i18n("Station:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.ComboBox {
                            id: alarmStation
                            Layout.fillWidth: true
                            model: stationsModel
                            textRole: "name"
                            Accessible.name: i18n("Station")
                        }

                        PlasmaComponents3.Label {
                            text: i18n("Start:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.SpinBox {
                                id: alarmHH
                                from: 0; to: 23
                                value: 7
                                textFromValue: function(v) { return root._pad2(v) }
                                wrap: true
                                Accessible.name: i18n("Start hour")
                            }
                            PlasmaComponents3.Label { text: ":" }
                            QQC2.SpinBox {
                                id: alarmMM
                                from: 0; to: 59
                                stepSize: 5
                                value: 0
                                textFromValue: function(v) { return root._pad2(v) }
                                wrap: true
                                Accessible.name: i18n("Start minute")
                            }
                        }

                        PlasmaComponents3.Label {
                            text: i18n("Repeat:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.ComboBox {
                                id: alarmRepeat
                                model: [i18n("Once"), i18n("Daily"), i18n("Weekly")]
                                currentIndex: 1
                                Accessible.name: i18n("Repeat")
                            }
                            QQC2.ComboBox {
                                id: alarmWeekday
                                visible: alarmRepeat.currentIndex === 2
                                // Fixed English day names (UI language is English by design)
                                model: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                                currentIndex: new Date().getDay()
                                Accessible.name: i18n("Weekday")
                            }
                        }

                        PlasmaComponents3.Label {
                            text: i18n("Volume:")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.SpinBox {
                            id: alarmVolume
                            // The floor is 15%: an alarm must never be silent.
                            from: 15; to: 100
                            stepSize: 5
                            value: 40
                            textFromValue: function(v) { return v + "%" }
                            valueFromText: function(t) { return parseInt(t) || 40 }
                            Accessible.name: i18n("Volume")
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.CheckBox {
                            id: alarmAwake
                            Layout.fillWidth: true
                            text: i18n("Keep the computer awake until the alarm")
                            checked: true
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.Button {
                            icon.name: "list-add"
                            text: i18n("Add")
                            enabled: alarmStation.currentIndex >= 0
                                     && alarmStation.currentIndex < stationsModel.count
                            onClicked: {
                                var st = stationsModel.get(alarmStation.currentIndex)
                                if (!st || !st.hostname) return
                                var repeats = ["once", "daily", "weekly"]
                                root.addAlarm(st.name, st.hostname, st.favicon || "",
                                              alarmHH.value, alarmMM.value,
                                              repeats[alarmRepeat.currentIndex],
                                              alarmWeekday.currentIndex,
                                              alarmVolume.value, alarmAwake.checked)
                            }
                        }
                    }
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
                        required property string filePath
                        // FolderListModel's fileUrl is already percent-encoded — a raw
                        // "file://" + filePath breaks on '#' or '?' in the file name.
                        required property url fileUrl
                        readonly property string localUrl: fileUrl.toString()
                        // completeBaseName behaviour: strip only the LAST suffix —
                        // fileBaseName would cut "Mr. Brightside.mp3" down to "Mr".
                        readonly property string displayName: {
                            const i = fileName.lastIndexOf(".")
                            return i > 0 ? fileName.substring(0, i) : fileName
                        }
                        readonly property bool isThisPlaying: isPlaying() && playMusic.source.toString() === localUrl
                        readonly property bool isVideo: fileName.endsWith(".mp4") || fileName.endsWith(".webm")
                        width: libraryView.width - libraryView.leftMargin - libraryView.rightMargin
                        height: Kirigami.Units.gridUnit * 3

                        // Keyboard + screen-reader access — the row is otherwise
                        // reachable only with a pointer (same pattern as web rows)
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: fileItem.isThisPlaying ? i18n("Stop: %1", displayName) : i18n("Play: %1", displayName)
                        Accessible.onPressAction: root.playLocalFile(fileItem.localUrl, fileItem.displayName)
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                root.playLocalFile(fileItem.localUrl, fileItem.displayName)
                                event.accepted = true
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing / 2
                            radius: Kirigami.Units.smallSpacing * 1.5
                            color: {
                                if (fileItem.isThisPlaying) return Qt.alpha(root.accent, 0.15)
                                if (fileHover.hovered) return Qt.alpha(root.accent, 0.07)
                                return Qt.alpha(Kirigami.Theme.textColor, 0.045)
                            }
                            border.width: fileItem.activeFocus ? 2 : 1
                            border.color: {
                                if (fileItem.activeFocus) return root.accent
                                if (fileItem.isThisPlaying) return Qt.alpha(root.accent, 0.55)
                                return fileHover.hovered ? Qt.alpha(root.accent, 0.25) : Qt.alpha(Kirigami.Theme.textColor, 0.06)
                            }

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
                                    text: fileItem.displayName
                                    textFormat: Text.PlainText
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
                                    // Not checkable: two-step confirm button; armed is a
                                    // visual state, not checkbox semantics.
                                    checked: armed
                                    checkedColor: "#E0463C"
                                    checkedIconColor: "#FFFFFF"
                                    // Row focus reveals the button so Tab can reach it;
                                    // its own focus keeps it revealed once tabbed into
                                    // (fileItem is no FocusScope — both terms needed).
                                    opacity: armed ? 1.0 : ((fileHover.hovered || fileItem.activeFocus || fileRemoveBtn.activeFocus) ? 0.6 : 0.0)
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
                            onTapped: root.playLocalFile(fileItem.localUrl, fileItem.displayName)
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
        if (favOnly) {
            // The favorites view follows the favorites list's own order (not
            // the main list's), so the reorder arrows work on exactly the
            // order the user is looking at.
            const idxByName = {}
            for (var m = 0; m < stationsModel.count; m++) {
                const st = stationsModel.get(m)
                if (idxByName[st.name] === undefined) idxByName[st.name] = m
            }
            for (var f = 0; f < root.favoriteNames.length; f++) {
                const fi = idxByName[root.favoriteNames[f]]
                if (fi === undefined) continue
                const fs = stationsModel.get(fi)
                if (filter !== "" && fs.name.toLowerCase().indexOf(filter) === -1) continue
                filteredStationsModel.append({
                    "name": fs.name || "",
                    "hostname": fs.hostname || "",
                    "favicon": fs.favicon || "",
                    "active": fs.active !== false,
                    "originalIndex": fi
                })
            }
            return
        }
        for (var i = 0; i < stationsModel.count; i++) {
            const s = stationsModel.get(i)
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
        // clear()+append() is the model's only mutation path (main.qml
        // reloadStationsModel), so count changes cover every reload; nothing
        // calls setProperty on it, so a dataChanged handler would be dead code.
        function onCountChanged() { rebuildFilteredModel() }
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

    // True when any text/form input (search field, scheduler SpinBoxes /
    // ComboBoxes, volume slider) owns keyboard focus — the global Space/M
    // shortcuts must stay inert then. Walks up from the focus item so a
    // control's internal TextInput contentItem is caught too.
    function _inputFocused() {
        var it = fullRepresentation.Window.activeFocusItem
        while (it && it !== fullRepresentation) {
            if (it.hasOwnProperty("stepSize")      // SpinBox / Slider
                || it.hasOwnProperty("editText")   // ComboBox
                || it.hasOwnProperty("echoMode"))  // TextInput / TextField
                return true
            it = it.parent
        }
        return false
    }

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            // Esc on ANY non-list page (Now Playing, My Music) returns to the
            // station list; only on the list itself it may close the popup.
            if (root.view !== 0) {
                root.view = 0
                event.accepted = true
            } else if (filterField.text !== "") {
                filterField.text = ""
                event.accepted = true
            }
        } else if (event.key === Qt.Key_Space && !_inputFocused()) {
            if (stationsModel.count > 0) {
                const idx = lastPlay >= 0 && lastPlay < stationsModel.count ? lastPlay : 0
                refreshServer(idx)
            }
            event.accepted = true
        } else if (event.key === Qt.Key_M && !_inputFocused()) {
            root.setUserVolume(playMusicOutput.volume > 0 ? 0 : root.targetVolume())
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
                checkable: true
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
                checkable: true
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
                    if (root.recording)
                        return "#E0463C"
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
                    if (root.recording) {
                        return "● REC " + root.recElapsedText()
                               + (root._recScheduled ? " · " + root._recStationName : "")
                    }
                    if (root.sleepRemainingSec > 0) {
                        return i18n("Sleeping in ") + sleepFormatted()
                    }
                    if (root.downloading) {
                        return "⬇ " + i18n("Downloading…")
                    }
                    if (root._casting) {
                        return i18n("Casting to %1", root._castName)
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

            // Cast button — DLNA renderers (TVs, soundbars, network speakers)
            // work with no extra packages; Google Cast devices additionally
            // appear when python-chromecast is installed. Hidden only when
            // the bridge itself is unusable (no python3).
            CircleButton {
                id: castBtn
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: Kirigami.Units.gridUnit * 2.2
                implicitHeight: implicitWidth
                visible: root._castAvailable
                iconName: root._casting ? "media-playback-cast" : "video-display"
                iconScale: 0.55
                checkable: true
                checked: root._casting
                tooltipText: root._casting
                             ? i18n("Casting to %1 — click to choose or stop", root._castName)
                             : i18n("Play on a device (Chromecast, TV, speaker)")
                onClicked: {
                    if (!castMenu.opened) {
                        root.castDiscover()
                        // Re-probe too: an adapter that came up after login
                        // (module reload, rfkill) should be noticed here, not
                        // only at the next plasmashell restart.
                        root.btProbe()
                        root.btList()
                        castMenu.open()
                    } else {
                        castMenu.close()
                    }
                }

                QQC2.Popup {
                    id: castMenu
                    y: -height - Kirigami.Units.smallSpacing
                    x: -width + parent.width
                    padding: Kirigami.Units.smallSpacing
                    modal: false
                    implicitWidth: Kirigami.Units.gridUnit * 18
                    // CloseOnPressOutsideParent (not ...Outside): the default
                    // policy closed the popup on the toggle button's own
                    // press, so the click's release always saw opened=false
                    // and REOPENED it — the close branch was dead code.
                    closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutsideParent
                    // Keyboard: focus the list so arrow keys reach the rows
                    // and Esc closes the menu instead of leaking to the
                    // page-switch handler.
                    focus: true

                    // The menu grew past what a small popup window can show
                    // (headers, pairing, sync controls, three device lists) —
                    // a QQC2 Popup cannot extend beyond its window, so
                    // without a scroll container the TOP rows silently
                    // clipped away on a minimum-height widget.
                    contentItem: PlasmaComponents3.ScrollView {
                        id: castMenuScroll
                        implicitWidth: castMenuColumn.implicitWidth
                        implicitHeight: Math.min(
                            castMenuColumn.implicitHeight,
                            fullRepresentation.height - Kirigami.Units.gridUnit * 3)
                        contentWidth: availableWidth

                        ColumnLayout {
                        id: castMenuColumn
                        width: castMenuScroll.availableWidth
                        spacing: Kirigami.Units.smallSpacing

                        // Title row — the menu is the one place everything
                        // audio-out lives, so it gets a proper header.
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: "media-playback-cast"
                                color: root.accent
                                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("Play on")
                                font.weight: Font.DemiBold
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true; opacity: 0.4 }

                        // This computer. While casting it becomes a checkbox:
                        // tick it to ALSO play locally (multi-room), untick to
                        // silence the local output. With no devices selected
                        // it is simply the (checked) only output.
                        PlasmaComponents3.CheckDelegate {
                            Layout.fillWidth: true
                            text: i18n("This computer")
                            icon.name: "computer"
                            checked: root._castTargets.length === 0 || root._castLocalPlay
                            enabled: root._castTargets.length > 0
                            onToggled: root.castToggleLocal()
                        }

                        // Local output picker (Bluetooth speakers, HDMI,
                        // headphones…). Only shown when there is a choice.
                        PlasmaComponents3.ComboBox {
                            id: outputCombo
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            Layout.rightMargin: Kirigami.Units.smallSpacing
                            visible: mediaDevices.audioOutputs.length > 1
                            model: {
                                var names = [i18n("System default output")];
                                var outs = mediaDevices.audioOutputs;
                                for (var i = 0; i < outs.length; i++)
                                    names.push(outs[i].description);
                                return names;
                            }
                            currentIndex: {
                                var wanted = Plasmoid.configuration.audioOutputDevice || "";
                                if (wanted === "") return 0;
                                var outs = mediaDevices.audioOutputs;
                                for (var i = 0; i < outs.length; i++)
                                    if (String(outs[i].id) === wanted) return i + 1;
                                return 0;
                            }
                            onActivated: function(index) {
                                var outs = mediaDevices.audioOutputs;
                                root.setAudioOutputDevice(index === 0 ? "" : String(outs[index - 1].id));
                            }
                        }

                        // Every local output at once, in sync: a PipeWire
                        // combined sink with latency compensation delays the
                        // wired outputs to match Bluetooth, so multiple
                        // speakers play together instead of echoing.
                        PlasmaComponents3.CheckDelegate {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            text: i18n("All local outputs, in sync")
                            icon.name: "speaker"
                            visible: root.sync._combineAvailable
                                     && (root.sync._combineWantActive || mediaDevices.audioOutputs.length >= 2)
                            // Bound to the INTENT flag (flips with the click),
                            // not the async pactl ack — and re-bound after
                            // every toggle, because the click itself severs a
                            // declarative binding. A failed load resets the
                            // intent and the box unchecks itself.
                            checked: root.sync._combineWantActive
                            onToggled: {
                                if (checked) root.sync.combineOutputsEnable()
                                else root.sync.combineOutputsDisable()
                                checked = Qt.binding(function() { return root.sync._combineWantActive })
                            }

                            PlasmaComponents3.ToolTip {
                                text: i18n("Plays on every connected speaker at the same time — wired outputs are delayed to stay in step with Bluetooth.")
                            }
                        }

                        // Bluetooth speakers buffer more than they admit —
                        // this nudges the wired outputs back until they match.
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            Layout.rightMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            visible: root.sync._combineWantActive

                            PlasmaComponents3.Label {
                                text: i18n("Sync fine-tune")
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                            PlasmaComponents3.Slider {
                                id: syncSlider
                                Layout.fillWidth: true
                                from: 0
                                // Matches the calibration's sanity ceiling —
                                // slow televisions really sit past 500 ms.
                                to: 900
                                stepSize: 10
                                value: Plasmoid.configuration.syncOffsetMs || 0
                                onMoved: root.sync.setSyncOffset(value)

                                PlasmaComponents3.ToolTip {
                                    text: i18n("If the Bluetooth speaker still trails the wired ones, raise this until they play together.")
                                }
                            }
                            PlasmaComponents3.Label {
                                text: Math.round(syncSlider.value) + " ms"
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }

                        // One button instead of ears: clicks through each
                        // speaker, the microphone times the arrivals, the
                        // slider sets itself.
                        PlasmaComponents3.ItemDelegate {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            visible: root.sync._combineWantActive && !root.sync._calibrating
                            enabled: root.sync.calibPairReady()
                            text: i18n("Calibrate with the microphone")
                            icon.name: "audio-input-microphone"
                            onClicked: root.sync.calibrateSync()

                            PlasmaComponents3.ToolTip {
                                text: i18n("Plays a few loud clicks through each speaker and measures with the microphone how far the Bluetooth speaker trails — the delay is set automatically.")
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            Layout.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            visible: root.sync._calibrating
                            PlasmaComponents3.BusyIndicator {
                                implicitWidth: Kirigami.Units.iconSizes.small
                                implicitHeight: implicitWidth
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("Listening to the clicks…")
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }

                        // Per-speaker balance while the combined output runs:
                        // the volume slider stays the master for the room,
                        // each speaker keeps its share of it. Applied to our
                        // own loopback only — other applications' audio and
                        // the speaker's own buttons are left alone.
                        Repeater {
                            // The FULL sink list, not the group: an excluded
                            // speaker must keep its row or there would be no
                            // way to bring it back in.
                            model: root.sync._combineWantActive ? root.sync._combineAllSinks() : []
                            delegate: RowLayout {
                                id: balanceRow
                                required property string modelData
                                readonly property string trimKey: root.sync._trimKeyForSink(modelData)
                                readonly property bool inGroup: { void root.sync._exclRev; return root.sync.syncDeviceIncluded(trimKey) }
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                                Layout.rightMargin: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing

                                // A speaker can sit an evening out without
                                // being disconnected — "everything except
                                // the bedroom" is one click.
                                PlasmaComponents3.CheckBox {
                                    checked: balanceRow.inGroup
                                    onToggled: {
                                        root.sync.setSyncDeviceIncluded(balanceRow.trimKey, checked)
                                        // The click broke the declarative
                                        // binding — put it back so an
                                        // enable-time exclusion reset (or a
                                        // second widget instance) still
                                        // reaches this box.
                                        checked = Qt.binding(function() { return balanceRow.inGroup })
                                    }

                                    PlasmaComponents3.ToolTip {
                                        text: i18n("Whether this speaker plays in the group — untick to leave it out without disconnecting it. Remembered for the device.")
                                    }
                                }
                                PlasmaComponents3.Label {
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                                    text: root.sync.outputDescription(balanceRow.modelData)
                                    font: Kirigami.Theme.smallFont
                                    opacity: balanceRow.inGroup ? 0.7 : 0.35
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents3.Slider {
                                    id: balanceSlider
                                    Layout.fillWidth: true
                                    from: 5
                                    to: 100
                                    stepSize: 1
                                    enabled: balanceRow.inGroup
                                    value: { void root.sync._trimRev; return Math.round(root.sync.trimOf(balanceRow.trimKey) * 100) }
                                    onMoved: root.sync.setDeviceTrim(balanceRow.trimKey, value / 100)

                                    PlasmaComponents3.ToolTip {
                                        text: i18n("This speaker's share of the volume — the balance follows every master move and is remembered for the device.")
                                    }
                                }
                                PlasmaComponents3.Label {
                                    text: Math.round(balanceSlider.value) + "%"
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                }
                                // Stereo pair, one click at a time: ST → L →
                                // R → M. Two speakers set to L and R make a
                                // true pair; M is the mono mix for a speaker
                                // standing alone in another room.
                                PlasmaComponents3.ToolButton {
                                    id: channelButton
                                    readonly property string chMode: { void root.sync._chanRev; return root.sync.channelOf(balanceRow.trimKey) }
                                    enabled: balanceRow.inGroup
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                                    text: chMode === "L" ? i18nc("compact: speaker plays the left channel", "L")
                                        : chMode === "R" ? i18nc("compact: speaker plays the right channel", "R")
                                        : chMode === "M" ? i18nc("compact: speaker plays a mono mix", "M")
                                        : i18nc("compact: speaker plays plain stereo", "ST")
                                    font.bold: chMode !== "S"
                                    onClicked: root.sync.cycleDeviceChannel(balanceRow.trimKey)

                                    PlasmaComponents3.ToolTip {
                                        text: i18n("Which channels this speaker plays: stereo, left only, right only, or a mono mix of both. Set one speaker to L and another to R for a true stereo pair — remembered for the device.")
                                    }
                                }
                            }
                        }

                        // Paired Bluetooth speakers/headphones that are not
                        // connected yet — one click connects and, once the
                        // sink appears, playback is routed onto it. Connected
                        // ones can be dropped the same way. Pairing itself
                        // stays in System Settings.
                        Kirigami.Separator {
                            Layout.fillWidth: true
                            visible: root._btAvailable
                            opacity: 0.4
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            visible: root._btAvailable
                            Kirigami.Icon {
                                source: "network-bluetooth"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                opacity: 0.7
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("Bluetooth")
                                font.weight: Font.DemiBold
                                opacity: 0.7
                            }
                        }

                        // An empty device list is ambiguous — say WHY. A dead
                        // adapter (firmware, rfkill, no hardware) and "nothing
                        // paired yet" look identical otherwise, and users
                        // blame the widget for the system's Bluetooth being
                        // down.
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            visible: root._btAvailable && !root._btControllerUp
                            text: i18n("Bluetooth is off or no adapter is available — check System Settings.")
                            font: Kirigami.Theme.smallFont
                            opacity: 0.6
                            wrapMode: Text.WordWrap
                        }

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            visible: root._btAvailable && root._btControllerUp
                                     && btDevicesModel.count === 0 && !root._btListing
                            text: i18n("No paired Bluetooth audio devices — pair the speaker once in System Settings and it appears here.")
                            font: Kirigami.Theme.smallFont
                            opacity: 0.6
                            wrapMode: Text.WordWrap
                        }

                        Repeater {
                            model: btDevicesModel
                            delegate: PlasmaComponents3.CheckDelegate {
                                required property string mac
                                required property string name
                                required property bool connected
                                Layout.fillWidth: true
                                text: root._btConnectingMac === mac
                                      ? i18n("%1 — connecting…", name) : name
                                icon.name: "network-bluetooth"
                                checked: connected
                                enabled: root._btConnectingMac === "" && root._btPairingMac === ""
                                onToggled: connected ? root.btDisconnect(mac)
                                                     : root.btConnect(mac, name)
                            }
                        }

                        // Freshly discovered, not yet paired — one click
                        // pairs, trusts and connects, and the music follows.
                        Repeater {
                            model: btFoundModel
                            delegate: PlasmaComponents3.ItemDelegate {
                                required property string mac
                                required property string name
                                Layout.fillWidth: true
                                text: root._btPairingMac === mac
                                      ? i18n("%1 — pairing…", name)
                                      : i18n("%1 — new, click to pair", name)
                                icon.name: "list-add"
                                enabled: root._btPairingMac === ""
                                onClicked: root.btPairNew(mac, name)
                            }
                        }

                        PlasmaComponents3.ItemDelegate {
                            Layout.fillWidth: true
                            visible: root._btAvailable && root._btControllerUp
                                     && !root._btScanning
                            text: i18n("Pair a new speaker…")
                            icon.name: "edit-find"
                            onClicked: root.btScan()
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            visible: root._btScanning
                            spacing: Kirigami.Units.smallSpacing
                            PlasmaComponents3.BusyIndicator {
                                implicitWidth: Kirigami.Units.iconSizes.small
                                implicitHeight: implicitWidth
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("Searching — put the speaker in pairing mode…")
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true; opacity: 0.4 }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: "network-wireless"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                opacity: 0.7
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("WiFi & network")
                                font.weight: Font.DemiBold
                                opacity: 0.7
                            }
                        }

                        Repeater {
                            model: castDevicesModel
                            // Per-role required properties, NOT `required
                            // property var model`: a role named "model"
                            // shadowed the delegate's model object and left
                            // every row blank (2026.8).
                            delegate: ColumnLayout {
                                id: castRow
                                required property string kind
                                required property string uuid
                                required property string name
                                required property string host
                                required property int port
                                required property string deviceModel
                                required property string location
                                // Speaker groups made in the Google Home app
                                // are one mDNS entry with this model name.
                                // Google keeps the members sample-synced —
                                // the only true whole-home sync we can offer.
                                readonly property bool isGroup: deviceModel === "Google Cast Group"
                                readonly property bool isTarget: root.castTargetIndex(uuid) >= 0
                                Layout.fillWidth: true
                                spacing: 0

                                PlasmaComponents3.CheckDelegate {
                                    Layout.fillWidth: true
                                    text: castRow.isGroup ? i18n("%1 (speaker group)", castRow.name) : castRow.name
                                    // The icon answers "how is this connected?" —
                                    // WiFi fan vs Bluetooth rune vs the group
                                    // glyph — so the menu reads at a glance which
                                    // radio a device is on (asked for explicitly:
                                    // everything connectable from one place).
                                    icon.name: castRow.isGroup ? "audio-speakers-symbolic" : "network-wireless"
                                    checked: castRow.isTarget
                                    onToggled: root.castToggleDevice({
                                        "kind": castRow.kind, "uuid": castRow.uuid, "name": castRow.name,
                                        "host": castRow.host, "port": castRow.port,
                                        "deviceModel": castRow.deviceModel, "location": castRow.location
                                    })
                                }

                                // Balance for a picked device — its share of
                                // the master volume, so one slider drives all
                                // rooms without flattening their levels. A
                                // freshly joined device adopts the loudness
                                // it already had.
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Kirigami.Units.gridUnit * 2
                                    Layout.rightMargin: Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing
                                    visible: castRow.isTarget

                                    PlasmaComponents3.Label {
                                        text: i18n("Balance")
                                        font: Kirigami.Theme.smallFont
                                        opacity: 0.7
                                    }
                                    PlasmaComponents3.Slider {
                                        id: castBalanceSlider
                                        Layout.fillWidth: true
                                        from: 5
                                        to: 100
                                        stepSize: 1
                                        value: { void root.sync._trimRev; return Math.round(root.sync.trimOf(castRow.uuid) * 100) }
                                        onMoved: root.sync.setDeviceTrim(castRow.uuid, value / 100)

                                        PlasmaComponents3.ToolTip {
                                            text: i18n("This device's share of the volume — the balance follows every master move and is remembered for the device.")
                                        }
                                    }
                                    PlasmaComponents3.Label {
                                        text: Math.round(castBalanceSlider.value) + "%"
                                        font: Kirigami.Theme.smallFont
                                        opacity: 0.7
                                    }
                                }
                            }
                        }

                        // Honesty about multi-room: every target buffers the
                        // stream on its own, so separately-picked devices sit
                        // seconds apart and there is no protocol-level way to
                        // line them up. Only a Cast speaker group (made in
                        // Google Home, clock-synced by Google, one entry
                        // here) plays in true sync — point the user there.
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            visible: root._castTargets.length > 1
                            text: i18n("Each device buffers on its own, so rooms may play a few seconds apart. For perfectly synced speakers, group them in the Google Home app — the group appears here as a single device.")
                            wrapMode: Text.Wrap
                            opacity: 0.6
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }

                        // One-click way out: stop every device, back to local.
                        PlasmaComponents3.ItemDelegate {
                            Layout.fillWidth: true
                            visible: root._castTargets.length > 0
                            text: i18n("Stop casting everywhere")
                            icon.name: "media-playback-stop"
                            onClicked: {
                                root.castDisconnect()
                                castMenu.close()
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            visible: root._castDiscovering
                            PlasmaComponents3.BusyIndicator {
                                implicitWidth: Kirigami.Units.iconSizes.small
                                implicitHeight: Kirigami.Units.iconSizes.small
                                running: parent.visible
                            }
                            PlasmaComponents3.Label {
                                text: i18n("Searching for devices…")
                                opacity: 0.7
                            }
                        }

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            Layout.margins: Kirigami.Units.smallSpacing
                            visible: !root._castDiscovering && castDevicesModel.count === 0
                            text: i18n("No devices found on your network")
                            wrapMode: Text.Wrap
                            opacity: 0.6
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        }
                    }
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
                        root.setUserVolume(playMusicOutput.volume + step)
                    }
                }

                QQC2.Popup {
                    id: volumePopup
                    y: -height - Kirigami.Units.smallSpacing
                    x: -width + parent.width
                    padding: Kirigami.Units.smallSpacing * 1.5
                    modal: false
                    // Keyboard path: opening moves focus onto the slider (arrow
                    // keys adjust, Esc closes), closing hands it back to the button
                    focus: true
                    onOpened: volumeSlider.forceActiveFocus()
                    onClosed: volumeBtn.forceActiveFocus()

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
                            // Same step as the wheel (arrow keys would jump 10% otherwise)
                            stepSize: 0.05
                            value: playMusicOutput.volume
                            onMoved: root.setUserVolume(value)
                            Accessible.name: i18n("Volume")
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
