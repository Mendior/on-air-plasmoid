/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick

import "EpisodeState.js" as EpisodeState
import "HostGuard.js" as HostGuard
import "OpmlLogic.js" as OpmlLogic
import "PodcastLogic.js" as PodcastLogic

// ── The podcast engine ───────────────────────────────────────────────────────
// First slice (2026-08-09): the downloads ledger — which files on disk are
// which episodes, and the two shell round-trips that may drop a ledger row.
// Carved out of main.qml along the boundary the extraction map drew; the
// search, feed and download pipeline follow in their own slices.
//
// The engine imports nothing but QtQuick and the podcast library: every touch
// on the outside world goes through `app` (main.qml's facade — exec/nextSeq/
// downloadDirPath) and every setting through `cfg`. Same contract as
// SyncEngine and TimeshiftEngine, and for the same reason: a mock app and a
// plain cfg object are all a test needs to drive this whole ledger.
Item {
    id: engine

    // main.qml's root item. This slice uses exactly: exec(cmd), nextSeq(),
    // downloadDirPath.
    required property var app
    // Plasmoid's configuration object in production; a plain object in tests.
    required property var cfg


    // ── The playing identity (A2) ────────────────────────────────────────
    // Written by the play/stop/death roads in main (through the aliases)
    // and read by thirty-odd UI sites; owned HERE so the lifecycle is
    // testable. The fields move and clear as one unit.
    // Resume bookkeeping: the playing episode's key and the seek waiting
    // for the media to load.
    // A subscribed show's feed was healed to a new address: whoever keys
    // state by the old one (the alarm engine) follows it.
    signal feedMoved(string oldFeed, string newFeed)
    property string _podPlayingKey: ""
    // The exact source URL of the tracked episode. The position-stamp and
    // played-mark act ONLY when the current source is this — otherwise a
    // file:// alarm chime playing over a stale _podPlayingKey would stamp
    // and mark the WRONG episode (the key is not cleared on every stop).
    property string _podPlayingUrl: ""
    // Cover for the episode currently playing — the show art captured when it
    // started. Non-empty ONLY while a podcast plays (cleared on handoff), so
    // it never overrides a station's own art. Feeds the now-playing panel.
    property string _podPlayingArt: ""
    // The playing episode's show name — shown small above the episode title,
    // the way every podcast app frames "Show › Episode". Same lifecycle as
    // _podPlayingArt (set on play, cleared on handoff/stop).
    property string _podPlayingShow: ""
    // Playback speed for local playback. Remembered per show (feedUrl of the
    // playing episode) over a global default; pitch-corrected where the
    // backend can, so voices don't chipmunk. A radio stream always plays 1x.
    property real podcastRate: 1.0
    property string _currentEpisodeFeed: ""
    // The playing file's silence map, cached for the skip timer.
    property var _podSilCur: []
    // The enclosure exactly as the ROW spelled it (identity for the row
    // ticks) — _podPlayingUrl carries the player's normalized spelling.
    property string _podPlayingRawUrl: ""
    // True while a podcast start rolls through the generic play roads.
    property bool _podStarting: false
    // The playing file's chapters ([[sec, title], …]) for the seek menu.
    property var _podChaptersCur: []

    // The 7-field death-clear, once — it was duplicated verbatim at four
    // player-death sites in main.qml, which is how identity fields drift
    // apart (the raw-URL invariant exists because one of them once did).
    function clearPlaying() {
        _podPlayingKey = "";
        _podPlayingUrl = "";
        _podPlayingRawUrl = "";
        _podPlayingArt = "";
        _podPlayingShow = "";
        _podSilCur = [];
        _podChaptersCur = [];
    }

    // filename → { key, title, show, art, feed, at }. The ledger behind the
    // Downloaded view; entries whose file is gone simply never render, and
    // the same at-based pruner the positions use caps it.
    property var downloads: ({})
    property int dlRev: 0

    // Token maps for the two async acks below. The token maps the ack back
    // to the file name without the name ever riding a shell sentinel.
    property var _rmByTok: ({})
    property int _rmTok: 0
    // Files whose playback erred, awaiting shell proof of absence before
    // the ledger row falls (shares the token counter with POD_RM).
    property var _goneByTok: ({})

    function loadDownloads() {
        try {
            var m = JSON.parse(cfg.podcastDownloads || "{}");
            downloads = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            downloads = {};
        }
    }

    function saveDownloads() {
        downloads = PodcastLogic.prunePositions(downloads, 500);
        cfg.podcastDownloads = JSON.stringify(downloads);
        dlRev++;
    }

    function downloadMeta(fileName) {
        void dlRev;
        var e = downloads[fileName];
        return (e && typeof e === "object") ? e : null;
    }

    // The file an episode was downloaded to, found by the episode's OWN
    // identity rather than by recomputing its name. The name carries a tag
    // derived from the feed, and a feed can move: `_podFeedRescue` rewrites
    // the subscription when a show changes host, and from that moment every
    // recomputed name misses — the row reads "not downloaded", tapping it
    // streams over the network while the file sits on disk, and ⬇ fetches a
    // second copy. The key never moves, so the ledger is asked instead.
    function fileForKey(key) {
        void dlRev;
        if (!key) return "";
        for (var fn in downloads) {
            var e = downloads[fn];
            if (e && typeof e === "object" && e.key === key) return fn;
        }
        return "";
    }

    // Remove one downloaded episode: the FILE (guarded to the Podcasts
    // folder — the name must be bare, no path parts) and its ledger row.
    // Positions and played-marks stay: re-downloading resumes where the
    // listener left off, which is the whole promise of the position map.
    function deleteDownload(fileName) {
        var name = (fileName || "").toString();
        if (name === "" || name.indexOf("/") !== -1 || name.indexOf("\\") !== -1
            || name.charAt(0) === ".") return;
        // The ledger row falls ONLY when the file is provably gone — the rm
        // is asynchronous, and dropping the metadata up front turned a
        // failed delete (read-only mount) into a bare-name row that had
        // lost its cover and resume point.
        var tok = ++_rmTok;
        _rmByTok[tok] = name;
        app.exec(": POD_RM " + tok + "; rm -f -- "
            + PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts/" + name)
            + " " + PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts/" + name + ".part")
            + "; [ ! -e " + PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts/" + name) + " ]"
            + " && echo __POD_RM_OK__; true # " + app.nextSeq());
    }

    // A playback error blamed this file. Ask the shell whether it is truly
    // gone; the ledger row falls only on proof — a healthy download whose
    // decode hiccuped keeps its cover and resume point.
    function requestGoneCheck(fileName) {
        if (fileName === "") return;
        var tok = ++_rmTok;
        _goneByTok[tok] = fileName;
        app.exec(": POD_GONE " + tok + "; [ ! -e "
            + PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts/" + fileName)
            + " ] && echo __POD_GONE__; true # " + app.nextSeq());
    }

    // The engine's half of the exec round-trips it started. Answers true
    // when the command was its own — the dispatcher's contract, shared with
    // SyncEngine.handleExec and TimeshiftEngine.handleExec.
    // stderr rides along for the failure messages: the download handler read
    // it as a bare name that nothing declared, so every failed transfer threw
    // ReferenceError before the slot was freed and no download ran again
    // until the widget restarted.
    function handleExec(cmd, stdout, stderr) {
        if (cmd.indexOf(": POD_RM") === 0) {
            var rmTokM = cmd.match(/^: POD_RM (\d+);/);
            var rmName = rmTokM ? _rmByTok[rmTokM[1]] : undefined;
            if (rmTokM) delete _rmByTok[rmTokM[1]];
            if (rmName !== undefined
                && (stdout || "").indexOf("__POD_RM_OK__") !== -1
                && downloads[rmName] !== undefined) {
                delete downloads[rmName];
                saveDownloads();
            } else if (rmName !== undefined
                       && (stdout || "").indexOf("__POD_RM_OK__") === -1) {
                console.warn("[ARP] podcast delete: file still present — ledger kept for " + rmName);
            }
            return true;
        }
        if (cmd.indexOf(": POD_GONE") === 0) {
            var goneM = cmd.match(/^: POD_GONE (\d+);/);
            var goneName = goneM ? _goneByTok[goneM[1]] : undefined;
            if (goneM) delete _goneByTok[goneM[1]];
            if (goneName !== undefined
                && (stdout || "").indexOf("__POD_GONE__") !== -1
                && downloads[goneName] !== undefined) {
                delete downloads[goneName];
                saveDownloads();
            }
            return true;
        }
        // OPML export written (or not) — one honest word with the path.
        if (cmd.indexOf(": OPML_EXPORT;") === 0) {
            if ((stdout || "").indexOf("__OPML_OK__") !== -1)
                app.notify(i18n("Subscriptions exported"), _opmlExportPath, "application-rss+xml");
            else
                app.notify(i18n("Export failed"),
                       i18n("Could not write the subscriptions file."), "dialog-error");
            return true;
        }
        // OPML import — the file's contents come back as stdout; parse
        // and subscribe (each feed still gated by addPodcastSub).
        if (cmd.indexOf(": OPML_IMPORT;") === 0) {
            _applyImportedOpml(stdout || "");
            return true;
        }
        if (cmd.indexOf(": POD_URL;") === 0) {
            if (_podDownloadKey === "") return true;
            if ((stdout || "").indexOf("__POD_URL_OK__") !== -1)
                _podRunDownload();
            else
                _podDownloadFail("could not stage the URL file");
            return true;
        }
        // Podcast episode download finished — one honest word either
        // way, and the single-download slot frees up. The Podcasts
        // folder model watches the directory itself, so the new file
        // appears without a manual refresh.
        if (cmd.indexOf(": POD_DL;") === 0) {
            var podOk = (stdout || "").indexOf("__POD_OK__") !== -1;
            if (podOk) {
                // The ledger row, written only on a landed file: the
                // Downloaded view joins the folder against this to show
                // an EPISODE — show, cover, resume — not a bare name.
                var pdm = _podDownloadMeta;
                if (pdm && pdm.file) {
                    downloads[pdm.file] = {
                        "key": pdm.key, "title": pdm.title, "show": pdm.show,
                        "art": pdm.art, "feed": pdm.feed, "at": Date.now()
                    };
                    saveDownloads();
                }
                // A night cycle's transfers stay quiet — the aggregate
                // already spoke for them; the user's own taps keep their
                // one honest word each.
                if (!_podDownloadAuto)
                    app.notify(i18n("Episode downloaded"), _podDownloadTitle, "folder-music");
            } else {
                console.warn("[ARP] podcast download failed: "
                             + (stderr || "").trim().split("\n").slice(-2).join(" "));
                if (!_podDownloadAuto)
                    app.notify(i18n("Episode download failed"), _podDownloadTitle, "dialog-error");
            }
            _podDownloadKey = "";
            _podDownloadTitle = "";
            var scanFile = podOk && _podDownloadMeta ? _podDownloadMeta.file : "";
            _podDownloadMeta = null;
            // The landed file gets its silence map (for skip-silence)…
            // The scan lives HERE, not on app: `app._podScanStart` was undefined,
            // and the TypeError landed before the queue moved on — one finished
            // episode and the line stood still until the widget restarted.
            if (scanFile !== "") _podScanStart(scanFile);
            // …and the line moves: next queued transfer starts now.
            if (_podDlQueue.length > 0) {
                var nextJob = _podDlQueue.shift();
                _podDlQueue = _podDlQueue;
                _podStartDownload(nextJob);
            }
            return true;
        }
        if (cmd.indexOf(": POD_SCAN;") === 0) {
            var sf = _podScanFile;
            _podScanFile = "";
            if (sf !== "" && downloads[sf] !== undefined) {
                var scanParts = (stdout || "").split("__CHAPTERS__");
                var sil = PodcastLogic.parseSilences(scanParts[0] || "", 0.9);
                var chs = PodcastLogic.parseChapters(scanParts[1] || "", 100);
                var dirty = false;
                if (sil.length > 0) { downloads[sf].sil = sil; dirty = true; }
                if (chs.length > 0) { downloads[sf].ch = chs; dirty = true; }
                if (dirty) {
                    saveDownloads();
                    app.applyFreshScan(sf, sil, chs);
                }
            }
            if (_podScanQueue.length > 0)
                _podScanStart(_podScanQueue.shift());
            return true;
        }
        return false;
    }

    // ── Subscriptions, OPML, the directory search, the charts and the open
    // feed — second slice, moved verbatim modulo the facade renames. ──────

    ListModel { id: podcastSubsModel }      // {title, author, art, feedUrl}
    ListModel { id: podcastSearchModel }    // merged directory results, same roles
    ListModel { id: podcastTrendingModel }  // the charts: Apple top list, fyyd standing in
    ListModel { id: podcastEpisodesModel }  // open feed: {title,url,guid,pubMs,durationSec,sizeBytes}
    // Episode-level hits across ALL shows — the search's second answer:
    // {title, show, art, url, guid, feed, dateMs, durationMs}
    ListModel { id: podcastEpSearchModel }

    readonly property alias subsModel: podcastSubsModel
    readonly property alias searchModel: podcastSearchModel
    readonly property alias trendingModel: podcastTrendingModel
    readonly property alias episodesModel: podcastEpisodesModel
    readonly property alias epSearchModel: podcastEpSearchModel

    property bool podcastSearchBusy: false
    property int _podSearchSeq: 0
    // How many directory responses the current search still waits for.
    property int _podSearchPending: 0
    property bool podcastTrendingBusy: false
    property int _podTrendSeq: 0
    property string podcastEpisodesFor: ""   // feedUrl the episodes model shows
    property string podcastEpisodesTitle: ""
    // The open show's artwork — the subscription/search row's art if it has
    // one, else the feed's own channel image. Fallback cover for episode rows
    // and the now-playing panel; always http(s)-gated before it is shown.
    property string podcastEpisodesArt: ""
    property bool podcastFeedLoading: false
    property string podcastFeedError: ""
    property int _podFeedSeq: 0
    // One retry per open: the rescue's own reload must not rescue again.
    property bool _podFeedNoRescue: false
    // ── OPML — the universal subscription backup / migration format ───────
    property string _opmlExportPath: ""
    // Which shows' newest episodes we have already seen (feed refresh news).
    property var seen: ({})

    function loadSubs() {
        try {
            const arr = JSON.parse(cfg.podcastSubs || "[]");
            podcastSubsModel.clear();
            for (var i = 0; i < arr.length && i < 100; i++) {
                const e = arr[i] || {};
                if (!PodcastLogic.urlAllowed(e.feedUrl)) continue;
                podcastSubsModel.append({
                    "title": String(e.title || "").substring(0, 200),
                    "author": String(e.author || "").substring(0, 200),
                    "art": PodcastLogic.urlAllowed(e.art) ? String(e.art).substring(0, 2048) : "",
                    "feedUrl": e.feedUrl
                });
            }
        } catch (e) {
            console.log("[ARP] loadPodcastSubs: " + e);
        }
    }

    function saveSubs() {
        const arr = [];
        for (var i = 0; i < podcastSubsModel.count; i++) {
            const p = podcastSubsModel.get(i);
            arr.push({ "title": p.title, "author": p.author, "art": p.art, "feedUrl": p.feedUrl });
        }
        cfg.podcastSubs = JSON.stringify(arr);
    }

    function isPodcastSubscribed(feedUrl) {
        // By feedKey, not by string: the same show reached over http and
        // https, or with and without a trailing slash, used to subscribe
        // twice and refresh twice.
        var want = PodcastLogic.feedKey(feedUrl);
        for (var i = 0; i < podcastSubsModel.count; i++)
            if (PodcastLogic.feedKey(podcastSubsModel.get(i).feedUrl) === want) return true;
        return false;
    }

    function addPodcastSub(title, author, art, feedUrl) {
        if (!PodcastLogic.urlAllowed(feedUrl) || isPodcastSubscribed(feedUrl)) return false;
        // The cap the loader enforces, enforced at the door too: an OPML
        // with a thousand feeds used to bloat the config past what the next
        // start would silently drop at 100 — everything past the cap looked
        // imported and then vanished on restart.
        if (podcastSubsModel.count >= 100) return false;
        podcastSubsModel.append({
            "title": String(title || "").substring(0, 200),
            "author": String(author || "").substring(0, 200),
            // Capped like the texts: a feed-controlled megabyte "URL" must
            // not ride into the config file.
            "art": PodcastLogic.urlAllowed(art) ? String(art).substring(0, 2048) : "",
            "feedUrl": feedUrl
        });
        saveSubs();
        return true;
    }

    function removePodcastSub(feedUrl) {
        // By feedKey, like isPodcastSubscribed — the star's state and the road
        // that clears it have to agree on what "this show" means. While one
        // matched keys and the other raw strings, a row reached over the other
        // spelling read as subscribed and its unsubscribe did nothing at all.
        var want = PodcastLogic.feedKey(feedUrl);
        for (var i = 0; i < podcastSubsModel.count; i++) {
            if (PodcastLogic.feedKey(podcastSubsModel.get(i).feedUrl) === want) {
                podcastSubsModel.remove(i);
                saveSubs();
                return;
            }
        }
    }

    function exportSubscriptions() {
        var subs = [];
        for (var i = 0; i < podcastSubsModel.count; i++) {
            var p = podcastSubsModel.get(i);
            subs.push({ title: p.title, feedUrl: p.feedUrl });
        }
        if (subs.length === 0) {
            app.notify(i18n("Nothing to export"), i18n("Subscribe to a show first."), "dialog-information");
            return;
        }
        var opml = OpmlLogic.buildOpml(subs);
        _opmlExportPath = app.downloadDirPath + "/onair-subscriptions.opml";
        // The whole document goes through the one tested quoter — titles and
        // feed URLs are user/feed data and must not reach the shell raw.
        app.exec(": OPML_EXPORT; mkdir -p " + PodcastLogic.shQuote(app.downloadDirPath)
            + " && printf '%s' " + PodcastLogic.shQuote(opml)
            + " > " + PodcastLogic.shQuote(_opmlExportPath)
            + " && echo __OPML_OK__ || echo __OPML_FAIL__; true # " + app.nextSeq());
    }

    // Read an OPML file the user picked and subscribe to every feed in it.
    // The file is read through the exec channel (a QML file:// XHR is
    // sandboxed), parsed by the never-throws OpmlLogic, and every feedUrl
    // still passes addPodcastSub's HostGuard gate + the 100-sub cap.
    function importSubscriptionsFromPath(path) {
        if (!path) return;
        var p = path.toString().replace(/^file:\/\//, "");
        try { p = decodeURIComponent(p); } catch (e) {}
        app.exec(": OPML_IMPORT; cat " + PodcastLogic.shQuote(p)
            + " 2>/dev/null; true # " + app.nextSeq());
    }

    function _applyImportedOpml(xml) {
        var subs = OpmlLogic.parseOpml(xml);
        var added = 0;
        for (var i = 0; i < subs.length; i++) {
            if (addPodcastSub(subs[i].title, "", "", subs[i].feedUrl)) added++;
        }
        if (added > 0)
            app.notify(i18n("Subscriptions imported"),
                   i18np("%1 show added", "%1 shows added", added), "application-rss+xml");
        else
            app.notify(i18n("Nothing imported"),
                   i18n("No new podcast feeds were found in that file."), "dialog-information");
    }

    // Show search via the iTunes directory — keyless, so no secret ever
    // sits in a public plasmoid (the PodcastIndex API wants a signed
    // key and is out for exactly that reason).
    function podcastSearch(term) {
        var q = (term || "").trim();
        // The early returns bump the sequence too: an older query's XHR still
        // in flight must find itself stale, or its late response repopulates
        // the list the clear below just emptied.
        // A single character buys four API calls and burns the shared
        // per-IP budget the cover search also lives on — no directory
        // answers anything useful to it anyway.
        if (q.length < 2) {
            _podSearchSeq++; podcastSearchModel.clear(); podcastEpSearchModel.clear();
            podcastSearchBusy = false; return;
        }
        // A pasted feed URL is not a directory query — the shows view offers a
        // direct "open this feed" action for it, so no iTunes round-trip here.
        if (/^https?:\/\//i.test(q)) {
            _podSearchSeq++; podcastSearchModel.clear(); podcastEpSearchModel.clear();
            podcastSearchBusy = false; return;
        }
        // THREE directories at once — iTunes (primary, biggest index),
        // fyyd.de and gpodder.net — plus iTunes again at the EPISODE level,
        // which finds the needle no show-title search can (a topic, a guest,
        // one famous interview). Show results merge as they land, deduped by
        // canonical feed key; a source failing just means the others answer.
        podcastSearchBusy = true;
        var seq = ++_podSearchSeq;
        podcastSearchModel.clear();
        podcastEpSearchModel.clear();
        _podSearchPending = 4;
        _podSearchITunes(q, seq);
        _podSearchFyyd(q, seq);
        _podSearchGpodder(q, seq);
        _podSearchEpisodes(q, seq);
    }

    function _podAppendSearchRow(title, author, art, feed, rank) {
        feed = String(feed || "").trim();
        if (!PodcastLogic.urlAllowed(feed)) return;
        // Cross-directory twins wear different coats for one address —
        // http vs https, a trailing slash, a shouting host. The canonical
        // key sees through all three. A twin does not vanish: it UPGRADES
        // the row it duplicates — the fast directory used to win the slot
        // with a missing (or dead-host) cover while the slow one arrived
        // holding the real artwork, and the real artwork was thrown away.
        var fkey = PodcastLogic.feedKey(feed);
        for (var i = 0; i < podcastSearchModel.count; i++) {
            if (PodcastLogic.feedKey(podcastSearchModel.get(i).feedUrl) !== fkey) continue;
            var row = podcastSearchModel.get(i);
            var artOk = PodcastLogic.urlAllowed(art);
            if (artOk && (row.art === ""
                          || (_podFyydArt.test(row.art) && !_podFyydArt.test(art))))
                podcastSearchModel.setProperty(i, "art", String(art).substring(0, 2048));
            if (row.author === "" && author)
                podcastSearchModel.setProperty(i, "author", String(author).substring(0, 200));
            return;
        }
        if (podcastSearchModel.count >= 50) return;
        // Sources land in whatever order the network felt like — the same
        // query used to open with a different first row every time, the
        // fastest directory claiming the top. Each source carries a rank
        // (iTunes 0, fyyd 1, gpodder 2) and a row files in behind its own
        // block, so the order is the directories' judgment, not the race's.
        var r = rank === undefined ? 9 : rank;
        var at = podcastSearchModel.count;
        for (var p = 0; p < podcastSearchModel.count; p++) {
            if (podcastSearchModel.get(p).rank > r) { at = p; break; }
        }
        podcastSearchModel.insert(at, {
            "title": String(title || "").substring(0, 200),
            "author": String(author || "").substring(0, 200),
            "art": PodcastLogic.urlAllowed(art) ? String(art).substring(0, 2048) : "",
            "feedUrl": feed,
            "rank": r
        });
    }

    // A source finished (well or badly) — the spinner stops when the last
    // one is in. A stale seq never settles: the counter belongs to the
    // query that superseded it.
    function _podSearchSettle(seq) {
        if (seq !== _podSearchSeq) return;
        _podSearchPending--;
        if (_podSearchPending <= 0) podcastSearchBusy = false;
    }

    function _podSearchITunes(q, seq) {
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        xhr.onreadystatechange = function() {
            // The same 512 KB leash the gpodder handler carries: a search
            // answer is a few dozen KB, anything bigger is broken or hostile.
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 512 * 1024) {
                    aborted = true;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podSearchSeq) return;   // a newer search took over
            try {
                var res = JSON.parse(xhr.responseText || "{}").results || [];
                for (var i = 0; i < res.length; i++) {
                    var r = res[i] || {};
                    _podAppendSearchRow(r.collectionName, r.artistName,
                        String(r.artworkUrl600 || r.artworkUrl100 || "").trim(),
                        r.feedUrl, 0);
                }
            } catch (e) {
                console.log("[ARP] podcastSearch(iTunes): " + e);
            }
            _podSearchSettle(seq);
        };
        xhr.open("GET", "https://itunes.apple.com/search?media=podcast&limit=30&term="
                        + encodeURIComponent(q));
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 10000);
        xhr.send();
    }

    function _podSearchFyyd(q, seq) {
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 512 * 1024) {
                    aborted = true;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podSearchSeq) return;
            try {
                var res = JSON.parse(xhr.responseText || "{}").data || [];
                for (var i = 0; i < res.length; i++) {
                    var r = res[i] || {};
                    _podAppendSearchRow(r.title, r.author,
                        String(r.smallImageURL || r.imgURL || "").trim(),
                        r.xmlURL, 1);
                }
            } catch (e) {
                console.log("[ARP] podcastSearch(fyyd): " + e);
            }
            _podSearchSettle(seq);
        };
        xhr.open("GET", "https://api.fyyd.de/0.2/search/podcast?count=30&title="
                        + encodeURIComponent(q));
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 10000);
        xhr.send();
    }

    // gpodder.net — the open-source directory, keyless like fyyd, with the
    // feed URL first-class in every row. No author field; the show's own
    // website host stands in so the row is not naked.
    function _podSearchGpodder(q, seq) {
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 512 * 1024) {
                    aborted = true;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podSearchSeq) return;
            try {
                var res = JSON.parse(xhr.responseText || "[]") || [];
                for (var i = 0; i < res.length && i < 30; i++) {
                    var r = res[i] || {};
                    var hm = /^https?:\/\/([^\/?#:]+)/i.exec(String(r.website || ""));
                    var host = hm ? hm[1] : "";
                    _podAppendSearchRow(r.title, host,
                        String(r.logo_url || "").trim(), r.url, 2);
                }
            } catch (e) {
                console.log("[ARP] podcastSearch(gpodder): " + e);
            }
            _podSearchSettle(seq);
        };
        xhr.open("GET", "https://gpodder.net/search.json?q=" + encodeURIComponent(q));
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 10000);
        xhr.send();
    }

    // Episode-level search across every show — iTunes carries it keyless
    // under the same endpoint (entity=podcastEpisode), and it answers the
    // queries a show-title search cannot: a topic, a guest's name, that
    // one famous interview. The row plays directly (the enclosure URL is
    // in the answer) and carries its show's feed for the "open the show"
    // road. Verified live 2026-08-06: episodeUrl + feedUrl + duration in
    // every row.
    function _podSearchEpisodes(q, seq) {
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 512 * 1024) {
                    aborted = true;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podSearchSeq) return;
            try {
                var res = JSON.parse(xhr.responseText || "{}").results || [];
                for (var i = 0; i < res.length && podcastEpSearchModel.count < 30; i++) {
                    var r = res[i] || {};
                    var eurl = String(r.episodeUrl || "").trim();
                    if (!PodcastLogic.urlAllowed(eurl)) continue;
                    var seen = false;
                    for (var d = 0; d < podcastEpSearchModel.count; d++)
                        if (podcastEpSearchModel.get(d).url === eurl) { seen = true; break; }
                    if (seen) continue;
                    var eart = String(r.artworkUrl600 || r.artworkUrl160 || r.artworkUrl100 || "").trim();
                    var efeed = String(r.feedUrl || "").trim();
                    var dm = Date.parse(String(r.releaseDate || ""));
                    podcastEpSearchModel.append({
                        "title": String(r.trackName || "").substring(0, 200),
                        "show": String(r.collectionName || "").substring(0, 200),
                        "art": PodcastLogic.urlAllowed(eart) ? eart.substring(0, 2048) : "",
                        "url": eurl,
                        "guid": String(r.episodeGuid || "").substring(0, 512),
                        "feed": PodcastLogic.urlAllowed(efeed) ? efeed.substring(0, 2048) : "",
                        "dateMs": isFinite(dm) ? dm : 0,
                        "durationMs": Number(r.trackTimeMillis) > 0 ? Number(r.trackTimeMillis) : 0
                    });
                }
            } catch (e) {
                console.log("[ARP] podcastSearch(episodes): " + e);
            }
            _podSearchSettle(seq);
        };
        xhr.open("GET", "https://itunes.apple.com/search?media=podcast&entity=podcastEpisode&limit=30&term="
                        + encodeURIComponent(q));
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 10000);
        xhr.send();
    }

    // The charts. Apple's per-country top list is keyless and fresh, and
    // ONE batch lookup turns its ids into feed URLs — two requests for a
    // local Top 25. fyyd's worldwide hot list stands in when Apple
    // refuses: for a small country it is no replacement (measured
    // 2026-08-06: fyyd has zero Estonian shows — 'et' is not even in its
    // language list), but it is better than an empty pane. Cached for the
    // session; `force` re-fetches.
    function podcastLoadTrending(force) {
        if (podcastTrendingBusy) return;
        if (!force && podcastTrendingModel.count > 0) return;
        var seq = ++_podTrendSeq;
        podcastTrendingBusy = true;
        _podTrendApple(seq);
    }

    function _podTrendRow(title, author, art, feed) {
        if (podcastTrendingModel.count >= 30) return;
        feed = String(feed || "").trim();
        if (!PodcastLogic.urlAllowed(feed)) return;
        podcastTrendingModel.append({
            "title": String(title || "").substring(0, 200),
            "author": String(author || "").substring(0, 200),
            "art": PodcastLogic.urlAllowed(art) ? String(art).substring(0, 2048) : "",
            "feedUrl": feed
        });
    }

    function _podTrendApple(seq) {
        var cc = /^[A-Za-z]{2}$/.test(app.homeCountryCode) ? app.homeCountryCode.toLowerCase() : "us";
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 512 * 1024) {
                    aborted = true;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podTrendSeq) return;
            var ids = [];
            var meta = {};
            try {
                var res = (JSON.parse(xhr.responseText || "{}").feed || {}).results || [];
                for (var i = 0; i < res.length && ids.length < 25; i++) {
                    var r = res[i] || {};
                    var id = String(r.id || "").trim();
                    if (!/^\d{1,12}$/.test(id)) continue;
                    ids.push(id);
                    meta[id] = { "name": String(r.name || ""), "artist": String(r.artistName || ""),
                                 "art": String(r.artworkUrl100 || "").trim() };
                }
            } catch (e) {
                console.log("[ARP] podcastTrending(apple): " + e);
            }
            if (ids.length === 0) { _podTrendFyyd(seq); return; }
            _podTrendAppleResolve(seq, ids, meta);
        };
        xhr.open("GET", "https://rss.marketingtools.apple.com/api/v2/" + cc
                        + "/podcasts/top/25/podcasts.json");
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 10000);
        xhr.send();
    }

    // The chart names shows; subscribing needs their FEEDS. One lookup
    // call resolves the whole list, and the walk keeps the CHART's order —
    // the lookup answers in whatever order it pleases.
    function _podTrendAppleResolve(seq, ids, meta) {
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 512 * 1024) {
                    aborted = true;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podTrendSeq) return;
            var byId = {};
            try {
                var res = JSON.parse(xhr.responseText || "{}").results || [];
                for (var i = 0; i < res.length; i++) {
                    var r = res[i] || {};
                    byId[String(r.collectionId || "")] = {
                        "feed": String(r.feedUrl || "").trim(),
                        "art": String(r.artworkUrl600 || "").trim()
                    };
                }
            } catch (e) {
                console.log("[ARP] podcastTrending(lookup): " + e);
            }
            podcastTrendingModel.clear();
            for (var k = 0; k < ids.length; k++) {
                var m = meta[ids[k]] || {};
                var hit = byId[ids[k]];
                if (!hit || hit.feed === "") continue;
                _podTrendRow(m.name, m.artist, hit.art || m.art, hit.feed);
            }
            if (podcastTrendingModel.count === 0) { _podTrendFyyd(seq); return; }
            podcastTrendingBusy = false;
        };
        xhr.open("GET", "https://itunes.apple.com/lookup?id=" + ids.join(","));
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 10000);
        xhr.send();
    }

    function _podTrendFyyd(seq) {
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 512 * 1024) {
                    aborted = true;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podTrendSeq) return;
            podcastTrendingBusy = false;
            podcastTrendingModel.clear();
            try {
                var res = JSON.parse(xhr.responseText || "{}").data || [];
                for (var i = 0; i < res.length && podcastTrendingModel.count < 30; i++) {
                    var r = res[i] || {};
                    _podTrendRow(r.title, r.author,
                                      String(r.smallImageURL || r.imgURL || "").trim(),
                                      String(r.xmlURL || "").trim());
                }
            } catch (e) {
                console.log("[ARP] podcastLoadTrending: " + e);
            }
        };
        xhr.open("GET", "https://api.fyyd.de/0.2/feature/podcast/hot?count=30");
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 10000);
        xhr.send();
    }

    function loadPodcastFeed(feedUrl, showTitle, showArt, noRescue) {
        if (!PodcastLogic.urlAllowed(feedUrl)) {
            podcastFeedError = i18n("This feed address is not allowed.");
            return;
        }
        _podFeedNoRescue = noRescue === true;
        var seq = ++_podFeedSeq;
        podcastEpisodesFor = feedUrl;
        podcastEpisodesTitle = showTitle || "";
        // The row's own art up front (instant cover); the feed's channel image
        // fills in below only when the row brought none (a hand-typed URL).
        podcastEpisodesArt = PodcastLogic.urlAllowed(showArt)
                             ? String(showArt).substring(0, 2048) : "";
        podcastFeedLoading = true;
        podcastFeedError = "";
        podcastEpisodesModel.clear();
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        var partial = "";
        xhr.onreadystatechange = function() {
            // 4 MB cap: a mega-feed must not balloon plasmashell. Abort is
            // DEFERRED — aborting inside the handler re-enters the dying
            // reply and has crashed the shell before (the probe lesson).
            // The body is SAVED first: abort clears responseText, and a
            // 7 MB libsyn feed (measured live, perfectly valid RSS) used to
            // parse as emptiness and earn a false 'not a podcast feed'.
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 4 * 1024 * 1024) {
                    aborted = true;
                    partial = xhr.responseText;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podFeedSeq) return;
            podcastFeedLoading = false;
            // urlAllowed vetted the FIRST address only — Qt follows the
            // redirects internally. A feed answering from the LAN must not
            // have its body parsed into enclosures: the same last-hop gate
            // the playlist unwrapper carries.
            if (!HostGuard.answerFromPublicHost(xhr)) {
                podcastFeedError = i18n("This feed address is not allowed.");
                return;
            }
            // A capped body still parses — RSS carries the newest items first.
            var feed = PodcastLogic.parseFeed((xhr.responseText || "") || partial, 50);
            if (!feed.ok) {
                // Transport failure is not directory rot: a timeout, a DNS
                // blip or a 5xx must neither blame the address nor call the
                // rescue — one 15 s hiccup used to rewrite a living feed's
                // subscription to whatever iTunes matched the title to,
                // permanently.
                // "hiccup", not "transient": the latter is an ECMAScript
                // future-reserved word, and Qt 6.10's parser rejects those
                // as identifiers outright — the `var final` lesson.
                var hiccup = xhr.status === 0 || xhr.status === 408
                             || xhr.status === 429 || xhr.status >= 500;
                // Directory rot is ordinary: fyyd and gpodder carry
                // addresses their crawlers last saw months ago. Before the
                // honest error, one rescue — the same cure the stations
                // have: ask iTunes for the show BY TITLE and follow where
                // it lives today. A subscribed show heals PERMANENTLY.
                if (!hiccup && !_podFeedNoRescue && (showTitle || "") !== "") {
                    _podFeedRescue(seq, feedUrl, showTitle, showArt || "",
                                        xhr.status);
                    return;
                }
                podcastFeedError = xhr.status === 0
                    ? i18n("The feed could not be reached — check the connection and try again.")
                    : xhr.status >= 400
                      ? i18n("The feed did not answer (error %1).", xhr.status)
                      : i18n("This address is not a podcast feed.");
                return;
            }
            if (podcastEpisodesTitle === "" && feed.title !== "")
                podcastEpisodesTitle = feed.title.substring(0, 200);
            // A hand-typed feed URL brings no row art — adopt the show's own
            // channel image so its episodes get a cover too.
            if (podcastEpisodesArt === "" && feed.image !== "")
                podcastEpisodesArt = feed.image.substring(0, 2048);
            for (var i = 0; i < feed.episodes.length; i++)
                podcastEpisodesModel.append(feed.episodes[i]);
            if (feed.episodes.length === 0)
                podcastFeedError = i18n("No playable episodes in this feed.");
        };
        xhr.open("GET", feedUrl);
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 15000);
        xhr.send();
    }

    function _podFeedRescue(seq, deadFeed, showTitle, showArt, deadStatus) {
        var xhr = new XMLHttpRequest();
        var guard = null;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            app._clearXhrTimeout(guard); guard = null;
            if (seq !== _podFeedSeq) return;
            var fresh = "";
            try {
                var res = JSON.parse(xhr.responseText || "{}").results || [];
                var want = String(showTitle).replace(/\s+/g, " ").trim().toLowerCase();
                var deadKey = PodcastLogic.feedKey(deadFeed);
                for (var i = 0; i < res.length; i++) {
                    var r = res[i] || {};
                    var cand = String(r.feedUrl || "").trim();
                    if (!PodcastLogic.urlAllowed(cand)) continue;
                    if (PodcastLogic.feedKey(cand) === deadKey) continue;
                    var rn = String(r.collectionName || "").replace(/\s+/g, " ").trim().toLowerCase();
                    if (rn !== want) continue;      // identity, not resemblance
                    fresh = cand;
                    break;
                }
            } catch (e) {}
            if (fresh === "") {
                podcastFeedLoading = false;
                podcastFeedError = deadStatus === 0
                    ? i18n("The feed could not be reached — check the connection and try again.")
                    : deadStatus >= 400
                      ? i18n("The feed did not answer (error %1).", deadStatus)
                      : i18n("This address is not a podcast feed.");
                return;
            }
            console.log("[ARP] podcast feed heal: " + app._hostOf(deadFeed) + " -> " + app._hostOf(fresh));
            // A subscribed show follows its feed for good — the seen map
            // and the per-show speed move with it, so nothing re-announces
            // and the remembered pace survives the move.
            for (var si = 0; si < podcastSubsModel.count; si++) {
                if (podcastSubsModel.get(si).feedUrl !== deadFeed) continue;
                podcastSubsModel.setProperty(si, "feedUrl", fresh);
                saveSubs();
                if (seen[deadFeed] !== undefined) {
                    seen[fresh] = seen[deadFeed];
                    delete seen[deadFeed];
                    saveSeen();
                }
                break;
            }
            // Everything else keyed by the old address moves too, or the
            // show's speed resets, the alarm that plays "the newest episode
            // of this show" finds no episode under the new feed, and
            // auto-clean judges downloads by a feed that no longer exists.
            if (_podSpeeds[deadFeed] !== undefined) {
                var sp = {};
                for (var sk in _podSpeeds) sp[sk] = _podSpeeds[sk];
                sp[fresh] = sp[deadFeed]; delete sp[deadFeed];
                _podSpeeds = sp;
                cfg.podcastSpeeds = JSON.stringify(_podSpeeds);
            }
            var moved = false;
            for (var dk in downloads)
                if (downloads[dk] && downloads[dk].feed === deadFeed) { downloads[dk].feed = fresh; moved = true; }
            if (moved) saveDownloads();
            feedMoved(deadFeed, fresh);
            loadPodcastFeed(fresh, showTitle, showArt, true);
        };
        xhr.open("GET", "https://itunes.apple.com/search?media=podcast&limit=10&term="
                        + encodeURIComponent(showTitle));
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = app._armXhrTimeout(xhr, 8000);
        xhr.send();
    }

    function loadSeen() {
        try {
            var m = JSON.parse(cfg.podcastSeen || "{}");
            seen = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            seen = {};
        }
    }

    function saveSeen() {
        cfg.podcastSeen = JSON.stringify(seen);
    }

    // ── The download pipeline — slice 3a: one slot, a bounded queue, the
    // staged curl transfer, and the two acks that write the ledger. ──────

    // One transfer at a time, the rest wait in a bounded line — the queue
    // is what lets a refresh cycle fetch three shows' new episodes without
    // trampling the single download slot the UI also uses.
    property var _podDlQueue: []

    property bool _podDownloadAuto: false
    // One download at a time — deterministic, and the status line stays honest.
    property string _podDownloadKey: ""
    property string _podDownloadTitle: ""
    // The download in flight, remembered in full: the OK ack writes this
    // into the downloads ledger so the Downloaded view can show the episode
    // as an EPISODE — show, cover, resume — not as a bare file name.
    property var _podDownloadMeta: null

    // The exact filename an episode downloads to — the UI checks the
    // Podcasts folder for it to tell "download" from "play". The feed+guid
    // tag is what keeps two shows' "Trailer" apart; podcastFileNameLegacy
    // is the pre-tag name, which files already on disk still carry.
    function podcastFileName(title, url, feed, guid) {
        return PodcastLogic.episodeFileName(title, url, feed, guid);
    }

    function podcastFileNameLegacy(title, url) {
        return PodcastLogic.legacyEpisodeFileName(title, url);
    }

    // May THIS show claim a pre-tag file? The old name carries no feed, so
    // the ledger is the only witness — and it is asked only to CONTRADICT.
    // A file the ledger never knew (downloaded before it, or pruned since)
    // still belongs to whoever opens it, exactly as it always did; a row
    // naming a different feed is proof of the very collision the tag was
    // added to end, and then the alias is refused rather than handing one
    // show the other's audio under the right title.
    function podcastLegacyIsOurs(fileName, feed, guid, url) {
        var e = downloads[fileName];
        if (!e) return true;
        if (e.key !== undefined && e.key !== "") {
            var k = PodcastLogic.episodeKey(guid, url);
            if (k !== "" && e.key === k) return true;
        }
        if (!e.feed || !feed) return true;
        return e.feed === feed;
    }

    function downloadEpisode(title, url, guid) {
        // The UI road: the open show's identity rides into the job, so the
        // ledger row (and the Downloaded view) knows the episode's home.
        _podEnqueueDownload({
            "title": title, "url": url, "guid": guid,
            "show": String(podcastEpisodesTitle || "").substring(0, 200),
            "art": PodcastLogic.urlAllowed(podcastEpisodesArt)
                   ? String(podcastEpisodesArt).substring(0, 2048) : "",
            "feed": String(podcastEpisodesFor || "").substring(0, 2048)
        });
    }

    function _podEnqueueDownload(job) {
        if (!job || !PodcastLogic.urlAllowed(job.url)) return false;
        var key = PodcastLogic.episodeKey(job.guid, job.url);
        if (_podDownloadKey === key) return true;          // already fetching
        for (var i = 0; i < _podDlQueue.length; i++)
            if (PodcastLogic.episodeKey(_podDlQueue[i].guid, _podDlQueue[i].url) === key)
                return true;                               // already queued
        if (_podDownloadKey !== "") {
            if (_podDlQueue.length >= 20) return false;    // bounded line
            _podDlQueue.push(job);
            _podDlQueue = _podDlQueue;
            return true;
        }
        _podStartDownload(job);
        return true;
    }

    function _podStartDownload(job) {
        var title = job.title, url = job.url, guid = job.guid;
        _podDownloadAuto = job.auto === true;
        _podDownloadKey = PodcastLogic.episodeKey(guid, url);
        // The title reaches the notification body, which Plasma renders with
        // markup — a feed's "<a href=…>tap</a>" would become a live phishing
        // link. Strip markup and bidi/control chars, exactly as every LAN
        // device name is stripped before it reaches a notification or a list.
        _podDownloadTitle = app._sanitizeDeviceName(title);
        // The episode's identity, held until the OK ack writes the ledger.
        _podDownloadMeta = {
            "file": podcastFileName(title, url, job.feed, guid),
            "key": _podDownloadKey,
            "title": _podDownloadTitle,
            "show": String(job.show || "").substring(0, 200),
            "art": PodcastLogic.urlAllowed(job.art) ? String(job.art).substring(0, 2048) : "",
            "feed": String(job.feed || "").substring(0, 2048)
        };
        // A control character in the URL could smuggle a second line — a
        // second directive — into the curl config written below. urlAllowed
        // has vetted scheme and host already; an address with a newline in
        // it is not an address.
        if (/[\x00-\x1f\x7f]/.test(url)) {
            _podDownloadFail("control character in enclosure URL");
            return;
        }
        // The URL goes to disk first (owner-only, like reader.py's file) and
        // curl picks it up with -K, so it never rides a long-lived argv. It
        // is on THIS printf's command line for the microseconds the write
        // takes — the whole-transfer exposure was the point of the change.
        var cfgLine = 'url = "' + url.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + '"';
        app.exec(": POD_URL; umask 077; printf '%s' "
            + PodcastLogic.shQuote(cfgLine)
            + " > " + PodcastLogic.shQuote(app._podUrlFile)
            + " && echo __POD_URL_OK__ || echo __POD_URL_FAIL__; "
            + "true # " + app.nextSeq());
    }

    // One failure road for both halves of a download: free the slot, tell
    // the user if this was their own tap, and let the line move. The reason
    // is for the journal, so it names no URL.
    function _podDownloadFail(reason) {
        console.warn("[ARP] podcast download failed: " + reason);
        if (!_podDownloadAuto)
            app.notify(i18n("Episode download failed"), _podDownloadTitle, "dialog-error");
        _podDownloadKey = "";
        _podDownloadTitle = "";
        _podDownloadMeta = null;
        if (_podDlQueue.length > 0) {
            var nextJob = _podDlQueue.shift();
            _podDlQueue = _podDlQueue;
            _podStartDownload(nextJob);
        }
    }

    // The transfer itself, started only once the URL file is on disk.
    // Every word single-quoted through the ONE tested escaper — the file
    // name derives from feed data, so a hand-rolled inline escape is
    // exactly where a mistyped backslash became command injection.
    function _podRunDownload() {
        var pdm = _podDownloadMeta;
        if (!pdm || !pdm.file) return;
        var part = PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts/" + pdm.file + ".part");
        var dest = PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts/" + pdm.file);
        var dir = PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts");
        var cfg = PodcastLogic.shQuote(app._podUrlFile);
        // Staged download: .part first, atomic rename on success — the
        // folder model never lists a half-written file as playable. The
        // size cap guards the disk; -f keeps HTTP errors out of the file.
        // The config file is spent the moment curl exits, either way.
        // Redirects stay on http(s) and stop at ten hops: urlAllowed vets
        // only the FIRST address, and a hostile enclosure answering with
        // a Location elsewhere must not widen what -L will follow — the
        // same leash the favicon fetcher already wears.
        app.exec(": POD_DL; mkdir -p " + dir + " && "
            + "curl -fSL --proto '=http,https' --proto-redir '=http,https' --max-redirs 10 "
            + "--max-time 3600 --max-filesize 1073741824 --retry 2 "
            + "-A 'OnAir/2026.39' -o " + part + " -K " + cfg + "; "
            + "rc=$?; rm -f " + cfg + "; "
            + "[ \"$rc\" -eq 0 ] && mv -f " + part + " " + dest + " "
            + "&& echo __POD_OK__ || { rm -f " + part + "; echo __POD_FAIL__; }; "
            + "true # " + app.nextSeq());
    }

    // ── Slice 3b: the refresh machine, the silence scan, the queue and
    // every per-episode memory map — data only; the player stays out. ─────

    Timer {
        id: podRefreshTick
        interval: 30 * 60 * 1000
        repeat: true
        running: true
        onTriggered: _podRefreshMaybe()
    }
    // One early look after login, once the shell has settled.
    Timer {
        id: podRefreshKickoff
        interval: 90 * 1000
        repeat: false
        running: true
        onTriggered: _podRefreshMaybe()
    }

    property var _podRefreshQueue: []
    property bool _podRefreshBusy: false
    property var _podRefreshNews: []
    property int _podRefreshDls: 0
    property int _podRefreshOkCount: 0
    // Serialized ffmpeg silence scans over landed files.
    property string _podScanFile: ""
    property var _podScanQueue: []
    property var _podUpNext: []
    property int _podUpNextRev: 0
    property var _podPositions: ({})
    // Bumped on every positions-map mutation: the map itself is mutated in
    // place (no change signal), so badges bind through this tick instead.
    property int _podPosRev: 0
    property var _podSpeeds: ({})
    // Played/unplayed memory: an episodeKey -> timestamp map. Filled when an
    // episode finishes (or is manually marked); the delegate reads it through
    // the change tick, since the map is mutated in place.
    property var _podPlayed: ({})
    property int _podPlayedRev: 0

    function _podRefreshMaybe() {
        var hours = parseInt(cfg.podcastAutoRefreshHours);
        if (!isFinite(hours)) hours = 12;
        if (hours <= 0 || _podRefreshBusy || podcastSubsModel.count === 0) return;
        var last = parseInt(cfg.podcastLastRefresh) || 0;
        if (Date.now() - last < hours * 3600 * 1000) return;
        _podRefreshBusy = true;
        _podRefreshNews = [];
        _podRefreshDls = 0;
        _podRefreshOkCount = 0;
        _podRefreshQueue = [];
        for (var i = 0; i < podcastSubsModel.count; i++) {
            var sub = podcastSubsModel.get(i);
            _podRefreshQueue.push({ "feed": sub.feedUrl, "title": sub.title, "art": sub.art });
        }
        _podRefreshNext();
    }

    function _podRefreshNext() {
        if (_podRefreshQueue.length === 0) { _podRefreshFinish(); return; }
        var job = _podRefreshQueue.shift();
        _podFetchFeedSilent(job.feed, function(feed) {
            if (feed && feed.ok) _podRefreshOkCount++;
            var newest = (feed && feed.ok && feed.episodes.length > 0) ? feed.episodes[0] : null;
            if (newest) {
                // A guid-less feed whose enclosure URL wears a per-request
                // token would read "new" on every fetch — the TITLE-derived
                // filename is the stable identity to remember it by.
                // The LEGACY (title-only) name is the right stable identity
                // here: the tagged name folds the guid back in, and for a
                // guid-less feed that is exactly what this branch cannot use.
                var seenKeyOf = function(ep) {
                    return ep.guid !== "" ? PodcastLogic.episodeKey(ep.guid, ep.url)
                                          : "t:" + podcastFileNameLegacy(ep.title, ep.url);
                };
                var nk = seenKeyOf(newest);
                var known = seen[job.feed];
                if (known === undefined) {
                    seen[job.feed] = nk;      // first acquaintance: quiet
                } else if (known !== nk) {
                    // Everything ABOVE the remembered key is news. Only the
                    // newest used to count: a show dropping two episodes
                    // between cycles announced one, and the other never got
                    // a word or a byte. The walk stops at ten — a feed that
                    // rewrote every key wholesale (token rotation) is not a
                    // ten-episode news day, so it falls back to the newest.
                    var fresh = [];
                    for (var fi = 0; fi < feed.episodes.length && fi < 10; fi++) {
                        if (seenKeyOf(feed.episodes[fi]) === known) break;
                        fresh.push(feed.episodes[fi]);
                    }
                    if (fresh.length === 0 || fresh.length >= 10) fresh = [newest];
                    seen[job.feed] = nk;
                    _podRefreshNews.push(app._sanitizeDeviceName(job.title || feed.title || ""));
                    for (var ni = 0; ni < fresh.length && ni < 3; ni++) {
                        var ep = fresh[ni];
                        var epKey = PodcastLogic.episodeKey(ep.guid, ep.url);
                        // Either name counts as "already here": episodes fetched
                        // before the tag existed sit under the legacy one.
                        var legacyName = podcastFileNameLegacy(ep.title, ep.url);
                        var already = downloads[podcastFileName(ep.title, ep.url,
                                                                    job.feed, ep.guid)] !== undefined
                                      || (downloads[legacyName] !== undefined
                                          && podcastLegacyIsOurs(legacyName, job.feed,
                                                                 ep.guid, ep.url));
                        if (cfg.podcastAutoDownload === true
                            && !already && !isEpisodePlayed(epKey)) {
                            // Counted only when the queue actually TOOK it — a
                            // full line must not inflate the aggregate's claim.
                            if (_podEnqueueDownload({ "title": ep.title, "url": ep.url,
                                    "guid": ep.guid, "show": job.title || feed.title || "",
                                    "art": job.art || feed.image || "", "feed": job.feed,
                                    "auto": true }))
                                _podRefreshDls++;
                        }
                    }
                }
            }
            _podRefreshNext();
        });
    }

    function _podRefreshFinish() {
        _podRefreshBusy = false;
        // A cycle where NOTHING answered is not a refresh — a laptop that
        // woke before its WiFi used to stamp the clock and skip the real
        // check for twelve hours. No answer, no stamp: the half-hour tick
        // simply tries again.
        if (_podRefreshOkCount === 0 && podcastSubsModel.count > 0) {
            _podRefreshOkCount = 0;
            return;
        }
        _podRefreshOkCount = 0;
        cfg.podcastLastRefresh = String(Date.now());
        // Unsubscribed shows leave the seen map with them.
        var live = {};
        for (var i = 0; i < podcastSubsModel.count; i++)
            live[podcastSubsModel.get(i).feedUrl] = true;
        for (var f in seen)
            if (!live[f]) delete seen[f];
        saveSeen();
        if (_podRefreshNews.length > 0) {
            var names = _podRefreshNews.slice(0, 3).join(", ");
            if (_podRefreshNews.length > 3)
                names += " +" + (_podRefreshNews.length - 3);
            var body = _podRefreshDls > 0
                ? i18n("%1 — the newest episodes are downloading.", names)
                : names;
            app.notify(i18n("New podcast episodes"), body, "application-rss+xml");
        }
        // Storage auto-care, timid by design: played and old goes, past ten
        // per show the oldest PLAYED go, the unplayed are never touched.
        if (cfg.podcastAutoClean === true) {
            var del = PodcastLogic.cleanCandidates(downloads, _podPlayed,
                                                   Date.now(), 10, 3);
            var removed = 0;
            for (var d = 0; d < del.length; d++) {
                if (app._podPlayingUrl !== "" && _podFileOfUrl(app._podPlayingUrl) === del[d])
                    continue;                      // never the one on the air
                deleteDownload(del[d]);
                removed++;
            }
            if (removed > 0)
                console.log("[ARP] podcast auto-clean: removed " + removed + " played file(s)");
        }
    }

    // A feed fetch with NO UI side effects — the refresh cycle's road.
    // Same caps and the same deferred abort the visible loader carries.
    function _podFetchFeedSilent(feedUrl, cb) {
        if (!PodcastLogic.urlAllowed(feedUrl)) { cb(null); return; }
        var xhr = new XMLHttpRequest();
        var guard = null;
        var aborted = false;
        var partial = "";
        var done = false;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (!aborted && (xhr.responseText || "").length > 4 * 1024 * 1024) {
                    aborted = true;
                    partial = xhr.responseText;
                    Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
                }
                return;
            }
            if (xhr.readyState !== XMLHttpRequest.DONE || done) return;
            done = true;
            _clearXhrTimeout(guard); guard = null;
            // Same last-hop gate as the visible loader: a feed that
            // redirected into the LAN answers nothing to the refresh.
            if (!HostGuard.answerFromPublicHost(xhr)) { cb(null); return; }
            cb(PodcastLogic.parseFeed((xhr.responseText || "") || partial, 50));
        };
        xhr.open("GET", feedUrl);
        xhr.setRequestHeader("User-Agent", "OnAir/2026.39");
        guard = _armXhrTimeout(xhr, 15000);
        xhr.send();
    }

    // A file URL the QUrl parser cannot mangle: '#' would become a
    // fragment and '?' a query — "Episode #42.mp3" opened a truncated
    // path on the raw-string road while the FolderListModel road (percent-
    // encoded) worked, which is exactly the kind of split that ships.
    function _podFileUrl(fileName) {
        var pth = app.downloadDirPath + "/Podcasts/" + fileName;
        return "file://" + pth.replace(/%/g, "%25").replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    // Ledger filename of a playing file:// URL ("" when it is not ours).
    function _podFileOfUrl(url) {
        var u = (url || "").toString();
        // file:// only: a REMOTE enclosure whose basename happens to match
        // a ledger row must not inherit that file's silence map, chapters
        // or delete road — the wild is full of "episode.mp3".
        if (u.indexOf("file://") !== 0) return "";
        var base = u.split("/").pop();
        try { base = decodeURIComponent(base); } catch (e) {}
        return downloads[base] !== undefined ? base : "";
    }

    function _podScanStart(fileName) {
        if (_podScanFile !== "") {
            if (_podScanQueue.length < 20) _podScanQueue.push(fileName);
            return;
        }
        _podScanFile = fileName;
        var full = PodcastLogic.shQuote(app.downloadDirPath + "/Podcasts/" + fileName);
        app.exec(": POD_SCAN; command -v ffmpeg >/dev/null 2>&1 && "
            + "timeout 180 ffmpeg -hide_banner -nostats -i " + full
            + " -af silencedetect=noise=-35dB:d=0.9 -f null - 2>&1"
            + " | grep -E 'silence_(start|end)' | head -600;"
            + " echo __CHAPTERS__;"
            + " command -v ffprobe >/dev/null 2>&1 && "
            + "timeout 60 ffprobe -v quiet -print_format json -show_chapters " + full
            + " 2>/dev/null | head -c 400000; true # " + app.nextSeq());
    }

    function _loadPodUpNext() {
        try {
            var a = JSON.parse(cfg.podcastUpNext || "[]");
            _podUpNext = Array.isArray(a)
                ? a.filter(function(e) {
                      return e && typeof e === "object" && typeof e.key === "string"
                             && e.key !== "";
                  }).slice(0, 50)
                : [];
        } catch (e) {
            _podUpNext = [];
        }
        _podUpNextRev++;
    }

    function _savePodUpNext() {
        // Reassign, never just persist: in-place splices are invisible to
        // the chip's length binding, and a "gone" queue kept its button.
        _podUpNext = _podUpNext.slice();
        cfg.podcastUpNext = JSON.stringify(_podUpNext);
        _podUpNextRev++;
    }

    function podcastQueueHas(key) {
        void _podUpNextRev;
        return PodcastLogic.upNextIndex(_podUpNext, key) >= 0;
    }

    // One tap queues, the second unqueues — entries are gated the same as
    // every other feed-fed row before they persist.
    function podcastQueueToggle(entry) {
        if (!entry || !entry.key) return;
        var idx = PodcastLogic.upNextIndex(_podUpNext, entry.key);
        if (idx >= 0) {
            _podUpNext.splice(idx, 1);
        } else {
            if (!PodcastLogic.urlAllowed(entry.url)) return;
            _podUpNext = PodcastLogic.upNextAdd(_podUpNext, {
                "key": String(entry.key),
                "title": app._sanitizeDeviceName(String(entry.title || "")).substring(0, 200),
                "show": app._sanitizeDeviceName(String(entry.show || "")).substring(0, 200),
                "art": PodcastLogic.urlAllowed(entry.art)
                       ? String(entry.art).substring(0, 2048) : "",
                "feed": String(entry.feed || "").substring(0, 2048),
                "url": String(entry.url).substring(0, 2048),
                "fileTitle": String(entry.fileTitle || entry.title || "").substring(0, 200)
            }, 50);
        }
        _savePodUpNext();
    }

    function _loadPodPositions() {
        try {
            var m = JSON.parse(cfg.podcastPositions || "{}");
            _podPositions = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            _podPositions = {};
        }
    }

    function _savePodPositions() {
        _podPositions = PodcastLogic.prunePositions(_podPositions, 200);
        cfg.podcastPositions = JSON.stringify(_podPositions);
    }

    function podcastPositionSec(key) {
        var e = _podPositions[key];
        return (e && e.sec > 0) ? e.sec : 0;
    }

    // ── Playback speed + skip ────────────────────────────────────────────
    function _loadPodSpeeds() {
        try {
            var m = JSON.parse(cfg.podcastSpeeds || "{}");
            _podSpeeds = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            _podSpeeds = {};
        }
    }

    // The rate for a show: its own if set, else the global default ("" key),
    // else 1x. Every stored value re-clamped in case the config was edited.
    function _podSpeedFor(feed) {
        var v = (feed && _podSpeeds[feed] !== undefined) ? _podSpeeds[feed]
              : _podSpeeds[""];
        return PodcastLogic.clampRate(v === undefined ? 1.0 : v);
    }

    // ── Played / unplayed state ──────────────────────────────────────────
    function _loadPodPlayed() {
        try {
            var m = JSON.parse(cfg.podcastPlayed || "{}");
            _podPlayed = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            _podPlayed = {};
        }
    }

    function _savePodPlayed() {
        _podPlayed = EpisodeState.prunePlayed(_podPlayed, 1000);
        cfg.podcastPlayed = JSON.stringify(_podPlayed);
    }

    function isEpisodePlayed(key) {
        return !!(key && _podPlayed[key] !== undefined);
    }

    function episodeState(key) {
        return EpisodeState.stateOf(_podPlayed, _podPositions, key);
    }

    function markEpisodePlayed(key) {
        if (!key || _podPlayed[key] !== undefined) return;
        EpisodeState.markPlayed(_podPlayed, key, Date.now());
        // A played episode's resume bookmark is no longer wanted — it must
        // not offer to resume at the credits.
        if (_podPositions[key] !== undefined) { delete _podPositions[key]; _savePodPositions(); }
        _podPlayedRev++;
        _podPosRev++;
        _savePodPlayed();
    }

    function markEpisodeUnplayed(key) {
        if (!key || _podPlayed[key] === undefined) return;
        EpisodeState.markUnplayed(_podPlayed, key);
        _podPlayedRev++;
        _savePodPlayed();
    }

    function toggleEpisodePlayed(key) {
        if (isEpisodePlayed(key)) markEpisodeUnplayed(key);
        else markEpisodePlayed(key);
    }

    // Mark every episode currently listed in the open feed as played — the
    // "I've caught up" bulk action. keys is an array of episodeKeys.
    function markEpisodesPlayed(keys) {
        var changed = false;
        for (var i = 0; i < keys.length; i++) {
            var k = keys[i];
            if (k && _podPlayed[k] === undefined) {
                EpisodeState.markPlayed(_podPlayed, k, Date.now());
                if (_podPositions[k] !== undefined) delete _podPositions[k];
                changed = true;
            }
        }
        if (changed) {
            _podPlayedRev++;
            _podPosRev++;
            _savePodPositions();
            _savePodPlayed();
        }
    }

}
