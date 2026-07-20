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

import "PodcastLogic.js" as PodcastLogic
import "ReorderLogic.js" as ReorderLogic
import "SearchLogic.js" as SearchLogic

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
        // The preview ladder's honest give-up doubles as a probe verdict:
        // the row the listener just heard fail gets its offline tag, so
        // the list learns what the ear already knows.
        function on_FriendlyErrorChanged() {
            if (root._friendlyError !== "" && root._previewUrl !== "") {
                fullRepresentation._probeVerdicts[root._previewUrl] =
                    { "v": 0, "t": Date.now() }
                fullRepresentation._webSetAlive(root._previewUrl, 0)
            }
        }
    }

    readonly property bool _streamActive: root._casting
                                          || (isPlaying()
                                              && (playMusic.mediaStatus === MediaPlayer.BufferedMedia
                                                  || playMusic.mediaStatus === MediaPlayer.BufferingMedia))
    // A local track is playback too, but it is not an "eter": no LIVE pill,
    // no "Connecting…" — it plays from disk or it does not play at all.
    readonly property bool _localPlayback: playMusic.source.toString().indexOf("file://") === 0

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
    // Every directory mirror failed on the last search — a network problem
    // is not "no matching stations", and the empty-state must say which of
    // the two it is telling the user about.
    property bool webSearchFailed: false

    // ── Search 2.0 state ──────────────────────────────────────────────────
    // What the query MEANS: matched against names, genre tags, countries or
    // languages — the directory indexes all four, the field is one.
    property string webSearchMode: "all"
    // votes = the directory's quality signal, clicktrend = what the world
    // plays right now, bitrate = audiophile ordering.
    property string webSearchOrder: "votes"
    // Rows the list will show — "Show more" raises it page by page.
    property int webResultCap: 30
    // Where "Show more" stops for good — a result this deep is noise, and
    // every extra page still knocks on up to thirty stream hosts.
    readonly property int webResultCapMax: 300
    // The last query string sent, offset-free — "Show more" re-issues it.
    property string _webLastQs: ""
    // Rows the last parsed directory page carried, and how many known
    // duplicates paging must ask past: a whole page can be rows the list
    // already shows (the dedup eats it), and offset=count would then
    // fetch that same page forever.
    property int _webLastParsed: 0
    property int _webSkipAhead: 0
    // Recent successful searches, newest first, persisted in the config.
    property var webHistory: []

    // ── Result liveness probes ────────────────────────────────────────────
    // hidebroken=true only filters what the directory's checker KNOWS is
    // broken — and that knowledge can be months stale (Bauer Media Finland
    // moved hosts in January; in July every dead mount still read
    // lastcheckok=1). Each shown row gets one real GET, aborted at the
    // response headers: 2xx marks it alive, 4xx/5xx tags it "not
    // answering" and dims the row. Timeouts and transport errors stay
    // unknown — a slow server is not a dead station.
    property var _probeSpent: ({})
    property int _probeActive: 0
    // Verdicts remembered for the session (15 min a piece) — retyping a
    // query must not re-knock on the same thirty hosts. A CDN throttled
    // exactly that burst during testing: every fresh connection got a
    // non-standard 460, playback included. The cache is why the widget
    // itself can never work a host up to that point.
    property var _probeVerdicts: ({})
    readonly property int _probeVerdictTtlMs: 15 * 60 * 1000
    // URLs with a probe in flight right now. _probeSpent is cleared on every
    // new search, but an in-flight probe from the previous generation has no
    // cached verdict yet — without this, a retype whose rows overlap would
    // open a SECOND GET to a host already being probed (the very per-host
    // double-knock the verdict cache exists to prevent).
    property var _probeInFlight: ({})

    function _probeKick(seq) {
        if (seq !== fullRepresentation._webSearchSeq) return
        var now = Date.now()
        for (var i = 0; i < webResultsModel.count; i++) {
            var row = webResultsModel.get(i)
            if (row.alive !== -1 || fullRepresentation._probeSpent[row.url]) continue
            // Loopback/private hosts never get the knock — the row keeps
            // its "unknown" verdict and stays clickable (a preview is the
            // user's own deliberate act; the background probe is not).
            if (!SearchLogic.isProbeSafeHost(row.url)) {
                fullRepresentation._probeSpent[row.url] = true
                continue
            }
            var hit = fullRepresentation._probeVerdicts[row.url]
            if (hit !== undefined && now - hit.t < fullRepresentation._probeVerdictTtlMs) {
                fullRepresentation._probeSpent[row.url] = true
                if (hit.v !== -1) _webSetAlive(row.url, hit.v)
                continue
            }
            if (fullRepresentation._probeInFlight[row.url]) continue
            if (fullRepresentation._probeActive >= 6) continue
            fullRepresentation._probeSpent[row.url] = true
            fullRepresentation._probeInFlight[row.url] = true
            fullRepresentation._probeActive++
            _probeOne(row.url, seq)
        }
    }

    // Drop expired verdicts so the map cannot grow for the whole session —
    // plasmashell runs for weeks and every probed URL would otherwise stay.
    function _probeVerdictsPrune(now) {
        var v = fullRepresentation._probeVerdicts
        for (var k in v)
            if (now - v[k].t >= fullRepresentation._probeVerdictTtlMs)
                delete v[k]
    }

    function _probeOne(url, seq) {
        var xhr = new XMLHttpRequest()
        var guard = null
        var settled = false
        var done = function(verdict) {
            if (settled) return
            settled = true
            root._clearXhrTimeout(guard)
            fullRepresentation._probeActive = Math.max(0, fullRepresentation._probeActive - 1)
            delete fullRepresentation._probeInFlight[url]
            var now = Date.now()
            _probeVerdictsPrune(now)
            // Unknowns are cached too: a host that just timed out does not
            // deserve a knock from every retyped query either.
            fullRepresentation._probeVerdicts[url] = { "v": verdict, "t": now }
            if (seq === fullRepresentation._webSearchSeq && verdict !== -1)
                _webSetAlive(url, verdict)
            // Kick the CURRENT generation, not this probe's: a freed slot must
            // serve the search now on screen. If the user retyped while these
            // probes were slow, the old seq would fail _probeKick's guard and
            // the new rows would never be probed at all. Verdict application
            // above stays guarded by this probe's own seq.
            Qt.callLater(function() { _probeKick(fullRepresentation._webSearchSeq) })
        }
        xhr.onreadystatechange = function() {
            if (settled) return
            if (xhr.readyState === xhr.HEADERS_RECEIVED) {
                // The verdict is in the status line — but abort() MUST NOT
                // run inside this handler: it re-enters the dying reply and
                // plasmashell segfaults in QIODevice::readAll (three cores
                // measured live, reproduced standalone). One tick later is
                // the same safe side the timeout guard's Timer aborts from,
                // and still cuts the endless stream body off instantly.
                done(SearchLogic.probeVerdict(xhr.status))
                Qt.callLater(function() { try { xhr.abort() } catch (e) {} })
            } else if (xhr.readyState === xhr.DONE) {
                done(SearchLogic.probeVerdict(xhr.status))
            }
        }
        xhr.open("GET", url)
        guard = root._armXhrTimeout(xhr, 6000)
        xhr.send()
    }

    // The verdict lands by URL, not by index — probes race against
    // relevance moves, "Show more" pages and the ⭐ remove.
    function _webSetAlive(url, verdict) {
        for (var i = 0; i < webResultsModel.count; i++)
            if (webResultsModel.get(i).url === url) {
                webResultsModel.setProperty(i, "alive", verdict)
                return
            }
    }

    // Every search road ends here. A directory that answered but left the
    // list empty gets the stem retry: the query inflected ("Elmari" hunting
    // "Elmar") or every hit already sitting in the user's own list — both
    // read as "no results" without one more, shorter question.
    function _webFinish(q, seq, tail, gotAnswer) {
        if (seq !== fullRepresentation._webSearchSeq) return
        if (gotAnswer && webResultsModel.count === 0
            && fullRepresentation.webSearchMode === "all"
            && _countryCodeOf(q) === "") {
            var stems = SearchLogic.stems(q)
            if (stems.length > 0) {
                // The word pass froze the cap at count+1 to retire its own
                // "Show more" — but with ZERO rows found that freeze is 1,
                // and the stem retry about to run would append exactly one
                // row and stop: 'raadio elmari' showed a single result
                // where the directory had thirty. An empty pass has nothing
                // to protect — the stems start with the full page again.
                fullRepresentation.webResultCap = 30
                _webStemChain(q, stems, 0, seq, tail)
                return
            }
        }
        fullRepresentation.webSearchFailed = !gotAnswer
        fullRepresentation.webSearching = false
    }

    function _webStemChain(q, stems, idx, seq, tail) {
        if (seq !== fullRepresentation._webSearchSeq) return
        if (idx >= stems.length) {
            fullRepresentation.webSearchFailed = false
            fullRepresentation.webSearching = false
            return
        }
        // A shaved stem can itself be an exact country key — "Soomet"/"Soomee"
        // stem to "Soome", which means Finland, not a station name. Route it
        // the way the full query would have gone.
        var stem = stems[idx]
        var cc = _countryCodeOf(stem)
        var qs = cc !== "" ? "/json/stations/search?countrycode=" + cc
                           : "/json/stations/search?name=" + encodeURIComponent(stem)
        root._rbFetch(qs + tail, 4000, function(xhr) {
            if (seq !== fullRepresentation._webSearchSeq) return
            _webAppendResults(xhr)
            if (webResultsModel.count > 0) {
                _webRememberQuery(q)
                if (cc === "") _webBoostRelevance(stem)
                // "Show more" must page the query that actually filled the
                // list, not the original name query that returned nothing.
                fullRepresentation._webLastQs = qs + tail
                _probeKick(seq)
                fullRepresentation.webSearchFailed = false
                fullRepresentation.webSearching = false
                return
            }
            _webStemChain(q, stems, idx + 1, seq, tail)
        })
    }

    // Stable two-pass float: exact (fold-blind) name matches keep their
    // vote order among themselves and rise first, then prefix matches —
    // the directory only ranks by fame, and fame buries the exact station
    // the user just typed out in full.
    function _webBoostRelevance(q) {
        var target = 0
        for (var cls = 0; cls <= 1; cls++)
            for (var i = target; i < webResultsModel.count; i++) {
                if (SearchLogic.relevance(webResultsModel.get(i).name, q) !== cls)
                    continue
                if (i > target)
                    webResultsModel.move(i, target, 1)
                target++
            }
    }

    // Canvas gradients want CSS color strings — built from the live accent
    // so the aurora and the vinyl glint follow the follow-system setting
    // instead of the hard-coded default green.
    function cssRgba(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255)
               + "," + Math.round(c.b * 255) + "," + a + ")"
    }
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

    // A prototype-safe country-map lookup: a plain `in` also matched
    // Object.prototype keys, so searching "constructor" went to the
    // country branch with an undefined code.
    function _countryCodeOf(q) {
        var key = q.toLowerCase()
        return Object.prototype.hasOwnProperty.call(_countryMap, key)
               ? _countryMap[key] : ""
    }

    function runWebSearch(q) {
        q = (q || "").trim()
        // A chip click runs the search NOW — a debounce still pending from
        // typing would fire the same query a beat later as a duplicate.
        webSearchDebounce.stop()
        webResultsModel.clear()
        fullRepresentation._probeSpent = ({})
        const seq = ++fullRepresentation._webSearchSeq
        fullRepresentation.webSearchFailed = false
        // Short queries are noise — EXCEPT exact country-map keys ("uk").
        const cc = _countryCodeOf(q)
        if (q.length < 3 && cc === "") {
            fullRepresentation.webSearching = false
            return
        }
        fullRepresentation.webSearching = true
        fullRepresentation.webResultCap = 30
        fullRepresentation._webSkipAhead = 0
        const tail = "&hidebroken=true&order=" + fullRepresentation.webSearchOrder
                     + "&reverse=true&limit=50"
        const mode = fullRepresentation.webSearchMode
        var qs
        if (mode === "genre")
            qs = "/json/stations/search?tag=" + encodeURIComponent(q.toLowerCase())
        else if (mode === "language")
            qs = "/json/stations/search?language=" + encodeURIComponent(q.toLowerCase())
        else if (mode === "country" || cc !== "")
            qs = cc !== "" ? "/json/stations/search?countrycode=" + cc
                           : "/json/stations/search?country=" + encodeURIComponent(q)
        else
            qs = "/json/stations/search?name=" + encodeURIComponent(q)
        fullRepresentation._webLastQs = qs + tail
        // Mirror failover lives in main.qml's _rbFetch — the same chain every
        // other radio-browser call uses.
        root._rbFetch(qs + tail, 4000, function(xhr) {
            if (seq !== fullRepresentation._webSearchSeq) return // stale request
            const gotAnswer = _webAppendResults(xhr)
            if (gotAnswer && webResultsModel.count > 0)
                _webRememberQuery(q)
            if (gotAnswer && mode === "all" && cc === "")
                _webBoostRelevance(q)
            _probeKick(seq)
            // Genre pass: a one-word query is as likely a genre as a name —
            // the search field literally suggests "jazz", yet the query only
            // ever ran against station names. Tag matches fill in after the
            // name matches, deduped, same 30-row cap.
            if (gotAnswer && mode === "all" && cc === ""
                && webResultsModel.count < fullRepresentation.webResultCap
                && /^\S+$/.test(q)) {
                var tagQs = "/json/stations/search?tag="
                            + encodeURIComponent(q.toLowerCase())
                var beforeTag = webResultsModel.count
                root._rbFetch(tagQs + tail, 4000, function(xhr2) {
                    if (seq !== fullRepresentation._webSearchSeq) return
                    _webAppendResults(xhr2)
                    // "jazz" can be a genre with zero NAME matches — a query
                    // that only produced tag hits is still a successful
                    // query, and history exists for successful queries.
                    if (webResultsModel.count > 0)
                        _webRememberQuery(q)
                    // If the tag pass is what filled the list, "Show more"
                    // must page IT, not the name query that ran short.
                    if (webResultsModel.count > beforeTag)
                        fullRepresentation._webLastQs = tagQs + tail
                    _probeKick(seq)
                    _webFinish(q, seq, tail, true)
                })
                return
            }
            // Word pass: the directory only ever matches SUBSTRINGS —
            // "nova radio" never finds "Radio Nova". Ask it for the longest
            // word alone and keep the rows containing every word, any
            // order, fold-blind ("jarvi" finds "Järviradio").
            if (gotAnswer && mode === "all" && cc === ""
                && webResultsModel.count < fullRepresentation.webResultCap
                && SearchLogic.words(q).length >= 2) {
                const ws = SearchLogic.words(q)
                // "Show more" can't re-run a client-side word filter, and the
                // longest-word query alone would page in unrelated stations —
                // so the word pass is a one-shot: freeze the cap at what it
                // found and let the button hide rather than mislead.
                root._rbFetch("/json/stations/search?name="
                              + encodeURIComponent(SearchLogic.longestWord(q)) + tail,
                              4000, function(xhr2) {
                    if (seq !== fullRepresentation._webSearchSeq) return
                    _webAppendResults(xhr2, function(r) {
                        return SearchLogic.matchesAllWords((r.name || "").toString(), ws)
                    })
                    if (webResultsModel.count > 0)
                        _webRememberQuery(q)
                    // count < cap hides "Show more" (visible needs count >=
                    // cap) — this pass has no honest next page to offer.
                    fullRepresentation.webResultCap = webResultsModel.count + 1
                    _probeKick(seq)
                    _webFinish(q, seq, tail, true)
                })
                return
            }
            _webFinish(q, seq, tail, gotAnswer)
        })
    }

    // Trending: what the world tunes into right now — a discovery rail for
    // the empty query, one tap away.
    function runWebTrending() {
        // A debounce still pending from just-cleared search text would fire
        // runWebSearch("") a beat later, bump the seq and wipe these results
        // — the same stop() runWebSearch does for the same reason.
        webSearchDebounce.stop()
        webResultsModel.clear()
        fullRepresentation._probeSpent = ({})
        const seq = ++fullRepresentation._webSearchSeq
        fullRepresentation.webSearchFailed = false
        fullRepresentation.webResultCap = 30
        fullRepresentation._webSkipAhead = 0
        fullRepresentation.webSearching = true
        const qs = "/json/stations/search?hidebroken=true&order=clicktrend&reverse=true&limit=50"
        fullRepresentation._webLastQs = qs
        root._rbFetch(qs, 4000, function(xhr) {
            if (seq !== fullRepresentation._webSearchSeq) return
            fullRepresentation.webSearchFailed = !_webAppendResults(xhr)
            _probeKick(seq)
            fullRepresentation.webSearching = false
        })
    }

    // The next page of whatever is showing — same query, same generation.
    function loadMoreWeb() {
        if (fullRepresentation._webLastQs === "" || fullRepresentation.webSearching) return
        if (fullRepresentation.webResultCap >= fullRepresentation.webResultCapMax) return
        const seq = fullRepresentation._webSearchSeq
        const before = webResultsModel.count
        fullRepresentation.webResultCap += 30
        fullRepresentation.webSearching = true
        root._rbFetch(fullRepresentation._webLastQs + "&offset="
                      + (webResultsModel.count + fullRepresentation._webSkipAhead),
                      4000, function(xhr) {
            if (seq !== fullRepresentation._webSearchSeq) return
            // A failed page must give the cap back — the button's
            // visibility compares count against the cap, and a raised cap
            // with no rows to show made "Show more" vanish for good after
            // one bad mirror moment.
            if (!_webAppendResults(xhr)) {
                fullRepresentation.webResultCap = Math.max(30, fullRepresentation.webResultCap - 30)
            } else if (fullRepresentation._webLastParsed > 0
                       && webResultsModel.count === before) {
                // The server page existed but the dedup ate every row of
                // it — the next request must ask PAST it, and the cap
                // falls back to the count so the button survives to ask.
                // An empty page (_webLastParsed 0) is the honest end of
                // the results and retires the button as before.
                fullRepresentation._webSkipAhead += fullRepresentation._webLastParsed
                fullRepresentation.webResultCap = webResultsModel.count
            }
            _probeKick(seq)
            fullRepresentation.webSearching = false
        })
    }

    function _webRememberQuery(q) {
        if (q.length < 3) return
        var ql = q.toLowerCase()
        var h = fullRepresentation.webHistory.filter(function(e) {
            var el = e.toLowerCase()
            // A stored entry that is a prefix of the new query is the same
            // search half-typed (the debounce saved "eston" on the way to
            // "estonia") — it collapses into the finished one. And typing
            // BACKWARDS must not respawn the fragments.
            return el !== ql && ql.indexOf(el) !== 0 && el.indexOf(ql) !== 0
        })
        h.unshift(q)
        fullRepresentation.webHistory = h.slice(0, 8)
        Plasmoid.configuration.searchHistory = JSON.stringify(fullRepresentation.webHistory)
    }

    function _webForgetQuery(q) {
        fullRepresentation.webHistory = fullRepresentation.webHistory.filter(
            function(e) { return e !== q })
        Plasmoid.configuration.searchHistory = JSON.stringify(fullRepresentation.webHistory)
    }

    function _webClearHistory() {
        fullRepresentation.webHistory = []
        Plasmoid.configuration.searchHistory = "[]"
    }

    // Appends one directory answer to the results model (deduped against the
    // user's list AND rows already shown). Returns true when the answer was
    // usable — null/non-200 means the whole mirror chain failed. keepRow,
    // when given, decides per directory row (the word pass keeps only names
    // containing every query word).
    function _webAppendResults(xhr, keepRow) {
        if (!xhr || xhr.status !== 200) return false
        try {
            const results = JSON.parse(xhr.responseText) || []
            fullRepresentation._webLastParsed = results.length
            // Null-prototype maps: these are keyed by names and urls from
            // the catalogue, and a station called "constructor" would hit
            // Object.prototype on a plain {} (same trap _countryCodeOf dodges).
            const existing = Object.create(null)
            for (var i = 0; i < stationsModel.count; i++)
                existing[stationsModel.get(i).hostname] = true
            const seen = Object.create(null)
            for (var j = 0; j < webResultsModel.count; j++)
                seen[webResultsModel.get(j).url] = true
            for (const r of results) {
                if (webResultsModel.count >= fullRepresentation.webResultCap) break
                if (keepRow && !keepRow(r)) continue
                const u = (r.url_resolved || r.url || "").toString()
                // http(s) only — catalogue data is untrusted and these URLs
                // reach playMusic.source, the config and ffmpeg (same rule
                // as _favUrls in main.qml).
                if (!u || !/^https?:\/\//i.test(u) || existing[u] || seen[u]) continue
                // A station the user already has, saved under its RAW url
                // while the directory now reports a different url_resolved
                // (or vice versa), would slip past the check above and show
                // as a web result that ⭐ then duplicates. Dedup on the raw
                // url too — the shipped MANGORADIO default is exactly this.
                var rawU = (r.url || "").toString()
                if (rawU && (existing[rawU] || seen[rawU])) continue
                seen[u] = true
                if (rawU) seen[rawU] = true
                var br = parseInt(r.bitrate) || 0
                // kbps is the directory's unit; only clearly-bps values are
                // scaled down. The old >1000 cutoff mangled honest high-rate
                // streams (1411 kbps lossless became "1 kb/s").
                if (br >= 8000) br = Math.round(br / 1000)
                // The favicon lands in an Image.source — same http(s) gate
                // the stream url gets, or a file:///data: favicon from the
                // catalogue would probe local files behind the row.
                var fav = (r.favicon || "").toString()
                webResultsModel.append({
                    "name": (r.name || "").replace(/\s+/g, " ").trim() || u,
                    "url": u,
                    "rawUrl": (/^https?:\/\//i.test(rawU) && rawU !== u) ? rawU : "",
                    "favicon": /^https?:\/\//i.test(fav) ? fav : "",
                    "country": r.country || "",
                    "bitrate": br,
                    "codec": (r.codec || "").toUpperCase(),
                    "rbUuid": r.stationuuid || "",
                    "alive": -1
                })
            }
            return true
        } catch (e) {
            console.log("[ARP] webSearch parse: " + e)
            return false
        }
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
            readonly property color tint: root.accent
            onTintChanged: requestPaint()
            width: Kirigami.Units.gridUnit * 16
            height: width
            x: -width * 0.3
            y: -height * 0.25
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var g = ctx.createRadialGradient(width / 2, height / 2, 0, width / 2, height / 2, width / 2)
                g.addColorStop(0, fullRepresentation.cssRgba(tint, 0.30))
                g.addColorStop(0.55, fullRepresentation.cssRgba(tint, 0.10))
                g.addColorStop(1, fullRepresentation.cssRgba(tint, 0))
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
            readonly property color tint: root.accentTeal
            onTintChanged: requestPaint()
            width: Kirigami.Units.gridUnit * 13
            height: width
            x: fullRepresentation.width - width * 0.4
            y: fullRepresentation.height - height * 0.35
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var g = ctx.createRadialGradient(width / 2, height / 2, 0, width / 2, height / 2, width / 2)
                g.addColorStop(0, fullRepresentation.cssRgba(tint, 0.26))
                g.addColorStop(0.55, fullRepresentation.cssRgba(tint, 0.09))
                g.addColorStop(1, fullRepresentation.cssRgba(tint, 0))
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
        // With the blur setting off the texture is pure waste — don't
        // even fetch it. (Not gated on the view: page swipes must fade
        // the ready image, not reload it.)
        source: Plasmoid.configuration.blurBackdrop ? fullRepresentation._bestArtUrl : ""
        fillMode: Image.PreserveAspectCrop
        // The source can be a catalog-controlled station favicon, and the
        // catalog is publicly writable — a pixel-flood image (30000×30000)
        // would otherwise decode full-res into plasmashell and exhaust
        // memory. It only feeds a blurred backdrop; 512² is plenty.
        sourceSize.width: 512
        sourceSize.height: 512
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

            // ── Search 2.0 rail ──────────────────────────────────────────
            // While typing: what the query MEANS (name/genre/country/language)
            // and how to rank it. While idle: the recent searches and a
            // trending shortcut — discovery one tap away.
            Flow {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: root.searchFilter !== ""
                         || fullRepresentation.webHistory.length > 0

                Repeater {
                    model: root.searchFilter !== "" ? [
                        { "key": "all",      "label": i18n("All") },
                        { "key": "genre",    "label": i18n("Genre") },
                        { "key": "country",  "label": i18n("Country") },
                        { "key": "language", "label": i18n("Language") }
                    ] : []
                    delegate: PlasmaComponents3.ToolButton {
                        required property var modelData
                        text: modelData.label
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        checkable: true
                        checked: fullRepresentation.webSearchMode === modelData.key
                        onClicked: {
                            fullRepresentation.webSearchMode = modelData.key
                            runWebSearch(root.searchFilter)
                        }
                    }
                }
                Repeater {
                    model: root.searchFilter !== "" ? [
                        { "key": "votes",      "label": i18n("Top voted"),  "icon": "starred-symbolic" },
                        { "key": "clicktrend", "label": i18n("Trending"),   "icon": "office-chart-line" },
                        { "key": "bitrate",    "label": i18n("Bitrate"),    "icon": "audio-volume-high" }
                    ] : []
                    delegate: PlasmaComponents3.ToolButton {
                        required property var modelData
                        text: modelData.label
                        icon.name: modelData.icon
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        checkable: true
                        checked: fullRepresentation.webSearchOrder === modelData.key
                        onClicked: {
                            fullRepresentation.webSearchOrder = modelData.key
                            runWebSearch(root.searchFilter)
                        }
                    }
                }
                PlasmaComponents3.ToolButton {
                    visible: root.searchFilter === ""
                    text: i18n("Trending now")
                    icon.name: "office-chart-line"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    onClicked: runWebTrending()
                }
                Repeater {
                    model: root.searchFilter === "" ? fullRepresentation.webHistory : []
                    delegate: PlasmaComponents3.ToolButton {
                        id: historyChip
                        required property string modelData
                        text: modelData
                        icon.name: "view-history"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        onClicked: filterField.text = modelData

                        PlasmaComponents3.ToolTip {
                            text: i18n("Search again — right-click removes this entry")
                        }
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onTapped: fullRepresentation._webForgetQuery(historyChip.modelData)
                        }
                    }
                }
                PlasmaComponents3.ToolButton {
                    visible: root.searchFilter === "" && fullRepresentation.webHistory.length > 0
                    icon.name: "edit-clear-history"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    onClicked: fullRepresentation._webClearHistory()

                    PlasmaComponents3.ToolTip { text: i18n("Clear search history") }
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
                    // A live drag is in progress (a row handle owns the
                    // pointer and moves the row through the model as it
                    // travels) — the keyboard reorder stands aside for it.
                    property bool dragActive: false

                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    model: filteredStationsModel
                    // Not gated on connectivity: a click while offline just
                    // runs the normal error path, and the red "Check internet
                    // connection…" status line is the hint — a greyed-out list
                    // on a possibly-stale Disconnected report only looks broken.
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
                        // hover arrows, reachable without a mouse). UI
                        // first, like the arrows: the view moves, the
                        // engine persists, a refused persist walks back.
                        if (event.modifiers & Qt.ControlModifier
                            && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)
                            && currentIndex >= 0 && currentItem
                            && root.searchFilter === "" && !dragActive) {
                            const delta = event.key === Qt.Key_Up ? -1 : 1
                            const next = currentIndex + delta
                            if (next >= 0 && next < count) {
                                const it = filteredStationsModel.get(currentIndex)
                                const nm = it.name, hn = it.hostname
                                const ti = currentItem.targetIndex
                                const cur = currentIndex
                                filteredStationsModel.move(cur, next, 1)
                                const ok = root.favoritesOnly
                                           ? root.moveFavorite(nm, delta)
                                           : root.moveStation(ti, nm, hn, delta)
                                if (ok)
                                    currentIndex = next
                                else
                                    filteredStationsModel.move(next, cur, 1)
                            }
                            event.accepted = true
                        }
                    }

                    // 2026: rows entering in a cascade. Filter rebuilds
                    // replace the whole model on every keystroke — replaying
                    // the stagger there turns typing into a light show.
                    populate: Transition {
                        id: popTrans
                        enabled: root.searchFilter === ""
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
                        enabled: root.searchFilter === ""
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
                                      : i18n("%1 (%2)", i18n("From the web"), webResultsModel.count)
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
                                // A cast preview leaves the local player idle
                                // — the row must still show its stop state.
                                readonly property bool isPreviewing: root._previewUrl === model.url && (isPlaying() || root._casting)
                                width: parent.width
                                height: Kirigami.Units.gridUnit * 3

                                // Keyboard + screen-reader access — the row is otherwise
                                // reachable only with a pointer (TapHandler).
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: webItem.isPreviewing
                                                 ? i18n("Stop preview: %1", model.name)
                                                 : i18n("Preview: %1", model.name)
                                Accessible.onPressAction: root.previewStation(webItem.model.name, webItem.model.url, webItem.model.favicon, webItem.model.rbUuid, webItem.model.rawUrl)
                                Keys.onPressed: (event) => {
                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                        root.previewStation(webItem.model.name, webItem.model.url, webItem.model.favicon, webItem.model.rbUuid, webItem.model.rawUrl)
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
                                        // A probed-dead row steps back visually but
                                        // stays clickable — the preview ladder's name
                                        // rescue can still find the living twin.
                                        opacity: webItem.model.alive === 0 ? 0.45 : 1.0

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
                                                // Decode at display size — catalogue favicons are
                                                // untrusted (same pixel-flood cap as the backdrop).
                                                sourceSize.width: 128
                                                sourceSize.height: 128
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
                                                    if (webItem.model.alive === 0) bits.push(i18n("not answering"))
                                                    if (webItem.model.country) bits.push(webItem.model.country)
                                                    if (webItem.model.bitrate > 0) bits.push(i18n("%1 kb/s", webItem.model.bitrate))
                                                    if (webItem.model.codec) bits.push(webItem.model.codec)
                                                    return bits.join(" · ")
                                                }
                                                textFormat: Text.PlainText
                                                visible: text !== ""
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                                color: webItem.model.alive === 0
                                                       ? Kirigami.Theme.negativeTextColor
                                                       : Kirigami.Theme.textColor
                                                opacity: webItem.model.alive === 0 ? 0.9 : 0.55
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
                                    onTapped: root.previewStation(webItem.model.name, webItem.model.url, webItem.model.favicon, webItem.model.rbUuid, webItem.model.rawUrl)
                                }

                                PlasmaCore.ToolTipArea {
                                    anchors.fill: parent
                                    mainText: webItem.isPreviewing
                                              ? i18n("Click = stop preview")
                                              : i18n("Click = preview · ⭐ = add to my stations")
                                }
                            }
                        }

                        PlasmaComponents3.ToolButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: webResultsModel.count >= fullRepresentation.webResultCap
                                     && fullRepresentation.webResultCap < fullRepresentation.webResultCapMax
                                     && !fullRepresentation.webSearching
                            text: i18n("Show more results")
                            icon.name: "arrow-down"
                            onClicked: loadMoreWeb()
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
                            source: root.favoritesOnly
                                    ? "favorite"
                                    : (fullRepresentation.webSearchFailed ? "network-disconnect" : "search")
                            width: Kirigami.Units.iconSizes.huge
                            height: width
                            opacity: 0.4
                        }
                        PlasmaComponents3.Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            horizontalAlignment: Text.AlignHCenter
                            text: root.favoritesOnly
                                  ? i18n("No favorite stations yet")
                                  : (fullRepresentation.webSearchFailed
                                     ? i18n("The station directory is not reachable")
                                     : (root.searchFilter !== "" ? i18n("No matching stations") : i18n("No stations")))
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
                                  : (fullRepresentation.webSearchFailed
                                     ? i18n("Check the connection and type to search again")
                                     : (root.searchFilter !== "" ? i18n("Try a different search term") : ""))
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

                // Top breather — a fillHeight twin sits below the controls, so
                // the whole page stays vertically centred at any popup size.
                Item { Layout.fillHeight: true; Layout.fillWidth: true }

                Item {
                    id: artContainer
                    Layout.alignment: Qt.AlignHCenter
                    // The cover is sized from what's LEFT after the controls
                    // below take their real height — so the transport and
                    // action rows always fit, at any popup size, and the art
                    // fills the rest (square, capped by width and a ceiling).
                    // implicitHeight, not height, keeps this free of a layout
                    // feedback loop.
                    readonly property real _reservedBelow:
                        (pillsRow.visible ? pillsRow.implicitHeight : 0)
                        + labelsCol.implicitHeight
                        + transportRow.implicitHeight
                        + (seekRow.visible ? seekRow.implicitHeight : 0)
                        + actionsRow.implicitHeight
                        // row spacings, per-row top margins and both breathers
                        + Kirigami.Units.gridUnit * 2.5
                    readonly property real _side: Math.max(
                        Kirigami.Units.gridUnit * 7,
                        Math.min(fullRepresentation.width - Kirigami.Units.largeSpacing * 4,
                                 Kirigami.Units.gridUnit * 18,
                                 nowPlayingFlick.height - _reservedBelow))
                    Layout.preferredWidth: _side
                    Layout.preferredHeight: _side

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
                            // Catalog-controlled favicon can be a pixel-flood
                            // image — cap the decode. The cover art panel is
                            // never larger than a few hundred px.
                            sourceSize.width: 600
                            sourceSize.height: 600
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
                                    // A corrupt CACHED favicon: mark it in the
                                    // central map too, so _bestArtUrl gets one
                                    // more try at the REMOTE favicon instead of
                                    // dead-ending on the same broken file. The
                                    // identity check matters: albumArtUrl can be
                                    // a file:// sidecar cover — a stale one
                                    // failing here must not get the STATION's
                                    // healthy cache file deleted in its name.
                                    if (source.toString().indexOf("file://") === 0
                                        && source.toString() === root.faviconSrc(root.currentStationFavicon))
                                        root.faviconCacheBroken(root.currentStationFavicon)
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
                                readonly property color tintA: root.accent
                                readonly property color tintB: root.accentTeal
                                onTintAChanged: requestPaint()
                                onTintBChanged: requestPaint()
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
                                    g.addColorStop(0, fullRepresentation.cssRgba(tintA, 0.14))
                                    g.addColorStop(0.5, fullRepresentation.cssRgba(tintA, 0))
                                    g.addColorStop(1, fullRepresentation.cssRgba(tintB, 0.10))
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
                                    id: vinylCenterLogo
                                    anchors.fill: parent
                                    // Decode at display size: a station's full-res logo
                                    // otherwise keeps a full-size texture alive here.
                                    sourceSize.width: 256
                                    sourceSize.height: 256
                                    // Disk-cached copy when available. Self-heal goes
                                    // through the central _favBroken map (faviconSrc
                                    // then serves the remote), so the binding stays
                                    // declarative and station changes keep working.
                                    source: root.faviconSrc(root.currentStationFavicon)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    smooth: true
                                    visible: status === Image.Ready
                                    onStatusChanged: {
                                        if (status === Image.Error && root.currentStationFavicon
                                            && source.toString().indexOf("file://") === 0) {
                                            root.faviconCacheBroken(root.currentStationFavicon)
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

                                // Record-label monogram: a station with no
                                // obtainable logo still gets a face in the most
                                // looked-at spot. The vinyl center is always
                                // dark (#1f1f1f), so the ink uses the dark-side
                                // pair regardless of the desktop theme.
                                PlasmaComponents3.Label {
                                    anchors.centerIn: parent
                                    readonly property string mono: root.monogramText(root.currentStation)
                                    text: mono
                                    visible: mono !== "" && vinylCenterLogo.status !== Image.Ready
                                    color: Qt.hsla(root.monogramHue(root.currentStation) / 360,
                                                   0.55, 0.82, 1)
                                    font.weight: Font.DemiBold
                                    font.letterSpacing: 1
                                    font.pixelSize: parent.width * (mono.length > 1 ? 0.30 : 0.38)
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
                    id: pillsRow
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    visible: fullRepresentation._streamActive
                             && (!fullRepresentation._localPlayback
                                 || fullRepresentation._nowBitrate > 0)

                    Rectangle {
                        visible: !fullRepresentation._localPlayback
                        implicitHeight: liveRow.implicitHeight + Kirigami.Units.smallSpacing
                        implicitWidth: liveRow.implicitWidth + Kirigami.Units.largeSpacing
                        radius: height / 2
                        // Theme red, not a fixed dark-theme red: on a light
                        // popup (a station with no cover, so no dark backdrop)
                        // the old #e0463c pill left #ff8a80 text at ~1.9:1
                        // contrast — unreadable. negativeTextColor stays red
                        // and legible in both schemes.
                        color: Qt.alpha(Kirigami.Theme.negativeTextColor, 0.16)
                        border.width: 1
                        border.color: Qt.alpha(Kirigami.Theme.negativeTextColor, 0.4)

                        RowLayout {
                            id: liveRow
                            anchors.centerIn: parent
                            spacing: Kirigami.Units.smallSpacing / 1.5

                            Rectangle {
                                id: liveDot
                                width: 7
                                height: 7
                                radius: 3.5
                                color: Kirigami.Theme.negativeTextColor
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
                                color: Kirigami.Theme.negativeTextColor
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
                            text: i18n("%1 kb/s", fullRepresentation._nowBitrate)
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            color: root.accentBright
                        }
                    }
                }

                ColumnLayout {
                    id: labelsCol
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
                    id: transportRow
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

                // Seek row — local playback only (podcast episodes, My Music
                // tracks). A radio stream has no position to hold; the LIVE
                // pill already owns that story.
                RowLayout {
                    id: seekRow
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.largeSpacing * 2
                    Layout.rightMargin: Kirigami.Units.largeSpacing * 2
                    visible: fullRepresentation._localPlayback && playMusic.duration > 0
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        text: PodcastLogic.fmtTime(playMusic.position / 1000)
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        opacity: 0.75
                    }
                    QQC2.Slider {
                        id: seekSlider
                        Layout.fillWidth: true
                        from: 0
                        to: Math.max(1, playMusic.duration)
                        stepSize: 5000
                        Accessible.name: i18n("Seek")
                        // While the hand is on the slider, the hand leads;
                        // the player follows only on release. Keyboard steps
                        // arrive as onMoved without a press and apply at once.
                        Binding on value {
                            when: !seekSlider.pressed
                            value: playMusic.position
                        }
                        onPressedChanged: if (!pressed) playMusic.position = value
                        onMoved: if (!pressed) playMusic.position = value
                    }
                    PlasmaComponents3.Label {
                        text: PodcastLogic.fmtTime(playMusic.duration / 1000)
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        opacity: 0.75
                    }
                }

                RowLayout {
                    id: actionsRow
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
                                // The uuid rides along: a station saved
                                // without its directory identity can only
                                // ever be healed by name-guessing. And the
                                // LIVE address is what gets saved — after a
                                // rescue rung the row's own url is the dead
                                // one, and starring it used to persist a
                                // corpse that errored seconds after a
                                // perfectly good listen.
                                root.addStationToList(root.currentStation,
                                                      root._currentUnwrappedUrl !== ""
                                                      ? root._currentUnwrappedUrl : root._previewUrl,
                                                      root.currentStationFavicon, true,
                                                      root._previewUuid)
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
                        // Not checkable: one-shot action button (same rule as
                        // download); checked only drives the "voted" visual.
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

                // Bottom breather — twin of the top one, so the content stays
                // centred and any leftover height splits evenly above/below.
                Item { Layout.fillHeight: true; Layout.fillWidth: true }
            }
        }

        // ── PAGE 3: My Music — downloaded tracks for offline use ────────
        ColumnLayout {
            id: libraryPage
            // History header shows either the play history or the liked songs
            property bool showLiked: false
            spacing: 0

            // The Recently-played / Liked list shares the page with the
            // downloaded-files list below it, split by a drag divider. Its
            // height is user-set (0 = auto, the first few rows), clamped so
            // the files section below always keeps room. Remembered per config.
            readonly property real _histRowH: Kirigami.Units.gridUnit * 2.3
            readonly property int _histCount: showLiked ? likedModel.count : historyModel.count
            property real _userHistH: 0
            Component.onCompleted: _userHistH = Plasmoid.configuration.historyPanelHeight
            readonly property real _histMaxH: Math.max(_histRowH,
                libraryPage.height - Kirigami.Units.gridUnit * 11)
            readonly property real _histH: _histCount === 0 ? 0
                : Math.min(_histMaxH, _userHistH > 0
                    ? Math.max(_histRowH, _userHistH)
                    : Math.min(_histCount, 4) * _histRowH)

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
                        text: i18n("Downloading: %1", root._dlCurrentQuery || "…")
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
                    text: i18n("%1 (%2)",
                               libraryPage.showLiked ? i18n("Liked songs") : i18n("Recently played"),
                               libraryPage.showLiked ? likedModel.count : historyModel.count)
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
                Layout.preferredHeight: libraryPage._histH
                visible: libraryPage._histCount > 0
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
                                    // Newer history entries carry a ms-epoch "ts"; a bare
                                    // "14:05" on yesterday's play reads as today's. Fixed
                                    // English months, like the UI's fixed day names. Old
                                    // entries (and liked rows) have no ts and keep the
                                    // plain time.
                                    text: {
                                        var ts = histItem.model.ts
                                        if (ts) {
                                            var d = new Date(ts)
                                            var now = new Date()
                                            if (d.getFullYear() !== now.getFullYear()
                                                || d.getMonth() !== now.getMonth()
                                                || d.getDate() !== now.getDate()) {
                                                var mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                                           "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                                                return mon[d.getMonth()] + " " + d.getDate()
                                                       + " " + histItem.model.when
                                            }
                                        }
                                        return histItem.model.when
                                    }
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

            // Drag divider: pull DOWN to see more recently-played rows, UP to
            // give the downloaded files more room. Double-click resets to the
            // default few rows. Only present when there is history to size.
            // The cursor is tracked in SCREEN space (the grip moves as the
            // list grows under it, so a local coordinate would feed back and
            // the size would jump).
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit
                visible: libraryPage._histCount > 0
                Rectangle {
                    anchors.centerIn: parent
                    width: Kirigami.Units.gridUnit * 2.5
                    height: 4
                    radius: 2
                    color: Qt.alpha(Kirigami.Theme.textColor,
                        histGrip.pressed || histGrip.containsMouse ? 0.5 : 0.22)
                }
                MouseArea {
                    id: histGrip
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.SizeVerCursor
                    // The page lives inside a SwipeView — without this it
                    // grabbed the vertical drag partway and the divider
                    // "stuck". preventStealing keeps the gesture here.
                    preventStealing: true
                    property real _startY: 0
                    property real _startH: 0
                    onPressed: (m) => {
                        _startY = mapToGlobal(m.x, m.y).y
                        _startH = libraryPage._histH
                    }
                    onPositionChanged: (m) => {
                        if (!pressed) return
                        var dy = mapToGlobal(m.x, m.y).y - _startY   // down = positive
                        libraryPage._userHistH = Math.max(libraryPage._histRowH,
                            Math.min(libraryPage._histMaxH, _startH + dy))
                    }
                    onReleased: Plasmoid.configuration.historyPanelHeight = Math.round(libraryPage._userHistH)
                    onDoubleClicked: {
                        libraryPage._userHistH = 0
                        Plasmoid.configuration.historyPanelHeight = 0
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
                    text: i18n("%1 (%2)", i18n("My Music"), musicFolder.count)
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
                                            // The track's sidecar cover art goes with it:
                                            // yt-dlp leaves Title.webp/.jpg beside Title.opus
                                            // when embedding was unavailable, and deleting
                                            // only the audio strands covers in the library
                                            // forever.
                                            var safePath = fileItem.filePath.replace(/'/g, "'\\''")
                                            var stem = safePath.replace(/\.[^.\/]+$/, "")
                                            var slash = stem.lastIndexOf("/")
                                            var coverStem = stem.substring(0, slash) + "/.covers" + stem.substring(slash)
                                            executable.exec("rm -f '" + safePath + "'; "
                                                + "for e in jpg jpeg png webp; do rm -f '" + stem + "'.\"$e\" '" + coverStem + "'.\"$e\"; done")
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


        // ── PAGE 4: Podcasts — search, subscribe, download, resume ──────
        // Download-first: an episode is a file in Music/OnAir/Podcasts and
        // plays through the local road (seek, resume, no live-stream
        // machinery). The show search is the keyless iTunes directory; the
        // feed itself is fetched and parsed by the gated PodcastLogic.
        ColumnLayout {
            id: podcastPage
            spacing: 0

            readonly property bool showingEpisodes: root.podcastEpisodesFor !== ""
            readonly property bool searching: podSearchField.text.trim() !== ""

            // The downloaded-episodes ledger. Gated on the same latch as
            // My Music: a FolderListModel pointed at a missing folder
            // silently lists $HOME (issue #3's lesson).
            FolderListModel {
                id: podcastFolder
                readonly property var podFilters: ["*.mp3", "*.m4a", "*.aac", "*.ogg",
                                                   "*.opus", "*.oga", "*.flac", "*.wav"]
                nameFilters: ["#pending#"]
                showDirs: false

                function pointAtPodcasts() {
                    nameFilters = podFilters;
                    folder = "file://" + root.downloadDirPath + "/Podcasts";
                }

                Component.onCompleted: if (root._musicDirEnsured) pointAtPodcasts()
            }
            Connections {
                target: root
                function onMusicDirReady() { podcastFolder.pointAtPodcasts() }
            }

            // The exact filename an episode would carry, matched against
            // the folder — this is how a row knows it is downloaded. The
            // count reference makes every binding re-check when a download
            // lands or a file is deleted.
            function localEpisodeUrl(title, url) {
                var want = root.podcastFileName(title !== "" ? title : i18n("Episode"), url)
                for (var i = 0; i < podcastFolder.count; i++)
                    if (podcastFolder.get(i, "fileName") === want)
                        return podcastFolder.get(i, "fileUrl").toString()
                return ""
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                CircleButton {
                    visible: podcastPage.showingEpisodes
                    implicitWidth: Kirigami.Units.gridUnit * 2.4
                    implicitHeight: implicitWidth
                    iconName: "go-previous"
                    iconScale: 0.55
                    tooltipText: i18n("Back to shows")
                    onClicked: {
                        root.podcastEpisodesFor = ""
                        root.podcastFeedError = ""
                    }
                }
                Kirigami.SearchField {
                    id: podSearchField
                    visible: !podcastPage.showingEpisodes
                    Layout.fillWidth: true
                    autoAccept: true
                    placeholderText: i18n("Search podcasts… (e.g. history, technology)")
                    onTextChanged: podSearchDebounce.restart()
                }
                PlasmaComponents3.Label {
                    visible: podcastPage.showingEpisodes
                    Layout.fillWidth: true
                    text: root.podcastEpisodesTitle !== "" ? root.podcastEpisodesTitle : i18n("Episodes")
                    // Untrusted (feed/directory content) — never HTML
                    textFormat: Text.PlainText
                    font.weight: Font.DemiBold
                    color: root.accent
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                CircleButton {
                    visible: podcastPage.showingEpisodes
                    implicitWidth: Kirigami.Units.gridUnit * 2.4
                    implicitHeight: implicitWidth
                    iconName: "view-refresh"
                    iconScale: 0.55
                    tooltipText: i18n("Refresh episodes")
                    onClicked: root.loadPodcastFeed(root.podcastEpisodesFor, root.podcastEpisodesTitle)
                }
            }

            Timer {
                id: podSearchDebounce
                interval: 600
                repeat: false
                onTriggered: root.podcastSearch(podSearchField.text)
            }

            // One honest status line: searching, loading, or the error.
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                Layout.rightMargin: Kirigami.Units.smallSpacing * 2
                visible: root.podcastSearchBusy || root.podcastFeedLoading
                         || (podcastPage.showingEpisodes && root.podcastFeedError !== "")
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.BusyIndicator {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 1.2
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 1.2
                    running: visible
                    visible: root.podcastSearchBusy || root.podcastFeedLoading
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: root.podcastFeedLoading ? i18n("Loading episodes…")
                        : root.podcastSearchBusy ? i18n("Searching…")
                        : root.podcastFeedError
                    color: root.podcastFeedError !== "" && !root.podcastFeedLoading
                           ? "#E0463C" : Kirigami.Theme.textColor
                    opacity: 0.85
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    elide: Text.ElideRight
                }
            }

            // ── Shows (subscriptions, or search results while typing) ────
            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !podcastPage.showingEpisodes
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

                contentItem: ListView {
                    id: showsView
                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    model: podcastPage.searching ? podcastSearchModel : podcastSubsModel
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    spacing: 2

                    delegate: PlasmaComponents3.ItemDelegate {
                        id: showRow

                        required property int index
                        required property string title
                        required property string author
                        required property string art
                        required property string feedUrl

                        readonly property bool subscribed: {
                            podcastSubsModel.count   // re-check on change
                            return root.isPodcastSubscribed(feedUrl)
                        }

                        width: showsView.width - showsView.leftMargin - showsView.rightMargin
                        height: Kirigami.Units.gridUnit * 3
                        padding: 0
                        hoverEnabled: true
                        Accessible.name: title
                        Accessible.role: Accessible.Button

                        background: Item {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing / 2
                            Rectangle {
                                anchors.fill: parent
                                radius: Kirigami.Units.smallSpacing * 1.5
                                color: showRow.hovered ? Qt.alpha(root.accent, 0.07)
                                                       : Qt.alpha(Kirigami.Theme.textColor, 0.045)
                                border.width: 1
                                border.color: showRow.hovered ? Qt.alpha(root.accent, 0.25)
                                                              : Qt.alpha(Kirigami.Theme.textColor, 0.06)
                            }
                        }

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing * 1.5
                            anchors.fill: parent
                            anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
                            anchors.rightMargin: Kirigami.Units.smallSpacing

                            Rectangle {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 2
                                Layout.alignment: Qt.AlignVCenter
                                radius: width * 0.2
                                color: Qt.alpha(Kirigami.Theme.textColor, 0.1)
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: showRow.art
                                    sourceSize.width: 96
                                    sourceSize.height: 96
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    visible: status === Image.Ready
                                }
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    width: parent.width * 0.6
                                    height: width
                                    source: "application-rss+xml"
                                    opacity: 0.5
                                    visible: showRow.art === ""
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    text: showRow.title
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    text: showRow.author
                                    textFormat: Text.PlainText
                                    visible: text !== ""
                                    opacity: 0.6
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }

                            CircleButton {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
                                Layout.alignment: Qt.AlignVCenter
                                iconName: showRow.subscribed ? "favorite" : "non-starred-symbolic"
                                iconScale: 0.55
                                checkable: true
                                checked: showRow.subscribed
                                opacity: showRow.subscribed ? 1.0
                                         : (showRow.hovered || activeFocus
                                            || Kirigami.Settings.tabletMode) ? 0.85 : 0.35
                                tooltipText: showRow.subscribed ? i18n("Unsubscribe")
                                                                : i18n("Subscribe")
                                onClicked: {
                                    if (showRow.subscribed)
                                        root.removePodcastSub(showRow.feedUrl)
                                    else
                                        root.addPodcastSub(showRow.title, showRow.author,
                                                           showRow.art, showRow.feedUrl)
                                }
                            }
                        }

                        TapHandler {
                            onTapped: root.loadPodcastFeed(showRow.feedUrl, showRow.title)
                        }
                    }

                    // Empty states, honest per mode.
                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.largeSpacing * 2
                        visible: showsView.count === 0 && !root.podcastSearchBusy
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            source: "application-rss+xml"
                            width: Kirigami.Units.iconSizes.huge
                            height: width
                            opacity: 0.4
                        }
                        PlasmaComponents3.Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: podcastPage.searching ? i18n("No shows found")
                                                        : i18n("No subscriptions yet")
                            font.weight: Font.DemiBold
                            opacity: 0.7
                        }
                        PlasmaComponents3.Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                            wrapMode: Text.Wrap
                            visible: !podcastPage.searching
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: 0.55
                            text: i18n("Search for a show above, star it, and its episodes download here for offline listening")
                        }
                    }
                }
            }

            // ── Episodes of the open show ────────────────────────────────
            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: podcastPage.showingEpisodes
                PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

                contentItem: ListView {
                    id: episodesView
                    leftMargin: Kirigami.Units.smallSpacing
                    rightMargin: Kirigami.Units.smallSpacing
                    model: podcastEpisodesModel
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    spacing: 2

                    delegate: EpisodeListItem {
                        localUrl: {
                            podcastFolder.count   // re-check when files change
                            return podcastPage.localEpisodeUrl(title, url)
                        }
                    }
                }
            }
        }
        // ── PAGE 5: Timers — every clock in one place ───────────────────
        // Sleep timer, wake-up alarms and scheduled recordings share one
        // labeled tab. They used to live behind three near-identical
        // clock icons on two different pages; a user hunting the radio
        // alarm reliably found the sleep timer first.
        Flickable {
            id: timersPage
            clip: true
            contentHeight: timersCol.implicitHeight + Kirigami.Units.smallSpacing * 2
            boundsBehavior: Flickable.StopAtBounds
            PlasmaComponents3.ScrollBar.vertical: PlasmaComponents3.ScrollBar {}

            ColumnLayout {
                id: timersCol
                width: timersPage.width
                spacing: 0

                // ── Sleep timer ──────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    implicitHeight: sleepCol.implicitHeight + Kirigami.Units.smallSpacing * 3
                    radius: Kirigami.Units.smallSpacing * 1.5
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.03)
                    border.width: 1
                    border.color: Qt.alpha(root.accent, 0.25)

                    ColumnLayout {
                        id: sleepCol
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing * 1.5
                        spacing: Kirigami.Units.smallSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: "chronometer"
                                width: Kirigami.Units.iconSizes.small
                                height: width
                                color: root.accent
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("Sleep timer")
                                font.weight: Font.DemiBold
                                color: root.accent
                            }
                            PlasmaComponents3.Label {
                                visible: root.sleepRemainingSec > 0
                                text: i18n("Sleeping in %1", sleepFormatted())
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.8
                            }
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            Repeater {
                                model: [15, 30, 60, 90]
                                QQC2.Button {
                                    required property int modelData
                                    text: i18n("%1 min", modelData)
                                    onClicked: root.startSleepTimer(modelData * 60)
                                }
                            }
                            QQC2.Button {
                                icon.name: "dialog-cancel"
                                text: i18n("Cancel")
                                enabled: root.sleepRemainingSec > 0
                                onClicked: root.cancelSleepTimer()
                            }
                        }

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: i18n("Playback fades out and stops when the timer ends.")
                            wrapMode: Text.Wrap
                            opacity: 0.55
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                }

            // ── Wake-up alarms panel ─────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
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
                                    // Day names via i18n, NOT Qt.locale(): the catalog
                                    // keeps them in the widget's language, while the
                                    // system locale may be something else entirely.
                                    var days = [i18n("Sun"), i18n("Mon"), i18n("Tue"), i18n("Wed"),
                                                i18n("Thu"), i18n("Fri"), i18n("Sat")]
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
                                // Day names via i18n — same language as the rest of the UI
                                model: [i18n("Sun"), i18n("Mon"), i18n("Tue"), i18n("Wed"),
                                        i18n("Thu"), i18n("Fri"), i18n("Sat")]
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
                                              alarmVolume.value, alarmAwake.checked,
                                              st.uuid || "")
                            }
                        }
                    }
                }
            }

            // ── Scheduled recordings panel ───────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
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
                                    // Day names via i18n, NOT Qt.locale(): the catalog
                                    // keeps them in the widget's language, while the
                                    // system locale may be something else entirely.
                                    var days = [i18n("Sun"), i18n("Mon"), i18n("Tue"), i18n("Wed"),
                                                i18n("Thu"), i18n("Fri"), i18n("Sat")]
                                    var d = new Date(s.nextRun)
                                    var rep = s.repeat === "daily" ? i18n("Daily")
                                            : s.repeat === "weekly" ? i18n("Every %1", days[s.weekday])
                                            : days[d.getDay()] + " " + d.getDate() + "." + (d.getMonth() + 1) + "."
                                    return "⏺ " + rep + " " + when + " · " + i18n("%1 min", s.durationMin) + " · " + s.station
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
                            textFromValue: function(v) { return i18n("%1 min", v) }
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
                                // Day names via i18n — same language as the rest of the UI
                                model: [i18n("Sun"), i18n("Mon"), i18n("Tue"), i18n("Wed"),
                                        i18n("Thu"), i18n("Fri"), i18n("Sat")]
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

            }
        }
    }

    ListModel {
        id: filteredStationsModel
    }

    function rebuildFilteredModel() {
        // What SHOULD be on screen (fold-blind filter, favorites order,
        // duplicate-name and hidden-favorite rules) is decided by the
        // tested logic in ReorderLogic.js. If the station sequence already
        // matches — a reorder the view performed live before persisting,
        // or a favicon that just backfilled — the roles are patched in
        // place and no delegate is recreated: the hover survives for the
        // next arrow click and the entry cascade stays quiet.
        const stations = []
        for (var i = 0; i < stationsModel.count; i++)
            stations.push(stationsModel.get(i))
        const rows = ReorderLogic.buildFilteredRows(
            stations, root.favoriteNames, root.searchFilter, root.favoritesOnly)
        if (ReorderLogic.syncModelToRows(filteredStationsModel, rows)) return
        filteredStationsModel.clear()
        for (var r = 0; r < rows.length; r++)
            filteredStationsModel.append(rows[r])
    }

    Connections {
        target: stationsModel
        // clear()+append() is how the model reloads (main.qml
        // reloadStationsModel), so count changes cover every reload. The one
        // setProperty writer (faviconSelfHeal) always follows with a
        // _faviconStore config write, and THAT triggers a full reload —
        // countChanged covers it too; a dataChanged handler would only
        // double the rebuild.
        // Qt.callLater coalesces the burst: a 200-station reload used to run
        // the full rebuild once per append — O(n²) on every list load.
        function onCountChanged() { Qt.callLater(rebuildFilteredModel) }
    }

    Connections {
        target: root
        function onSearchFilterChanged() {
            rebuildFilteredModel()
            webSearchDebounce.restart()
        }
        function onFavoritesOnlyChanged() { rebuildFilteredModel() }
        // A reorder the view already performed live arrives here as an
        // identical sequence and no-ops inside rebuildFilteredModel — the
        // old _favMovedFrom/_favMovedTo index handshake this replaces is
        // gone with all of its bounds-guard edge cases.
        function onFavoriteNamesChanged() { rebuildFilteredModel() }
    }

    Component.onCompleted: {
        try {
            var h = JSON.parse(Plasmoid.configuration.searchHistory || "[]")
            if (Array.isArray(h))
                webHistory = h.filter(function(e) { return typeof e === "string" }).slice(0, 8)
        } catch (e) {}
        rebuildFilteredModel()
    }

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
            // Esc on ANY non-list page returns to the station list; only on
            // the list itself it may close the popup. Inside the podcasts
            // page an open feed steps back to the shows first.
            if (root.view === 3 && root.podcastEpisodesFor !== "") {
                root.podcastEpisodesFor = ""
                root.podcastFeedError = ""
                event.accepted = true
            } else if (root.view !== 0) {
                root.view = 0
                event.accepted = true
            } else if (filterField.text !== "") {
                filterField.text = ""
                event.accepted = true
            }
        } else if (event.key === Qt.Key_Space && !_inputFocused()) {
            // A true play/stop toggle: anything audible right now — a station,
            // a preview, a local file, a cast session — stops. Without the
            // stop branch, Space during a preview (lastPlay === -1) started
            // station 0 over it instead of stopping.
            if (isPlaying() || root._casting) {
                stopWithFade()
            } else if (stationsModel.count > 0) {
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
        height: Kirigami.Units.gridUnit * 4.5 + navTabs.implicitHeight
        background.visible: Plasmoid.userBackgroundHints !== PlasmaCore.Types.ShadowBackground

        Heading {
            id: headingRow
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Kirigami.Units.gridUnit * 4.5
            anchors.leftMargin: Kirigami.Units.smallSpacing * 1.5
            anchors.rightMargin: Kirigami.Units.smallSpacing * 1.5
        }

        // The popup's map, finally on the surface: four labeled tabs.
        // Before this bar the pages hid behind an unlabeled folder icon,
        // a post-first-play header button and an undiscoverable swipe —
        // and the alarms sat three clicks deep on the downloads page.
        PlasmaComponents3.TabBar {
            id: navTabs
            anchors.top: headingRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right

            // Two-way sync with root.view, imperative like the SwipeView's:
            // a declarative binding would break on the first click.
            Component.onCompleted: currentIndex = root.view
            onCurrentIndexChanged: {
                if (root.view !== currentIndex) root.view = currentIndex
            }
            Connections {
                target: root
                function onViewChanged() {
                    if (navTabs.currentIndex !== root.view) navTabs.currentIndex = root.view
                }
            }

            // Icon above label: four side-by-side labels wrap into
            // hyphen soup at popup width; stacked they stay whole in
            // every language the catalog carries.
            PlasmaComponents3.TabButton {
                icon.name: "radio"
                text: i18n("Stations")
                display: QQC2.AbstractButton.TextUnderIcon
                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                leftPadding: Kirigami.Units.smallSpacing / 2
                rightPadding: Kirigami.Units.smallSpacing / 2
                // Reachable by Tab, but a MOUSE click must not leave keyboard
                // focus on the tab — otherwise the focused button swallows the
                // global Space play/stop shortcut (the old CircleButton nav did
                // not grab click-focus, so Space kept working after navigating).
                focusPolicy: Qt.TabFocus
            }
            PlasmaComponents3.TabButton {
                icon.name: "view-media-lyrics"
                text: i18n("Playing")
                display: QQC2.AbstractButton.TextUnderIcon
                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                leftPadding: Kirigami.Units.smallSpacing / 2
                rightPadding: Kirigami.Units.smallSpacing / 2
                // Reachable by Tab, but a MOUSE click must not leave keyboard
                // focus on the tab — otherwise the focused button swallows the
                // global Space play/stop shortcut (the old CircleButton nav did
                // not grab click-focus, so Space kept working after navigating).
                focusPolicy: Qt.TabFocus
            }
            PlasmaComponents3.TabButton {
                icon.name: "folder-music"
                text: i18n("My Music")
                display: QQC2.AbstractButton.TextUnderIcon
                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                leftPadding: Kirigami.Units.smallSpacing / 2
                rightPadding: Kirigami.Units.smallSpacing / 2
                // Reachable by Tab, but a MOUSE click must not leave keyboard
                // focus on the tab — otherwise the focused button swallows the
                // global Space play/stop shortcut (the old CircleButton nav did
                // not grab click-focus, so Space kept working after navigating).
                focusPolicy: Qt.TabFocus
            }
            PlasmaComponents3.TabButton {
                icon.name: "application-rss+xml"
                text: i18n("Podcasts")
                display: QQC2.AbstractButton.TextUnderIcon
                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                leftPadding: Kirigami.Units.smallSpacing / 2
                rightPadding: Kirigami.Units.smallSpacing / 2
                // Reachable by Tab, but a MOUSE click must not leave keyboard
                // focus on the tab — otherwise the focused button swallows the
                // global Space play/stop shortcut (the old CircleButton nav did
                // not grab click-focus, so Space kept working after navigating).
                focusPolicy: Qt.TabFocus
            }
            PlasmaComponents3.TabButton {
                icon.name: "clock"
                text: i18n("Timers")
                display: QQC2.AbstractButton.TextUnderIcon
                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                leftPadding: Kirigami.Units.smallSpacing / 2
                rightPadding: Kirigami.Units.smallSpacing / 2
                // Reachable by Tab, but a MOUSE click must not leave keyboard
                // focus on the tab — otherwise the focused button swallows the
                // global Space play/stop shortcut (the old CircleButton nav did
                // not grab click-focus, so Space kept working after navigating).
                focusPolicy: Qt.TabFocus
            }
        }
    }

    footer: PlasmaExtras.PlasmoidHeading {
        background.visible: Plasmoid.userBackgroundHints !== PlasmaCore.Types.ShadowBackground

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // (The footer's sleep-timer button retired: the sleep timer
            // now lives on the Timers tab with the alarms and schedules, so
            // one clock served two homes. The running countdown still shows
            // in the status label below — "Sleeping in mm:ss".)

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
                        return i18n("Sleeping in %1", sleepFormatted())
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
                        // The human sentence beats the backend's growl when
                        // one is known (a preview whose whole retry ladder
                        // ran dry — offline or geo-blocked station).
                        return root._friendlyError !== ""
                               ? root._friendlyError
                               : i18n("Error: %1", playMusic.errorString)
                    else if (fullRepresentation._streamActive) {
                        if (fullRepresentation._nowBitrate > 0)
                            return i18n("Bitrate: %1 kb/s", fullRepresentation._nowBitrate)
                        else
                            // A playing local file has no ICY title to wait
                            // for — it is simply playing, never "connecting".
                            return (root.title !== Plasmoid.title || fullRepresentation._localPlayback)
                                   ? "♪ " + i18n("Playing") : i18n("Connecting…")
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
                // Always shown: this is the audio hub now (master volume +
                // output picker), and those need no python3. The cast, sync
                // and Bluetooth sections inside stay gated on _castAvailable,
                // so a machine without python3 still gets volume and output.
                visible: true
                iconName: root._casting ? "media-playback-cast"
                          : root._castAvailable ? "video-display" : "audio-volume-high"
                iconScale: 0.55
                checkable: true
                checked: root._casting
                tooltipText: root._casting
                             ? i18n("Casting to %1 — click to choose or stop", root._castName)
                             : root._castAvailable
                               ? i18n("Volume, output and devices (Chromecast, TV, speaker)")
                               : i18n("Volume and audio output")
                onClicked: {
                    if (!castMenu.opened) {
                        // Device discovery, Bluetooth and sync all need
                        // python3/pactl — skip the probes entirely without
                        // it (the menu still opens for volume and output).
                        if (root._castAvailable) {
                            root.castDiscover()
                            // Re-probe too: an adapter that came up after login
                            // (module reload, rfkill) should be noticed here,
                            // not only at the next plasmashell restart.
                            root.btProbe()
                            root.btList()
                        }
                        castMenu.open()
                    } else {
                        castMenu.close()
                    }
                }

                // A speaker powered off (or walking back in) while the menu
                // is OPEN: nothing else refreshes the Connected ticks, and a
                // stale tick turns the user's "reconnect" click into a
                // disconnect of a corpse. BT_LIST is serialized and seq'd —
                // a 5 s heartbeat costs nothing and only runs while looking.
                Timer {
                    // ...and only while the popup is actually on screen. The
                    // menu can stay "opened" inside a hidden popup (a click on
                    // the desktop hides the applet without closing the menu),
                    // and an unguarded heartbeat then spawned a bluetoothctl
                    // pipeline every 5 s forever — the same !expanded pause
                    // every other timer here honours.
                    running: castMenu.opened && root.expanded
                    interval: 5000
                    repeat: true
                    onTriggered: root.btList()
                }

                QQC2.Popup {
                    id: castMenu
                    y: -height - Kirigami.Units.smallSpacing
                    x: -width + parent.width
                    padding: Kirigami.Units.smallSpacing
                    modal: false
                    // 21 gu — the full-representation's own width. At 18 the
                    // balance row (checkbox + a full speaker name + slider +
                    // % + channel button) starved the slider to a sliver.
                    implicitWidth: Kirigami.Units.gridUnit * 21
                    // CloseOnPressOutsideParent (not ...Outside): the default
                    // policy closed the popup on the toggle button's own
                    // press, so the click's release always saw opened=false
                    // and REOPENED it — the close branch was dead code.
                    closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutsideParent
                    // Keyboard: focus the list so arrow keys reach the rows
                    // and Esc closes the menu instead of leaking to the
                    // page-switch handler.
                    focus: true

                    // The most this menu may be tall: it opens UPWARD from the
                    // footer button, so it has to fit between the popup's top
                    // and the button — never clipping the header, on any popup
                    // height.
                    readonly property real _maxMenuH: Math.max(Kirigami.Units.gridUnit * 10,
                        fullRepresentation.height - Kirigami.Units.gridUnit * 5)
                    // The user's dragged height (0 = auto-fit the content,
                    // capped so it opens compact and scrolls rather than
                    // swallowing a tall popup). Always clamped to the available
                    // range, so it can never overflow. Remembered per config.
                    property real _userMenuH: 0
                    Component.onCompleted: _userMenuH = Plasmoid.configuration.castMenuHeight
                    readonly property real _menuH: Math.min(_maxMenuH,
                        _userMenuH > 0 ? Math.max(Kirigami.Units.gridUnit * 10, _userMenuH)
                                       : Math.min(castMenuColumn.implicitHeight,
                                                  Kirigami.Units.gridUnit * 24))

                    // A scroll container so the content (headers, pairing,
                    // sync controls, three device lists) never clips on a
                    // small popup — a QQC2 Popup cannot extend beyond its
                    // window — with a drag grip on top to resize it.
                    contentItem: ColumnLayout {
                        spacing: 0

                        // Resize grip — drag up to grow the menu, down to
                        // shrink it (it opens upward); double-click resets to
                        // auto-fit. The chosen height is remembered.
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Kirigami.Units.gridUnit
                            Rectangle {
                                anchors.centerIn: parent
                                width: Kirigami.Units.gridUnit * 2.5
                                height: 4
                                radius: 2
                                color: Qt.alpha(Kirigami.Theme.textColor,
                                    gripArea.pressed || gripArea.containsMouse ? 0.5 : 0.22)
                            }
                            MouseArea {
                                id: gripArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.SizeVerCursor
                                // Keep the drag here — a Flickable ancestor
                                // (the scroll view, the swipe pages) must not
                                // grab it partway and stall the resize.
                                preventStealing: true
                                // The grip sits at the TOP of a menu that
                                // grows UPWARD — so resizing moves the grip
                                // itself, and a local mouse.y feeds back into
                                // its own coordinate and the drag oscillates.
                                // Track the cursor in SCREEN space instead: it
                                // is where the finger physically is, unaffected
                                // by the menu resizing under it.
                                property real _startY: 0
                                property real _startH: 0
                                onPressed: (m) => {
                                    _startY = mapToGlobal(m.x, m.y).y
                                    _startH = castMenu._menuH
                                }
                                onPositionChanged: (m) => {
                                    if (!pressed) return
                                    var dy = mapToGlobal(m.x, m.y).y - _startY  // up = negative
                                    castMenu._userMenuH = Math.max(Kirigami.Units.gridUnit * 10,
                                        Math.min(castMenu._maxMenuH, _startH - dy))
                                }
                                onReleased: Plasmoid.configuration.castMenuHeight = Math.round(castMenu._userMenuH)
                                onDoubleClicked: {
                                    castMenu._userMenuH = 0
                                    Plasmoid.configuration.castMenuHeight = 0
                                }
                            }
                        }

                        PlasmaComponents3.ScrollView {
                        id: castMenuScroll
                        Layout.fillWidth: true
                        Layout.preferredHeight: castMenu._menuH
                        contentWidth: availableWidth
                        // The content is fitted to the width by design — an
                        // AsNeeded horizontal bar only feeds the padding<->
                        // visibility binding loop Plasma's ScrollView logs
                        // on every popup open.
                        PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

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

                        // Master volume — the one the per-speaker balances
                        // all follow. It lived on a separate footer button;
                        // the output hub is where every audio control
                        // belongs, so it moved here (the panel icon's scroll
                        // wheel still nudges it without opening anything).
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.smallSpacing
                            Layout.rightMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            CircleButton {
                                implicitWidth: Kirigami.Units.gridUnit * 2
                                implicitHeight: implicitWidth
                                iconName: {
                                    if (playMusicOutput.volume <= 0) return "audio-volume-muted"
                                    if (playMusicOutput.volume <= 0.33) return "audio-volume-low"
                                    if (playMusicOutput.volume <= 0.66) return "audio-volume-medium"
                                    return "audio-volume-high"
                                }
                                iconScale: 0.5
                                tooltipText: playMusicOutput.volume > 0 ? i18n("Mute") : i18n("Unmute")
                                // Absolute gesture (mute/unmute names its level)
                                // — no step flag, so the auto-care park folds it
                                // as spoken rather than as a delta.
                                onClicked: root.setUserVolume(playMusicOutput.volume > 0 ? 0 : root.targetVolume())
                            }
                            PlasmaComponents3.Slider {
                                id: masterVolumeSlider
                                Layout.fillWidth: true
                                from: 0
                                to: 1
                                stepSize: 0.05
                                value: playMusicOutput.volume
                                onMoved: root.setUserVolume(value)
                                Accessible.name: i18n("Volume")
                            }
                            PlasmaComponents3.Label {
                                text: Math.round(playMusicOutput.volume * 100) + "%"
                                opacity: 0.7
                                Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                                horizontalAlignment: Text.AlignRight
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
                            onToggled: {
                                root.castToggleLocal()
                                // Toggling breaks the declared checked binding
                                // — restore it, or after casting ends the sole
                                // playing output would read as unchecked.
                                checked = Qt.binding(function() {
                                    return root._castTargets.length === 0 || root._castLocalPlay
                                })
                            }
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
                            // Wanted-but-idle-parked still reads as ON: the
                            // graph is only sleeping and the next play wakes
                            // it — an unchecked box here would let that wake
                            // contradict what the user just looked at, and
                            // unchecking a PARKED sync must genuinely turn
                            // it off (the disable clears the wish before its
                            // not-active early return).
                            checked: root.sync._combineWantActive
                                     || (root.sync._combineIdleParked
                                         && Plasmoid.configuration.combineWanted === true)
                            onToggled: {
                                if (checked) root.sync.combineOutputsEnable()
                                else root.sync.combineOutputsDisable()
                                checked = Qt.binding(function() {
                                    return root.sync._combineWantActive
                                           || (root.sync._combineIdleParked
                                               && Plasmoid.configuration.combineWanted === true)
                                })
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
                                     || (root.sync._combineIdleParked
                                         && Plasmoid.configuration.combineWanted === true)

                            PlasmaComponents3.Label {
                                text: i18n("Sync fine-tune")
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                            PlasmaComponents3.Slider {
                                id: syncSlider
                                Layout.fillWidth: true
                                Accessible.name: i18n("Sync fine-tune")
                                from: 0
                                // Matches the calibration's sanity ceiling —
                                // slow televisions really sit past 500 ms.
                                to: 900
                                stepSize: 10
                                value: Plasmoid.configuration.syncOffsetMs || 0
                                // Applied on RELEASE, not per step: every
                                // apply swaps the loopbacks, which is an
                                // audible ~1-2 s gap on every speaker — a
                                // drag across the scale used to stutter the
                                // room once per notch. One drag, one gap.
                                // The WHEEL has no press cycle at all (the
                                // PC3 slider scrolls via its own internal
                                // MouseArea), so wheel moves settle through
                                // a short debounce instead — one flurry of
                                // notches, one apply.
                                onPressedChanged: {
                                    if (!pressed) {
                                        syncWheelSettle.stop()
                                        root.sync.setSyncOffset(value)
                                    }
                                }
                                onMoved: {
                                    if (!pressed) syncWheelSettle.restart()
                                }
                                Timer {
                                    id: syncWheelSettle
                                    interval: 600
                                    repeat: false
                                    onTriggered: root.sync.setSyncOffset(syncSlider.value)
                                }

                                PlasmaComponents3.ToolTip {
                                    text: i18n("If the Bluetooth speaker still trails the wired ones, raise this until they play together.")
                                }
                            }
                            // Typing beats nudging: the slider steps by 10
                            // (coarse and fast), but an ear that knows it
                            // wants exactly 154 gets to say 154.
                            PlasmaComponents3.TextField {
                                id: syncMsField
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 3
                                horizontalAlignment: Text.AlignRight
                                font: Kirigami.Theme.smallFont
                                validator: IntValidator { bottom: 0; top: 900 }
                                Accessible.name: i18n("Sync delay in milliseconds")
                                text: Math.round(syncSlider.value).toString()
                                onEditingFinished: {
                                    var v = parseInt(text, 10);
                                    if (isFinite(v)) {
                                        v = Math.max(0, Math.min(900, v));
                                        // setSyncOffset writes the config; the
                                        // slider's declared value binding pulls
                                        // it along. Assigning syncSlider.value
                                        // directly would DESTROY that binding,
                                        // and a later calibration result would
                                        // then never move the slider again.
                                        root.sync.setSyncOffset(v);
                                    }
                                    // Hand the display back to the slider —
                                    // an edit must not freeze the field for
                                    // the rest of the session.
                                    text = Qt.binding(function() {
                                        return Math.round(syncSlider.value).toString();
                                    });
                                }
                                PlasmaComponents3.ToolTip {
                                    text: i18n("Type an exact delay in milliseconds — the slider moves in steps of ten.")
                                }
                            }
                            PlasmaComponents3.Label {
                                text: i18n("ms")
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
                            visible: root.sync._combineWantActive && root.sync.calibPhase === ""
                            enabled: root.sync.calibPairReady()
                            text: i18n("Calibrate with the microphone")
                            icon.name: "audio-input-microphone"
                            onClicked: root.sync.calibrateSync()

                            PlasmaComponents3.ToolTip {
                                text: i18n("Plays a few loud clicks through each speaker and measures with the microphone how far the Bluetooth speaker trails — the delay is set automatically.")
                            }
                        }

                        // The opt-in caretaker: a passive microphone check
                        // on the playing audio every few minutes, one
                        // automatic click-verify when it confirms a drift.
                        PlasmaComponents3.CheckBox {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            visible: root.sync._combineWantActive
                                     || (root.sync._combineIdleParked
                                         && Plasmoid.configuration.combineWanted === true)
                            checked: Plasmoid.configuration.syncAutoCare === true
                            onToggled: Plasmoid.configuration.syncAutoCare = checked
                            text: i18n("Keep sync tuned automatically")

                            PlasmaComponents3.ToolTip {
                                text: i18n("Listens to the playing audio with the microphone every few minutes and re-checks the sync when the speakers drift apart. Audio is processed on this computer only — never stored, never sent anywhere.")
                            }
                        }

                        // The caretaker's heartbeat: the last check's verdict
                        // and time, so "is it even running?" has an answer.
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 2.2
                            visible: Plasmoid.configuration.syncAutoCare === true
                                     && root.sync.driftLastText !== ""
                                     && (root.sync._combineWantActive
                                         || (root.sync._combineIdleParked
                                             && Plasmoid.configuration.combineWanted === true))
                            text: root.sync.driftLastText
                            font: Kirigami.Theme.smallFont
                            opacity: 0.6
                            wrapMode: Text.WordWrap
                        }

                        // A remembered sync member whose sink is gone right
                        // now (speaker asleep or powered off) used to just
                        // VANISH from the rows above — which read as "the
                        // widget forgot my speaker". Say what is true.
                        Repeater {
                            model: btDevicesModel
                            delegate: PlasmaComponents3.Label {
                                required property string mac
                                required property string name
                                required property bool connected
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.gridUnit * 2.2
                                visible: !connected
                                         && root._syncRemembersMac(mac)
                                         && (root.sync._combineWantActive
                                             || (root.sync._combineIdleParked
                                                 && Plasmoid.configuration.combineWanted === true))
                                text: i18n("%1 is remembered for the sync — connect it and it rejoins automatically.", name)
                                font: Kirigami.Theme.smallFont
                                opacity: 0.6
                                wrapMode: Text.WordWrap
                            }
                        }

                        // The whole ride, both rounds: the quiet gap between
                        // the calibration clicks and the check clicks reads
                        // as "done" — this row stays up until it really is.
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            Layout.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            visible: root.sync.calibPhase !== ""
                            PlasmaComponents3.BusyIndicator {
                                implicitWidth: Kirigami.Units.iconSizes.small
                                implicitHeight: implicitWidth
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: root.sync.calibPhase === "clicks"
                                      ? i18n("Round 1 of 2 — clicks through every speaker…")
                                      : i18n("Round 2 of 2 — quiet, checking the result…")
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                font.weight: Font.DemiBold
                                // The full sentence must be readable, not
                                // clipped at the popup's edge — it wraps.
                                wrapMode: Text.WordWrap
                                // Red on purpose: this is the one line that
                                // must catch the eye before someone decides
                                // the quiet gap means "done" and walks off
                                // mid-measurement. Theme red, both schemes.
                                color: Kirigami.Theme.negativeTextColor
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
                                    Accessible.name: i18n("%1 plays in the group", root.sync.outputDescription(balanceRow.modelData))
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
                                    // Wide enough that "JBL Xtreme 3" and
                                    // "USB Audio Front…" read whole, not as
                                    // three dots after two words.
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    text: root.sync.portUnplugged(balanceRow.modelData)
                                          ? i18n("%1 (nothing plugged in)",
                                                 root.sync.outputDescription(balanceRow.modelData))
                                          : root.sync.outputDescription(balanceRow.modelData)
                                    font: Kirigami.Theme.smallFont
                                    opacity: balanceRow.inGroup ? 0.7 : 0.35
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents3.Slider {
                                    id: balanceSlider
                                    Layout.fillWidth: true
                                    // Never collapse to a sliver, whatever the
                                    // name label claims — a balance slider you
                                    // cannot grab is not a control.
                                    Layout.minimumWidth: Kirigami.Units.gridUnit * 3.5
                                    Accessible.name: i18n("Balance of %1", root.sync.outputDescription(balanceRow.modelData))
                                    from: 5
                                    to: 100
                                    stepSize: 1
                                    enabled: balanceRow.inGroup
                                    value: { void root.sync._trimRev; return Math.round(root.sync.trimOf(balanceRow.trimKey) * 100) }
                                    onMoved: root.sync.setDeviceTrim(balanceRow.trimKey, value / 100)

                                    PlasmaComponents3.ToolTip {
                                        text: i18n("This speaker's share of the volume — the balance follows every master move and is remembered for the device. It scales only what this widget plays; the per-device volume in the system's audio settings is a separate, untouched layer — which is why those numbers differ from these sliders.")
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
                        // ones can be dropped the same way. Pairing happens
                        // either right below ("Pair a new speaker…") or in
                        // System Settings — BlueZ remembers it, not us.
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
                            text: i18n("No paired Bluetooth audio devices — use \"Pair a new speaker…\" below, or pair once in System Settings.")
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
            }

            // (The footer's volume button retired: master volume moved into
            // the output hub with the routing, sync and per-speaker balance
            // it governs. Quick nudges still ride the panel icon's scroll
            // wheel and the keyboard, no menu needed.)
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
