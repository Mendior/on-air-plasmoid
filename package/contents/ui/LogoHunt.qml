/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
import QtQuick

import "FaviconLogic.js" as FaviconLogic
import "HostGuard.js" as HostGuard

// The network half of looking for a station's logo on its homepage, one copy
// for both roads that do it: the settings page's Fetch missing logos and the
// popup's backfill, which runs with no click at all. Every request here has
// passed the private-host gate before it is sent, has its answer thrown away
// when Qt's own redirects ended on a private host, is cut off at a size and
// aborted by a timer. What to ask and what to keep is FaviconLogic's.
QtObject {
    id: hunt

    // Has _armXhrTimeout(xhr, ms) and _clearXhrTimeout(timer): main.qml's
    // root and the settings page both do. QML's own xhr.timeout does nothing.
    required property var app
    // Tests hand in a stand-in request here; null sends real ones.
    property var makeRequest: null

    // Read-only, so neither road can loosen them. Icons live in <head>, and
    // the head of a page is in its first 96 KiB.
    readonly property int pageCap: 524288
    readonly property int pageKept: 98304
    readonly property int imageCap: 524288
    readonly property int pageTimeoutMs: 12000
    readonly property int probeTimeoutMs: 6000

    function _request() {
        return hunt.makeRequest ? hunt.makeRequest() : new XMLHttpRequest();
    }

    // What a homepage names as its logo: onDone([{url, kind}], from), its
    // icon links and og:image, and the address the answer came from after
    // Qt's own redirects. [] and "" when the address is not public, nobody
    // answered, the answer came from a private host or was no page.
    // Both roads call in from inside a directory request's own handler, and
    // the page is asked only once that handler has returned. strict: an
    // answer counts only where Qt names a public host as its end
    // (HostGuard.answerKnownPublic), for the road nobody clicked.
    function readPage(homepage, onDone, strict) {
        Qt.callLater(function() { hunt._readPageNow(homepage, onDone, strict === true); });
    }

    function _fromPublicHost(xhr, strict) {
        return strict ? HostGuard.answerKnownPublic(xhr) : HostGuard.answerFromPublicHost(xhr);
    }

    function _readPageNow(homepage, onDone, strict) {
        var page = FaviconLogic.webUrlOrEmpty(homepage);
        var xhr = null, guard = null, settled = false;
        var finish = function(body, from) {
            var images = [];
            if (from !== "" && body.length > 200 && body.indexOf("<") !== -1)
                images = FaviconLogic.extractIconLinks(body.substring(0, hunt.pageKept), from);
            Qt.callLater(function() { onDone(images, from); });
        };
        if (page === "") {
            finish("", "");
            return;
        }
        try {
            xhr = _request();
            xhr.open("GET", page);
            xhr.setRequestHeader("User-Agent", "Mozilla/5.0 (compatible; OnAir/2026.42)");
            xhr.setRequestHeader("Accept", "text/html,application/xhtml+xml,*/*");
        } catch (e) {
            finish("", "");
            return;
        }
        xhr.onreadystatechange = function() {
            var text = "", from = "";
            if (settled || (xhr.readyState !== xhr.LOADING && xhr.readyState !== xhr.DONE)) return;
            try { text = xhr.responseText || ""; } catch (e) { text = ""; }
            if (xhr.readyState === xhr.LOADING && text.length <= hunt.pageCap) return;
            settled = true;
            app._clearXhrTimeout(guard);
            // Many station sites answer an unknown path with a 404 that is
            // the whole page, icons included, so the status is not asked.
            // Where the answer came from is: a redirect Qt followed into the
            // LAN would turn an internal page's links into candidates. The
            // verdict is taken before the abort below, which empties the
            // reply; responseURL already names the last hop while LOADING
            // (measured on Qt 6.12).
            if (hunt._fromPublicHost(xhr, strict))
                from = String(xhr.responseURL || "") || page;
            // A body still streaming past the cap is cut. Never abort from
            // inside this handler: that has crashed plasmashell.
            if (xhr.readyState === xhr.LOADING)
                Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
            finish(text, from);
        };
        guard = app._armXhrTimeout(xhr, hunt.pageTimeoutMs);
        try {
            xhr.send();
        } catch (e) {
            settled = true;
            app._clearXhrTimeout(guard);
            finish("", "");
        }
    }

    // Asks the candidates in FaviconLogic.probeOrder's order until
    // FaviconLogic.huntSettled says it has asked enough, and hands the best
    // real picture to onDone({url, size}), or null. A candidate on a
    // private host is skipped unasked, on both roads; strict as readPage's.
    function probe(candidates, onDone, strict) {
        var order = FaviconLogic.probeOrder(candidates);
        var found = [], asked = 0, next = 0;
        var step = function() {
            var target = "";
            while (target === "" && next < order.length && !FaviconLogic.huntSettled(found, asked))
                target = FaviconLogic.webUrlOrEmpty(order[next++]);
            if (target === "") {
                Qt.callLater(function() { onDone(FaviconLogic.bestLogo(found)); });
                return;
            }
            asked++;
            _fetchImage(target, function(size, isImage) {
                if (isImage) found.push({ url: target, size: size });
                step();
            }, strict === true);
        };
        // The settings page calls this from inside a directory request's
        // handler; the first picture is asked after it has returned.
        Qt.callLater(step);
    }

    // The popup's whole hunt: what the page names and the well-known paths
    // on its origin, and no private host at all. onDone(url), "" for none.
    // Nobody clicked, so every answer has to name its public end, and a
    // tab-sized icon is no logo: blown up in the list it reads as broken,
    // and saved it would stand for good, the next hunt asking only for an
    // empty one. The station keeps its initials instead.
    function huntHomepage(homepage, onDone) {
        // A station's own address that forwards to a landlord's page is read
        // as that page.
        readPage(homepage, function(images, from) {
            probe(FaviconLogic.homepageCandidates(images, from || homepage), function(best) {
                var tiny = best && FaviconLogic.logoRank(best.url, best.size) >= 4;
                onDone(best && !tiny ? best.url : "");
            }, true);
        }, true);
    }

    // One candidate: onDone(size, isImage), always from outside the
    // request's own handler, so the next request starts clean.
    function _fetchImage(url, onDone, strict) {
        var xhr = null, guard = null, settled = false;
        var finish = function(size, isImage) {
            Qt.callLater(function() { onDone(size, isImage); });
        };
        try {
            xhr = _request();
            xhr.open("GET", url);
            xhr.responseType = "arraybuffer";
            xhr.setRequestHeader("User-Agent", "OnAir/2026.42");
        } catch (e) {
            finish(null, false);
            return;
        }
        xhr.onreadystatechange = function() {
            var bytes = null, got = 0;
            if (settled) return;
            if (xhr.readyState === xhr.LOADING) {
                try { got = xhr.response ? xhr.response.byteLength : 0; } catch (e) { got = 0; }
                if (!(got > hunt.imageCap)) return;
                // A logo that streams past half a megabyte is not a logo.
                settled = true;
                app._clearXhrTimeout(guard);
                Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                finish(null, false);
                return;
            }
            if (xhr.readyState !== xhr.DONE) return;
            settled = true;
            app._clearXhrTimeout(guard);
            // The address was judged before the request, but Qt follows
            // redirects inside the network layer: a station page answering
            // "302 to http://192.168.1.1/x.png" would hand an internal
            // host's bytes to the picture check and the result would be
            // saved as this station's logo.
            if (xhr.status >= 200 && xhr.status < 400 && xhr.response
                && hunt._fromPublicHost(xhr, strict)) {
                try { bytes = new Uint8Array(xhr.response); } catch (e) { bytes = null; }
            }
            if (bytes && bytes.length <= hunt.imageCap && FaviconLogic.looksLikeImageBytes(bytes))
                finish(FaviconLogic.imageSize(bytes), true);
            else
                finish(null, false);
        };
        guard = app._armXhrTimeout(xhr, hunt.probeTimeoutMs);
        try {
            xhr.send();
        } catch (e) {
            settled = true;
            app._clearXhrTimeout(guard);
            finish(null, false);
        }
    }
}
