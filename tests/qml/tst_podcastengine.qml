// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The podcast engine's downloads ledger, driven end to end through a mock
// app and a plain cfg object — the whole point of the app/cfg facade. Every
// shell round-trip is asserted on the command STRING the engine emits and
// answered by calling handleExec back, the way the real dispatcher does.
import QtQuick
import QtTest
import "../../package/contents/ui"

TestCase {
    id: tc
    name: "PodcastEngine"

    property var execLog: []
    property var notified: []
    property int seq: 0

    // Engine notifications call i18n(); qmltestrunner has no KLocalizedContext,
    // so the scope chain finds this stand-in (production resolves the real one
    // from the plasmoid context — main.qml defines no such function).
    function i18n(s) {
        var out = s;
        for (var i = 1; i < arguments.length; i++)
            out = out.replace("%" + i, arguments[i]);
        return out;
    }
    // The import summary counts feeds with i18np(singular, plural, n).
    function i18np(s1, sn, n) {
        return (n === 1 ? s1 : sn).replace("%1", n);
    }

    Component {
        id: engineComp
        PodcastEngine {}
    }

    function makeEngine(cfgOverrides) {
        tc.execLog = [];
        tc.notified = [];
        tc.seq = 0;
        var cfg = { podcastDownloads: "{}" };
        for (var k in (cfgOverrides || {})) cfg[k] = cfgOverrides[k];
        var app = {
            exec: function(cmd) { tc.execLog.push(cmd); },
            nextSeq: function() { return ++tc.seq; },
            notify: function(t, x, i) { tc.notified.push(t + "|" + (x || "")); },
            downloadDirPath: "/home/x/Music/OnAir",
            _sanitizeDeviceName: function(s) { return s; },
            _hostOf: function(u) { return u; }
        };
        return engineComp.createObject(tc, { app: app, cfg: cfg });
    }

    // A search is four answers: iTunes, fyyd and gpodder for shows, iTunes
    // again for episodes. Each XHR handler hands its verdict to the settle;
    // these drive the settle directly, the way the handlers do, with no
    // network in the test.
    function settleAll(e, seq, shows, episodes) {
        for (var i = 0; i < 3; i++) e._podSearchSettle(seq, shows[i], false)
        e._podSearchSettle(seq, episodes, true)
    }

    // ── The refresh nobody watches ────────────────────────────────────────

    readonly property string feedXml: '<rss><channel><title>Show</title>'
        + '<item><title>Ep 1</title><guid>g1</guid>'
        + '<enclosure url="https://cdn.example/e1.mp3" type="audio/mpeg"/></item>'
        + '</channel></rss>'

    // An engine whose quiet refresh asks a stand-in request, and the
    // request: what was asked of it, and step(state, text, landed) to
    // answer the way Qt does.
    function quietEngine() {
        var e = makeEngine();
        var req = {
            readyState: 0, responseText: "", responseURL: "", onreadystatechange: null,
            opened: [], sent: 0, aborts: 0, armed: [], cleared: [],
            open: function(m, u) { req.opened.push(m + " " + u); },
            setRequestHeader: function() {},
            send: function() { req.sent++; },
            abort: function() { req.aborts++; },
            step: function(state, text, landed) {
                req.readyState = state;
                req.responseText = text;
                req.responseURL = landed || "";
                req.onreadystatechange();
            }
        };
        e.app._armXhrTimeout = function(x, ms) { req.armed.push(ms); return "guard"; };
        e.app._clearXhrTimeout = function(g) { req.cleared.push(g); };
        e.makeRequest = function() { return req; };
        return { e: e, req: req };
    }

    function test_the_quiet_refresh_reads_a_feed_and_puts_its_timer_away() {
        var q = quietEngine(), got = [];
        q.e._podFetchFeedSilent("https://feeds.example/show.rss", function(f) { got.push(f); });
        compare(q.req.opened.join(), "GET https://feeds.example/show.rss");
        compare(q.req.sent, 1);
        compare(q.req.armed.join(), "15000");
        q.req.step(4, tc.feedXml, "https://feeds.example/show.rss");
        compare(got.length, 1);
        compare(got[0].title, "Show");
        compare(got[0].episodes.length, 1);
        compare(q.req.cleared.join(), "guard");
        // Qt can say DONE twice around an abort. One answer is one answer.
        q.req.step(4, tc.feedXml, "https://feeds.example/show.rss");
        compare(got.length, 1);
        q.e.destroy();
    }

    function test_the_quiet_refresh_does_not_ask_a_private_address() {
        var q = quietEngine(), got = [];
        q.e._podFetchFeedSilent("http://192.168.1.5/feed.rss", function(f) { got.push(f); });
        compare(q.req.opened.length, 0);
        compare(got.length, 1);
        compare(got[0], null);
        q.e.destroy();
    }

    function test_a_feed_that_ends_inside_the_home_network_tells_the_refresh_nothing() {
        var q = quietEngine(), got = [];
        q.e._podFetchFeedSilent("https://feeds.example/show.rss", function(f) { got.push(f); });
        q.req.step(4, tc.feedXml, "http://192.168.1.5/feed.rss");
        compare(got.length, 1);
        compare(got[0], null);
        compare(q.req.cleared.join(), "guard");
        q.e.destroy();
    }

    function test_a_request_cut_by_the_timer_ends_the_refresh_without_a_feed() {
        // The timer aborts the request, and Qt answers an abort with DONE
        // and nothing in it.
        var q = quietEngine(), got = [];
        q.e._podFetchFeedSilent("https://feeds.example/show.rss", function(f) { got.push(f); });
        q.req.step(4, "", "");
        compare(got.length, 1);
        verify(!got[0].ok);
        compare(got[0].episodes.length, 0);
        q.e.destroy();
    }

    function test_an_endless_feed_is_cut_a_turn_later_and_read_as_far_as_it_came() {
        var q = quietEngine(), got = [];
        q.e._podFetchFeedSilent("https://feeds.example/show.rss", function(f) { got.push(f); });
        var big = tc.feedXml + new Array(4 * 1024 * 1024 + 2).join(" ");
        q.req.step(3, big, "https://feeds.example/show.rss");
        // Not from inside the handler: that takes the shell down (Qt 6.11).
        compare(q.req.aborts, 0);
        tryCompare(q.req, "aborts", 1);
        q.req.step(3, big + " ", "https://feeds.example/show.rss");
        wait(0);
        compare(q.req.aborts, 1);
        // The abort empties the text. What had arrived is still a feed.
        q.req.step(4, "", "https://feeds.example/show.rss");
        compare(got.length, 1);
        compare(got[0].episodes.length, 1);
        q.e.destroy();
    }

    function test_a_search_nobody_answered_is_not_no_shows_found() {
        // Measured on the bench with the directories unreachable: the page
        // said "No shows found", which tells the listener the show does not
        // exist, and offered no way to ask again.
        var e = makeEngine()
        var seq = e._podSearchBegin()
        verify(e.podcastSearchBusy)
        settleAll(e, seq, [false, false, false], false)
        verify(!e.podcastSearchBusy)
        verify(e.podcastSearchUnreached, "nobody answered and the shows view does not know")
        verify(e.podcastEpSearchUnreached, "the episode directory did not answer")
        e.destroy()
    }

    function test_one_directory_answering_empty_is_a_real_no_shows_found() {
        var e = makeEngine()
        var seq = e._podSearchBegin()
        settleAll(e, seq, [false, true, false], true)
        verify(!e.podcastSearchUnreached, "fyyd answered: the show is not there")
        verify(!e.podcastEpSearchUnreached)
        e.destroy()
    }

    function test_shows_and_episodes_are_judged_apart() {
        // The episode search rides iTunes alone: iTunes refusing while
        // gpodder answers leaves the shows answered and the episodes not.
        var e = makeEngine()
        var seq = e._podSearchBegin()
        settleAll(e, seq, [false, false, true], false)
        verify(!e.podcastSearchUnreached)
        verify(e.podcastEpSearchUnreached)
        e.destroy()
    }

    function test_the_verdict_waits_for_the_last_answer() {
        var e = makeEngine()
        var seq = e._podSearchBegin()
        e._podSearchSettle(seq, false, false)
        e._podSearchSettle(seq, false, false)
        e._podSearchSettle(seq, false, true)
        verify(!e.podcastSearchUnreached, "judged before gpodder was in")
        e._podSearchSettle(seq, true, false)
        verify(!e.podcastSearchUnreached)
        verify(e.podcastEpSearchUnreached)
        e.destroy()
    }

    function test_asking_again_clears_the_old_verdict_and_a_stale_answer_is_ignored() {
        var e = makeEngine()
        var old = e._podSearchBegin()
        settleAll(e, old, [false, false, false], false)
        verify(e.podcastSearchUnreached)
        // "Try again": a new search starts with no verdict at all.
        var seq = e._podSearchBegin()
        verify(!e.podcastSearchUnreached, "the retry still says unreachable while it asks")
        verify(!e.podcastEpSearchUnreached)
        // A late answer of the first search changes nothing.
        e._podSearchSettle(old, false, false)
        compare(e._podSearchPending, 4)
        settleAll(e, seq, [true, false, false], true)
        verify(!e.podcastSearchUnreached)
        e.destroy()
    }

    function test_the_ledger_survives_a_save_load_roundtrip() {
        var e = makeEngine();
        e.downloads["a.mp3"] = { key: "k1", title: "Ep 1", at: 111 };
        e.saveDownloads();
        var e2 = makeEngine({ podcastDownloads: e.cfg.podcastDownloads });
        e2.loadDownloads();
        compare(e2.downloadMeta("a.mp3").key, "k1");
        e.destroy(); e2.destroy();
    }

    function test_garbage_in_the_config_loads_as_an_empty_ledger() {
        var e = makeEngine({ podcastDownloads: "not json at all" });
        e.loadDownloads();
        compare(e.downloadMeta("a.mp3"), null);
        var e2 = makeEngine({ podcastDownloads: "[1,2,3]" });   // array, not map
        e2.loadDownloads();
        compare(e2.fileForKey("k"), "");
        e.destroy(); e2.destroy();
    }

    function test_an_episode_is_found_by_its_key_not_its_name() {
        // The feed can move and the recomputed name with it; the key never
        // does. This is the lookup that keeps "Downloaded" true after a
        // feed rescue.
        var e = makeEngine();
        e.downloads["old-tag-ep.mp3"] = { key: "stable-key", title: "Ep" };
        e.loadDownloads ? void 0 : void 0;
        compare(e.fileForKey("stable-key"), "old-tag-ep.mp3");
        compare(e.fileForKey("unknown"), "");
        compare(e.fileForKey(""), "");
        e.destroy();
    }

    function test_delete_refuses_a_name_with_path_parts() {
        // The rm runs in a shell against the Podcasts folder; a name that
        // climbs out of it must never reach the command line.
        var e = makeEngine();
        e.deleteDownload("../../etc/passwd");
        e.deleteDownload("/abs/path.mp3");
        e.deleteDownload(".hidden");
        e.deleteDownload("");
        compare(tc.execLog.length, 0);
        e.destroy();
    }

    function test_delete_emits_a_tokened_rm_and_the_ok_ack_drops_the_row() {
        var e = makeEngine();
        e.downloads["ep.mp3"] = { key: "k", title: "Ep" };
        e.deleteDownload("ep.mp3");
        compare(tc.execLog.length, 1);
        verify(tc.execLog[0].indexOf(": POD_RM 1;") === 0);
        // The file name rides only inside quoted paths, never the sentinel.
        verify(tc.execLog[0].indexOf("'/home/x/Music/OnAir/Podcasts/ep.mp3'") !== -1);
        verify(e.handleExec(": POD_RM 1;", "__POD_RM_OK__"));
        compare(e.downloadMeta("ep.mp3"), null);
        e.destroy();
    }

    function test_a_failed_rm_keeps_the_ledger_row() {
        // A read-only mount fails the rm; dropping the metadata anyway once
        // turned that into a bare-name row with no cover and no resume.
        var e = makeEngine();
        e.downloads["ep.mp3"] = { key: "k", title: "Ep" };
        e.deleteDownload("ep.mp3");
        verify(e.handleExec(": POD_RM 1;", ""));   // no OK marker
        compare(e.downloadMeta("ep.mp3").key, "k");
        e.destroy();
    }

    function test_gone_drops_the_row_only_on_proof_of_absence() {
        var e = makeEngine();
        e.downloads["dead.mp3"] = { key: "k", title: "Ep" };
        e.requestGoneCheck("dead.mp3");
        compare(tc.execLog.length, 1);
        verify(tc.execLog[0].indexOf(": POD_GONE 1;") === 0);
        // Decode hiccup, file still there: the row and its resume point stay.
        verify(e.handleExec(": POD_GONE 1;", ""));
        compare(e.downloadMeta("dead.mp3").key, "k");
        // Second check, file truly gone: now the row falls.
        e.requestGoneCheck("dead.mp3");
        verify(e.handleExec(": POD_GONE 2;", "__POD_GONE__"));
        compare(e.downloadMeta("dead.mp3"), null);
        e.destroy();
    }

    function test_a_stale_token_changes_nothing() {
        var e = makeEngine();
        e.downloads["ep.mp3"] = { key: "k" };
        verify(e.handleExec(": POD_RM 99;", "__POD_RM_OK__"));
        compare(e.downloadMeta("ep.mp3").key, "k");
        e.destroy();
    }

    function test_commands_that_are_not_ours_are_declined() {
        var e = makeEngine();
        compare(e.handleExec(": PW_PROBE;", "x"), false);
        compare(e.handleExec("plain command", ""), false);
        e.destroy();
    }

    // ── Slice 2: subscriptions and OPML, driven through the same mock ────

    function test_a_subscription_twin_over_https_is_one_show() {
        // http/https, a default port, a trailing slash — the same feed spelled
        // three ways used to be three subscriptions refreshing three times.
        var e = makeEngine();
        verify(e.addPodcastSub("Show A", "Author", "", "http://a.example/feed"));
        verify(e.isPodcastSubscribed("https://a.example/feed/"));
        verify(e.isPodcastSubscribed("HTTP://A.EXAMPLE:80/feed"));
        compare(e.addPodcastSub("Show A again", "", "", "https://a.example/feed/"), false);
        compare(JSON.parse(e.cfg.podcastSubs).length, 1);
        e.destroy();
    }

    function test_a_twin_spelling_can_also_unsubscribe() {
        // The star reads isPodcastSubscribed and its click hands the SAME url
        // to removePodcastSub. While the first matched feed keys and the second
        // raw strings, a show found under its other spelling showed a lit star
        // whose click did nothing — no row matched, and nothing said so.
        var e = makeEngine();
        verify(e.addPodcastSub("Show A", "Author", "", "http://a.example/feed"));
        verify(e.isPodcastSubscribed("https://a.example/feed/"));
        e.removePodcastSub("https://a.example/feed/");
        compare(e.isPodcastSubscribed("http://a.example/feed"), false);
        compare(e.subsModel.count, 0);
        e.destroy();
    }

    function test_subscriptions_survive_a_save_load_roundtrip() {
        var e = makeEngine({ podcastSubs: "[]" });
        verify(e.addPodcastSub("Show A", "Author", "", "https://a.example/feed"));
        compare(e.subsModel.count, 1);
        var e2 = makeEngine({ podcastSubs: e.cfg.podcastSubs });
        e2.loadSubs();
        compare(e2.subsModel.count, 1);
        compare(e2.subsModel.get(0).feedUrl, "https://a.example/feed");
        verify(e2.isPodcastSubscribed("https://a.example/feed"));
        e2.removePodcastSub("https://a.example/feed");
        compare(e2.subsModel.count, 0);
        e.destroy(); e2.destroy();
    }

    function test_a_disallowed_feed_url_never_becomes_a_subscription() {
        var e = makeEngine({ podcastSubs: "[]" });
        compare(e.addPodcastSub("Evil", "", "", "file:///etc/passwd"), false);
        compare(e.addPodcastSub("Evil", "", "", "javascript:x"), false);
        compare(e.subsModel.count, 0);
        e.destroy();
    }

    function test_the_hundredth_subscription_is_the_last() {
        var e = makeEngine({ podcastSubs: "[]" });
        for (var i = 0; i < 105; i++)
            e.addPodcastSub("S" + i, "", "", "https://h" + i + ".example/f");
        compare(e.subsModel.count, 100);
        e.destroy();
    }

    function test_opml_import_subscribes_each_gated_feed() {
        var e = makeEngine({ podcastSubs: "[]" });
        var opml = '<?xml version="1.0"?><opml version="2.0"><body>'
                 + '<outline text="One" xmlUrl="https://one.example/rss"/>'
                 + '<outline text="Bad" xmlUrl="ftp://nope.example/x"/>'
                 + '</body></opml>';
        verify(e.handleExec(": OPML_IMPORT;", opml));
        compare(e.subsModel.count, 1);
        compare(e.subsModel.get(0).feedUrl, "https://one.example/rss");
        e.destroy();
    }

    function test_opml_export_ack_speaks_once_with_the_path() {
        var e = makeEngine({ podcastSubs: "[]" });
        var told = [];
        e.app.notify = function(t, x, i) { told.push(t + "|" + x); };
        e._opmlExportPath = "/home/x/subs.opml";
        verify(e.handleExec(": OPML_EXPORT;", "__OPML_OK__"));
        compare(told.length, 1);
        verify(told[0].indexOf("/home/x/subs.opml") !== -1);
        verify(e.handleExec(": OPML_EXPORT;", ""));   // kirjutus ebaõnnestus
        compare(told.length, 2);
        e.destroy();
    }

    // ── Slice 3a: the download pipeline through the same mock ────────────

    function test_a_failed_download_frees_the_slot_and_names_the_reason() {
        // A curl that came back without __POD_OK__ used to throw on the
        // failure branch (it read a stderr nothing declared) before the slot
        // was cleared — one 404 and no episode downloaded again until the
        // widget restarted. The handler must finish, free the slot and tell.
        var e = makeEngine();
        e.app._podUrlFile = "/run/x/url";
        e.app._sanitizeDeviceName = function(s) { return s; };
        e.podcastEpisodesTitle = "Show"; e.podcastEpisodesFor = "https://f.example/rss";
        e.downloadEpisode("Ep 1", "https://h.example/e1.mp3", "g1");
        verify(e.handleExec(": POD_URL;", "__POD_URL_OK__"));
        verify(e._podDownloadKey !== "");
        verify(e.handleExec(": POD_DL;", "", "curl: (22) The requested URL returned error: 404"));
        compare(e._podDownloadKey, "");
        compare(e._podDownloadTitle, "");
        verify(e._podDownloadMeta === null);
        verify(tc.notified.some(function(n) { return n.indexOf("Episode download failed") === 0; }));
        e.destroy();
    }

    function test_a_download_stages_url_then_curl_then_writes_the_ledger() {
        var e = makeEngine();
        e.app._podUrlFile = "/run/x/url";
        e.app._sanitizeDeviceName = function(s) { return s; };
        e.podcastEpisodesTitle = "Show"; e.podcastEpisodesFor = "https://f.example/rss";
        e.downloadEpisode("Ep 1", "https://h.example/e1.mp3", "g1");
        compare(tc.execLog.length, 1);
        verify(tc.execLog[0].indexOf(": POD_URL;") === 0);
        verify(e.handleExec(": POD_URL;", "__POD_URL_OK__"));
        compare(tc.execLog.length, 2);
        verify(tc.execLog[1].indexOf(": POD_DL;") === 0);
        verify(tc.execLog[1].indexOf("curl") !== -1);
        verify(e.handleExec(": POD_DL;", "__POD_OK__"));
        var fn = e.fileForKey(e.podcastFileName ? "" : "");  // ledger via key:
        verify(e.downloadMeta(Object.keys(e.downloads)[0]).show === "Show");
        compare(e._podDownloadKey, "");
        // The landed file's silence scan is the engine's OWN call. Asserted on
        // the command the engine emits, not on a stand-in hung off the mock:
        // the mock used to carry a _podScanStart of its own, which is exactly
        // what let `app._podScanStart` — a name app never had — pass here.
        verify(tc.execLog[2].indexOf(": POD_SCAN;") === 0);
        verify(tc.execLog[2].indexOf("Podcasts/") !== -1);
        e.destroy();
    }

    function test_a_finished_download_lets_the_next_one_start() {
        // The scan call sits between the finished download and the queue, so a
        // throw there stopped the line: one episode landed and nothing after it
        // moved until the widget restarted, with nothing on screen to say so.
        var e = makeEngine();
        e.app._podUrlFile = "/run/x/url";
        e.podcastEpisodesTitle = "Show"; e.podcastEpisodesFor = "https://f.example/rss";
        e.downloadEpisode("Ep 1", "https://h.example/e1.mp3", "g1");
        e.downloadEpisode("Ep 2", "https://h.example/e2.mp3", "g2");
        compare(e._podDlQueue.length, 1);           // second one waits its turn
        verify(e.handleExec(": POD_URL;", "__POD_URL_OK__"));
        verify(e.handleExec(": POD_DL;", "__POD_OK__"));
        compare(e._podDlQueue.length, 0);           // …and the line moved
        compare(e._podDownloadTitle, "Ep 2");       // …onto the waiting episode
        e.destroy();
    }

    function test_a_failed_url_stage_frees_the_slot_and_tells_once() {
        var e = makeEngine();
        e.app._podUrlFile = "/run/x/url";
        e.app._sanitizeDeviceName = function(s) { return s; };
        e.downloadEpisode("Ep", "https://h.example/e.mp3", "g");
        verify(e.handleExec(": POD_URL;", "__POD_URL_FAIL__"));
        compare(e._podDownloadKey, "");
        compare(tc.notified.length, 1);
        e.destroy();
    }

    function test_the_same_episode_is_never_queued_twice() {
        var e = makeEngine();
        e.app._podUrlFile = "/run/x/url";
        e.app._sanitizeDeviceName = function(s) { return s; };
        e.downloadEpisode("A", "https://h.example/a.mp3", "ga");   // slot
        e.downloadEpisode("B", "https://h.example/b.mp3", "gb");   // queue
        e.downloadEpisode("B", "https://h.example/b.mp3", "gb");   // duplikaat
        compare(e._podDlQueue.length, 1);
        e.destroy();
    }

    // ── Slice 3b: the per-episode memories and the scan round-trip ───────

    function test_the_up_next_queue_toggles_and_survives_a_reload() {
        var e = makeEngine({ podcastUpNext: "[]" });
        e._loadPodUpNext();
        // Adding needs a gated url; toggle returns nothing, so assert on state.
        e.podcastQueueToggle({ key: "k1", title: "Ep", show: "S", url: "https://h.example/e.mp3" });
        verify(e.podcastQueueHas("k1"));
        var e2 = makeEngine({ podcastUpNext: e.cfg.podcastUpNext });
        e2._loadPodUpNext();
        verify(e2.podcastQueueHas("k1"));
        e2.podcastQueueToggle({ key: "k1" });
        compare(e2.podcastQueueHas("k1"), false);
        e.destroy(); e2.destroy();
    }

    function test_played_marks_roundtrip_and_tick_the_rev() {
        var e = makeEngine({ podcastPlayed: "{}" });
        e._loadPodPlayed();
        var r0 = e._podPlayedRev;
        e.markEpisodePlayed("kA");
        verify(e.isEpisodePlayed("kA"));
        verify(e._podPlayedRev > r0);
        e.toggleEpisodePlayed("kA");
        compare(e.isEpisodePlayed("kA"), false);
        e.destroy();
    }

    function test_the_scan_ack_writes_the_ledger_and_hands_midplay_to_the_app() {
        var e = makeEngine();
        var handed = [];
        e.app.applyFreshScan = function(sf, sil, chs) { handed.push(sf); };
        e.downloads["ep.mp3"] = { key: "k", title: "Ep" };
        e._podScanStart("ep.mp3");
        compare(tc.execLog.length, 1);
        verify(tc.execLog[0].indexOf(": POD_SCAN;") === 0);
        var out = "[silencedetect @ x] silence_start: 10.5\n"
                + "[silencedetect @ x] silence_end: 12.7 | silence_duration: 2.2\n"
                + "__CHAPTERS__{}";
        verify(e.handleExec(": POD_SCAN;", out));
        verify(e.downloads["ep.mp3"].sil !== undefined);
        compare(handed.length, 1);
        compare(handed[0], "ep.mp3");
        e.destroy();
    }

    // A subscribed show with everything that is filed under its feed: the
    // last episode seen, its speed and a downloaded file.
    readonly property string deadFeed: "https://dead.example/rss"
    readonly property string freshFeed: "https://new.example/rss"
    property var movedFeeds: []

    function subscribedEngine() {
        var e = makeEngine({ podcastSubs: JSON.stringify([
            { title: "Tech Talk", author: "A", art: "", feedUrl: deadFeed }]) });
        e.loadSubs();
        e.seen[deadFeed] = "seen-key";
        e._podSpeeds = { "https://dead.example/rss": 1.5 };
        e.downloads["Ep [0badf00d].mp3"] = { key: "k", feed: deadFeed };
        tc.movedFeeds = [];
        e.feedMoved.connect(function(from, to) { tc.movedFeeds.push(from + " -> " + to); });
        return e;
    }

    function test_a_refused_feed_does_not_rewrite_the_subscription_data() {
        return [
            { tag: "403", status: 403 },
            { tag: "401", status: 401 },
            { tag: "a web page", status: 200 },
            { tag: "400", status: 400 }
        ];
    }

    function test_a_refused_feed_does_not_rewrite_the_subscription(data) {
        // One 403 from a show's host, and iTunes knowing one show of that
        // name elsewhere, used to move the subscription there for good.
        var e = subscribedEngine();
        var subsBefore = e.cfg.podcastSubs;
        e._podFeedAdopt(deadFeed, freshFeed, data.status);
        compare(e.subsModel.get(0).feedUrl, deadFeed);
        compare(e.cfg.podcastSubs, subsBefore);
        compare(e.seen[deadFeed], "seen-key");
        compare(e.seen[freshFeed], undefined);
        compare(e._podSpeeds[deadFeed], 1.5);
        compare(e._podSpeeds[freshFeed], undefined);
        compare(e.downloads["Ep [0badf00d].mp3"].feed, deadFeed);
        compare(tc.movedFeeds.length, 0);
        e.destroy();
    }

    function test_a_feed_that_is_gone_takes_the_subscription_with_it_data() {
        return [{ tag: "404", status: 404 }, { tag: "410", status: 410 }];
    }

    function test_a_feed_that_is_gone_takes_the_subscription_with_it(data) {
        var e = subscribedEngine();
        e._podFeedAdopt(deadFeed, freshFeed, data.status);
        compare(e.subsModel.get(0).feedUrl, freshFeed);
        compare(JSON.parse(e.cfg.podcastSubs)[0].feedUrl, freshFeed);
        compare(e.seen[freshFeed], "seen-key");
        compare(e.seen[deadFeed], undefined);
        compare(e._podSpeeds[freshFeed], 1.5);
        compare(e._podSpeeds[deadFeed], undefined);
        compare(e.downloads["Ep [0badf00d].mp3"].feed, freshFeed);
        compare(tc.movedFeeds, [deadFeed + " -> " + freshFeed]);
        e.destroy();
    }

    property url asThePlayerHoldsIt

    function test_the_engine_spells_a_ledger_file_like_the_folder_model() {
        // Every download is called "Title [8hex].ext". The folder model
        // writes the brackets as %5B and %5D and the engine left them bare,
        // so an episode the widget started by itself (the next one in a
        // show, Up next, a podcast alarm) was not the one its own row and
        // its own Play button were looking at.
        var e = makeEngine();
        var want = "file:///home/x/Music/OnAir/Podcasts/Episode 12 %5B3f1c9a7e%5D.mp3";
        compare(e._podFileUrl("Episode 12 [3f1c9a7e].mp3"), want);
        // The player hands the same string back.
        asThePlayerHoldsIt = e._podFileUrl("Episode 12 [3f1c9a7e].mp3");
        compare(asThePlayerHoldsIt.toString(), want);
        compare(e._podFileUrl("100% #7 {a}^b [00c0ffee].mp3"),
                "file:///home/x/Music/OnAir/Podcasts/100%25 %237 %7Ba%7D%5Eb %5B00c0ffee%5D.mp3");
        e.destroy();
    }

    function test_a_playing_url_in_either_spelling_finds_its_ledger_row() {
        var names = ["Episode 12 [3f1c9a7e].mp3", "100% #7 {a}^b [00c0ffee].mp3"];
        var e = makeEngine();
        for (var i = 0; i < names.length; i++) e.downloads[names[i]] = { key: "k" + i };
        for (var j = 0; j < names.length; j++)
            compare(e._podFileOfUrl(e._podFileUrl(names[j])), names[j]);
        // A URL written before this, brackets bare, is still that file.
        compare(e._podFileOfUrl("file:///home/x/Music/OnAir/Podcasts/Episode 12 [3f1c9a7e].mp3"),
                "Episode 12 [3f1c9a7e].mp3");
        e.destroy();
    }

    function test_clearplaying_retires_the_whole_identity_as_one_unit() {
        // Four player-death sites used to spell these seven by hand; one
        // of them once drifted and the stale raw URL turned an episode
        // row into a stop button. One clear, one unit, forever.
        var e = makeEngine();
        e._podPlayingKey = "k1";
        e._podPlayingUrl = "https://a.example/ep.mp3";
        e._podPlayingRawUrl = "https://a.example/EP.mp3";
        e._podPlayingArt = "art.png";
        e._podPlayingShow = "Show";
        e._podSilCur = [[1, 2]];
        e._podChaptersCur = [[0, "Intro"]];
        e.clearPlaying();
        compare(e._podPlayingKey, "");
        compare(e._podPlayingUrl, "");
        compare(e._podPlayingRawUrl, "");
        compare(e._podPlayingArt, "");
        compare(e._podPlayingShow, "");
        compare(e._podSilCur.length, 0);
        compare(e._podChaptersCur.length, 0);
        e.destroy();
    }

}
