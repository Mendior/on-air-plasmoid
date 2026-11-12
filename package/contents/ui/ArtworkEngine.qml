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
// metadata handler, which clears a stale cover through artClearUnless and
// artClear. Nobody but _artShow writes the picture.
Item {
    id: engine

    // main.qml's root. Used: playerSourceString(), _localArtForSource,
    // currentStation, trackArtistTitleKey(), _armXhrTimeout(),
    // _clearXhrTimeout().
    required property var app
    // Plasmoid's configuration in production; a plain object in tests.
    required property var cfg

    // The picture beside the song and what it is of: one of
    // SearchLogic.artKind's three words while there is a picture, "" with
    // none. Both are written in _artShow and nowhere else.
    property string albumArtUrl: ""
    property string albumArtKind: ""
    // The picture for every place that cannot say what it shows, the lock
    // screen and a television among them: the song's own cover, and nothing
    // where the picture is of the artist or off another record.
    readonly property string trackArtUrl: albumArtKind === "track" ? albumArtUrl : ""

    // What is known about a lookup key: { url, t, kind }, url "" for a track
    // nobody has a picture for. It is a property of this engine and is
    // written nowhere else, so it starts empty with every panel start.
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
    // one chain per stable window. Only a title that follows another within
    // four seconds waits that window out: SearchLogic.artWaitMs.
    property string _artLookupPendingRaw: ""
    // The normalized lookup key the pending debounce is already aimed at —
    // so same-key raw flaps (an embedded per-second counter) don't restart
    // the timer forever and starve the lookup.
    property string _artPendingKey: ""
    // When the lookup key last moved, by either of the two doors below.
    property double _artKeyMovedAt: 0

    Timer {
        id: artLookupDebounce
        interval: 1500
        repeat: false
        onTriggered: engine.lookupAlbumArt(engine._artLookupPendingRaw)
    }

    // The one later attempt for a chain that ended on a timeout or a
    // refusal: { key, again } while it waits, null otherwise. again() starts
    // that lookup over. _artRetriedKey is the track that has had its attempt.
    property var _artRetry: null
    property string _artRetriedKey: ""
    property alias _artRetryArmed: artRetry.running
    property alias _artRetryWaitMs: artRetry.interval

    Timer {
        id: artRetry
        repeat: false
        onTriggered: engine._artAskAgain()
    }

    // Called where a chain ends without a cover. SearchLogic.artRetryMs
    // says whether this end is asked again and after how long.
    function _artRetryArm(unanswered, key, again) {
        var ms = again ? SearchLogic.artRetryMs(unanswered, key, app.trackArtistTitleKey(),
                                                _artRetriedKey, cfg.albumArtEnabled) : -1;
        if (ms < 0) return;
        _artRetry = { "key": key, "again": again };
        artRetry.interval = ms;
        artRetry.restart();
    }

    // The retry timer's handler, and the tests' door to it. The question is
    // put once more, because the wait is long enough for the track to change
    // or the covers to be switched off.
    function _artAskAgain() {
        var r = _artRetry;
        _artRetry = null;
        artRetry.stop();
        if (!r || SearchLogic.artRetryMs(true, r.key, app.trackArtistTitleKey(),
                                         _artRetriedKey, cfg.albumArtEnabled) < 0) return;
        _artRetriedKey = r.key;
        r.again();
    }

    // Writes the picture, its kind and the key of the track it belongs to.
    // "track" is the word that lets a picture out to the lock screen and a
    // television, so it is taken away before the address changes and given
    // only after: whoever reads the two between the writes never finds one
    // picture under another's kind.
    function _artShow(url, kind, key) {
        if (kind !== "track" || !url) albumArtKind = url ? kind : "";
        albumArtUrl = url;
        albumArtKind = url ? kind : "";
        _albumArtKey = url ? key : "";
    }

    // No picture: a title went away, or a lookup came to a dead end.
    function artClear() {
        _artShow("", "", "");
    }

    // A new track's lookup begins. Another track's cover goes at once, so it
    // does not pose over the new song while the network answers or fails to;
    // a cover that already belongs to this key stays.
    function artClearUnless(key) {
        if (albumArtUrl !== "" && _albumArtKey !== key) artClear();
    }

    // The sidecar cover of the local file that plays: that file's own cover.
    function artLocal(url) {
        _artShow(url, "track", "");
    }

    // Both doors are a title change as main.qml sees it: this one for a
    // title the cache settled or a header that went empty, the next for a
    // title that needs the network. Each stamps the moment, so the wait is
    // measured from the last change of either kind.
    function debounceStop() {
        _artKeyMovedAt = Date.now();
        artLookupDebounce.stop();
    }
    // first = the title that follows an empty header (a station start, a
    // return from a stop): there is nothing for it to flap against yet, and
    // the full window only kept every station's first cover a second and a
    // half further away. A flap that follows is back on the full window.
    function debounceRestart(first) {
        var now = Date.now();
        artLookupDebounce.interval = SearchLogic.artWaitMs(first === true, now - _artKeyMovedAt);
        _artKeyMovedAt = now;
        artLookupDebounce.restart();
    }

    // kind says what the picture is of, and a picture that comes without one
    // of the three words is no picture: it could not be shown honestly.
    // definitive=false means a transient failure (timeout, HTTP error, rate
    // limit) was met on the way. An empty result is then NOT cached, so the
    // next play of the same track simply tries again, and neither is a
    // picture that only stands in for the song's cover, because the request
    // that failed may have been the one that had the cover. Definitive
    // empties are cached with a timestamp and expire after _artNegativeTtlMs.
    function _artFinish(cacheKey, url, definitive, kind) {
        kind = url ? SearchLogic.artKind(kind) : "";
        if (url && kind === "") {
            url = "";
            definitive = false;
        }
        // Event-only log — keys and URLs are the listening history, which
        // has no business sitting in the journal.
        console.log("[ARP] artFinish " + (url ? "art found (" + kind + ")" : "no art")
                    + (definitive ? "" : " (transient, not cached)"));
        if (definitive) {
            if (_artCache[cacheKey] === undefined) {
                _artCacheKeys.push(cacheKey);
                if (_artCacheKeys.length > 200) {
                    delete _artCache[_artCacheKeys.shift()];
                }
            }
            _artCache[cacheKey] = { "url": url || "", "t": Date.now(), "kind": kind };
        }
        var currentKey = app.trackArtistTitleKey();
        if (url && currentKey === cacheKey) {
            _artShow(url, kind, cacheKey);
            console.log("[ARP] albumArtUrl set");
        } else if (!url && definitive && currentKey === cacheKey) {
            // A definitive miss for the CURRENT track clears the panel —
            // the previous track's cover posing over a new song is worse
            // than the honest vinyl.
            artClear();
        }
    }

    // One request to a catalogue: the address goes out and done(status, body)
    // comes back once, status 0 for a request that timed out or never left.
    // The tests put a catalogue of their own here.
    property var _fetch: function(address, done) {
        var xhr = new XMLHttpRequest;
        var guard = null;
        xhr.open("GET", address);
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== xhr.DONE) return;
            engine.app._clearXhrTimeout(guard);
            done(xhr.status, xhr.responseText);
        };
        guard = engine.app._armXhrTimeout(xhr, 2500);
        xhr.send();
    }

    // Asks one catalogue and hands the chain what its answer offers. read is
    // given the parsed answer and returns a picture with its kind, null for
    // an answer without one, or undefined for an answer that is no answer.
    // onResult is (url, definitive, kind): definitive=true means the service
    // really answered, with a picture or a real "no match"; definitive=false
    // is a transient failure, a timeout or an abort (status 0), an HTTP error
    // (iTunes rate-limits at ~20 req/min with 403), a quota error or a body
    // nobody can parse, and must not be negative-cached.
    // An answer the reader trips over counts as transient too, but it says
    // so: the engine once called a library it had not imported, every call
    // threw in here unseen, and the covers were dead until somebody looked.
    function _ask(address, read, onResult) {
        _fetch(address, function(status, body) {
            var got;
            if (status === 200) {
                try {
                    got = read(JSON.parse(body));
                } catch(e) {
                    console.warn("[ARP] art answer not read: " + e);
                }
            }
            if (got === undefined) onResult("", false, "");
            else onResult(got ? got.url : "", true, got ? got.kind : "");
        });
    }

    // The photo of SOME artist is not a fallback, it is a wrong picture with
    // a friendly face: the name has to be the one we asked for, which
    // SearchLogic.artFromDeezerArtist sees to.
    function _queryDeezerArtist(artistName, cacheKey, onResult) {
        console.log("[ARP] DeezerArtist query");
        _ask("https://api.deezer.com/search/artist?q=" + encodeURIComponent(artistName) + "&limit=1", function(data) {
            return data.error ? undefined : SearchLogic.artFromDeezerArtist(data, artistName);
        }, onResult);
    }

    // The artist's own sleeve for a song no catalogue has: the iTunes songs
    // filed under the whole credit, and the first of them that is exactly
    // the artist (SearchLogic.artPickByArtist). Measured 2026-11-02: Elmari
    // tantsuõhtu played Anne Loho's "Uus algus", which Deezer, iTunes and
    // MusicBrainz all lack, and Deezer's artist search does not know her,
    // but iTunes lists her own singles. One request, after everything else
    // came back empty; same host, timeout and one-at-a-time chain as the
    // iTunes song search, and a miss is cached like any other.
    function _queryItunesArtist(artistName, cacheKey, onResult) {
        console.log("[ARP] iTunes artist query");
        _ask("https://itunes.apple.com/search?term=" + encodeURIComponent(artistName) + "&entity=song&limit=25", function(data) {
            return data.results === undefined ? undefined : SearchLogic.artFromItunesArtist(data, artistName);
        }, onResult);
    }

    function _primaryArtist(artist) {
        return TrackLogic.primaryArtist(artist);
    }

    // What the cache already knows about a lookup key, applied at once.
    // True means the cache settled it — either a cover, or a still-fresh
    // "this track has none", which is just as final and costs no network.
    //
    // It is also the door both roads pass before the network (the metadata
    // handler's instant paint and lookupAlbumArt), so the station talking
    // about itself is settled here too: no record, the logo shows. Measured
    // on Dance Wave! 2026-09-23: the title "Dance Wave!" found an album of
    // that name on iTunes, and the second time round it came from the cache.
    //
    // artist is what the line parsed to, and a line that names no artist is
    // settled here the same way. Of 231 live titles (2026-11-02), 12 still
    // parse without one: eleven slogans, shows, news items and adverts, and
    // a song whose artist sits behind a "|". None of them got a right cover,
    // "Nachrichten" on Deutschlandfunk got a sleeve off a Kraftwerk tribute
    // album, and together they cost 36 requests. Both callers pass the
    // parsed artist; a call without one asks nothing and paints nothing.
    function _artFromCache(query, artist) {
        if (TrackLogic.stationTalk(query, app.currentStation) || !artist) {
            artClear();
            return true;
        }
        var hit = _artCache[query];
        if (hit === undefined) return false;
        if (hit.url === "" && Date.now() - hit.t >= _artNegativeTtlMs) return false;
        // Every entry was filed by _artFinish in this session and says what
        // its picture is of. One that does not is not taken for a song's
        // cover: the track is looked up again.
        if (hit.url !== "" && SearchLogic.artKind(hit.kind) === "") return false;
        _artShow(hit.url, hit.kind, query);
        return true;
    }

    function lookupAlbumArt(trackString) {
        // A local track's own sidecar cover outranks any network guess.
        if (app._localArtForSource !== ""
            && app.playerSourceString() === app._localArtForSource)
            return;
        if (!cfg.albumArtEnabled || !trackString || trackString.length === 0) {
            artClear();
            return;
        }
        var parsed = TrackLogic.parseTrackString(TrackLogic.preCleanTrack(trackString, app.currentStation));
        var query = TrackLogic.normalizeQuery((parsed.artist + " " + parsed.title).trim() || trackString);
        if (query.length === 0) {
            artClear();
            return;
        }
        if (_artFromCache(query, parsed.artist)) return;
        artClearUnless(query);

        // What the stream said it is playing — every candidate a music
        // service offers is judged against this, never accepted on faith.
        var want = { "artist": parsed.artist || "", "title": parsed.title || "" };
        _runAttempts(_artPlan(parsed, query, trackString), query, want,
                     function() { engine.lookupAlbumArt(trackString); });
    }

    // The requests a lookup will try, in order, each {fn, q, svc}: svc names
    // the service ("deezer", "itunes", "deezerArtist", "itunesArtist"), and
    // SearchLogic.artBrings says what each is sent for. The chain stops at
    // the first one that finds the song's cover, so a later entry only ever
    // runs when no earlier one had it. The song searches all come before the
    // two that can only bring a stand-in.
    // One request at a time, Deezer first: its rate limit is far
    // friendlier than iTunes' (~20 req/min per IP), so the common case
    // costs a single Deezer call and iTunes only ever sees fallbacks.
    // The old parallel-pair start burned both quotas on every track.
    function _artPlan(parsed, query, trackString) {
        // Deezer reads track:"…" against the title alone, and an aside the
        // station added is not part of it: track:"Kaotand pea (2026)"
        // answered total 0 where track:"Kaotand pea" has the record. A title
        // that is one aside and nothing else still goes as it came.
        var bare = (parsed.title || "").replace(/"/g, " ");
        bare = TrackLogic.cleanQueryLocal(bare) || bare.trim();
        var attempts = [
            {fn: _queryDeezer, q: query, svc: "deezer"},
            // Deezer's field search, for the records filed under a name the
            // stream does not use: measured, "Bodies Without Organs" returns
            // three karaoke pressings by free text, while track:"Sunshine In
            // The Rain" has the real one — under "BWO". The picker's initial
            // matching recognizes the pair; free text alone never could.
            {fn: _queryDeezer, q: 'track:"' + bare + '"', svc: "deezer"},
            {fn: _queryItunes, q: query, svc: "itunes"}
        ];
        var primary = _primaryArtist(parsed.artist);
        if (primary && parsed.title) {
            attempts.push({fn: _queryDeezer, q: primary + " " + parsed.title, svc: "deezer"});
            attempts.push({fn: _queryItunes, q: primary + " " + parsed.title, svc: "itunes"});
        }
        // An artist found behind the station's own name is trusted with a
        // sleeve, which has to be one of their records, but not with a
        // photo: on Kaaosradio two of the four photos it brought were of
        // another act with the same name (2026-11-02). The photo search asks
        // for the whole band, see photoArtist.
        var stationCut = TrackLogic.stationDropped(trackString, app.currentStation);
        var photo = TrackLogic.photoArtist(parsed.artist);
        if (photo && !stationCut) {
            attempts.push({fn: _queryDeezerArtist, q: photo, svc: "deezerArtist"});
        }
        // And last, a song of theirs from iTunes for a song no catalogue has,
        // under the same trust as the photo and so not behind a station's
        // name either. See _queryItunesArtist.
        if (parsed.artist && !stationCut) {
            attempts.push({fn: _queryItunesArtist, q: parsed.artist, svc: "itunesArtist"});
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
        return uniqAttempts;
    }

    // Runs the plan one request at a time for the lookup key query. Each fn
    // is called as fn(q, query, onResult(url, definitive, kind), want). The
    // song's own cover settles it at once and nothing after it is asked.
    // A picture of the artist or another record's sleeve that a song search
    // brings is kept and the chain goes on: it used to end there, and the
    // next service, which had the song, was never asked. What was kept
    // answers in place of a later request (SearchLogic.artSpare), or at the
    // plan's end. again, when given, starts this same lookup over, for the
    // one later attempt after a chain that met a transient failure.
    function _runAttempts(attempts, query, want, again) {
        var sawTransient = false;
        var spare = {};

        // The song's cover is final whatever happened on the way. Anything
        // else, a miss included, is final only when every service answered;
        // after a timeout it is shown, not filed, and the lookup gets its
        // later attempt.
        function settle(url, kind) {
            var sure = kind === "track" || !sawTransient;
            _artFinish(query, url, sure, kind);
            if (!sure) _artRetryArm(true, query, again);
        }

        function runNext() {
            // The track changed while the chain was running: stop burning
            // requests on it. Nothing is cached (the chain is incomplete);
            // the track's next play starts fresh.
            if (app.trackArtistTitleKey() !== query) return;
            var brings = attempts.length > 0 ? SearchLogic.artBrings(attempts[0].svc) : "";
            var kept = SearchLogic.artSpare(spare, brings);
            if (kept || attempts.length === 0) {
                settle(kept ? kept.url : "", kept ? kept.kind : "");
                return;
            }
            var step = attempts.shift();
            step.fn(step.q, query, function(url, definitive, kind) {
                // The listener switched the online covers off while this
                // request was in the air. lookupAlbumArt's door only stands
                // before the first request, so the empty answer used to send
                // the next one. The chain ends here whatever came home: a
                // cover is not painted either, and nothing is cached, the
                // same as for a chain a track change cut short.
                if (!cfg.albumArtEnabled) return;
                kind = url ? SearchLogic.artKind(kind) : "";
                if (kind === "track" || (kind !== "" && kind === brings)) {
                    settle(url, kind);
                    return;
                }
                if (kind !== "" && !spare[kind]) spare[kind] = { "url": url, "kind": kind };
                if (!definitive) sawTransient = true;
                runNext();
            }, want);
        }
        runNext();
    }

    // Five candidates, and the one whose ARTIST is ours, not simply the
    // first. Nothing matching is an honest "no cover": see
    // SearchLogic.artFromDeezerSongs. Deezer reports quota and rate problems
    // as 200 + {"error"}, which is a transient failure and not "no such
    // track".
    function _queryDeezer(query, cacheKey, onResult, want) {
        console.log("[ARP] Deezer query");
        _ask("https://api.deezer.com/search?q=" + encodeURIComponent(query) + "&limit=10", function(data) {
            return data.error ? undefined : SearchLogic.artFromDeezerSongs(data, want);
        }, onResult);
    }

    function _queryItunes(query, cacheKey, onResult, want) {
        console.log("[ARP] iTunes query");
        _ask("https://itunes.apple.com/search?term=" + encodeURIComponent(query) + "&entity=song&limit=10&media=music",
             function(data) {
            return data.results === undefined ? undefined : SearchLogic.artFromItunesSongs(data, want);
        }, onResult);
    }

}
