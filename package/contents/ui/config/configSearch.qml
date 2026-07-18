

/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2023 ivan tkachenko <me@ratijas.tk>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import QtMultimedia
import org.kde.plasma.plasmoid
import org.kde.kcmutils as KCM
import ".." as ARP

KCM.ScrollViewKCM {
    id: root

    property var items: ["de1"]
    property string server: "de1"
    property string cfg_servers: plasmoid.configuration.servers

    property int limit: 500
    property int offset: 0
    property string currentUrl
    property int stat: 1
    property bool isNoSearch: false
    property int _retryCount: 0
    property int _maxRetries: 3
    property var _activeXhr: null
    property var _activeLoadMoreXhr: null
    property int _httpTimeout: 15000

    // The catalog is publicly writable, so a row's favicon and stream URL are
    // untrusted: a file:// or data: favicon would probe local files behind
    // the Icon, and a file:// url_resolved would point the preview player (or
    // a saved station) at a local path. Every row is gated to http(s) as it
    // enters the model — the same rule the popup's own search enforces.
    function _webUrlOrEmpty(v) {
        const s = v && v !== "null" ? String(v).trim() : ""
        return /^https?:\/\//i.test(s) ? s : ""
    }

    function _appendRow(srv) {
        srv.name = (srv.name || "").replace(/\n/g, ' ').trim()
        srv.favicon = _webUrlOrEmpty(srv.favicon)
        srv.url_resolved = _webUrlOrEmpty(srv.url_resolved || srv.url)
        srv.homepage = _webUrlOrEmpty(srv.homepage)
        srv.added = false
        searchModel.append(srv)
    }

    ListModel {
        id: searchModel
        dynamicRoles: true
    }

    ARP.StationsModel {
        id: stationsModel
    }

    property int _serverIdx: -1

    // The first pick lands on a random mirror (the directory asks clients
    // to spread load); every retry then WALKS the list instead of drawing
    // again — the same dead mirror could be drawn twice in a row and eat
    // two of the three retries.
    function getServer() {
        _serverIdx = _serverIdx < 0
            ? Math.floor(Math.random() * items.length)
            : (_serverIdx + 1) % items.length
        server = items[_serverIdx]
    }

    // QML XHR's xhr.timeout/ontimeout are silently ignored by Qt — every
    // "timeout" on this page was dead code and a hung connection meant
    // "Please wait…" forever. A Timer that calls abort() is the real thing:
    // abort drives readyState to DONE with status 0, which lands in the same
    // error/retry paths a failed request takes.
    Component {
        id: xhrTimeoutGuard
        Timer { repeat: false }
    }

    function _armXhrTimeout(xhr, ms) {
        const t = xhrTimeoutGuard.createObject(root, { "interval": ms })
        t.triggered.connect(() => {
            try { xhr.abort() } catch(e) {}
            try { t.destroy() } catch(e) {}
        })
        t.start()
        return t
    }

    function _clearXhrTimeout(t) {
        if (!t) return
        try { t.stop(); t.destroy() } catch(e) {}
    }

    function discoverServers() {
        const xhr = new XMLHttpRequest
        var guard = null
        xhr.open("GET", "https://all.api.radio-browser.info/json/servers")
        setHeaders(xhr)
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return
            _clearXhrTimeout(guard)
            const finish = () => {
                if (items.length === 0)
                    items = ["de1"]
                getServer()
                getStations()
            }
            if (xhr.status === 200) {
                try {
                    const servers = JSON.parse(xhr.responseText)
                    const seen = {}
                    const names = []
                    for (const s of servers) {
                        const m = s.name.match(/^([a-z]+\d+)\.api\.radio-browser\.info$/)
                        if (m && !seen[m[1]]) {
                            seen[m[1]] = true
                            names.push(m[1])
                        }
                    }
                    if (names.length > 0)
                        items = names
                } catch(e) {}
            }
            finish()
        }
        guard = _armXhrTimeout(xhr, 5000)
        xhr.send()
    }

    function setHeaders(xhr) {
        xhr.setRequestHeader("User-Agent", "OnAir/2026.19")
    }

    function getStations(by, val) {
        isNoSearch = !(typeof by !== "undefined" && by !== null)
        offset = 0
        _retryCount = 0
        _doGetStations(by, val)
    }

    function _doGetStations(by, val) {
        busy.running = true
        busy.visible = true
        gettext.visible = true
        gettext.text = i18n("Get list of stations\nPlease wait…")
        view.enabled = false

        if (!server || server === "")
            server = "de1"

        // Clear the "active" slot BEFORE aborting: abort() dispatches the old
        // request's readystatechange synchronously, and without this order a
        // superseded request would enter the retry chain and double-query.
        if (_activeXhr) {
            const old = _activeXhr
            _activeXhr = null
            try { old.abort() } catch(e) {}
        }
        if (_activeLoadMoreXhr) {
            const oldLm = _activeLoadMoreXhr
            _activeLoadMoreXhr = null
            try { oldLm.abort() } catch(e) {}
        }

        const cleanVal = (val || "").toString().trim()
        const byVal = isNoSearch ? "" : `/${by}/${encodeURIComponent(cleanVal)}`
        const url = `https://${server}.api.radio-browser.info/json/stations${byVal}?hidebroken=true&limit=${limit}&offset=${offset}`

        const xhr = new XMLHttpRequest
        var guard = null
        xhr.open("GET", url)
        setHeaders(xhr)
        _activeXhr = xhr
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return
            _clearXhrTimeout(guard)
            if (_activeXhr !== xhr)
                return // superseded by a newer search
            _activeXhr = null
            if (xhr.status === 200) {
                // A 200 with a non-JSON body (captive portal, HTML error page)
                // must fall into the retry chain — an unguarded JSON.parse throw
                // would leave the page on "Please wait…" forever.
                try {
                    var servers = JSON.parse(xhr.responseText)
                    // Reset the retry counter only AFTER a successful parse.
                    _retryCount = 0
                    currentUrl = url.split("?")[0]
                    searchModel.clear()
                    for (var i = 0; i < servers.length; i++)
                        _appendRow(servers[i])
                    busy.running = false
                    busy.visible = false
                    gettext.visible = servers.length === 0
                    gettext.text = servers.length === 0
                        ? i18n("Nothing found\nTry changing your query")
                        : i18n("Get list of stations\nPlease wait…")
                    view.enabled = true
                    stat = 1
                } catch (e) {
                    _retryCount++
                    if (_retryCount < _maxRetries) {
                        getServer()
                        _doGetStations(by, val)
                    } else {
                        busy.running = false
                        busy.visible = false
                        gettext.visible = true
                        gettext.text = i18n("Error: Could not connect to API servers")
                        view.enabled = true
                    }
                }
            } else {
                _retryCount++
                if (_retryCount < _maxRetries) {
                    getServer()
                    _doGetStations(by, val)
                } else {
                    busy.running = false
                    busy.visible = false
                    gettext.visible = true
                    gettext.text = i18n("Error: Could not connect to API servers")
                    view.enabled = true
                }
            }
        }
        guard = _armXhrTimeout(xhr, _httpTimeout)
        xhr.send()
    }

    function loadMore() {
        if (!currentUrl)
            return
        stat = 0
        if (_activeLoadMoreXhr) {
            const oldLm = _activeLoadMoreXhr
            _activeLoadMoreXhr = null
            try { oldLm.abort() } catch(e) {}
        }
        const xhr = new XMLHttpRequest
        var guard = null
        const baseUrl = currentUrl.split("?")[0]
        // The cursor advances only on a successfully parsed page — the old
        // scroll-time increment skipped a failed page forever: one timeout
        // and rows 500-999 simply never existed for that session.
        const nextOffset = offset + limit
        const url = `${baseUrl}?hidebroken=true&limit=${limit}&offset=${nextOffset}`
        xhr.open("GET", url)
        setHeaders(xhr)
        _activeLoadMoreXhr = xhr
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return
            _clearXhrTimeout(guard)
            if (_activeLoadMoreXhr !== xhr)
                return // superseded
            _activeLoadMoreXhr = null
            if (xhr.status === 200) {
                try {
                    const servers = JSON.parse(xhr.responseText)
                    // Update currentUrl and the cursor only after a
                    // successful parse.
                    currentUrl = url
                    offset = nextOffset
                    if (servers.length > 0) {
                        for (const srv of servers)
                            _appendRow(srv)
                        stat = 1
                    }
                } catch (e) {
                    // Restore stat so the scroll trigger can try again.
                    stat = 1
                }
            } else {
                // Failed/timed-out page load — let scrolling retry it.
                stat = 1
            }
        }
        guard = _armXhrTimeout(xhr, _httpTimeout)
        xhr.send()
    }

    // Snapshot of the last state synced with plasmoid.configuration.servers —
    // see configGeneral.qml for the rationale (⭐ from the popup while the
    // settings window is open must not be lost on Apply).
    property string _lastSynced: ""

    Component.onCompleted: {
        stationsModel.clear()
        const servers = JSON.parse(cfg_servers)
        for (const srv of servers) {
            stationsModel.append(srv)
        }
        _lastSynced = cfg_servers
        stat = 0
        discoverServers()
    }

    Connections {
        target: plasmoid.configuration
        function onServersChanged() {
            const external = plasmoid.configuration.servers
            if (external === root.cfg_servers) {
                root._lastSynced = external
                return
            }
            if (root.cfg_servers === root._lastSynced) {
                try {
                    const servers = JSON.parse(external)
                    stationsModel.clear()
                    for (const srv of servers) stationsModel.append(srv)
                    root.cfg_servers = external
                    root._lastSynced = external
                } catch (e) {}
            } else {
                try {
                    const ext = JSON.parse(external)
                    const have = {}
                    for (var i = 0; i < stationsModel.count; i++)
                        have[stationsModel.get(i).hostname] = true
                    var added = false
                    for (const srv of ext) {
                        if (!have[srv.hostname]) { stationsModel.append(srv); added = true }
                    }
                    if (added) root.cfg_servers = JSON.stringify(getServersArray())
                } catch (e) {}
            }
        }
    }

    Kirigami.Dialog {
        id: searchDrawer

        title: i18n("Search Station")
        padding: Kirigami.Units.largeSpacing
        standardButtons: Kirigami.Dialog.NoButton

        RowLayout {
            QQC2.Label {
                text: i18n("Search by")
            }
            QQC2.ComboBox {
                id: by
                textRole: "label"
                valueRole: "value"
                model: [
                    { label: i18n("name"), value: "byname" },
                    { label: i18n("country"), value: "bycountry" },
                    { label: i18n("language"), value: "bylanguage" },
                    { label: i18n("tags"), value: "bytag" }
                ]
            }
            Kirigami.SearchField {
                id: search

                Layout.fillWidth: true

                autoAccept: false

                onAccepted: {
                    const cleaned = text.trim()
                    if (cleaned !== "") {
                        const filter = by.currentValue || "byname"
                        testPlay.stop()
                        searchModel.clear()
                        root.currentUrl = ""
                        root.getStations(filter, cleaned)
                        searchDrawer.close()
                    } else {
                        if (!root.isNoSearch) {
                            searchModel.clear()
                            root.getStations()
                            searchDrawer.close()
                        }
                    }
                }
            }

            QQC2.Button {
                icon.name: "search"
                enabled: search.text !== ""
                onClicked: {
                    search.accepted()
                }
            }
        }

        onOpened: search.forceActiveFocus(Qt.MouseFocusReason)
    }

    Component {
        id: delegateComponent
        Item {
            id: listItem
            required property int index
            required property var model
            required property string name
            width: ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin
            height: swipeListItem.height
            Kirigami.SwipeListItem {
                id: swipeListItem
                down: false
                Kirigami.Theme.inherit: false
                Kirigami.Theme.colorSet: Kirigami.Theme.View
                alternatingBackground: true

                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        z: 2
                        source: listItem.model.favicon ? listItem.model.favicon : "view-media-track"
                        placeholder: "view-media-track"
                        fallback: "view-media-track"
                    }

                    Item {
                        id: trackRect

                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        clip: true

                        QQC2.Label {
                            id: trackName

                            text: listItem.name.trim().replace(/\n/g, " ")
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                            color: swipeListItem.textColor

                            XAnimator {
                                target: trackName
                                from: 0
                                to: -trackName.paintedWidth
                                duration: Math.round(
                                              Math.abs(
                                                  to - from) / Kirigami.Units.gridUnit * 300
                                              * plasmoid.configuration.speedfactor)
                                running: swipeListItem.containsMouse
                                         && trackName.width > trackRect.width
                                loops: 1
                                onFinished: {
                                    from = trackRect.width
                                    if (swipeListItem.containsMouse) {
                                        start()
                                    }
                                }
                                onStopped: {
                                    from = 0
                                    trackName.x = 0
                                }
                            }
                        }
                    }

                    Kirigami.Chip {
                        // Directory field, untrusted — Chip has no textFormat,
                        // so the value itself is reduced to the codec charset:
                        // an <img>/markup in a station's codec cannot survive
                        // to be interpreted as rich text.
                        text: (listItem.model.codec || "").replace(/[^A-Za-z0-9+.\/-]/g, "")
                        closable: false
                        enabled: false
                        visible: text !== "" && text !== "UNKNOWN"
                        implicitWidth: implicitContentWidth
                    }

                    Kirigami.Chip {
                        id: bitrate

                        text: listItem.model.bitrate ? i18n("%1 kBit/s", listItem.model.bitrate) : ""
                        closable: false
                        enabled: false
                        visible: listItem.model.bitrate !== 0
                        implicitWidth: implicitContentWidth
                    }

                    // Inline buttons instead of SwipeListItem "actions": the
                    // actions overlay is painted ON TOP of the row's right edge
                    // and collided with the codec/bitrate chips.
                    QQC2.ToolButton {
                        display: QQC2.AbstractButton.IconOnly
                        icon.name: "documentinfo"
                        QQC2.ToolTip.text: i18n("Info")
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                        onClicked: {
                            listItem.ListView.view.currentIndex = listItem.index
                            if (testPlay.source != listItem.model.url_resolved) {
                                testPlay.stop()
                            }
                            message.visible = false
                            infoSheet.open()
                        }
                    }

                    QQC2.ToolButton {
                        display: QQC2.AbstractButton.IconOnly
                        icon.name: listItem.model.added ? "checkbox" : "list-add"
                        // A row whose stream URL failed the http(s) gate has
                        // an empty url_resolved — there is nothing to add.
                        enabled: !listItem.model.added && listItem.model.url_resolved !== ""
                        QQC2.ToolTip.text: i18n("Add Station")
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                        onClicked: {
                            listItem.ListView.view.currentIndex = listItem.index
                            if (testPlay.source != listItem.model.url_resolved) {
                                testPlay.stop()
                            }
                            searchModel.setProperty(listItem.index,
                                                    "added", true)
                            const src = searchModel.get(listItem.index)
                            // favicon and url_resolved were gated to http(s)
                            // as the row entered the model (_appendRow).
                            const itemObject = {
                                "name": src.name,
                                "hostname": src.url_resolved,
                                "favicon": src.favicon || "",
                                "country": src.country || "",
                                "active": true
                            }
                            stationsModel.append(itemObject)
                            cfg_servers = JSON.stringify(getServersArray())
                            if (!message.visible) {
                                message.positive = true
                                message.text = i18n(
                                    "Station is added. Click 'Apply' to save changes.")
                                message.visible = true
                                closetimer.restart()
                            }
                        }
                    }

                    QQC2.ToolButton {
                        readonly property bool playingThis: root.isPlaying()
                                                            && testPlay.source == listItem.model.url_resolved
                        display: QQC2.AbstractButton.IconOnly
                        icon.name: playingThis ? "media-playback-stop" : "media-playback-start"
                        // Per-ROW check — the old binding looked at the SELECTED
                        // row's lastcheckok, so buttons enabled/disabled wrongly.
                        // An empty url_resolved (failed the http(s) gate) is
                        // not playable.
                        enabled: listItem.model.lastcheckok == 1 && listItem.model.url_resolved !== ""
                        QQC2.ToolTip.text: playingThis ? i18n("Stop") : i18n("Play")
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                        onClicked: {
                            listItem.ListView.view.currentIndex = listItem.index
                            message.visible = false
                            const currentUrl = listItem.model.url_resolved
                            if (root.isPlaying()
                                && testPlay.source == currentUrl) {
                                testPlay.stop()
                                testPlay.source = ""
                            } else {
                                testPlay.stop()
                                testPlay.source = currentUrl
                                testPlay.play()
                            }
                        }
                    }
                }
            }
        }
    }

    view: ListView {
        id: mainList

        model: searchModel
        moveDisplaced: Transition {
            YAnimator {
                duration: Kirigami.Units.longDuration
                easing.type: Easing.InOutQuad
            }
        }
        onContentYChanged: {
            if (contentY > contentHeight - height * 2 && root.stat == 1) {
                loadMore()
            }
        }
        reuseItems: true
        delegate: delegateComponent

        ColumnLayout {
            Layout.fillWidth: true
            anchors.centerIn: parent
            spacing: 0

            QQC2.BusyIndicator {
                id: busy
                running: false
                enabled: true
                implicitWidth: Kirigami.Units.iconSizes.enormous
                implicitHeight: Kirigami.Units.iconSizes.enormous
                Layout.alignment: Qt.AlignHCenter
            }

            QQC2.Label {
                id: gettext
                text: i18n("Get list of stations\nPlease wait…")
                visible: false
                enabled: true
                horizontalAlignment: Text.AlignHCenter
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    // }
    Kirigami.Separator {
        Layout.fillWidth: true
    }

    Timer {
        id: closetimer

        running: false
        repeat: false
        interval: 10000
        onTriggered: {
            message.visible = false
        }
    }

    footer: ColumnLayout {
        Kirigami.InlineMessage {
            id: message

            property bool positive
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            visible: false
            showCloseButton: true
            type: positive ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error
        }
        RowLayout {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing

            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: i18n("Search…")
                icon.name: "search"
                onClicked: searchDrawer.open()
            }

            Item {
                Layout.fillWidth: true
            }

            QQC2.Button {
                text: i18n("Clear Results")
                icon.name: "edit-clear-all"
                enabled: search.text !== ""
                onClicked: {
                    // The row being auditioned is about to vanish from the
                    // list — a preview nobody can see (or stop) must not
                    // keep playing.
                    testPlay.stop()
                    // Reload the default list DIRECTLY — routing through
                    // search.accepted() is a no-op when no search had been run
                    // (isNoSearch still true) and left the page blank forever.
                    search.text = ""
                    searchModel.clear()
                    root.getStations()
                }
            }
        }
    }

    Kirigami.Dialog {
        id: infoSheet
        padding: Kirigami.Units.largeSpacing
        title: i18n("Station Info")
        standardButtons: Kirigami.Dialog.NoButton
        contentItem: Kirigami.FormLayout {
            id: formLayout
            wideMode: true
            Kirigami.Heading {
                Kirigami.FormData.label: i18n("Name:")

                textFormat: Text.PlainText
                Layout.maximumWidth: root.width - Kirigami.Units.smallSpacing
                Layout.preferredWidth: root.width - Kirigami.Units.smallSpacing
                text: mainList.currentIndex !== -1 ? searchModel.get(
                                                         mainList.currentIndex).name : ""
                wrapMode: Text.Wrap
                verticalAlignment: Text.AlignVCenter
            }

            Kirigami.Icon {
                Kirigami.FormData.label: i18n("Favicon:")

                // Layout.preferredWidth: Kirigami.Units.iconSizes.huge
                // Layout.preferredHeight: Kirigami.Units.iconSizes.huge
                source: mainList.currentIndex !== -1 && searchModel.get(
                            mainList.currentIndex).favicon
                        != "" ? searchModel.get(
                                    mainList.currentIndex).favicon : "view-media-track"
                placeholder: "view-media-track"
                fallback: "view-media-track"
            }
            Kirigami.UrlButton {
                Kirigami.FormData.label: i18n("Homepage:")
                Layout.maximumWidth: root.width

                url: mainList.currentIndex !== -1 ? searchModel.get(
                                                        mainList.currentIndex).homepage : ""
                wrapMode: Text.WrapAnywhere
                horizontalAlignment: Text.AlignLeft
            }

            Kirigami.UrlButton {
                Kirigami.FormData.label: i18n("Stream URL:")
                Layout.maximumWidth: root.width

                url: mainList.currentIndex !== -1 ? searchModel.get(
                                                        mainList.currentIndex).url_resolved : ""
                wrapMode: Text.WrapAnywhere
                horizontalAlignment: Text.AlignLeft
            }

            QQC2.Label {
                property string status: {
                    if (mainList.currentIndex !== -1) {
                        if (searchModel.get(
                                    mainList.currentIndex).lastcheckok == 1) {
                            return i18n("OK")
                        } else {
                            return i18n("Error")
                        }
                    } else {
                        return ""
                    }
                }

                Kirigami.FormData.label: i18n("Server status:")
                Layout.maximumWidth: root.width

                text: {
                    if (mainList.currentIndex !== -1) {
                        const timeModel = searchModel.get(
                                            mainList.currentIndex).lastchecktime
                        const timeString = Date.fromLocaleString(
                                             Qt.locale(), timeModel,
                                             "yyyy-MM-dd hh:mm:ss").toLocaleString(
                                             Qt.locale(), Locale.ShortFormat)
                        return i18n("%1 (last check: %2)", status, timeString)
                    } else {
                        return ""
                    }
                }

                color: {
                    if (mainList.currentIndex !== -1) {
                        if (searchModel.get(
                                    mainList.currentIndex).lastcheckok == 1) {
                            return Kirigami.Theme.positiveTextColor
                        } else {
                            return Kirigami.Theme.negativeTextColor
                        }
                    } else {
                        return Kirigami.Theme.textColor
                    }
                }
            }

            Kirigami.Chip {
                Kirigami.FormData.label: i18n("Codec:")

                text: mainList.currentIndex !== -1 ? searchModel.get(
                                                         mainList.currentIndex).codec : ""
                closable: false
                checkable: false
                visible: mainList.currentIndex !== -1 && searchModel.get(
                             mainList.currentIndex).codec != "UNKNOWN"
            }

            Kirigami.Chip {
                Kirigami.FormData.label: i18n("Bitrate:")

                text: {
                    if (mainList.currentIndex !== -1) {
                        const bitrate = searchModel.get(
                                          mainList.currentIndex).bitrate
                        return i18n("%1 kBit/s", bitrate)
                    } else {
                        return ""
                    }
                }
                closable: false
                checkable: false
                visible: mainList.currentIndex !== -1 && searchModel.get(
                             mainList.currentIndex).bitrate != 0
            }

            QQC2.Label {
                Kirigami.FormData.label: i18n("Country:")

                textFormat: Text.PlainText
                visible: text !== ""
                text: mainList.currentIndex !== -1 ? searchModel.get(
                                                         mainList.currentIndex).country : ""
            }

            QQC2.Label {
                Kirigami.FormData.label: i18n("Language:")

                textFormat: Text.PlainText
                visible: text !== ""
                text: mainList.currentIndex !== -1 ? searchModel.get(
                                                         mainList.currentIndex).language : ""
            }

            Flow {
                Kirigami.FormData.label: i18n("Tags:")

                Layout.maximumWidth: root.width
                Layout.preferredWidth: root.width

                spacing: Kirigami.Units.smallSpacing
                visible: mainList.currentIndex !== -1 && searchModel.get(
                             mainList.currentIndex).tags.length > 0

                Repeater {
                    model: mainList.currentIndex !== -1 ? searchModel.get(
                                                              mainList.currentIndex).tags.split(
                                                              ",") : []

                    delegate: Kirigami.Chip {
                        closable: false
                        checkable: false
                        // Untrusted tag string — Chip has no textFormat, so
                        // strip anything that could read as markup rather
                        // than let it be interpreted as rich text.
                        text: (modelData || "").replace(/[<>&]/g, "")
                    }
                }
            }
        }
        //   }
    }

    // }
    MediaPlayer {
        id: testPlay
        audioOutput: AudioOutput {}
        onErrorOccurred: {
            message.positive = false
            message.text = i18n("Error: %1", testPlay.errorString)
            message.visible = true
            closetimer.restart()
        }
    }

    function isPlaying() {
        return testPlay.playbackState === MediaPlayer.PlayingState
    }

    function getServersArray() {
        const serversArray = []
        for (var i = 0; i < stationsModel.count; i++) {
            serversArray.push(stationsModel.get(i))
        }
        return serversArray
    }
}
