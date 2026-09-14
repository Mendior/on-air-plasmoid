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
            _sanitizeDeviceName: function(s) { return s; }
        };
        return engineComp.createObject(tc, { app: app, cfg: cfg });
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
}
