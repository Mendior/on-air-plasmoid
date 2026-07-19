import ".." as ARP
import "../HostGuard.js" as HostGuard
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

    property string cfg_servers: plasmoid.configuration.servers

    property int dialogMode: -1

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

    // A logo source that is small by construction: bare /favicon.ico, an
    // explicit 16/32-pixel variant, or the Google s2 service (64 px). Worth
    // one upgrade attempt when the user asks for logos — a 16 px icon
    // upscaled into the popup's cover panel reads as "broken logo".
    function _tinyLogoUrl(u) {
        return /(?:^|\/)favicon\.ico(?:$|\?)|favicon-(?:16|32)x(?:16|32)|google\.com\/s2\/favicons/i
               .test(String(u || ""));
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
            } else if (_tinyLogoUrl(fav)) {
                // Upgrade job: hunt for a bigger variant, but never replace
                // the working tiny logo with another tiny one or with itself
                // (_probeNextCandidate filters those), and keep it whole
                // when nothing better answers (_saveLogo only writes wins).
                // The uuid rides along so upgrades take the identity road.
                _logoQueue.push({ "index": i, "name": it.name, "hostname": it.hostname,
                                  "uuid": (it.uuid || "").toString(),
                                  "upgrade": true, "oldFavicon": fav });
            }
        }
        _logoTotal = _logoQueue.length;
        _logoDone = 0;
        _logoFound = 0;
        _logoUpgradeTotal = 0;
        _logoUpgradeFound = 0;
        for (var q = 0; q < _logoQueue.length; q++)
            if (_logoQueue[q].upgrade === true) _logoUpgradeTotal++;
        if (_logoTotal === 0) {
            showMessage(true, i18n("All stations already have a logo."));
            return;
        }
        _logoFetching = true;
        _apiServer = "all";
        _fetchNextLogo();
    }

    function _fetchNextLogo() {
        if (_logoQueue.length === 0) {
            _logoFetching = false;
            cfg_servers = JSON.stringify(getServersArray());
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
        xhr.setRequestHeader("User-Agent", "OnAir/2026.20");
        _activeLogoXhr = xhr;
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== xhr.DONE)
                return;
            _clearXhrTimeout(guard);
            if (_activeLogoXhr === xhr)
                _activeLogoXhr = null;
            let fav = "";
            let home = "";
            let ok = false;
            if (xhr.status === 200) {
                try {
                    const row = (JSON.parse(xhr.responseText) || [])[0] || {};
                    ok = true;
                    fav = _webUrlOrEmpty(row.favicon);
                    home = _webUrlOrEmpty(row.homepage);
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
                const candidates = [fav];
                for (const u of _hostnameStdCandidates(job.hostname))
                    if (candidates.indexOf(u) === -1) candidates.push(u);
                for (const u of _googleFaviconCandidates(job.hostname))
                    if (candidates.indexOf(u) === -1) candidates.push(u);
                _probeNextCandidate(job, candidates, 0);
            }
        };
        guard = _armXhrTimeout(xhr, 8000);
        xhr.send();
    }

    function _queryRadioBrowser(job, cleanName, retryCount) {
        // search?name=... endpoint is robust against '/' and special chars (unlike byname/<path>)
        const url = "https://" + _apiServer + ".api.radio-browser.info/json/stations/search"
                  + "?name=" + encodeURIComponent(cleanName)
                  + "&limit=20&hidebroken=true&order=votes&reverse=true";
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", url);
        xhr.setRequestHeader("User-Agent", "OnAir/2026.20");
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
                            // Catalogue data is untrusted: only plain web
                            // URLs may become favicon sources or homepage
                            // scrape targets (same rule the popup search
                            // applies to stream URLs) — a file:// or data:
                            // entry from the publicly writable directory
                            // must never reach an Image or an XHR.
                            const fav = _webUrlOrEmpty(r.favicon);
                            const home = _webUrlOrEmpty(r.homepage);
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
        // Same self-hosted-station exception as _probeNextCandidate: a LAN
        // favicon is refused unless it is the user's own station origin.
        if (_privateHostUrl(faviconUrl) && _originOf(faviconUrl) !== _originOf(job.hostname))
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
        if (_privateHostUrl(homepage)) {
            // A loopback/LAN homepage never gets scraped — continue the
            // ladder as if the catalogue had no homepage at all.
            const candidates = [];
            if (apiFavicon !== "")
                candidates.push(apiFavicon);
            for (const u of _hostnameStdCandidates(job.hostname))
                if (candidates.indexOf(u) === -1)
                    candidates.push(u);
            for (const u of _googleFaviconCandidates(job.hostname))
                if (candidates.indexOf(u) === -1)
                    candidates.push(u);
            _probeNextCandidate(job, candidates, 0);
            return;
        }
        const xhr = new XMLHttpRequest();
        var guard = null;
        var keptPrefix = "";
        xhr.open("GET", homepage);
        xhr.setRequestHeader("User-Agent", "Mozilla/5.0 (compatible; OnAir/2026.20)");
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
            // Only the first ~96 KiB get scraped anyway — a body that keeps
            // streaming past 512 KiB must not buffer without bound. abort()
            // clears responseText, so keep the head first (icons live in
            // <head>, within the first 96 KiB) and fall back to it below.
            if (xhr.readyState === xhr.LOADING && xhr.responseText
                && xhr.responseText.length > 524288) {
                keptPrefix = xhr.responseText.substring(0, 98304);
                try { xhr.abort() } catch(e) {}
                return;
            }
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
            const body = xhr.responseText || keptPrefix;
            const respLen = body.length;
            const bodyLooksHtml = respLen > 200 && body.indexOf("<") !== -1;
            if (bodyLooksHtml) {
                const html = body.substring(0, 98304);
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
        // An upgrade hunt only considers candidates that would actually be
        // an upgrade: the current tiny URL itself and the tiny-class
        // sources (bare favicon.ico, 16/32 px variants, Google s2) are
        // filtered out once, before the first probe.
        if (job.upgrade === true && idx === 0)
            candidates = candidates.filter(c => !_tinyLogoUrl(c) && c !== job.oldFavicon);
        if (idx >= candidates.length) {
            _logoDone++;
            _fetchNextLogo();
            return;
        }
        const url = candidates[idx];
        // A LAN address is refused as an SSRF target, EXCEPT when it is
        // the user's own station origin — a self-hosted stream's own
        // favicon (from _hostnameStdCandidates) is legitimate intent,
        // not a remote catalogue/homepage reaching for an internal host.
        if (_privateHostUrl(url) && _originOf(url) !== _originOf(job.hostname)) {
            _probeNextCandidate(job, candidates, idx + 1);
            return;
        }
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", url);
        xhr.responseType = "arraybuffer";
        xhr.setRequestHeader("User-Agent", "OnAir/2026.20");
        _activeLogoXhr = xhr;
        xhr.onreadystatechange = () => {
            // A "logo" that streams past 512 KiB is not a logo — cap the
            // buffer; abort() lands back here as DONE and the empty
            // response fails the magic-byte check like any bad candidate.
            if (xhr.readyState === xhr.LOADING) {
                try {
                    if (xhr.responseText && xhr.responseText.length > 524288)
                        xhr.abort();
                } catch(e) {}
                return;
            }
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
            _logoQueue.push({ "index": i, "name": it.name, "hostname": it.hostname,
                              "uuid": (it.uuid || "").toString() });
        }
        _logoTotal = _logoQueue.length;
        _logoDone = 0;
        _logoFound = 0;
        if (_logoTotal === 0) {
            showMessage(true, i18n("No stations to refresh."));
            return;
        }
        _logoFetching = true;
        _apiServer = "all";
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
                        const plain = JSON.parse(JSON.stringify(o));
                        delete plain.objectName;
                        const keys = [];
                        for (const k in plain)
                            if (plain[k] !== undefined) keys.push(k);
                        keys.sort();
                        const flat = {};
                        for (const k of keys) flat[k] = plain[k];
                        return JSON.stringify(flat);
                    };
                    const baseByHost = {};
                    for (const b of base) baseByHost[b.hostname] = norm(b);
                    const extByHost = {};
                    for (const srv of ext) extByHost[srv.hostname] = srv;
                    var changed = false;
                    // Backwards: removals must not shift unvisited rows.
                    for (var i = stationsModel.count - 1; i >= 0; i--) {
                        const cur = stationsModel.get(i);
                        const baseNorm = baseByHost[cur.hostname];
                        if (baseNorm === undefined || norm(cur) !== baseNorm)
                            continue; // locally added or edited — local wins
                        const extRow = extByHost[cur.hostname];
                        if (extRow === undefined) {
                            // Externally deleted, untouched here — do not
                            // resurrect it.
                            stationsModel.remove(i);
                            changed = true;
                        } else if (norm(extRow) !== baseNorm) {
                            stationsModel.set(i, extRow);
                            changed = true;
                        }
                    }
                    const have = {};
                    for (var j = 0; j < stationsModel.count; j++)
                        have[stationsModel.get(j).hostname] = true;
                    for (const srv of ext) {
                        if (!have[srv.hostname]) { stationsModel.append(srv); changed = true; }
                    }
                    if (changed) root.cfg_servers = JSON.stringify(getServersArray());
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
            // A station saved without a logo gets one looked up right away —
            // the same ladder as "Fetch missing logos", one row only. The
            // user is present (they just pressed OK), so the deep road
            // including the homepage scrape is appropriate here.
            if (itemObject.favicon === "" && !_logoFetching) {
                const rowIdx = dialogMode === -1 ? stationsModel.count - 1 : dialogMode;
                _logoQueue = [{ "index": rowIdx, "name": itemObject.name,
                                "hostname": itemObject.hostname }];
                _logoTotal = 1;
                _logoDone = 0;
                _logoFound = 0;
                _logoFetching = true;
                _apiServer = "all";
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
                // writableLocation returns a URL (file:///home/…), not a
                // bare path — prefixing another file:/// used to produce
                // file:///file:///home/… and a dialog with a broken default.
                const home = Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation).toString();
                currentFile = (home.indexOf("file://") === 0 ? home : "file://" + home)
                              + "/stations.arp";
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
                            "favicon": _webUrlOrEmpty(clip(srv.favicon)),
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
                        stationsModel.append(row);
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
