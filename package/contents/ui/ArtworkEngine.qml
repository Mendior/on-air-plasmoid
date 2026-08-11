/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick

import "SearchLogic.js" as SearchLogic
import "TrackLogic.js" as TrackLogic

// ── The artwork engine ───────────────────────────────────────────────────────
// The online half of the now-playing cover: a bounded cache with a negative
// TTL, the debounce that keeps a flapping StreamTitle from burning a lookup
// chain per flap, and the Deezer-first/iTunes-fallback pipeline. What stays
// in main.qml is everything that owns a PLAYER fact: the local sidecar-cover
// road (its guard reaches in through app.playerSourceString) and the
// metadata handler's stale-clear, which writes back through the aliases.
Item {
    id: engine

    // main.qml's root. Used: playerSourceString(), _localArtForSource,
    // trackArtistTitleKey(), _armXhrTimeout(), _clearXhrTimeout().
    required property var app
    // Plasmoid's configuration in production; a plain object in tests.
    required property var cfg

    property string albumArtUrl: ""

    property var _artCache: ({})

    // FIFO queue to bound _artCache — plasmashell runs for weeks, and an
    // unbounded cache would be a slow memory leak.
    property var _artCacheKeys: []
    // Misses are retried after this long. Radio repeats its playlist all day,
    // and a single bad moment on the first play (XHR timeout, iTunes 403,
    // network blip) must not leave that track coverless for the whole session.
    readonly property int _artNegativeTtlMs: 30 * 60 * 1000

    // Which track's key the shown albumArtUrl belongs to — so a track
    // change can clear a stale cover the moment the new lookup starts,
    // instead of letting the old song's face sit there until (unless)
    // the new answer lands.
    property string _albumArtKey: ""

    // A flapping StreamTitle (rotating ad text, titles carrying elapsed
    // time) used to launch a full art-lookup chain per flap. Debounced to
    // one chain per stable window; the ~1.5 s later cover is acceptable.
    property string _artLookupPendingRaw: ""
    // The normalized lookup key the pending debounce is already aimed at —
    // so same-key raw flaps (an embedded per-second counter) don't restart
    // the timer forever and starve the lookup.
    property string _artPendingKey: ""

    Timer {
        id: artLookupDebounce
        interval: 1500
        repeat: false
        onTriggered: engine.lookupAlbumArt(engine._artLookupPendingRaw)
    }

    function debounceStop() { artLookupDebounce.stop(); }
    function debounceRestart() { artLookupDebounce.restart(); }

    // definitive=false means the empty result came from a transient failure
    // (timeout, HTTP error, rate limit) — it is NOT cached, so the next play
    // of the same track simply tries again. Definitive empties are cached
    // with a timestamp and expire after _artNegativeTtlMs.
    function _artFinish(cacheKey, url, definitive) {
        // Event-only log — keys and URLs are the listening history, which
        // has no business sitting in the journal.
        console.log("[ARP] artFinish " + (url ? "art found" : "no art")
                    + (definitive ? "" : " (transient, not cached)"));
        if (url || definitive) {
            if (_artCache[cacheKey] === undefined) {
                _artCacheKeys.push(cacheKey);
                if (_artCacheKeys.length > 200) {
                    delete _artCache[_artCacheKeys.shift()];
                }
            }
            _artCache[cacheKey] = { "url": url || "", "t": Date.now() };
        }
        var currentKey = app.trackArtistTitleKey();
        if (url && currentKey === cacheKey) {
            albumArtUrl = url;
            _albumArtKey = cacheKey;
            console.log("[ARP] albumArtUrl set");
        } else if (!url && definitive && currentKey === cacheKey) {
            // A definitive miss for the CURRENT track clears the panel —
            // the previous track's cover posing over a new song is worse
            // than the honest vinyl.
            albumArtUrl = "";
            _albumArtKey = "";
        }
    }

    // A Deezer entity without an image still returns a VALID URL — it just
    // has an empty image id ("…/images/artist//250x250-….jpg") and serves a
    // grey placeholder silhouette. Accepting one poisons the art cache with
    // junk for the whole session; treat it as "no image". The empty id has
    // a second spelling: d41d8cd98f00b204e9800998ecf8427e is the MD5 of ""
    // — the same grey silhouette wearing a hash (caught live: artist
    // fallback for an unmatched track showed the silhouette instead of
    // falling through to the station's own logo).
    function _deezerRealArt(url) {
        var u = (url || "").toString();
        if (u === "" || /\/images\/\w+\/\//.test(u)
            || u.indexOf("d41d8cd98f00b204e9800998ecf8427e") !== -1) return "";
        return u;
    }

    function _queryDeezerArtist(artistName, cacheKey, onResult) {
        console.log("[ARP] DeezerArtist query");
        var xhr = new XMLHttpRequest;
        var guard = null;
        xhr.open("GET", "https://api.deezer.com/search/artist?q=" + encodeURIComponent(artistName) + "&limit=1");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            app._clearXhrTimeout(guard);
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (!data.error) {
                        if (data.data && data.data.length > 0) {
                            var artist = data.data[0];
                            // The photo of SOME artist is not a fallback,
                            // it is a wrong picture with a friendly face —
                            // the name has to be the one we asked for.
                            if (SearchLogic.nameAkin(SearchLogic.fold(artistName),
                                                     SearchLogic.fold(artist.name || ""))) {
                                var artUrl = _deezerRealArt(artist.picture_big)
                                             || _deezerRealArt(artist.picture_medium);
                                if (artUrl) {
                                    onResult(artUrl, true);
                                    return;
                                }
                            }
                        }
                        onResult("", true);
                        return;
                    }
                } catch(e) {}
            }
            onResult("", false);
        };
        guard = app._armXhrTimeout(xhr, 2500);
        xhr.send();
    }

    function _primaryArtist(artist) {
        return TrackLogic.primaryArtist(artist);
    }

    // What the cache already knows about a lookup key, applied at once.
    // True means the cache settled it — either a cover, or a still-fresh
    // "this track has none", which is just as final and costs no network.
    function _artFromCache(query) {
        var hit = _artCache[query];
        if (hit === undefined) return false;
        if (hit.url === "" && Date.now() - hit.t >= _artNegativeTtlMs) return false;
        albumArtUrl = hit.url;
        _albumArtKey = hit.url ? query : "";
        return true;
    }

    function lookupAlbumArt(trackString) {
        // A local track's own sidecar cover outranks any network guess.
        if (app._localArtForSource !== ""
            && app.playerSourceString() === app._localArtForSource)
            return;
        if (!cfg.albumArtEnabled) {
            albumArtUrl = "";
            return;
        }
        if (!trackString || trackString.length === 0) {
            albumArtUrl = "";
            return;
        }
        var parsed = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(trackString));
        var query = TrackLogic.normalizeQuery((parsed.artist + " " + parsed.title).trim() || trackString);
        if (query.length === 0) {
            albumArtUrl = "";
            _albumArtKey = "";
            return;
        }
        if (_artFromCache(query)) return;
        // A NEW track's lookup begins: the old track's cover must not pose
        // over it while the network answers (or fails to).
        if (albumArtUrl !== "" && _albumArtKey !== query) {
            albumArtUrl = "";
            _albumArtKey = "";
        }

        // One request at a time, Deezer first: its rate limit is far
        // friendlier than iTunes' (~20 req/min per IP), so the common case
        // costs a single Deezer call and iTunes only ever sees fallbacks.
        // The old parallel-pair start burned both quotas on every track.
        // What the stream said it is playing — every candidate a music
        // service offers is judged against this, never accepted on faith.
        var want = { "artist": parsed.artist || "", "title": parsed.title || "" };
        var attempts = [
            {fn: _queryDeezer, q: query},
            // Deezer's field search, for the records filed under a name the
            // stream does not use: measured, "Bodies Without Organs" returns
            // three karaoke pressings by free text, while track:"Sunshine In
            // The Rain" has the real one — under "BWO". The picker's initial
            // matching recognizes the pair; free text alone never could.
            {fn: _queryDeezer, q: 'track:"' + (parsed.title || "").replace(/"/g, " ") + '"'},
            {fn: _queryItunes, q: query}
        ];
        var primary = _primaryArtist(parsed.artist);
        if (primary && parsed.title) {
            attempts.push({fn: _queryDeezer, q: primary + " " + parsed.title});
            attempts.push({fn: _queryItunes, q: primary + " " + parsed.title});
        }
        if (primary) {
            attempts.push({fn: _queryDeezerArtist, q: primary});
        } else if (parsed.title) {
            attempts.push({fn: _queryDeezer, q: parsed.title});
            attempts.push({fn: _queryItunes, q: parsed.title});
        }

        // Two of these repeat earlier ones byte for byte in the ordinary
        // "Artist - Title" case: _primaryArtist hands back the artist
        // unchanged when it carries no splitter, and _normalizeQuery is a
        // no-op on a title with no bracket, pipe or kbps tag — so the
        // primary+title Deezer attempt is the plain Deezer one again, and
        // likewise for iTunes. Checked against the real functions on
        // "ABBA - Dancing Queen", "Curly Strings - Kuu" and
        // "Metallica - Nothing Else Matters - Raadio 2": six attempts, two
        // of them exact repeats. They only run on the MISS path, which is
        // precisely where someone is already waiting longest, and the cache
        // is keyed on the track rather than the attempt, so each repeat
        // really does go back out to the network.
        var uniqAttempts = [];
        for (var ai = 0; ai < attempts.length; ai++) {
            var isDup = false;
            for (var bi = 0; bi < uniqAttempts.length; bi++) {
                if (uniqAttempts[bi].fn === attempts[ai].fn
                    && uniqAttempts[bi].q === attempts[ai].q) { isDup = true; break; }
            }
            if (!isDup) uniqAttempts.push(attempts[ai]);
        }
        attempts = uniqAttempts;

        var sawTransient = false;

        function runNext() {
            // The track changed while the chain was running: stop burning
            // requests on it. Nothing is cached (the chain is incomplete);
            // the track's next play starts fresh.
            if (app.trackArtistTitleKey() !== query) return;
            if (attempts.length === 0) {
                // Cache the miss only when every source really said "no
                // match" — a timeout/quota blip must retry on the next play.
                _artFinish(query, "", !sawTransient);
                return;
            }
            var step = attempts.shift();
            step.fn(step.q, query, function(url, definitive) {
                if (url) {
                    _artFinish(query, url, true);
                    return;
                }
                if (!definitive) sawTransient = true;
                runNext();
            }, want);
        }
        runNext();
    }

    function _queryDeezer(query, cacheKey, onResult, want) {
        console.log("[ARP] Deezer query");
        var xhr = new XMLHttpRequest;
        var guard = null;
        xhr.open("GET", "https://api.deezer.com/search?q=" + encodeURIComponent(query) + "&limit=10");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            app._clearXhrTimeout(guard);
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    // Deezer reports quota/rate problems as 200 + {"error"} —
                    // that is a transient failure, not "no such track".
                    if (!data.error) {
                        if (data.data && data.data.length > 0) {
                            // Five candidates, and the one whose ARTIST is
                            // ours — not simply the first. Nothing matching
                            // is an honest "no cover": see artPick.
                            var cands = [];
                            for (var ci = 0; ci < data.data.length; ci++)
                                cands.push({ "artist": ((data.data[ci] || {}).artist || {}).name || "",
                                             "title": (data.data[ci] || {}).title || "" });
                            var pi = SearchLogic.artPick(want.artist, want.title, cands);
                            if (pi >= 0) {
                                var album = data.data[pi].album || {};
                                var artUrl = _deezerRealArt(album.cover_big)
                                             || _deezerRealArt(album.cover_medium)
                                             || _deezerRealArt((data.data[pi].artist || {}).picture_medium);
                                if (artUrl) {
                                    onResult(artUrl, true);
                                    return;
                                }
                            }
                        }
                        onResult("", true);
                        return;
                    }
                } catch(e) {}
            }
            onResult("", false);
        };
        guard = app._armXhrTimeout(xhr, 2500);
        xhr.send();
    }

    // All three query callbacks are (url, definitive): definitive=true means
    // the service really answered (with a result or a real "no match");
    // definitive=false is a transient failure — timeout/abort (status 0),
    // an HTTP error (iTunes rate-limits at ~20 req/min with 403), a quota
    // error or an unparseable body — and must not be negative-cached.
    function _queryItunes(query, cacheKey, onResult, want) {
        console.log("[ARP] iTunes query");
        var xhr = new XMLHttpRequest;
        var guard = null;
        xhr.open("GET", "https://itunes.apple.com/search?term=" + encodeURIComponent(query) + "&entity=song&limit=10&media=music");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            app._clearXhrTimeout(guard);
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.results && data.results.length > 0) {
                        var icands = [];
                        for (var ii = 0; ii < data.results.length; ii++)
                            icands.push({ "artist": data.results[ii].artistName || "",
                                          "title": data.results[ii].trackName || "" });
                        var ip = SearchLogic.artPick(want.artist, want.title, icands);
                        var artUrl = ip >= 0 ? (data.results[ip].artworkUrl100 || "") : "";
                        if (artUrl) {
                            onResult(artUrl.replace("100x100bb", "300x300bb"), true);
                            return;
                        }
                    }
                    if (data.results !== undefined) {
                        onResult("", true);
                        return;
                    }
                } catch(e) {}
            }
            onResult("", false);
        };
        guard = app._armXhrTimeout(xhr, 2500);
        xhr.send();
    }

}
