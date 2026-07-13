import ".." as ARP
import Qt.labs.platform as Labs
/*
* SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
* SPDX-FileCopyrightText: 2023 ivan tkachenko <me@ratijas.tk>
*
* SPDX-License-Identifier: LGPL-2.0-or-later
*/
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support 2.0 as P5Support
import org.kde.plasma.plasmoid

KCM.ScrollViewKCM {
    id: root

    property string cfg_servers: plasmoid.configuration.servers
    property int dialogMode: -1

    property var _apiServers: ["de1", "de2", "nl1", "at1", "fi1"]
    property string _apiServer: "de1"
    property var _logoQueue: []
    property int _logoTotal: 0
    property int _logoDone: 0
    property int _logoFound: 0
    property bool _logoFetching: false
    property var _activeLogoXhr: null

    function fileUtils(fileUrl, text, mode) {
        var file = fileUrl.toString().replace("file:///", "/").replace(/'/g, "'\\''");
        if (mode === 1) {
            var escapedText = text.replace(/'/g, "'\\''");
            // printf %s, NOT echo: a dash/busybox /bin/sh echo interprets the
            // backslash escapes JSON.stringify emits (\\, \n, \t) and corrupts
            // the exported file (same pattern as _mprisWriteState in main.qml).
            executable.exec("sh -c 'printf %s \"$1\" > \"$2\" && cat \"$2\"' _ '" + escapedText + "' '" + file + "'");
        } else {
            executable.exec("cat '" + file + "'");
        }
    }

    function showMessage(positive, text) {
        importexportmessage.positive = positive;
        importexportmessage.text = text;
        importexportmessage.visible = true;
        closetimer.restart();
    }

    function getServersArray() {
        var serversArray = [];
        for (var i = 0; i < stationsModel.count; i++) {
            serversArray.push(stationsModel.get(i));
        }
        return serversArray;
    }

    function addServer() {
        dialogMode = -1;
        serverName.text = "";
        serverHostname.text = "";
        serverFavicon.text = "";
        serverActive.checked = true;
        serverDialog.visible = true;
    }

    function editServer() {
        dialogMode = mainList.currentIndex;
        const item = stationsModel.get(dialogMode);
        serverName.text = item.name;
        serverHostname.text = item.hostname;
        serverFavicon.text = item.favicon ? item.favicon : "";
        serverActive.checked = item.active;
        serverDialog.visible = true;
    }

    function _pickApiServer() {
        _apiServer = _apiServers[Math.floor(Math.random() * _apiServers.length)];
    }

    // QML XHR ignores xhr.timeout/ontimeout entirely (Qt quirk) — the logo
    // fetcher could hang forever on one dead server. A Timer calling abort()
    // is the working replacement: abort lands in onreadystatechange with
    // status 0, i.e. the same path as any failed request.
    Component {
        id: xhrTimeoutGuard
        Timer { repeat: false }
    }

    function _armXhrTimeout(xhr, ms) {
        const t = xhrTimeoutGuard.createObject(root, { "interval": ms });
        t.triggered.connect(() => {
            try { xhr.abort() } catch(e) {}
            try { t.destroy() } catch(e) {}
        });
        t.start();
        return t;
    }

    function _clearXhrTimeout(t) {
        if (!t) return;
        try { t.stop(); t.destroy() } catch(e) {}
    }

    function fetchMissingLogos() {
        if (_logoFetching)
            return;
        _logoQueue = [];
        for (var i = 0; i < stationsModel.count; i++) {
            const it = stationsModel.get(i);
            const fav = it.favicon ? String(it.favicon).trim() : "";
            if (fav === "" || fav === "null") {
                _logoQueue.push({ "index": i, "name": it.name, "hostname": it.hostname });
            }
        }
        _logoTotal = _logoQueue.length;
        _logoDone = 0;
        _logoFound = 0;
        if (_logoTotal === 0) {
            showMessage(true, i18n("All stations already have a logo."));
            return;
        }
        _logoFetching = true;
        _pickApiServer();
        _fetchNextLogo();
    }

    function _fetchNextLogo() {
        if (_logoQueue.length === 0) {
            _logoFetching = false;
            cfg_servers = JSON.stringify(getServersArray());
            const missed = _logoTotal - _logoFound;
            if (missed === 0) {
                showMessage(true, i18n("Logo fetch complete: %1 / %2 stations updated. Click Apply to save.", _logoFound, _logoTotal));
            } else {
                showMessage(true, i18n("Logo fetch complete: %1 / %2 stations updated (%3 could not be found automatically). Click Apply to save.",
                                       _logoFound, _logoTotal, missed));
            }
            return;
        }
        const job = _logoQueue.shift();
        const cleanName = (job.name || "").replace(/\s+/g, " ").trim();
        if (cleanName === "") {
            _logoDone++;
            _fetchNextLogo();
            return;
        }
        _queryRadioBrowser(job, cleanName, 0);
    }

    function _queryRadioBrowser(job, cleanName, retryCount) {
        // search?name=... endpoint is robust against '/' and special chars (unlike byname/<path>)
        const url = "https://" + _apiServer + ".api.radio-browser.info/json/stations/search"
                  + "?name=" + encodeURIComponent(cleanName)
                  + "&limit=20&hidebroken=true&order=votes&reverse=true";
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", url);
        xhr.setRequestHeader("User-Agent", "OnAir/2026.13");
        _activeLogoXhr = xhr;
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return;
            _clearXhrTimeout(guard);
            if (_activeLogoXhr === xhr)
                _activeLogoXhr = null;
            let parseOk = false;
            let pickedFavicon = "";
            let pickedHomepage = "";
            if (xhr.status === 200) {
                const txt = xhr.responseText || "";
                if (txt.trim() !== "") {
                    try {
                        const results = JSON.parse(txt) || [];
                        parseOk = true;
                        const want = cleanName.toLowerCase();
                        let exactFav = "";
                        let exactHome = "";
                        let firstWithIcon = "";
                        let firstHome = "";
                        for (const r of results) {
                            const rn = (r.name || "").replace(/\s+/g, " ").trim().toLowerCase();
                            const fav = r.favicon && r.favicon !== "null" ? r.favicon : "";
                            const home = r.homepage && r.homepage !== "null" ? r.homepage : "";
                            if (firstHome === "" && home !== "")
                                firstHome = home;
                            if (firstWithIcon === "" && fav !== "")
                                firstWithIcon = fav;
                            if (rn === want) {
                                if (fav !== "" && exactFav === "")
                                    exactFav = fav;
                                if (home !== "" && exactHome === "")
                                    exactHome = home;
                            }
                            if (exactFav !== "" && exactHome !== "")
                                break;
                        }
                        pickedFavicon = exactFav !== "" ? exactFav : firstWithIcon;
                        pickedHomepage = exactHome !== "" ? exactHome : firstHome;
                    } catch (e) {
                        parseOk = false;
                    }
                }
            }
            if (!parseOk && retryCount < _apiServers.length - 1) {
                // server returned empty/error -> rotate to a different mirror
                _pickApiServer();
                _queryRadioBrowser(job, cleanName, retryCount + 1);
                return;
            }
            // Now we have the best-effort favicon and homepage. Build candidate list:
            //   1. API favicon (if any) - validated below to avoid storing dead URLs
            //   2. Homepage HTML scrape (extracts <link rel="icon|apple-touch-icon">)
            //   3. Standard well-known favicon paths on homepage origin
            //   4. Standard paths on the station's own hostname origin (streaming URL)
            //   5. Google s2/favicons fallback (last resort)
            if (pickedHomepage !== "") {
                _scrapeHomepageAndProbe(job, pickedFavicon, pickedHomepage);
            } else {
                // No homepage: build candidates from API favicon + hostname origin + Google fallback
                const candidates = [];
                if (pickedFavicon !== "")
                    candidates.push(pickedFavicon);
                for (const u of _hostnameStdCandidates(job.hostname))
                    if (candidates.indexOf(u) === -1)
                        candidates.push(u);
                for (const u of _googleFaviconCandidates(job.hostname))
                    if (candidates.indexOf(u) === -1)
                        candidates.push(u);
                _probeNextCandidate(job, candidates, 0);
            }
        };
        guard = _armXhrTimeout(xhr, 8000);
        xhr.send();
    }

    function _saveLogo(job, faviconUrl) {
        if (faviconUrl === "" || job.index >= stationsModel.count)
            return false;
        const cur = stationsModel.get(job.index);
        if (cur && cur.name === job.name) {
            stationsModel.setProperty(job.index, "favicon", faviconUrl);
            _logoFound++;
            return true;
        }
        return false;
    }

    function _originOf(url) {
        const m = String(url).match(/^(https?:\/\/[^\/]+)/i);
        return m ? m[1] : "";
    }

    function _resolveUrl(href, baseUrl) {
        if (!href)
            return "";
        href = String(href).trim();
        if (href === "" || href.charAt(0) === "#" || href.indexOf("data:") === 0
            || href.indexOf("javascript:") === 0)
            return "";
        if (href.indexOf("//") === 0)
            return "https:" + href;
        if (/^https?:\/\//i.test(href))
            return href;
        const origin = _originOf(baseUrl);
        if (origin === "")
            return "";
        if (href.charAt(0) === "/")
            return origin + href;
        // relative path - resolve against base URL directory
        const baseNoQuery = baseUrl.split("?")[0].split("#")[0];
        const lastSlash = baseNoQuery.lastIndexOf("/");
        const baseDir = lastSlash > 8 ? baseNoQuery.substring(0, lastSlash + 1) : (origin + "/");
        return baseDir + href;
    }

    function _extractIconLinks(html, baseUrl) {
        const out = [];
        if (!html)
            return out;
        // Find all <link ...> tags
        const linkRe = /<link\b([^>]*?)\/?>/gi;
        let m;
        while ((m = linkRe.exec(html)) !== null) {
            const attrs = m[1];
            // rel attribute
            const relMatch = attrs.match(/\brel\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
            if (!relMatch)
                continue;
            const rel = (relMatch[1] || relMatch[2] || relMatch[3] || "").toLowerCase();
            const isIcon = rel.indexOf("icon") !== -1 || rel.indexOf("apple-touch") !== -1
                        || rel.indexOf("shortcut") !== -1 || rel.indexOf("mask-icon") !== -1
                        || rel.indexOf("fluid-icon") !== -1;
            if (!isIcon)
                continue;
            // href attribute
            const hrefMatch = attrs.match(/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
            if (!hrefMatch)
                continue;
            const href = hrefMatch[1] || hrefMatch[2] || hrefMatch[3] || "";
            const resolved = _resolveUrl(href, baseUrl);
            if (resolved !== "" && out.indexOf(resolved) === -1)
                out.push(resolved);
        }
        // Also <meta property="og:image" ...>
        const ogRe = /<meta\b[^>]*?(?:property|name)\s*=\s*["']og:image["'][^>]*?content\s*=\s*["']([^"']+)["']/gi;
        while ((m = ogRe.exec(html)) !== null) {
            const resolved = _resolveUrl(m[1], baseUrl);
            if (resolved !== "" && out.indexOf(resolved) === -1)
                out.push(resolved);
        }
        return out;
    }

    function _scrapeHomepageAndProbe(job, apiFavicon, homepage) {
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", homepage);
        xhr.setRequestHeader("User-Agent", "Mozilla/5.0 (compatible; OnAir/2026.13)");
        xhr.setRequestHeader("Accept", "text/html,application/xhtml+xml,*/*");
        _activeLogoXhr = xhr;
        const stdCandidates = () => {
            const out = [];
            const origin = _originOf(homepage);
            if (origin !== "") {
                out.push(
                    origin + "/apple-touch-icon.png",
                    origin + "/apple-touch-icon-precomposed.png",
                    origin + "/favicon-194x194.png",
                    origin + "/favicon-192x192.png",
                    origin + "/favicon-96x96.png",
                    origin + "/favicon-32x32.png",
                    origin + "/favicon.ico"
                );
            }
            return out;
        };
        const fallback = () => {
            const candidates = [];
            if (apiFavicon !== "")
                candidates.push(apiFavicon);
            for (const u of stdCandidates()) {
                if (candidates.indexOf(u) === -1)
                    candidates.push(u);
            }
            _probeNextCandidate(job, candidates, 0);
        };
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return;
            _clearXhrTimeout(guard);
            if (_activeLogoXhr === xhr)
                _activeLogoXhr = null;
            const candidates = [];
            if (apiFavicon !== "")
                candidates.push(apiFavicon);
            // IMPORTANT: many SPAs/React sites (e.g. pleier.ee uses react-helmet) return 404
            // for unknown paths but the response body still contains the full HTML with icon
            // <link> tags. So scrape whenever the body looks like HTML, regardless of status.
            const respLen = xhr.responseText ? xhr.responseText.length : 0;
            const bodyLooksHtml = respLen > 200 && xhr.responseText.indexOf("<") !== -1;
            if (bodyLooksHtml) {
                const html = xhr.responseText.substring(0, 98304);
                const finalUrl = xhr.responseURL || homepage;
                const scraped = _extractIconLinks(html, finalUrl);
                for (const u of scraped) {
                    if (candidates.indexOf(u) === -1)
                        candidates.push(u);
                }
            }
            for (const u of stdCandidates()) {
                if (candidates.indexOf(u) === -1)
                    candidates.push(u);
            }
            // Final fallbacks: hostname origin std paths + Google s2/favicons
            for (const u of _hostnameStdCandidates(job.hostname))
                if (candidates.indexOf(u) === -1)
                    candidates.push(u);
            for (const u of _googleFaviconCandidates(job.hostname, homepage))
                if (candidates.indexOf(u) === -1)
                    candidates.push(u);
            _probeNextCandidate(job, candidates, 0);
        };
        guard = _armXhrTimeout(xhr, 12000);
        xhr.send();
    }

    function _hostnameStdCandidates(hostname) {
        const origin = _originOf(hostname);
        if (origin === "")
            return [];
        return [
            origin + "/apple-touch-icon.png",
            origin + "/favicon-192x192.png",
            origin + "/favicon-32x32.png",
            origin + "/favicon.ico"
        ];
    }

    function _hostDomainOnly(url) {
        // strip port and path -> bare domain (e.g. radio.streemlion.com:2525 -> radio.streemlion.com)
        const m = String(url).match(/^https?:\/\/([^\/:]+)/i);
        return m ? m[1] : "";
    }

    function _baseDomain(domain) {
        // strip sub-domain: s5.radio.co -> radio.co, cast4.asurahosting.com -> asurahosting.com
        // simple heuristic: keep last 2 labels (works for .com, .ee, .fi etc but not .co.uk style)
        if (!domain)
            return "";
        const parts = domain.split(".");
        if (parts.length <= 2)
            return domain;
        return parts.slice(-2).join(".");
    }

    function _googleFaviconCandidates() {
        const seen = {};
        const out = [];
        const addDomain = (dom) => {
            if (!dom || seen[dom])
                return;
            seen[dom] = true;
            out.push("https://www.google.com/s2/favicons?domain=" + encodeURIComponent(dom) + "&sz=128");
        };
        for (let i = 0; i < arguments.length; i++) {
            const dom = _hostDomainOnly(arguments[i]);
            addDomain(dom);
            // Google often returns 404 for sub-domains; try base domain as well
            // (e.g. s5.radio.co -> radio.co)
            addDomain(_baseDomain(dom));
        }
        return out;
    }

    function _looksLikeImageBytes(buf) {
        if (!buf || buf.length < 4)
            return false;
        // PNG: 89 50 4E 47
        if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47)
            return true;
        // JPEG: FF D8 FF
        if (buf[0] === 0xFF && buf[1] === 0xD8 && buf[2] === 0xFF)
            return true;
        // GIF: 47 49 46 38
        if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38)
            return true;
        // ICO: 00 00 01 00 (icon) or 00 00 02 00 (cursor)
        if (buf[0] === 0x00 && buf[1] === 0x00 && (buf[2] === 0x01 || buf[2] === 0x02) && buf[3] === 0x00)
            return true;
        // BMP: 42 4D
        if (buf[0] === 0x42 && buf[1] === 0x4D)
            return true;
        // WebP: RIFF....WEBP
        if (buf.length >= 12
            && buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46
            && buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50)
            return true;
        // SVG/XML: '<' followed by '?xml' or '<svg'
        if (buf[0] === 0x3C) {
            let head = "";
            for (let i = 0; i < Math.min(buf.length, 256); i++)
                head += String.fromCharCode(buf[i]);
            const lower = head.toLowerCase();
            if (lower.indexOf("<svg") !== -1 || lower.indexOf("<?xml") !== -1)
                return true;
        }
        return false;
    }

    function _probeNextCandidate(job, candidates, idx) {
        if (idx >= candidates.length) {
            _logoDone++;
            _fetchNextLogo();
            return;
        }
        const url = candidates[idx];
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", url);
        xhr.responseType = "arraybuffer";
        xhr.setRequestHeader("User-Agent", "OnAir/2026.13");
        _activeLogoXhr = xhr;
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return;
            _clearXhrTimeout(guard);
            if (_activeLogoXhr === xhr)
                _activeLogoXhr = null;
            let ok = false;
            if (xhr.status >= 200 && xhr.status < 400 && xhr.response) {
                try {
                    const buf = new Uint8Array(xhr.response);
                    ok = _looksLikeImageBytes(buf);
                } catch (e) {
                    ok = false;
                }
            }
            if (ok) {
                _saveLogo(job, url);
                _logoDone++;
                _fetchNextLogo();
            } else {
                _probeNextCandidate(job, candidates, idx + 1);
            }
        };
        guard = _armXhrTimeout(xhr, 6000);
        xhr.send();
    }

    function refetchAllLogos() {
        if (_logoFetching)
            return;
        _logoQueue = [];
        for (var i = 0; i < stationsModel.count; i++) {
            const it = stationsModel.get(i);
            // Do NOT clear the current favicon up front: _saveLogo only writes
            // on a validated success, so a failed lookup keeps the previous
            // (possibly hand-entered) URL instead of wiping it from the config.
            _logoQueue.push({ "index": i, "name": it.name, "hostname": it.hostname });
        }
        _logoTotal = _logoQueue.length;
        _logoDone = 0;
        _logoFound = 0;
        if (_logoTotal === 0) {
            showMessage(true, i18n("No stations to refresh."));
            return;
        }
        _logoFetching = true;
        _pickApiServer();
        _fetchNextLogo();
    }

    // Snapshot of the last state synced with plasmoid.configuration.servers —
    // used to detect whether this page has unsaved local edits.
    property string _lastSynced: ""

    Component.onCompleted: {
        stationsModel.clear();
        var servers = JSON.parse(cfg_servers);
        for (const server of servers) {
            stationsModel.append(server);
        }
        _lastSynced = cfg_servers;
    }

    // The dialog's cfg_servers is a SNAPSHOT: without this, adding a station
    // from the popup (⭐) while the settings window is open would be silently
    // overwritten by the next Apply.
    Connections {
        target: plasmoid.configuration
        function onServersChanged() {
            const external = plasmoid.configuration.servers;
            if (external === root.cfg_servers) {
                root._lastSynced = external;
                return;
            }
            if (root.cfg_servers === root._lastSynced) {
                // No unsaved edits on this page — take the external state over.
                try {
                    const servers = JSON.parse(external);
                    stationsModel.clear();
                    for (const server of servers) stationsModel.append(server);
                    root.cfg_servers = external;
                    root._lastSynced = external;
                } catch (e) {}
            } else {
                // Unsaved local edits — merge in externally added stations by
                // hostname so Apply loses neither side.
                try {
                    const ext = JSON.parse(external);
                    const have = {};
                    for (var i = 0; i < stationsModel.count; i++)
                        have[stationsModel.get(i).hostname] = true;
                    var added = false;
                    for (const srv of ext) {
                        if (!have[srv.hostname]) { stationsModel.append(srv); added = true; }
                    }
                    if (added) root.cfg_servers = JSON.stringify(getServersArray());
                } catch (e) {}
            }
        }
    }

    Component {
        id: delegateComponent

        Item {
            id: listItem

            required property int index
            required property var model
            required property bool active
            required property string name

            width: mainList.width
            height: swipeListItem.height

            Kirigami.SwipeListItem {
                id: swipeListItem

                down: false
                alternatingBackground: true
                Kirigami.Theme.inherit: true
                Kirigami.Theme.colorSet: Kirigami.Theme.View
                hoverEnabled: true
                separatorVisible: true
                actions: [
                    Kirigami.Action {
                        icon.name: "edit-entry"
                        text: i18n("Edit")
                        onTriggered: {
                            listItem.ListView.view.currentIndex = listItem.index;
                            editServer();
                        }
                    },
                    Kirigami.Action {
                        icon.name: checked ? "view-visible" : "view-hidden"
                        text: checked ? i18n("Hide") : i18n("Show")
                        checked: listItem.active
                        checkable: true
                        onTriggered: {
                            listItem.model.active = checked;
                            cfg_servers = JSON.stringify(getServersArray());
                        }
                    },
                    Kirigami.Action {
                        icon.name: "delete"
                        text: i18n("Remove")
                        onTriggered: {
                            stationsModel.remove(listItem.index);
                            cfg_servers = JSON.stringify(getServersArray());
                        }
                    }
                ]

                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing

                    QQC2.Label {
                        Layout.preferredWidth: listCounterMetrics.advanceWidth
                        horizontalAlignment: Text.AlignHCenter
                        LayoutMirroring.enabled: false
                        text: listItem.index + 1
                        color: swipeListItem.textColor
                        Component.onCompleted: {
                            listCounterMetrics.font = font;
                        }
                    }

                    Kirigami.ListItemDragHandle {
                        listItem: swipeListItem
                        listView: listItem.ListView.view
                        onMoveRequested: {
                            stationsModel.move(oldIndex, newIndex, 1);
                            cfg_servers = JSON.stringify(getServersArray());
                        }
                    }

                    Item {
                        id: faviconHolder

                        readonly property string faviconUrl: listItem.model.favicon ? listItem.model.favicon : ""

                        Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                        Layout.alignment: Qt.AlignVCenter

                        Kirigami.Icon {
                            id: faviconFallback

                            anchors.fill: parent
                            source: "view-media-track"
                            visible: faviconImage.status !== Image.Ready
                        }

                        Image {
                            id: faviconImage

                            anchors.fill: parent
                            source: faviconHolder.faviconUrl
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            cache: true
                            visible: status === Image.Ready
                        }
                    }

                    Item {
                        id: trackRect

                        clip: true
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        QQC2.Label {
                            id: trackName

                            anchors.verticalCenter: parent.verticalCenter
                            text: listItem.name
                            color: swipeListItem.textColor

                            XAnimator {
                                target: trackName
                                from: 0
                                to: -trackName.paintedWidth
                                duration: Math.round(Math.abs(to - from) / Kirigami.Units.gridUnit * 300 * plasmoid.configuration.speedfactor)
                                running: swipeListItem.containsMouse && trackName.width > trackRect.width
                                loops: 1
                                onFinished: {
                                    from = trackRect.width;
                                    if (swipeListItem.containsMouse)
                                        start();

                                }
                                onStopped: {
                                    from = 0;
                                    trackName.x = 0;
                                }
                            }

                        }

                    }

                }

            }

        }

    }

    ARP.StationsModel {
        id: stationsModel
    }

    TextMetrics {
        id: listCounterMetrics

        text: ''.padStart(Math.max(0, mainList.count - 1).toString().length, '9')
    }

    Kirigami.Dialog {
        id: serverDialog

        title: dialogMode === -1 ? i18n("Add Station") : i18n("Edit station")
        padding: Kirigami.Units.largeSpacing
        standardButtons: QQC2.Dialog.Ok | QQC2.Dialog.Cancel
        // An entry without a URL is unplayable and confuses removal — keep OK
        // disabled until a non-empty URL is entered.
        function updateOkEnabled() {
            const ok = standardButton(QQC2.Dialog.Ok);
            if (ok) ok.enabled = serverHostname.text.trim().length > 0;
        }
        onOpened: {
            updateOkEnabled();
            serverName.forceActiveFocus(Qt.MouseFocusReason);
        }
        onAccepted: {
            const nameClean = serverName.text.trim();
            const hostClean = serverHostname.text.trim();
            const faviconClean = serverFavicon.text.trim();
            if (hostClean === "") return;
            let itemObject;
            if (dialogMode === -1) {
                itemObject = {
                    "name": nameClean !== "" ? nameClean : hostClean,
                    "hostname": hostClean,
                    "favicon": faviconClean,
                    "active": serverActive.checked
                };
                stationsModel.append(itemObject);
            } else {
                const existing = stationsModel.get(dialogMode);
                itemObject = {};
                for (const key in existing) {
                    itemObject[key] = existing[key];
                }
                itemObject.name = nameClean !== "" ? nameClean : hostClean;
                itemObject.hostname = hostClean;
                itemObject.favicon = faviconClean;
                itemObject.active = serverActive.checked;
                stationsModel.set(dialogMode, itemObject);
            }
            cfg_servers = JSON.stringify(getServersArray());
        }

        ColumnLayout {
            Kirigami.FormLayout {
                QQC2.TextField {
                    id: serverName

                    Kirigami.FormData.label: i18n("Name:")
                }

                QQC2.TextField {
                    id: serverHostname

                    Kirigami.FormData.label: i18n("URL:")
                    onTextChanged: serverDialog.updateOkEnabled()
                }

                QQC2.TextField {
                    id: serverFavicon

                    Kirigami.FormData.label: i18n("Logo URL:")
                    placeholderText: i18n("e.g. https://example.com/logo.png")
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 22
                }

                QQC2.CheckBox {
                    id: serverActive

                    checked: true
                    text: i18n("Active")
                }

            }

        }

    }

    Labs.FileDialog {
        id: openFileDialog

        nameFilters: ["ARP Stations Backup (*.arp)"]
        fileMode: Labs.FileDialog.OpenFile
        folder: Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation)
        onAccepted: {
            fileUtils(currentFile, cfg_servers, 0);
        }
    }

    Labs.FileDialog {
        id: saveFileDialog

        nameFilters: ["ARP Stations Backup (*.arp)"]
        folder: Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation)
        fileMode: Labs.FileDialog.SaveFile
        onVisibleChanged: {
            if (visible) {
                const home = Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation);
                currentFile = "file:///" + home + "/stations.arp";
            }
        }
        onAccepted: fileUtils(currentFile, cfg_servers, 1)
    }

    P5Support.DataSource {
        id: executable

        signal exited(string cmd, int exitCode, int exitStatus, string stdout, string stderr)

        function exec(cmd) {
            if (cmd)
                connectSource(cmd);

        }

        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            var exitCode = data["exit code"];
            var exitStatus = data["exit status"];
            var stdout = data["stdout"];
            var stderr = data["stderr"];
            exited(sourceName, exitCode, exitStatus, stdout, stderr);
            disconnectSource(sourceName);
        }
    }

    Connections {
        //   }

        function onExited(cmd, exitCode, exitStatus, stdout, stderr) {
            var formattedText = stdout.trim();
            if (cmd.startsWith("cat")) {
                //   if (formattedText != cfg_servers) {
                try {
                    const servers = JSON.parse(formattedText);
                    stationsModel.clear();
                    for (const srv of servers) {
                        stationsModel.append(srv);
                    }
                    cfg_servers = JSON.stringify(getServersArray());
                    showMessage(true, i18n("Configuration has been loaded. Click 'Apply' to save changes."));
                } catch (e) {
                    showMessage(false, i18n("Error loading configuration. Try choosing a different file."));
                }
            } else {
                if (formattedText === cfg_servers)
                    showMessage(true, i18n("Your configuration was saved successfully."));
                else
                    showMessage(false, i18n("Error, make sure the selected directory is writable!"));
            }
            importexportmessage.visible = true;
            closetimer.restart();
        }

        target: executable
    }

    view: ListView {
        id: mainList

        focus: true
        model: stationsModel
        reuseItems: true
        delegate: delegateComponent

        moveDisplaced: Transition {
            YAnimator {
                duration: Kirigami.Units.longDuration
                easing.type: Easing.InOutQuad
            }

        }

    }

    footer: ColumnLayout {
        Kirigami.InlineMessage {
            id: importexportmessage

            property bool positive

            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            visible: false
            showCloseButton: true
            type: positive ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error
        }

        Timer {
            id: closetimer

            running: false
            repeat: false
            interval: 10000
            onTriggered: {
                importexportmessage.visible = false;
            }
        }

        RowLayout {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: i18n("Add…")
                icon.name: "list-add"
                onClicked: addServer()
            }

            QQC2.Button {
                id: fetchLogosButton

                text: root._logoFetching
                      ? i18n("Fetching… %1 / %2", root._logoDone, root._logoTotal)
                      : i18n("Fetch missing logos")
                icon.name: "download"
                enabled: !root._logoFetching
                onClicked: root.fetchMissingLogos()
            }

            QQC2.Button {
                id: refetchAllLogosButton

                text: i18n("Re-fetch all")
                icon.name: "view-refresh"
                enabled: !root._logoFetching
                onClicked: root.refetchAllLogos()
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: i18n("Fetch fresh logos for all stations; existing logos are kept if nothing better is found")
            }

            QQC2.BusyIndicator {
                running: root._logoFetching
                visible: root._logoFetching
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }

            Item {
                Layout.fillWidth: true
            }

            QQC2.Button {
                text: i18n("Import…")
                icon.name: "document-import"
                onClicked: openFileDialog.open()
            }

            QQC2.Button {
                text: i18n("Export…")
                icon.name: "document-export"
                onClicked: saveFileDialog.open()
            }

        }

    }

}
