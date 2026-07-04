/*
 *  SPDX-FileCopyrightText: 2022-2023 Yuri Saurov <dr@i-glu4it.ru>
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import Qt.labs.platform as Labs
import QtMultimedia
import QtNetwork
import QtQuick
import org.kde.notification
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support 2.0 as P5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    property string title: Plasmoid.title
    property string imageurl: ""
    property string metadata: ""
    property string currentStation: ""
    property string currentStationFavicon: ""
    property string albumArtUrl: ""
    property string trackArtist: ""
    property string trackTitle: ""
    property bool isError: false
    property int lastPlay: 0
    property int view: 0
    property bool isConnected: NetworkInformation.reachability === NetworkInformation.Reachability.Online
    property var _artCache: ({})

    // ── 2026 signatuur-palett: päris must + smaragd (ei sõltu süsteemiteemast,
    //    mis võib aktsendid siniseks värvida) ─────────────────────────────
    readonly property color accent: "#6FCF97"
    readonly property color accentBright: "#3BEE96"
    readonly property color accentTeal: "#2BB3A3"
    readonly property color accentTextOn: "#04140B"

    property string searchFilter: ""
    property bool favoritesOnly: false
    property var favoriteNames: parseFavorites(Plasmoid.configuration.favorites)
    property int sleepRemainingSec: 0
    // Taimeri algväärtus — vajalik une-taimeri edenemise rõnga joonistamiseks
    property int sleepTotalSec: 0

    // MPRIS-failid elavad XDG_RUNTIME_DIR-is (0700, tmpfs) — /tmp asemel
    readonly property string _mprisRunDir: {
        var loc = Labs.StandardPaths.writableLocation(Labs.StandardPaths.RuntimeLocation).toString();
        return loc.indexOf("file://") === 0 && loc.length > 7 ? loc.substring(7) : "/tmp";
    }
    readonly property string _mprisStateFile: _mprisRunDir + "/arp-mpris-state-" + Date.now().toString() + ".json"
    readonly property string _mprisCmdFile: _mprisRunDir + "/arp-mpris-cmd-" + Date.now().toString() + ".txt"
    property int _mprisCmdSeq: 0
    property bool _mprisStarted: false
    // Kas inotifywait on saadaval (0 protsessi-spawni jõudeolekus) või pollime
    property bool _hasInotify: false

    // ── Allalaadimine (yt-dlp) ja kohalik muusikakogu ────────────────────
    property bool downloading: false
    property string _dlPendingRaw: ""
    // Mida parasjagu alla laaditakse — kuvamiseks My Music lehel ja footeris
    property string _dlCurrentQuery: ""
    readonly property string downloadDirPath: {
        var conf = (Plasmoid.configuration.downloadDir || "").trim();
        if (conf !== "") return conf;
        var loc = Labs.StandardPaths.writableLocation(Labs.StandardPaths.MusicLocation).toString();
        var base = loc.indexOf("file://") === 0 && loc.length > 7 ? loc.substring(7) : (_mprisRunDir + "/Music");
        return base + "/OnAir";
    }

    Notification {
        id: dlNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        autoDelete: true
    }

    // Source URL that has confirmed it does NOT expose ICY metadata. While set,
    // we suppress reader.py polling for that source to avoid spawning python
    // every 2 seconds forever. Cleared each time playback begins.
    property string _noIcySource: ""

    // URL, mille jaoks viimane reader.py päring tehti — hilinenud tulemus
    // EI tohi rakenduda teisele (vahepeal vahetatud) jaamale.
    property string _icyQueryUrl: ""

    // Järjestikused tühjad reader.py tulemused — pärast 6 katset lõpetame
    // pollimise (server ei anna kasutatavat tiitlit, nt UA-filter või placeholder).
    property int _icyEmptyCount: 0

    // Qt FFmpeg-backend annab paljudel voogudel ICY-tiitli otse metaData kaudu —
    // kui see töötab, pole reader.py protsesse üldse vaja spawnida.
    property bool _qtMetaWorks: false

    // Consecutive stall retries — drives an exponential backoff so we don't
    // hammer a permanently broken stream every 15 seconds.
    property int _stallAttempts: 0

    // Volume captured at the moment the sleep-fade animation starts, so we can
    // restore exactly what the user had set (not the config default) if they
    // cancel or restart the sleep timer mid-fade. -1 means "no fade in progress".
    property real _volumeBeforeSleepFade: -1

    // Auto-bitrate state. _bitrateCache maps user's configured URL → URL we
    // actually play (may be a higher-bitrate variant from radio-browser.info).
    // _currentOrigUrl / _currentResolvedUrl track the most recent play so the
    // error handler can fall back to the original if the upgrade fails.
    // _resolveCallSeq prevents stale async callbacks from re-triggering an
    // older click if the user has already moved on.
    property var _bitrateCache: ({})
    property string _currentOrigUrl: ""
    property string _currentResolvedUrl: ""
    property int _resolveCallSeq: 0

    function isPlaying() {
        return playMusic.playbackState === MediaPlayer.PlayingState;
    }

    function parseFavorites(s) {
        try {
            const arr = JSON.parse(s || "[]");
            return Array.isArray(arr) ? arr : [];
        } catch (e) {
            return [];
        }
    }

    function isFavorite(name) {
        if (!name) return false;
        return favoriteNames.indexOf(name) !== -1;
    }

    function toggleFavorite(name) {
        if (!name) return;
        const list = favoriteNames.slice();
        const idx = list.indexOf(name);
        if (idx === -1) list.push(name);
        else list.splice(idx, 1);
        favoriteNames = list;
        Plasmoid.configuration.favorites = JSON.stringify(list);
    }

    function reloadStationsModel() {
        playMusic.stop();
        stationsModel.clear();
        try {
            const servers = JSON.parse(Plasmoid.configuration.servers);
            const allNames = [];
            for (const server of servers) {
                allNames.push(server.name || "");
                if (server.active)
                    stationsModel.append(server);
            }
            // Puhasta surnud lemmikud — jaam on loendist päriselt kustutatud
            // (mitteaktiivne jaam jääb lemmikuks alles).
            const pruned = favoriteNames.filter(n => allNames.indexOf(n) !== -1);
            if (pruned.length !== favoriteNames.length) {
                favoriteNames = pruned;
                Plasmoid.configuration.favorites = JSON.stringify(pruned);
            }
        } catch (e) {
            console.log(e);
        }
    }

    function targetVolume() {
        return Math.max(0, Math.min(1, Plasmoid.configuration.defaultVolume / 100));
    }

    function refreshServer(index) {
        if (index < 0 || index >= stationsModel.count) {
            return;
        }
        const station = stationsModel.get(index);
        if (!station || !station.hostname) {
            return;
        }
        // When checking "user clicked the currently-playing tile", compare against
        // BOTH the configured URL and the auto-bitrate resolved URL (which is what
        // playMusic.source actually holds during playback).
        const origHost = (station.hostname || "").toString();
        const resolved = _bitrateCache[origHost] !== undefined ? _bitrateCache[origHost] : origHost;
        const stopping = isPlaying()
                         && (playMusic.source == origHost || playMusic.source == resolved)
                         && lastPlay === index;
        if (stopping) {
            stopWithFade();
        } else {
            root._previewUrl = "";
            root.currentStationFavicon = station.favicon || "";
            _playStation(station);
        }
    }

    // URL, mida mängitakse PROOVINA (internetiotsingu tulemus, mida pole
    // kasutaja nimekirja lisatud). Tühi = tavaline mängimine.
    property string _previewUrl: ""

    // Internetiotsingu tulemuse KUULAMINE (proov) — EI lisa nimekirja.
    // Teine klikk sama tulemuse peal peatab.
    function previewStation(name, url, favicon) {
        if (!url) return;
        if (isPlaying() && root._previewUrl === url) {
            stopWithFade();
            return;
        }
        root._previewUrl = url;
        root.lastPlay = -1;
        root.currentStationFavicon = favicon || "";
        _playStation({ "name": name || url, "hostname": url, "favicon": favicon || "", "active": true });
    }

    // ── YouTube-otsing ja allalaadimine ──────────────────────────────────

    function _currentTrackQuery() {
        var q = ((root.trackArtist ? root.trackArtist + " - " : "") + root.trackTitle).trim();
        if (!q && root.title !== Plasmoid.title) q = root.title;
        return q;
    }

    // Kiire kohalik pealkirja-puhastus (töötab alati, AI-ta)
    function _cleanQueryLocal(s) {
        return (s || "")
            .replace(/\s*\([^)]*\)\s*/g, " ")
            .replace(/\s*\[[^\]]*\]\s*/g, " ")
            .replace(/\b\d{2,3}\s?kbps\b/gi, " ")
            .replace(/\s+/g, " ").trim();
    }

    // Ava lugu YouTube'i otsingus (brauseris)
    function youtubeSearchFor(q) {
        q = _cleanQueryLocal(q);
        if (!q) return;
        var url = "https://www.youtube.com/results?search_query=" + encodeURIComponent(q);
        executable.exec("xdg-open '" + url.replace(/'/g, "'\\''") + "'");
    }

    function youtubeOpenSearch() {
        youtubeSearchFor(_currentTrackQuery());
    }

    // Laadi lugu alla. Kui AI-abiline on sees ja claude CLI olemas,
    // puhastatakse räpane raadiopealkiri enne otsingut (15 s timeout,
    // ebaõnnestumisel kasutatakse kohalikku puhastust — AI pole kunagi
    // kriitilisel teel).
    function downloadTrack(raw) {
        if (downloading) return;
        if (!raw) return;
        downloading = true;
        if (Plasmoid.configuration.aiHelperEnabled) {
            root._dlPendingRaw = raw;
            var safePrompt = ("Puhasta see raadio metaandmete pealkiri muusikaotsinguks. Tagasta AINULT kujul: Artist - Pealkiri (ilma jutumärkide, selgituste ja lisainfota): " + raw).replace(/'/g, "'\\''");
            executable.exec(": AI_CLEAN; command -v claude >/dev/null 2>&1 && timeout 15 claude -p '" + safePrompt + "' 2>/dev/null || true");
        } else {
            _startDownload(_cleanQueryLocal(raw));
        }
    }

    function downloadCurrentTrack() {
        downloadTrack(_currentTrackQuery());
    }

    function _startDownload(query) {
        if (!query) { downloading = false; return; }
        root._dlCurrentQuery = query;
        var fmt = (Plasmoid.configuration.downloadFormat || "best").toLowerCase();
        var fmtArgs;
        if (fmt === "mp3") {
            fmtArgs = "-x --audio-format mp3 --audio-quality 0 --embed-metadata --embed-thumbnail";
        } else if (fmt === "opus") {
            fmtArgs = "-x --audio-format opus --audio-quality 0 --embed-metadata";
        } else if (fmt === "mp4") {
            fmtArgs = "-f 'bv*[height<=1080]+ba/b' --merge-output-format mp4 --embed-metadata";
        } else {
            // "best": originaal-heli ILMA ümberkodeerimata — maksimaalne
            // võimalik kvaliteet (tavaliselt opus ~160k). Transkodeerimine
            // (nt MP3-ks) ainult kaotaks kvaliteeti.
            fmtArgs = "-f bestaudio -x --audio-quality 0 --embed-metadata --embed-thumbnail";
        }
        var safeDir = downloadDirPath.replace(/'/g, "'\\''");
        var safeQuery = query.replace(/'/g, "'\\''");
        executable.exec("mkdir -p '" + safeDir + "' && yt-dlp --no-playlist " + fmtArgs
                        + " -o '" + safeDir + "/%(title)s.%(ext)s' 'ytsearch1:" + safeQuery + "'");
    }

    // ── Lugude ajalugu (Recently played) — püsib configis, max 30 ────────

    function _loadHistory() {
        try {
            const arr = JSON.parse(Plasmoid.configuration.history || "[]");
            historyModel.clear();
            for (var i = 0; i < arr.length && i < 30; i++) {
                historyModel.append({
                    "artist": arr[i].artist || "",
                    "trackName": arr[i].trackName || "",
                    "station": arr[i].station || "",
                    "when": arr[i].when || ""
                });
            }
        } catch (e) {
            console.log("[ARP] loadHistory: " + e);
        }
    }

    function _saveHistory() {
        const arr = [];
        for (var i = 0; i < historyModel.count; i++) {
            const h = historyModel.get(i);
            arr.push({ "artist": h.artist, "trackName": h.trackName, "station": h.station, "when": h.when });
        }
        Plasmoid.configuration.history = JSON.stringify(arr);
    }

    function _pushHistory(artist, trackName, station) {
        if (!trackName) return;
        if (historyModel.count > 0) {
            const last = historyModel.get(0);
            if (last.trackName === trackName && last.artist === (artist || "")) return;
        }
        const d = new Date();
        const when = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
        historyModel.insert(0, { "artist": artist || "", "trackName": trackName, "station": station || "", "when": when });
        while (historyModel.count > 30) historyModel.remove(historyModel.count - 1);
        _saveHistory();
    }

    function clearHistory() {
        historyModel.clear();
        Plasmoid.configuration.history = "[]";
    }

    ListModel { id: historyModel }

    // Mängi allalaaditud faili (Minu muusika leht)
    function playLocalFile(fileUrl, displayName) {
        if (!fileUrl) return;
        var urlStr = fileUrl.toString();
        if (isPlaying() && playMusic.source.toString() === urlStr) {
            stopWithFade();
            return;
        }
        root._previewUrl = "";
        root.lastPlay = -1;
        root.currentStationFavicon = "";
        startWithFade({ "name": displayName || i18n("My Music"), "hostname": urlStr, "favicon": "", "active": true });
    }

    // Eemalda jaam püsivalt nimekirjast (prügikasti-nupp real).
    // Lemmikutest koristab reloadStationsModel'i prune automaatselt.
    // Kui parasjagu mängis TEINE jaam, jätkub see pärast eemaldust.
    function removeStation(hostname) {
        if (!hostname) return;
        try {
            const servers = JSON.parse(Plasmoid.configuration.servers);
            const out = [];
            var removed = false;
            for (var i = 0; i < servers.length; i++) {
                if (!removed && (servers[i].hostname || "") === hostname) {
                    removed = true;
                    continue;
                }
                out.push(servers[i]);
            }
            if (!removed) return;
            const wasPlayingUrl = isPlaying() && root._previewUrl === "" ? root._currentOrigUrl : "";
            Plasmoid.configuration.servers = JSON.stringify(out); // → reload (peatab mängimise)
            Qt.callLater(function() {
                if (wasPlayingUrl !== "" && wasPlayingUrl !== hostname) {
                    for (var k = 0; k < stationsModel.count; k++) {
                        if (stationsModel.get(k).hostname === wasPlayingUrl) {
                            lastPlay = k;
                            refreshServer(k);
                            return;
                        }
                    }
                }
                lastPlay = 0;
            });
        } catch (e) {
            console.log("[ARP] removeStation: " + e);
        }
    }

    // ⭐ internetitulemuse peal: lisa jaam PÜSIVALT nimekirja + lemmikutesse.
    // Mängimist EI alustata; kui sama jaam juba proovina mängib, jätkub see
    // katkematult (nüüd juba "oma" jaamana).
    function addStationToList(name, url, favicon, makeFavorite) {
        if (!url) return;
        const keepPlaying = isPlaying() && root._previewUrl === url;
        try {
            const servers = JSON.parse(Plasmoid.configuration.servers);
            for (var i = 0; i < servers.length; i++) {
                if ((servers[i].hostname || "") === url) {
                    if (makeFavorite && !isFavorite(servers[i].name)) toggleFavorite(servers[i].name);
                    return;
                }
            }
            const stName = (name || url).toString();
            servers.push({ "active": true, "hostname": url, "name": stName, "favicon": favicon || "" });
            // See käivitab onServersChanged → reloadStationsModel (stop + reload),
            // seepärast jätkame alles pärast event-loop'i tsüklit.
            Plasmoid.configuration.servers = JSON.stringify(servers);
            if (makeFavorite) toggleFavorite(stName);
            Qt.callLater(function() {
                for (var k = 0; k < stationsModel.count; k++) {
                    if (stationsModel.get(k).hostname === url) {
                        if (keepPlaying) {
                            root._previewUrl = "";
                            lastPlay = k;
                            refreshServer(k);
                        }
                        return;
                    }
                }
            });
        } catch (e) {
            console.log("[ARP] addStationToList: " + e);
        }
    }

    // --- Auto-bitrate helpers ---------------------------------------------
    // Queries radio-browser.info for higher-quality variants of the same station
    // and plays the best one. Falls back to the user's original URL on error.

    function _hostOf(url) {
        const m = String(url).match(/^https?:\/\/([^\/:]+)/i);
        return m ? m[1].toLowerCase() : "";
    }

    function _baseDomain(domain) {
        if (!domain) return "";
        const parts = domain.split(".");
        if (parts.length <= 2) return domain;
        return parts.slice(-2).join(".");
    }

    function _streamFormat(url) {
        const lower = String(url).toLowerCase();
        const noQuery = lower.split("?")[0];
        if (noQuery.endsWith(".m3u8")) return "hls";
        if (noQuery.endsWith(".m3u")) return "playlist";
        if (noQuery.endsWith(".pls")) return "playlist";
        if (noQuery.endsWith(".aac") || noQuery.endsWith(".aacp")) return "aac";
        if (noQuery.endsWith(".ogg")) return "ogg";
        if (noQuery.endsWith(".opus")) return "opus";
        if (noQuery.endsWith(".flac")) return "flac";
        if (noQuery.endsWith(".mp3")) return "mp3";
        if (noQuery.indexOf("aacp") !== -1 || noQuery.indexOf("aac") !== -1) return "aac";
        if (noQuery.indexOf("mp3") !== -1) return "mp3";
        return "unknown";
    }

    function _autoSelectBitrate(station, onPicked) {
        const origUrl = (station.hostname || "").toString();
        if (!Plasmoid.configuration.autoBitrate || !origUrl) {
            onPicked(origUrl);
            return;
        }
        if (_bitrateCache[origUrl] !== undefined) {
            onPicked(_bitrateCache[origUrl]);
            return;
        }
        const stationName = (station.name || "").replace(/\s+/g, " ").trim();
        const origBase = _baseDomain(_hostOf(origUrl));
        if (!stationName || !origBase) {
            _bitrateCache[origUrl] = origUrl;
            onPicked(origUrl);
            return;
        }
        const servers = ["de1", "de2", "nl1", "at1", "fi1"];
        const srv = servers[Math.floor(Math.random() * servers.length)];
        const xhr = new XMLHttpRequest();
        var guard = null;
        xhr.open("GET", "https://" + srv + ".api.radio-browser.info/json/stations/search?name="
                + encodeURIComponent(stationName)
                + "&hidebroken=true&order=bitrate&reverse=true&limit=30");
        xhr.setRequestHeader("User-Agent", "OnAir/2026.1");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            _clearXhrTimeout(guard);
            let pickedUrl = origUrl;
            if (xhr.status === 200) {
                try {
                    const results = JSON.parse(xhr.responseText) || [];
                    const nameLower = stationName.toLowerCase();
                    const origFmt = _streamFormat(origUrl);
                    const origUrlNoProto = origUrl.replace(/^https?:\/\//i, "").replace(/\/$/, "").toLowerCase();

                    // First pass: find the user's exact URL in the results so we
                    // know its reported bitrate. Without this floor, the first
                    // same-bitrate candidate would be picked as a false "upgrade".
                    let origBr = 0;
                    let foundOrig = false;
                    for (const r of results) {
                        const rn = (r.name || "").replace(/\s+/g, " ").trim().toLowerCase();
                        if (rn !== nameLower) continue;
                        const u = (r.url_resolved || r.url || "").toString();
                        if (!u) continue;
                        const uNoProto = u.replace(/^https?:\/\//i, "").replace(/\/$/, "").toLowerCase();
                        if (uNoProto !== origUrlNoProto) continue;
                        let br = parseInt(r.bitrate) || 0;
                        if (br > 1000) br = Math.round(br / 1000);
                        origBr = br;
                        foundOrig = true;
                        break;
                    }
                    // If we can't find the user's URL in radio-browser we can't
                    // judge "higher bitrate" safely — skip the upgrade entirely.
                    if (!foundOrig) {
                        _bitrateCache[origUrl] = origUrl;
                        onPicked(origUrl);
                        return;
                    }

                    // Second pass: pick the candidate with the highest bitrate
                    // that's STRICTLY greater than what the user already has.
                    let bestBr = origBr;
                    let bestUrl = origUrl;
                    for (const r of results) {
                        const rn = (r.name || "").replace(/\s+/g, " ").trim().toLowerCase();
                        if (rn !== nameLower) continue;
                        const url = (r.url_resolved || r.url || "").toString();
                        if (!url) continue;
                        if (_baseDomain(_hostOf(url)) !== origBase) continue;
                        const urlFmt = _streamFormat(url);
                        // Reject playlist wrappers — Qt may follow them but our
                        // ICY reader cannot, and HLS support differs by backend.
                        if (urlFmt === "playlist" || urlFmt === "hls") continue;
                        // Don't silently switch codecs (mp3→aac etc).
                        if (origFmt !== "unknown" && urlFmt !== "unknown"
                            && origFmt !== urlFmt) continue;
                        let br = parseInt(r.bitrate) || 0;
                        if (br > 1000) br = Math.round(br / 1000);
                        if (br <= 0 || br > 2000) continue;
                        if (br > bestBr) {
                            bestBr = br;
                            bestUrl = url;
                        }
                    }
                    pickedUrl = bestUrl;
                } catch (e) {
                    console.log("[ARP] auto-bitrate parse error: " + e);
                }
            }
            _bitrateCache[origUrl] = pickedUrl;
            if (pickedUrl !== origUrl) {
                console.log("[ARP] auto-bitrate upgrade: " + stationName + " => " + pickedUrl);
            }
            onPicked(pickedUrl);
        };
        // NB: QML XHR-i xhr.timeout on no-op — päris-timeout käib abort-taimeriga,
        // mille abort() viib readyState DONE-i (status 0) → ülalolev fallback-tee.
        guard = _armXhrTimeout(xhr, 4000);
        xhr.send();
    }

    // --- QML XHR-i töötav timeout (xhr.timeout/ontimeout ei tee Qt-s midagi) ---
    function _armXhrTimeout(xhr, ms) {
        var timer = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", root, "xhrTimeoutGuard");
        timer.interval = ms;
        timer.triggered.connect(function() {
            try { xhr.abort(); } catch (e) {}
            try { timer.destroy(); } catch (e) {}
        });
        timer.start();
        return timer;
    }

    function _clearXhrTimeout(timer) {
        if (!timer) return;
        try { timer.stop(); timer.destroy(); } catch (e) {}
    }

    function _playStation(station) {
        bitrateFallbackTimer.stop();
        bitrateFallbackTimer.fallbackUrl = "";
        const mySeq = ++_resolveCallSeq;
        _autoSelectBitrate(station, function(resolvedUrl) {
            // Bail out if the user clicked another station while we were
            // waiting for the radio-browser response.
            if (mySeq !== _resolveCallSeq) return;
            root._currentOrigUrl = (station.hostname || "").toString();
            root._currentResolvedUrl = resolvedUrl;
            const effective = {
                "name": station.name,
                "hostname": resolvedUrl,
                "favicon": station.favicon,
                "active": station.active
            };
            startWithFade(effective);
        });
    }

    function stopWithFade() {
        infoTimer.stop();
        root._previewUrl = "";
        // Invalideeri lennus olevad auto-bitrate resolve'id — muidu "unustatakse"
        // stopp ja hilinenud callback käivitab mängimise uuesti.
        _resolveCallSeq++;
        // Peata vastassuuna-fade ja une-fade, et kaks animatsiooni ei võitleks
        // volume-property pärast.
        fadeInAnimation.stop();
        _abortSleepFade();
        if (Plasmoid.configuration.fadeEnabled) {
            fadeOutAnimation.toValue = 0;
            fadeOutAnimation.target = playMusicOutput;
            fadeOutAnimation.from = playMusicOutput.volume;
            fadeOutAnimation.to = 0;
            fadeOutAnimation.duration = Plasmoid.configuration.fadeDuration;
            fadeOutAnimation.restart();
        } else {
            playMusic.stop();
            playMusic.source = "";
            root.title = Plasmoid.title;
            root.currentStation = "";
            root.currentStationFavicon = "";
            playMusicOutput.volume = targetVolume();
        }
    }

    function startWithFade(station) {
        infoTimer.stop();
        // Fade-out võib olla parasjagu pooleli (kasutaja vahetas jaama fade'i
        // ajal) — peata see, muidu tema onFinished tapab äsja käivitatud jaama.
        fadeOutAnimation.stop();
        _abortSleepFade();
        // Clear NO_ICY guard so a fresh playback attempt retries ICY metadata —
        // user may have picked a new station, or be re-clicking to force retry.
        root._noIcySource = "";
        root._icyEmptyCount = 0;
        root._qtMetaWorks = false;
        root._stallAttempts = 0;
        root.title = Plasmoid.title;
        root.currentStation = station.name || "";
        playMusic.stop();
        playMusic.source = "";
        if (Plasmoid.configuration.fadeEnabled) {
            playMusicOutput.volume = 0;
        } else {
            playMusicOutput.volume = targetVolume();
        }
        playMusic.source = station.hostname;
        playMusic.play();
        if (Plasmoid.configuration.fadeEnabled) {
            fadeInAnimation.from = 0;
            fadeInAnimation.to = targetVolume();
            fadeInAnimation.duration = Plasmoid.configuration.fadeDuration;
            fadeInAnimation.target = playMusicOutput;
            fadeInAnimation.restart();
        }
        infoTimer.restart();
    }

    function getStreamInfo(streamUrl, metadata) {
        if (!streamUrl || streamUrl.toString() === "") {
            return;
        }
        if (root._noIcySource && root._noIcySource === streamUrl.toString()) {
            return;
        }
        // Jäta meelde, millise URL-i jaoks see päring on — hilinenud tulemus
        // ei tohi rakenduda vahepeal vahetatud jaamale.
        root._icyQueryUrl = streamUrl.toString();
        var safeUrl = streamUrl.toString().replace(/'/g, "'\\''");
        var safeMeta = (metadata || "").toString().replace(/'/g, "'\\''");
        var scriptPath = Qt.resolvedUrl("reader.py").toString().substring(7);
        var safeScript = scriptPath.replace(/'/g, "'\\''");
        var cmd = "python3 '" + safeScript + "' '" + safeUrl + "' '" + safeMeta + "'";
        executable.exec(cmd);
    }

    property var _artPending: ({})
    // FIFO järjekord _artCache'i piiramiseks — plasmashell elab nädalaid,
    // piiramata cache oleks aeglane mäluleke.
    property var _artCacheKeys: []

    function _normalizeQuery(s) {
        return (s || "").replace(/\s*\([^)]*\)\s*/g, " ")
                        .replace(/\s*\[[^\]]*\]\s*/g, " ")
                        .replace(/\s+/g, " ").trim();
    }

    function _artFinish(cacheKey, url) {
        console.log("[ARP] artFinish key=" + cacheKey.substring(0, 60) + " url=" + (url || "<empty>"));
        if (_artCache[cacheKey] === undefined) {
            _artCacheKeys.push(cacheKey);
            if (_artCacheKeys.length > 200) {
                delete _artCache[_artCacheKeys.shift()];
            }
        }
        _artCache[cacheKey] = url || "";
        var currentKey = trackArtistTitleKey();
        console.log("[ARP] currentKey=" + currentKey.substring(0, 60));
        if (url && currentKey === cacheKey) {
            albumArtUrl = url;
            console.log("[ARP] albumArtUrl set");
        }
    }

    function trackArtistTitleKey() {
        return _normalizeQuery((root.trackArtist + " " + root.trackTitle).trim() || root.title);
    }

    function _queryItunes(query, cacheKey, onResult) {
        console.log("[ARP] iTunes query: " + query);
        var xhr = new XMLHttpRequest;
        var guard = null;
        xhr.open("GET", "https://itunes.apple.com/search?term=" + encodeURIComponent(query) + "&entity=song&limit=1&media=music");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            _clearXhrTimeout(guard);
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.results && data.results.length > 0) {
                        var artUrl = data.results[0].artworkUrl100 || "";
                        if (artUrl) {
                            onResult(artUrl.replace("100x100bb", "300x300bb"));
                            return;
                        }
                    }
                } catch(e) {}
            }
            onResult("");
        };
        guard = _armXhrTimeout(xhr, 3500);
        xhr.send();
    }

    function _queryDeezer(query, cacheKey, onResult) {
        console.log("[ARP] Deezer query: " + query);
        var xhr = new XMLHttpRequest;
        var guard = null;
        xhr.open("GET", "https://api.deezer.com/search?q=" + encodeURIComponent(query) + "&limit=1");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            _clearXhrTimeout(guard);
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.data && data.data.length > 0) {
                        var album = data.data[0].album || {};
                        var artUrl = album.cover_big || album.cover_medium || data.data[0].artist.picture_medium || "";
                        if (artUrl) {
                            onResult(artUrl);
                            return;
                        }
                    }
                } catch(e) {}
            }
            onResult("");
        };
        guard = _armXhrTimeout(xhr, 3500);
        xhr.send();
    }

    function _queryDeezerArtist(artistName, cacheKey, onResult) {
        console.log("[ARP] DeezerArtist query: " + artistName);
        var xhr = new XMLHttpRequest;
        var guard = null;
        xhr.open("GET", "https://api.deezer.com/search/artist?q=" + encodeURIComponent(artistName) + "&limit=1");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            _clearXhrTimeout(guard);
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.data && data.data.length > 0) {
                        var artist = data.data[0];
                        var artUrl = artist.picture_big || artist.picture_medium || "";
                        if (artUrl) {
                            onResult(artUrl);
                            return;
                        }
                    }
                } catch(e) {}
            }
            onResult("");
        };
        guard = _armXhrTimeout(xhr, 3500);
        xhr.send();
    }

    function _primaryArtist(artist) {
        if (!artist) return "";
        var s = artist;
        var splitters = [" & ", " feat. ", " feat ", " ft. ", " ft ", " with ", " vs. ", " vs ", ", ", " and ", " x ", " X "];
        for (var i = 0; i < splitters.length; i++) {
            var idx = s.toLowerCase().indexOf(splitters[i].toLowerCase());
            if (idx > 0) {
                s = s.substring(0, idx);
                break;
            }
        }
        return s.trim();
    }

    function lookupAlbumArt(trackString) {
        if (!Plasmoid.configuration.albumArtEnabled) {
            albumArtUrl = "";
            return;
        }
        if (!trackString || trackString.length === 0) {
            albumArtUrl = "";
            return;
        }
        var parsed = parseTrackString(trackString);
        var query = _normalizeQuery((parsed.artist + " " + parsed.title).trim() || trackString);
        if (query.length === 0) {
            albumArtUrl = "";
            return;
        }
        if (_artCache[query] !== undefined) {
            albumArtUrl = _artCache[query];
            return;
        }

        var resolved = false;
        var fallbacksStarted = false;
        var pending = 2;

        function startFallbacks() {
            if (fallbacksStarted) return;
            fallbacksStarted = true;
            var primary = _primaryArtist(parsed.artist);
            var attempts = [];
            if (primary && parsed.title) {
                attempts.push({fn: _queryItunes, q: primary + " " + parsed.title});
                attempts.push({fn: _queryDeezer, q: primary + " " + parsed.title});
            }
            if (primary) {
                attempts.push({fn: _queryDeezerArtist, q: primary});
            } else if (parsed.title) {
                attempts.push({fn: _queryItunes, q: parsed.title});
                attempts.push({fn: _queryDeezer, q: parsed.title});
            }

            function runNext() {
                if (resolved) return;
                if (attempts.length === 0) {
                    _artFinish(query, "");
                    return;
                }
                var step = attempts.shift();
                step.fn(step.q, query, function(url) {
                    if (resolved) return;
                    if (url) {
                        resolved = true;
                        _artFinish(query, url);
                    } else {
                        runNext();
                    }
                });
            }
            runNext();
        }

        function tryDone(url) {
            if (resolved) {
                pending -= 1;
                return;
            }
            pending -= 1;
            if (url) {
                resolved = true;
                _artFinish(query, url);
                return;
            }
            if (pending === 0) {
                startFallbacks();
            }
        }

        _queryItunes(query, query, tryDone);
        _queryDeezer(query, query, tryDone);
    }

    function parseTrackString(s) {
        if (!s) return { artist: "", title: "" };
        var parts = s.split(" - ");
        if (parts.length >= 2) {
            return { artist: parts[0].trim(), title: parts.slice(1).join(" - ").trim() };
        }
        return { artist: "", title: s.trim() };
    }

    function _abortSleepFade() {
        if (!sleepFadeAnimation.running) return;
        sleepFadeAnimation.stop();
        // Restore exactly what the user had — not the config default — so
        // cancelling the sleep timer doesn't silently overwrite a manual
        // volume setting they made before the fade kicked in.
        if (root._volumeBeforeSleepFade >= 0) {
            playMusicOutput.volume = root._volumeBeforeSleepFade;
        } else {
            playMusicOutput.volume = targetVolume();
        }
        root._volumeBeforeSleepFade = -1;
    }

    function startSleepTimer(seconds) {
        sleepRemainingSec = Math.max(0, Math.floor(seconds));
        sleepTotalSec = sleepRemainingSec;
        _abortSleepFade();
        if (sleepRemainingSec === 0) {
            sleepTimer.stop();
        } else {
            sleepTimer.restart();
        }
    }

    function cancelSleepTimer() {
        sleepRemainingSec = 0;
        sleepTotalSec = 0;
        sleepTimer.stop();
        _abortSleepFade();
    }

    function _mprisStart() {
        if (_mprisStarted) return;
        if (!Plasmoid.configuration.mprisEnabled) return;
        // Uus daemon alustab seq=1-st ja launcher tühjendab cmd-faili —
        // vana kõrge seq blokeeriks kõik uued käsud (meediaklahvid "surnud").
        _mprisCmdSeq = 0;
        var launcher = Qt.resolvedUrl("start-mpris.sh").toString().substring(7);
        var safeLauncher = launcher.replace(/'/g, "'\\''");
        var safeState = _mprisStateFile.replace(/'/g, "'\\''");
        var safeCmd = _mprisCmdFile.replace(/'/g, "'\\''");
        executable.exec("bash '" + safeLauncher + "' '" + safeState + "' '" + safeCmd + "'");
        _mprisStarted = true;
        // Eelista inotify-põhist ootamist (0 spawni jõudeolekus); probe vastus
        // saabub executable.onExited kaudu ja käivitab õige mehhanismi.
        executable.exec("command -v inotifywait >/dev/null 2>&1 && echo INOTIFY_YES || echo INOTIFY_NO");
        mprisStateDebounce.restart();
    }

    function _mprisStop() {
        if (!_mprisStarted) return;
        mprisCmdPoll.stop();
        mprisStateDebounce.stop();
        var safeState = _mprisStateFile.replace(/'/g, "'\\''");
        var safeCmd = _mprisCmdFile.replace(/'/g, "'\\''");
        executable.exec("pkill -f 'mpris.py " + safeState + "' ; pkill -f 'inotifywait.*" + safeCmd + "' 2>/dev/null ; rm -f '" + safeState + "' '" + safeCmd + "'");
        _mprisStarted = false;
    }

    function _mprisQueueWrite() {
        if (!_mprisStarted) return;
        // Throttle, MITTE debounce: fade-animatsioon muudab volume'i igal
        // kaadril ja restart() lükkaks kirjutamist lõputult edasi.
        if (!mprisStateDebounce.running) mprisStateDebounce.start();
    }

    function _mprisWriteState() {
        if (!_mprisStarted) return;
        var state = {
            status: isPlaying() ? "Playing" : "Stopped",
            station: root.currentStation,
            artist: root.trackArtist,
            title: root.trackTitle,
            art: root.albumArtUrl || root.imageurl || "",
            volume: playMusicOutput.volume,
            canGoNext: stationsModel.count > 1,
            canGoPrevious: stationsModel.count > 1,
            canPlay: stationsModel.count > 0,
            canPause: isPlaying()
        };
        var json = JSON.stringify(state).replace(/'/g, "'\\''");
        var safe = _mprisStateFile.replace(/'/g, "'\\''");
        executable.exec("sh -c 'printf %s \"$1\" > \"$2\"' _ '" + json + "' '" + safe + "'");
    }

    function _handleMprisCommand(cmd) {
        if (!cmd) return;
        if (cmd === "PlayPause" || cmd === "Stop" || cmd === "Pause") {
            if (isPlaying()) {
                stopWithFade();
            } else if (stationsModel.count > 0) {
                // Sama fallback nagu UI play-nupul: kui lastPlay on loendi
                // kahanemise järel piiridest väljas, mängi esimest jaama.
                const idx = lastPlay >= 0 && lastPlay < stationsModel.count ? lastPlay : 0;
                lastPlay = idx;
                refreshServer(idx);
            }
        } else if (cmd === "Play") {
            if (!isPlaying() && stationsModel.count > 0) {
                const idx = lastPlay >= 0 && lastPlay < stationsModel.count ? lastPlay : 0;
                lastPlay = idx;
                refreshServer(idx);
            }
        } else if (cmd === "Next") {
            if (stationsModel.count < 1) return;
            var next = (lastPlay + 1) % stationsModel.count;
            lastPlay = next;
            refreshServer(next);
        } else if (cmd === "Previous") {
            if (stationsModel.count < 1) return;
            var prev = lastPlay - 1;
            if (prev < 0) prev = stationsModel.count - 1;
            lastPlay = prev;
            refreshServer(prev);
        } else if (cmd.indexOf("Volume ") === 0) {
            var v = parseFloat(cmd.substring(7));
            if (!isNaN(v)) {
                playMusicOutput.volume = Math.max(0, Math.min(1, v));
            }
        }
    }

    onMetadataChanged: function() {
        if (metadata.length > 0) {
            // Separaator on TAB (reader.py uus formaat) — '::' esines lugude
            // pealkirjades ja lõhkus splitti. Vana '::' toetus fallback'ina.
            var parts = metadata.indexOf("\t") !== -1 ? metadata.split("\t") : metadata.split("::");
            var raw = parts[0] || "";
            root.title = raw;
            root.imageurl = parts[1] || "";
            var parsed = parseTrackString(raw);
            root.trackArtist = parsed.artist;
            root.trackTitle = parsed.title;
            // Ajalukku ainult raadiolood (mitte kohalikud failid)
            if (playMusic.source.toString().indexOf("file://") !== 0) {
                _pushHistory(parsed.artist, parsed.title, root.currentStation);
            }
            lookupAlbumArt(raw);
        } else {
            root.title = Plasmoid.title;
            root.imageurl = "";
            root.trackArtist = "";
            root.trackTitle = "";
            root.albumArtUrl = "";
        }
        _mprisQueueWrite();
    }

    onCurrentStationChanged: _mprisQueueWrite()
    onAlbumArtUrlChanged: _mprisQueueWrite()

    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground

    Component.onCompleted: {
        reloadStationsModel();
        _loadHistory();
        playMusicOutput.volume = targetVolume();
        _mprisStart();
    }

    Component.onDestruction: {
        _mprisStop();
    }

    StationsModel {
        id: stationsModel
    }

    Connections {
        function onServersChanged() {
            playMusic.stop();
            reloadStationsModel();
        }
        function onPanelChanged() {
            playMusic.stop();
        }
        function onFavoritesChanged() {
            favoriteNames = parseFavorites(Plasmoid.configuration.favorites);
        }
        function onDefaultVolumeChanged() {
            if (!isPlaying()) {
                playMusicOutput.volume = targetVolume();
            }
        }
        function onMprisEnabledChanged() {
            if (Plasmoid.configuration.mprisEnabled) _mprisStart();
            else _mprisStop();
        }
        target: Plasmoid.configuration
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
        onNewData: function(sourceName, data) {
            const exitCode = data["exit code"];
            const exitStatus = data["exit status"];
            const stdout = data["stdout"];
            const stderr = data["stderr"];
            exited(sourceName, exitCode, exitStatus, stdout, stderr);
            disconnectSource(sourceName);
        }
    }

    Connections {
        function onExited(cmd, exitCode, exitStatus, stdout, stderr) {
            // inotifywait-i olemasolu probe (MPRIS-i käsukanali jaoks)
            if (cmd.indexOf("command -v inotifywait") === 0) {
                root._hasInotify = (stdout || "").indexOf("INOTIFY_YES") !== -1;
                if (_mprisStarted) {
                    if (root._hasInotify) mprisCmdReader.watchNow();
                    else mprisCmdPoll.start();
                }
                return;
            }
            // AI-pealkirjapuhastuse vastus → alusta allalaadimist
            if (cmd.indexOf(": AI_CLEAN;") === 0) {
                var cleaned = (stdout || "").split("\n")[0].trim();
                // Usu AI vastust ainult siis, kui see näeb mõistlik välja
                if (cleaned.length < 3 || cleaned.length > 120) {
                    cleaned = _cleanQueryLocal(root._dlPendingRaw);
                }
                root._dlPendingRaw = "";
                _startDownload(cleaned);
                return;
            }
            // yt-dlp lõpetas → teavitus
            if (cmd.indexOf("yt-dlp --no-playlist") >= 0) {
                root.downloading = false;
                root._dlCurrentQuery = "";
                if (exitCode === 0) {
                    dlNotification.title = i18n("Track downloaded ✓");
                    dlNotification.text = i18n("Saved to: ") + root.downloadDirPath;
                    dlNotification.iconName = "download";
                } else {
                    dlNotification.title = i18n("Download failed");
                    dlNotification.text = ((stderr || "").split("\n").filter(function(l){ return l.indexOf("ERROR") >= 0; })[0] || i18n("Unknown error")).substring(0, 120);
                    dlNotification.iconName = "dialog-error";
                }
                dlNotification.sendEvent();
                return;
            }
            if (cmd.indexOf("reader.py") < 0) return;
            // Millise URL-i jaoks see päring oli? Hilinenud tulemus ei tohi
            // rakenduda vahepeal vahetatud jaamale ega pinnida __NO_ICY__
            // valele voole.
            var m = cmd.match(/reader\.py' '([^']*)'/);
            var queryUrl = m ? m[1] : root._icyQueryUrl;
            if (queryUrl !== playMusic.source.toString()) {
                return; // vananenud tulemus — jaam on vahetatud
            }
            var formattedText = (stdout || "").trim();
            if (!isPlaying()) {
                root.metadata = "";
                root.title = Plasmoid.title;
                return;
            }
            if (formattedText === "__NO_ICY__") {
                // Stream does not carry ICY metadata. Pin the source and stop
                // polling — both infoTimer and fastRetryTimer would otherwise
                // respawn reader.py forever (every 2-5 s) producing nothing.
                root._noIcySource = queryUrl;
                infoTimer.stop();
                fastRetryTimer.stop();
                return;
            }
            if (formattedText.length > 0) {
                root._icyEmptyCount = 0;
                root.metadata = formattedText;
            } else if (root.currentStation !== "" && root.trackTitle === "") {
                root._icyEmptyCount += 1;
                if (root._icyEmptyCount >= 6) {
                    // Server ei anna kasutatavat tiitlit (UA-filter, placeholder
                    // vms) — käsitle nagu __NO_ICY__, et mitte pollida igavesti.
                    root._noIcySource = queryUrl;
                    infoTimer.stop();
                    fastRetryTimer.stop();
                } else {
                    fastRetryTimer.restart();
                }
            }
        }
        target: executable
    }

    MediaPlayer {
        id: playMusic

        onErrorOccurred: {
            isError = true;
            errorTimer.start();
            infoTimer.stop();
            _mprisQueueWrite();
            // Auto-bitrate fallback: if the URL we're playing is an auto-upgrade
            // (different from the user's configured URL), the upgrade just failed.
            // Negative-cache it and retry with the original URL.
            if (root._currentOrigUrl !== ""
                && root._currentResolvedUrl !== ""
                && root._currentOrigUrl !== root._currentResolvedUrl
                && playMusic.source.toString() === root._currentResolvedUrl) {
                _bitrateCache[root._currentOrigUrl] = root._currentOrigUrl;
                console.log("[ARP] auto-bitrate fallback: " + root._currentResolvedUrl
                            + " failed, retrying with " + root._currentOrigUrl);
                bitrateFallbackTimer.fallbackUrl = root._currentOrigUrl;
                // Mark as already-downgraded so a second error on the original
                // URL won't re-enter this branch.
                root._currentResolvedUrl = root._currentOrigUrl;
                bitrateFallbackTimer.restart();
            }
        }
        onPlayingChanged: {
            if (!isPlaying()) {
                root.metadata = "";
                infoTimer.stop();
            }
            _mprisQueueWrite();
        }
        onMetaDataChanged: {
            // Qt FFmpeg-backend annab paljudel voogudel ICY StreamTitle'i otse —
            // siis pole reader.py protsesse vaja üldse spawnida.
            if (!isPlaying()) return;
            var t = metaData.value(MediaMetaData.Title);
            if (t === undefined || t === null) return;
            var cleaned = String(t).replace(/\t/g, " ").trim();
            var ph = ["", "-", "--", "unknown", "n/a", "none", "null"];
            if (ph.indexOf(cleaned.toLowerCase()) !== -1) return;
            root._qtMetaWorks = true;
            infoTimer.stop();
            fastRetryTimer.stop();
            var newMeta = cleaned + "\t";
            if (root.metadata !== newMeta) root.metadata = newMeta;
        }
        onMediaStatusChanged: {
            if (playMusic.mediaStatus === MediaPlayer.StalledMedia) {
                stallTimer.restart();
            } else {
                stallTimer.stop();
            }
            if (playMusic.mediaStatus === MediaPlayer.BufferedMedia && isPlaying() && !isError && !root._qtMetaWorks
                && playMusic.source.toString().indexOf("file://") !== 0) {
                root._stallAttempts = 0;
                getStreamInfo(playMusic.source, root.metadata);
                // NB: võrdle URL-i, mitte truthiness'i — bitrate-fallback vahetab
                // source'i ilma startWithFade'ita ja vana pin ei tohi uut voogu
                // igaveseks vaigistada.
                if (!infoTimer.running && root._noIcySource !== playMusic.source.toString()) infoTimer.start();
            }
            if (playMusic.mediaStatus === MediaPlayer.EndOfMedia
                || playMusic.mediaStatus === MediaPlayer.InvalidMedia
                || playMusic.mediaStatus === MediaPlayer.NoMedia) {
                infoTimer.stop();
            }
        }

        audioOutput: AudioOutput {
            id: playMusicOutput

            volume: 0.75

            onVolumeChanged: _mprisQueueWrite()
        }
    }

    NumberAnimation {
        id: fadeInAnimation
        target: playMusicOutput
        property: "volume"
        easing.type: Easing.InOutQuad
    }

    NumberAnimation {
        id: fadeOutAnimation
        target: playMusicOutput
        property: "volume"
        easing.type: Easing.InOutQuad
        property real toValue: 0
        onFinished: {
            playMusic.stop();
            playMusic.source = "";
            root.title = Plasmoid.title;
            root.currentStation = "";
            root.currentStationFavicon = "";
            playMusicOutput.volume = targetVolume();
        }
    }

    Timer {
        id: stallTimer
        running: false
        repeat: false
        // Exponential backoff: 15s, 30s, 60s, 120s, 240s, capped at 5 min.
        // Counter is reset to 0 in onMediaStatusChanged once playback buffers.
        interval: Math.min(300000, 15000 * Math.pow(2, root._stallAttempts))
        onTriggered: {
            if (playMusic.mediaStatus === MediaPlayer.StalledMedia) {
                root._stallAttempts += 1;
                var src = playMusic.source;
                playMusic.stop();
                playMusic.source = src;
                playMusic.play();
            }
        }
    }

    Timer {
        id: errorTimer
        running: false
        repeat: false
        interval: 5000
        onTriggered: {
            isError = false;
        }
    }

    Timer {
        id: bitrateFallbackTimer
        running: false
        repeat: false
        interval: 600
        property string fallbackUrl: ""
        onTriggered: {
            if (!fallbackUrl) return;
            isError = false;
            errorTimer.stop();
            // Uus voog = puhas leht ICY-metainfo jaoks (vana pin käis
            // ebaõnnestunud upgrade-URL-i, mitte originaali kohta).
            root._noIcySource = "";
            root._icyEmptyCount = 0;
            playMusic.stop();
            playMusic.source = "";
            playMusic.source = fallbackUrl;
            playMusic.play();
            fallbackUrl = "";
        }
    }

    Timer {
        id: infoTimer
        interval: 5000
        repeat: true
        triggeredOnStart: false
        onTriggered: {
            if (!isPlaying() || isError) return;
            if (root._qtMetaWorks) {
                // Qt annab tiitli ise — reader.py spawn on liigne.
                infoTimer.stop();
                return;
            }
            if (root._noIcySource && root._noIcySource === playMusic.source.toString()) {
                infoTimer.stop();
                return;
            }
            getStreamInfo(playMusic.source, root.metadata);
        }
    }

    Timer {
        id: fastRetryTimer
        interval: 2000
        repeat: false
        running: false
        onTriggered: {
            if (isPlaying() && !isError) {
                getStreamInfo(playMusic.source, root.metadata);
            }
        }
    }

    Timer {
        id: sleepTimer
        interval: 1000
        repeat: true
        running: false
        onTriggered: {
            if (sleepRemainingSec <= 1) {
                sleepRemainingSec = 0;
                sleepTotalSec = 0;
                sleepTimer.stop();
                if (sleepFadeAnimation.running) sleepFadeAnimation.stop();
                root._volumeBeforeSleepFade = -1;
                if (isPlaying()) stopWithFade();
            } else {
                sleepRemainingSec -= 1;
                // Begin a 30-second linear fade so audio tapers off naturally
                // instead of cutting abruptly when the timer hits zero.
                if (sleepRemainingSec === 30 && isPlaying() && !sleepFadeAnimation.running) {
                    root._volumeBeforeSleepFade = playMusicOutput.volume;
                    sleepFadeAnimation.from = playMusicOutput.volume;
                    sleepFadeAnimation.restart();
                }
            }
        }
    }

    NumberAnimation {
        id: sleepFadeAnimation
        target: playMusicOutput
        property: "volume"
        easing.type: Easing.Linear
        to: 0
        duration: 30 * 1000
    }

    Timer {
        id: mprisStateDebounce
        interval: 300
        repeat: false
        running: false
        onTriggered: _mprisWriteState()
    }

    P5Support.DataSource {
        id: mprisCmdReader
        engine: "executable"
        connectedSources: []
        property string buf: ""

        function readNow() {
            if (!_mprisStarted) return;
            const safe = _mprisCmdFile.replace(/'/g, "'\\''");
            connectSource("cat '" + safe + "' 2>/dev/null || true");
        }

        // inotify-režiim: blokeeriv ootamine faili muutusele — 0 protsessi-spawni
        // jõudeolekus (vana 250 ms 'cat'-poll tegi ~345 000 forki päevas).
        // Timeout 900 s on turvavõrk kaotsi läinud sündmuste vastu.
        function watchNow() {
            if (!_mprisStarted) return;
            const safe = _mprisCmdFile.replace(/'/g, "'\\''");
            connectSource("inotifywait -qq -t 900 -e modify '" + safe + "' 2>/dev/null ; cat '" + safe + "' 2>/dev/null || true");
        }

        onNewData: function(sourceName, data) {
            const stdout = data["stdout"] || "";
            disconnectSource(sourceName);
            const lines = stdout.split("\n");
            for (var i = 0; i < lines.length; i++) {
                const line = lines[i].trim();
                if (!line) continue;
                const tabIdx = line.indexOf("\t");
                if (tabIdx < 0) continue;
                const seq = parseInt(line.substring(0, tabIdx), 10);
                if (isNaN(seq) || seq <= _mprisCmdSeq) continue;
                _mprisCmdSeq = seq;
                const cmd = line.substring(tabIdx + 1);
                _handleMprisCommand(cmd);
            }
            // inotify-ahel: taasalusta ootamist alles pärast töötlust
            if (root._hasInotify && _mprisStarted && sourceName.indexOf("inotifywait") === 0) {
                Qt.callLater(watchNow);
            }
        }
    }

    Timer {
        id: mprisCmdPoll
        // Fallback ainult siis, kui inotifywait puudub — seepärast leebe intervall
        interval: 1500
        repeat: true
        running: false
        onTriggered: mprisCmdReader.readNow()
    }

    compactRepresentation: CompactRepresentation {
    }

    fullRepresentation: FullRepresentation {
        id: dialogItem
        anchors.fill: parent
        focus: true
    }
}
