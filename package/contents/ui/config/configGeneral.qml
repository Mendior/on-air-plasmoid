import ".." as ARP
import "../DoorLogic.js" as DoorLogic
import "../FaviconLogic.js" as FaviconLogic
import "../HealLogic.js" as HealLogic
import "../HostGuard.js" as HostGuard
import "../ReorderLogic.js" as ReorderLogic
import "../StreamLogic.js" as StreamLogic
import Qt.labs.platform as Labs
/*
* SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
* SPDX-FileCopyrightText: 2023 ivan tkachenko <me@ratijas.tk>
* SPDX-FileCopyrightText: 2026 Egon Greenberg
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

    // The list as this page would save it. It is deliberately not a cfg_
    // property: plasmoidviewer's settings dialog marks a page changed on
    // every cfg_ change signal, whatever the value (the Plasma 6.7 desktop
    // dialog compares the values first), so taking over a list the popup had
    // just given logos lit Apply and asked "Apply Settings?" on the way out
    // with nothing changed here. An edit says so with configurationChanged(),
    // and saveConfig() does the writing, which both kinds of dialog call.
    property string _servers: ""
    signal configurationChanged()

    // Every edit on this page ends here.
    function _edited() {
        const s = JSON.stringify(getServersArray());
        if (s === _servers)
            return;
        _servers = s;
        configurationChanged();
    }

    // A page with no edits writes nothing: what it shows is what the popup
    // last wrote, and writing that back is at best nothing and at worst the
    // older copy.
    function saveConfig() {
        if (_servers === _lastSynced || _servers === plasmoid.configuration.servers)
            return;
        plasmoid.configuration.servers = _servers;
        _lastSynced = _servers;
        plasmoid.configuration.writeConfig();
    }

    property int dialogMode: -1
    // The Edit dialog's fields as it filled them, for DoorLogic.editedRow.
    property var _editOpened: ({})

    // "all" is the directory's own DNS round-robin over LIVE servers — every
    // fetch starts there deterministically; the named mirrors are only the
    // retry rotation's rungs (live set as of 2026-07 — most of the old
    // hardcoded ones are dead DNS by now, and a settings page should not
    // gamble on history).
    property var _apiServers: ["all", "de1", "de2"]
    property string _apiServer: "all"
    property var _logoQueue: []
    property int _logoTotal: 0
    property int _logoDone: 0
    property int _logoFound: 0
    property int _logoUpgradeTotal: 0
    property int _logoUpgradeFound: 0
    property bool _logoFetching: false
    property var _activeLogoXhr: null

    function fileUtils(fileUrl, text, mode) {
        // toString() percent-encodes the path ("minu jaamad.arp" becomes
        // minu%20jaamad.arp) and the shell then reads a file that does not
        // exist — decode first. Malformed sequences stay literal.
        var raw = fileUrl.toString();
        try { raw = decodeURIComponent(raw); } catch (e) {}
        var file = raw.replace("file:///", "/").replace(/'/g, "'\\''");
        if (mode === 1) {
            var escapedText = text.replace(/'/g, "'\\''");
            // printf %s, NOT echo: a dash/busybox /bin/sh echo interprets the
            // backslash escapes JSON.stringify emits (\\, \n, \t) and corrupts
            // the exported file (same pattern as _mprisWriteState in main.qml).
            // Write to .tmp then mv: a full disk or a kill mid-write must not
            // leave a half-written file where the user's backup was.
            executable.exec("sh -c 'printf %s \"$1\" > \"$2.tmp\" && mv \"$2.tmp\" \"$2\" && cat \"$2\"' _ '" + escapedText + "' '" + file + "'");
        } else {
            // 2 MiB cap: a mispicked huge file just fails JSON.parse below
            // instead of being slurped whole into the shell and the heap.
            executable.exec("head -c 2097152 '" + file + "'");
        }
    }

    function _webUrlOrEmpty(v) {
        const s = v && v !== "null" ? String(v).trim() : "";
        return /^https?:\/\//i.test(s) ? s : "";
    }

    // The same gate plus the HOST judgement, for strings that arrive from
    // somewhere the user did not type: a catalogue row, an imported file.
    // Those reach an Image.source, which fetches with no click at all, and
    // get saved with the station — a scheme test alone let a crafted entry
    // aim that silent GET at the user's own network. What the user types
    // into the logo field themselves keeps the plain gate: their machine,
    // their choice, and a self-hosted logo is a fair thing to want.
    function _extUrlOrEmpty(v) {
        const s = _webUrlOrEmpty(v);
        return (s !== "" && _privateHostUrl(s)) ? "" : s;
    }

    // Catalogue data must not point the fetcher (or a saved logo URL) at
    // localhost or the LAN. The address judgement lives in HostGuard.js,
    // shared with the search's liveness probe — one gate, every spelling.
    function _privateHostUrl(url) {
        var host = HostGuard.hostOf(String(url));
        return host !== "" && HostGuard.isPrivateHost(host);
    }

    function showMessage(positive, text) {
        importexportmessage.positive = positive;
        importexportmessage.text = text;
        importexportmessage.visible = true;
        closetimer.restart();
    }

    function getServersArray() {
        return ReorderLogic.savedRows(stationsModel);
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
        _editOpened = { "name": serverName.text, "hostname": serverHostname.text,
                        "favicon": serverFavicon.text, "active": serverActive.checked };
        serverDialog.visible = true;
    }

    property int _apiServerIdx: 0

    // Every batch starts on "all" — say so to the WALK too, or a stale
    // index from the last batch desyncs it and the first retry can land
    // back on the very door that just timed out.
    function _apiServerReset() {
        _apiServerIdx = 0;
        _apiServer = _apiServers[0];
    }

    function _pickApiServer() {
        // Walk the rungs, never draw with replacement: a draw could hand
        // the retry the very mirror it just timed out on and eat both
        // retries on one dead door (configSearch walks for the same
        // reason). Index 0 is "all", matching the deterministic start.
        _apiServerIdx = (_apiServerIdx + 1) % _apiServers.length;
        _apiServer = _apiServers[_apiServerIdx];
    }

    // QML XHR ignores xhr.timeout/ontimeout entirely (Qt quirk) — the logo
    // fetcher could hang forever on one dead server. A Timer calling abort()
    // is the working replacement: abort lands in onreadystatechange with
    // status 0, i.e. the same path as any failed request.
    Component {
        id: xhrTimeoutGuard
        Timer { repeat: false }
    }

    // The network half of the logo hunt, shared with the popup's backfill.
    ARP.LogoHunt {
        id: logoHunt
        app: root
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

    // All five counters, because the summary at the end subtracts the upgrade
    // pair from the other two. Three roads start a fetch and two of them used
    // to leave the upgrade pair holding the previous run's numbers, which
    // skews "how many were missed" — and when the skew happens to land on
    // zero, the run reports itself as clean while stations that genuinely
    // failed go unmentioned.
    function _resetLogoCounters() {
        _logoTotal = _logoQueue.length;
        _logoDone = 0;
        _logoFound = 0;
        _logoUpgradeTotal = 0;
        _logoUpgradeFound = 0;
    }

    function fetchMissingLogos() {
        if (_logoFetching)
            return;
        _logoQueue = [];
        for (var i = 0; i < stationsModel.count; i++) {
            const it = stationsModel.get(i);
            const fav = it.favicon ? String(it.favicon).trim() : "";
            if (fav === "" || fav === "null") {
                _logoQueue.push({ "index": i, "name": it.name, "hostname": it.hostname,
                                  "uuid": (it.uuid || "").toString() });
            } else if (FaviconLogic.tinyLogoUrl(fav)) {
                // Upgrade job: hunt for a bigger variant, but never replace
                // the working tiny logo with another tiny one or with itself
                // (_probeCandidates filters those), and keep it whole
                // when nothing better answers (_saveLogo only writes wins).
                // The uuid rides along so upgrades take the identity road.
                _logoQueue.push({ "index": i, "name": it.name, "hostname": it.hostname,
                                  "uuid": (it.uuid || "").toString(),
                                  "upgrade": true, "oldFavicon": fav });
            }
        }
        _resetLogoCounters();
        // Counted after the reset, never before — the reset would wipe it.
        for (var q = 0; q < _logoQueue.length; q++)
            if (_logoQueue[q].upgrade === true) _logoUpgradeTotal++;
        if (_logoTotal === 0) {
            showMessage(true, i18n("All stations already have a logo."));
            return;
        }
        _logoFetching = true;
        _apiServerReset();
        _fetchNextLogo();
    }

    function _fetchNextLogo() {
        if (_logoQueue.length === 0) {
            _logoFetching = false;
            _edited();
            // An upgrade job that found nothing better KEPT its working
            // logo — counting it "could not be found" would report a
            // healthy station as a failure.
            const missed = (_logoTotal - _logoUpgradeTotal)
                           - (_logoFound - _logoUpgradeFound);
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
        if (job.uuid && /^[0-9a-fA-F-]{36}$/.test(job.uuid)) {
            _queryByUuid(job, cleanName, 0);
            return;
        }
        _queryRadioBrowser(job, cleanName, 0);
    }

    // The identity road: byuuid answers with THE station's row — its logo
    // and homepage are the right ones even when five broadcasters share the
    // name. Falls through to the name search only when the row has neither.
    function _queryByUuid(job, cleanName, retryCount) {
        const url = "https://" + _apiServer + ".api.radio-browser.info/json/stations/byuuid/"
                  + encodeURIComponent(job.uuid);
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", url);
        xhr.setRequestHeader("User-Agent", "OnAir/2026.42");
        _activeLogoXhr = xhr;
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return;
            _clearXhrTimeout(guard);
            if (_activeLogoXhr === xhr)
                _activeLogoXhr = null;
            var fav = "";
            var home = "";
            var ok = false;
            if (xhr.status === 200) {
                try {
                    var row = (JSON.parse(xhr.responseText) || [])[0] || {};
                    ok = true;
                    fav = _extUrlOrEmpty(row.favicon);
                    home = _extUrlOrEmpty(row.homepage);
                } catch (e) { ok = false; }
            }
            if (!ok && retryCount < _apiServers.length - 1) {
                _pickApiServer();
                _queryByUuid(job, cleanName, retryCount + 1);
                return;
            }
            if (fav === "" && home === "") {
                _queryRadioBrowser(job, cleanName, 0);
                return;
            }
            if (home !== "") {
                _scrapeHomepageAndProbe(job, fav, home);
            } else {
                _probeCandidates(job, _ladder(job, fav, [], ""));
            }
        };
        guard = _armXhrTimeout(xhr, 8000);
        xhr.send();
    }

    function _queryRadioBrowser(job, cleanName, retryCount) {
        // search?name=... endpoint is robust against '/' and special chars (unlike byname/<path>)
        const url = "https://" + _apiServer + ".api.radio-browser.info/json/stations/search"
                  + "?name=" + encodeURIComponent(cleanName)
                  + "&limit=30&order=votes&reverse=true";
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", url);
        xhr.setRequestHeader("User-Agent", "OnAir/2026.42");
        _activeLogoXhr = xhr;
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return;
            _clearXhrTimeout(guard);
            if (_activeLogoXhr === xhr)
                _activeLogoXhr = null;
            var parseOk = false;
            var pickedFavicon = "";
            var pickedHomepage = "";
            if (xhr.status === 200) {
                var txt = xhr.responseText || "";
                if (txt.trim() !== "") {
                    try {
                        var results = JSON.parse(txt) || [];
                        parseOk = true;
                        // Whose logo, and whose homepage to look for one
                        // on, is FaviconLogic.donorRows' call (tests/qml).
                        // This loop used to settle for the first row with
                        // any icon at all, exact name or not, and the first
                        // homepage likewise. On the answer "Kiss FM" gave on
                        // 2026-09-21 that is a Ukrainian logo for a Spanish
                        // station.
                        var donors = FaviconLogic.donorRows(results, HealLogic.normName(cleanName),
                                                            HealLogic.normName, job.hostname, 30);
                        for (var d = 0; d < donors.length; d++) {
                            // Catalogue data is untrusted: only plain web
                            // URLs on public hosts may become a favicon
                            // source or a homepage to scrape, never a
                            // file:// or data: entry somebody typed in.
                            if (pickedFavicon === "")
                                pickedFavicon = _extUrlOrEmpty(donors[d].favicon);
                            if (pickedHomepage === "")
                                pickedHomepage = _extUrlOrEmpty(donors[d].homepage);
                        }
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
            // The favicon and homepage found above go into _ladder, the
            // homepage read first when there is one.
            if (pickedHomepage !== "") {
                _scrapeHomepageAndProbe(job, pickedFavicon, pickedHomepage);
            } else {
                _probeCandidates(job, _ladder(job, pickedFavicon, [], ""));
            }
        };
        guard = _armXhrTimeout(xhr, 8000);
        xhr.send();
    }

    function _saveLogo(job, faviconUrl) {
        if (faviconUrl === "" || job.index >= stationsModel.count)
            return false;
        // LogoHunt asks no private host, so nothing from one can arrive
        // here; refused again all the same.
        if (_privateHostUrl(faviconUrl))
            return false;
        const cur = stationsModel.get(job.index);
        if (cur && cur.name === job.name) {
            stationsModel.setProperty(job.index, "favicon", faviconUrl);
            _logoFound++;
            if (job.upgrade === true) _logoUpgradeFound++;
            return true;
        }
        return false;
    }

    // The homepage's own icons and og:image join the ladder, read by the
    // same LogoHunt the popup's backfill uses.
    function _scrapeHomepageAndProbe(job, apiFavicon, homepage) {
        logoHunt.readPage(homepage, function(images, from) {
            _probeCandidates(job, _ladder(job, apiFavicon, images, from || homepage));
        });
    }

    // Everything the ladder may ask for one station, in the order the lists
    // come: the directory's own logo, what the homepage names, the
    // well-known paths on the homepage and on the stream's host, and
    // Google's icon service. FaviconLogic.probeOrder decides who is asked
    // first, and LogoHunt never asks one on a private host.
    function _ladder(job, apiFavicon, images, homepage) {
        var home = FaviconLogic.webUrlOrEmpty(homepage);
        var out = apiFavicon !== "" ? [{ "url": apiFavicon, "kind": "page" }] : [];
        var onHost = _hostnameStdCandidates(job.hostname);
        var google = _googleFaviconCandidates(job.hostname, home);
        out = out.concat(FaviconLogic.homepageCandidates(images, home));
        for (var i = 0; i < onHost.length; i++)
            out.push({ "url": onHost[i], "kind": "host" });
        for (var g = 0; g < google.length; g++)
            out.push({ "url": google[g], "kind": "guess" });
        return out;
    }

    // The best picture the ladder finds is saved, not the first: Raadio
    // Kadi's page names a 16x16 favicon.ico ahead of its 1200x1200 logo, and
    // the first real picture used to win. An upgrade job only looks for
    // something better than the tiny logo it has, and keeps that one when
    // the best it finds is tiny too, which no address tells of a 16 px
    // logo.png.
    function _probeCandidates(job, candidates) {
        if (job.upgrade === true)
            candidates = candidates.filter(c => !FaviconLogic.tinyLogoUrl(c.url) && c.url !== job.oldFavicon);
        const cur = job.index < stationsModel.count ? stationsModel.get(job.index) : null;
        const had = cur ? FaviconLogic.webUrlOrEmpty(cur.favicon) : "";
        // The logo the row has is weighed with the finds and stays unless one
        // beats it; a dead one never loads, so the best picture that does wins.
        if (had !== "" && job.upgrade !== true)
            candidates = [{ "url": had, "kind": "current" }].concat(candidates);
        logoHunt.probe(candidates, function(best) {
            if (FaviconLogic.keepsFind(best, had, job.upgrade === true))
                _saveLogo(job, best.url);
            _logoDone++;
            _fetchNextLogo();
        });
    }

    function _hostnameStdCandidates(hostname) {
        const origin = FaviconLogic.originOf(hostname);
        if (origin === "")
            return [];
        // A landlord's own icon is nobody's logo: on a tenant's row zeno.fm's
        // favicon is as wrong as a namesake's (the icon service answers for
        // zeno.fm with a 746-byte image, measured 2026-09-21).
        if (HealLogic.sharedBase(_baseDomain(_hostDomainOnly(hostname))))
            return [];
        return [
            origin + "/apple-touch-icon.png",
            origin + "/favicon-192x192.png",
            origin + "/favicon-32x32.png",
            origin + "/favicon.ico"
        ];
    }

    function _hostDomainOnly(url) {
        // The player's parser, so userinfo and IPv6 brackets read the same
        // here as everywhere else.
        return StreamLogic.hostOf(url);
    }

    function _baseDomain(domain) {
        // The shared heuristic knows co.uk-style pairs and IP literals.
        // This page's own copy did not: it asked Google for the favicon
        // of "co.uk", and made "1.5" out of an IP-hosted stream.
        return StreamLogic.baseDomain(domain);
    }

    function _googleFaviconCandidates() {
        const seen = {};
        const out = [];
        const addDomain = (dom) => {
            if (!dom || seen[dom] || HealLogic.sharedBase(_baseDomain(dom)))
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

    function refetchAllLogos() {
        if (_logoFetching)
            return;
        _logoQueue = [];
        for (var i = 0; i < stationsModel.count; i++) {
            const it = stationsModel.get(i);
            // Do NOT clear the current favicon up front: _saveLogo only writes
            // on a validated success, so a failed lookup keeps the previous
            // (possibly hand-entered) URL instead of wiping it from the config.
            _logoQueue.push({ "index": i, "name": it.name, "hostname": it.hostname,
                              "uuid": (it.uuid || "").toString() });
        }
        _resetLogoCounters();
        if (_logoTotal === 0) {
            showMessage(true, i18n("No stations to refresh."));
            return;
        }
        _logoFetching = true;
        _apiServerReset();
        _fetchNextLogo();
    }

    // Snapshot of the last state synced with plasmoid.configuration.servers —
    // used to detect whether this page has unsaved local edits.
    property string _lastSynced: ""

    Component.onCompleted: {
        stationsModel.clear();
        // Same guard as configSearch: a stored list that does not parse
        // leaves the page empty and alive, not dead on its first line.
        _servers = plasmoid.configuration.servers;
        var servers = [];
        try { servers = JSON.parse(_servers) || []; }
        catch (e) { console.warn("[ARP] settings: stored station list is not valid JSON —", e); }
        if (!Array.isArray(servers)) servers = [];
        for (const server of servers) {
            stationsModel.append(DoorLogic.normalize(server));
        }
        _lastSynced = _servers;
    }

    // The page's list is a SNAPSHOT: without this, adding a station from the
    // popup (⭐) while the settings window is open would be silently
    // overwritten by the next Apply.
    Connections {
        target: plasmoid.configuration
        function onServersChanged() {
            const external = plasmoid.configuration.servers;
            if (external === root._servers) {
                root._lastSynced = external;
                return;
            }
            if (root._servers === root._lastSynced) {
                // No unsaved edits on this page — take the external state
                // over, quietly: nothing here changed, so nothing is announced.
                try {
                    const servers = JSON.parse(external);
                    stationsModel.clear();
                    for (const server of servers) stationsModel.append(DoorLogic.normalize(server));
                    root._servers = external;
                    root._lastSynced = external;
                } catch (e) {}
            } else {
                // Unsaved local edits — three-way merge against the
                // _lastSynced base so Apply loses neither side: rows this
                // page never touched follow the external outcome (a deletion
                // stays deleted, a healed hostname moves instead of
                // duplicating), rows edited here win their conflicts, and
                // externally added stations still come along.
                try {
                    const ext = JSON.parse(external);
                    let base = [];
                    try { base = JSON.parse(root._lastSynced) || []; } catch (e2) {}
                    // Key-order-stable serialization. The JSON round-trip
                    // flattens ListModel rows to plain objects (for..in over
                    // a model row drags wrapper internals along with the
                    // roles) and the wrapper's objectName is not an edit.
                    const norm = (o) => {
                        const plain = DoorLogic.normalize(JSON.parse(JSON.stringify(o)));
                        delete plain.objectName;
                        const keys = [];
                        for (const k in plain)
                            if (plain[k] !== undefined) keys.push(k);
                        keys.sort();
                        const flat = {};
                        for (const k of keys) flat[k] = plain[k];
                        return JSON.stringify(flat);
                    };
                    const merged = ReorderLogic.mergeExternal(base, ReorderLogic.savedRows(stationsModel), ext, norm);
                    const changed = merged.changed;
                    if (changed) {
                        stationsModel.clear();
                        for (const row of merged.rows) stationsModel.append(DoorLogic.normalize(row));
                    }
                    // The page already has edits of its own and has said so.
                    if (changed) root._servers = JSON.stringify(getServersArray());
                    // The base advances to the state just merged — otherwise
                    // an adopted row reads as a local edit next time and a
                    // later external deletion would resurrect it.
                    root._lastSynced = external;
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
                            _edited();
                        }
                    },
                    Kirigami.Action {
                        icon.name: "delete"
                        text: i18n("Remove")
                        onTriggered: {
                            stationsModel.remove(listItem.index);
                            _edited();
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
                            _edited();
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
                            // Decode at display size: a station's 512-pixel
                            // logo otherwise keeps a full-size texture per
                            // visible row (same cap as MediaListItem).
                            sourceSize.width: 64
                            sourceSize.height: 64
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
                            textFormat: Text.PlainText
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
            // Normalize the logo field: a scheme-less "host.tld/path" gets
            // the courtesy https://, then everything passes the same
            // http(s)-or-empty gate every other favicon road uses — file://,
            // data: and "null" persist as "" (which the runtime backfill
            // and the auto-lookup below then fill).
            let faviconClean = serverFavicon.text.trim();
            if (faviconClean !== "" && !/^[a-z][a-z0-9+.-]*:/i.test(faviconClean)
                && /^[^\/\s]+\.[^\s]+/.test(faviconClean))
                faviconClean = "https://" + faviconClean;
            faviconClean = _webUrlOrEmpty(faviconClean);
            if (hostClean === "") return;
            const clean = { "name": nameClean !== "" ? nameClean : hostClean, "hostname": hostClean,
                            "favicon": faviconClean, "active": serverActive.checked };
            let itemObject = clean;
            let rowAt = -1;
            if (dialogMode !== -1) {
                // The popup writes the list while the dialog is open, and this
                // page follows it: the row is found again by the address it
                // was opened on, and only what was changed here is written
                // (DoorLogic.editedRow). An OK used to write the dialog's
                // snapshot back, so a rename put a healed station back on its
                // dead address and lost the logo the popup had just found.
                // A row pointed at another station lets go of its uuid there:
                // the heal trusts a uuid for good.
                const rows = getServersArray();
                rowAt = DoorLogic.editRowIndex(rows, dialogMode, _editOpened);
                if (rowAt !== -1) {
                    const shown = { "name": serverName.text, "hostname": serverHostname.text,
                                    "favicon": serverFavicon.text, "active": serverActive.checked };
                    itemObject = DoorLogic.editedRow(rows[rowAt], _editOpened, shown, clean);
                    stationsModel.set(rowAt, DoorLogic.normalize(itemObject));
                }
            }
            // An Add, or an edit whose row was removed in the popup meanwhile:
            // what was typed here is the listener's last word.
            if (rowAt === -1) {
                stationsModel.append(DoorLogic.normalize(itemObject));
                rowAt = stationsModel.count - 1;
            }
            _edited();
            // A station saved without a logo gets one looked up right away —
            // the same ladder as "Fetch missing logos", one row only. The
            // user is present (they just pressed OK), so the deep road
            // including the homepage scrape is appropriate here.
            if (itemObject.favicon === "" && !_logoFetching) {
                const rowIdx = rowAt;
                _logoQueue = [{ "index": rowIdx, "name": itemObject.name,
                                "hostname": itemObject.hostname }];
                _resetLogoCounters();
                _logoFetching = true;
                _apiServerReset();
                _fetchNextLogo();
            }
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

        // Any file may be opened, not only *.arp: backups made before the
        // suffix was enforced (and files a listener renamed by hand) are
        // still perfectly good JSON, and the import path validates the
        // content anyway — a filter that hides them helps nobody.
        nameFilters: [i18n("On Air stations backup (*.arp)"), i18n("All files (*)")]
        fileMode: Labs.FileDialog.OpenFile
        folder: Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation)
        onAccepted: {
            fileUtils(currentFile, _servers, 0);
        }
    }

    Labs.FileDialog {
        id: saveFileDialog

        nameFilters: [i18n("On Air stations backup (*.arp)")]
        // A backup saved as "minu jaamad" — no extension, because the name
        // field is free text — was then INVISIBLE to the import dialog,
        // whose filter shows *.arp only: the file existed and the listener
        // could not find it. The suffix is added when the typed name has
        // none, which is exactly the case that went missing.
        defaultSuffix: "arp"
        folder: Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation)
        fileMode: Labs.FileDialog.SaveFile
        onVisibleChanged: {
            if (visible) {
                // writableLocation returns a URL (file:///home/…), not a
                // bare path — prefixing another file:/// used to produce
                // file:///file:///home/… and a dialog with a broken default.
                const home = Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation).toString();
                currentFile = (home.indexOf("file://") === 0 ? home : "file://" + home)
                              + "/stations.arp";
            }
        }
        onAccepted: fileUtils(currentFile, _servers, 1)
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
            if (cmd.startsWith("head")) {
                //   if (formattedText != cfg_servers) {
                try {
                    const servers = JSON.parse(formattedText);
                    stationsModel.clear();
                    // An .arp is just a file the user picked: rebuild each
                    // row from the fields the config actually uses, coerced
                    // and capped, instead of appending whatever object the
                    // file carried (a file:// favicon, a 10 MB "name", keys
                    // nothing here ever wrote). 500 rows / 500 chars is far
                    // beyond any real station list.
                    const clip = (v) => v == null ? "" : String(v).substring(0, 500);
                    for (const srv of servers.slice(0, 500)) {
                        const row = {
                            "name": clip(srv.name),
                            "hostname": clip(srv.hostname),
                            "favicon": _extUrlOrEmpty(clip(srv.favicon)),
                            "active": srv.active === undefined ? true
                                      : srv.active !== false && srv.active !== "false" && srv.active !== 0
                        };
                        // No URL = unplayable and unremovable-by-URL — the
                        // add dialog refuses these too.
                        if (row.hostname === "")
                            continue;
                        if (row.name === "")
                            row.name = row.hostname;
                        if (srv.country !== undefined)
                            row.country = clip(srv.country);
                        if (srv.uuid !== undefined)
                            row.uuid = clip(srv.uuid);
                        row.prev = srv.prev;
                        stationsModel.append(DoorLogic.normalize(row));
                    }
                    _edited();
                    showMessage(true, i18n("Configuration has been loaded. Click 'Apply' to save changes."));
                } catch (e) {
                    showMessage(false, i18n("Error loading configuration. Try choosing a different file."));
                }
            } else {
                if (formattedText === _servers)
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

        // Feedback doors: a user with a bug in hand should not have to go
        // hunting for the repository to say so.
        RowLayout {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.largeSpacing

            Kirigami.UrlButton {
                text: i18n("Report an issue")
                url: "https://github.com/Mendior/on-air-plasmoid/issues/new/choose"
                font: Kirigami.Theme.smallFont
            }

            Kirigami.UrlButton {
                text: i18n("Suggest a feature")
                url: "https://github.com/Mendior/on-air-plasmoid/discussions"
                font: Kirigami.Theme.smallFont
            }

            Item {
                Layout.fillWidth: true
            }

        }

    }

}
