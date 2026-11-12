// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The alarm engine's scheduling half, driven through a mock app: list
// round-trips, the 30 s tick's three verdicts (wait / fire / missed), the
// same-minute pile-up, the zone retime, and the keep-awake inhibit shell.
// Since the second slice the FIRE paths live here too, and the tests drive
// their verdicts through the mocked facade — the exact scenarios the ear
// caught on 2026-08-10 are pinned below.
import QtQuick
import QtTest
import "../../package/contents/ui"
import "../../package/contents/ui/RetryLogic.js" as RL
import "../../package/contents/ui/AlarmLogic.js" as AL

TestCase {
    id: tc
    name: "AlarmEngine"

    property var execLog: []
    property var notified: []
    property var faded: []          // startWithFade orders, in sequence
    property var podPlays: []
    property var timerLog: []
    property int tzCalls: 0
    property int seq: 0
    // On the CASE, not in the mock: the app object is copied through the
    // required-property seam (tst_syncengine's header explains), so a flag
    // inside it would split into twins the closures cannot see.
    property bool playingNow: false
    property var engRef: null
    property var firingSeen: null

    function i18n(s) {
        var out = s;
        for (var i = 1; i < arguments.length; i++) out = out.replace("%" + i, arguments[i]);
        return out;
    }

    Component { id: engineComp; AlarmEngine {} }

    function makeEngine(cfgOverrides) {
        tc.execLog = []; tc.notified = []; tc.faded = []; tc.podPlays = [];
        tc.timerLog = []; tc.tzCalls = 0; tc.seq = 0; tc.playingNow = false;
        tc.engRef = null; tc.firingSeen = null;
        var cfg = { alarms: "[]" };
        for (var k in (cfgOverrides || {})) cfg[k] = cfgOverrides[k];
        function tmr(name) {
            return { stop: function() { tc.timerLog.push(name + ".stop"); },
                     restart: function() { tc.timerLog.push(name + ".restart"); } };
        }
        var app = {
            exec: function(c) { tc.execLog.push(c); },
            nextSeq: function() { return ++tc.seq; },
            notify: function(t, x, i) { tc.notified.push({ title: t, text: x }); },
            _schedApplyTzChange: function(now) { tc.tzCalls++; },
            _mprisRunDir: "/run/user/1000",
            _mprisId: "42",
            // ── the fire half's facade, every lever a mock ──
            cancelSleepTimer: function() {},
            _podHandoff: function() {},
            startWithFade: function(o) { tc.faded.push(o); },
            _castSetVolume: function(v) {},
            targetVolume: function() { return 0.4; },
            isPlaying: function() { return tc.playingNow; },
            _healClearPending: function() {},
            playPodcastEpisode: function(u, t, k, sh, ar, fe) {
                tc.podPlays.push(u);
                // The caller's badge, read at the exact moment main's
                // playLocalFile would read it in production.
                tc.firingSeen = tc.engRef ? tc.engRef._alarmFiring : null;
            },
            _podFileUrl: function(f) { return "file:///pods/" + f; },
            _volumeOverridePct: -1,
            _castCurrentUrl: "x", _previewUrl: "", _previewCodec: "", _previewUuid: "",
            _previewSeq: 0, _currentOrigUrl: "", _currentUnwrappedUrl: "",
            _currentResolvedUrl: "", _wantsPlaying: false, _healRetryAttempts: 0,
            lastPlay: -1, _orphanOrder: null, _healSeq: 0, _healRun: null,
            _casting: false, _castLocalPlay: false,
            _podDownloads: ({}), _podPlayed: ({}),
            healRetryTimerRef: tmr("healRetry"), netResumeTimerRef: tmr("netResume"),
            healTimerRef: tmr("heal"), connectWatchdogRef: tmr("watchdog"),
            playMusicRef: { source: "", mediaStatus: 0, position: 0 },
            playMusicOutputRef: { volume: 0.1 },
            stationsModelRef: { count: 0, get: function(i) { return null; } }
        };
        return engineComp.createObject(tc, { app: app, cfg: cfg });
    }

    function _lastExec() { return tc.execLog[tc.execLog.length - 1]; }

    function test_add_persists_computes_nextrun_and_arms_the_holder() {
        var e = makeEngine();
        e.addAlarm("Radio", "https://s.example/stream", "", 7, 30, "daily", undefined, 55, true, "u1");
        compare(e.alarms.length, 1);
        verify(e.alarms[0].nextRun > Date.now());
        compare(e.alarms[0].volumePct, 55);
        verify(_lastExec().indexOf(": ALARM_INHIBIT;") === 0);
        // keepAwake ahead: the holder command actually takes the machine.
        verify(_lastExec().indexOf("systemd-inhibit") !== -1);
        // The kill of a previous holder stays identity-checked, never blind.
        verify(_lastExec().indexOf("systemd-inhibit.*On Air") !== -1);
        // Round-trips through config for the next session.
        var e2 = makeEngine({ alarms: e.cfg.alarms });
        e2._loadAlarms();
        compare(e2.alarms.length, 1);
        e.destroy(); e2.destroy();
    }

    function test_a_healed_station_moves_its_alarms() {
        // The alarm's copy of the address has to follow the station: the
        // list said "moved, saved", and the alarm rang the dead address
        // every morning for as long as it lived.
        var e = makeEngine();
        e.addAlarm("Rock FM", "https://old.example/live", "", 7, 0, "daily", undefined, 50, true, "u-1");
        e.addAlarm("Rock FM weekend", "https://old.example/live", "", 9, 0, "weekly", 6, 50, true, "u-1");
        e.addAlarm("Other", "https://other.example/live", "", 8, 0, "daily", undefined, 40, false, "");
        e.addAlarm("Show", "podcast:https://old.example/live", "", 6, 0, "daily", undefined, 40, false, "");
        verify(e.retargetStation("https://old.example/live", "https://new.example/live"));
        compare(e.alarms[0].url, "https://new.example/live");
        compare(e.alarms[1].url, "https://new.example/live");
        compare(e.alarms[2].url, "https://other.example/live");
        compare(e.alarms[3].url, "podcast:https://old.example/live");
        compare(e.alarms[0].station, "Rock FM");
        compare(e.alarms[0].uuid, "u-1");
        compare(JSON.parse(e.cfg.alarms)[1].url, "https://new.example/live");
        // Nothing to move is not a change, and junk moves nothing.
        verify(!e.retargetStation("https://nobody.example/x", "https://new.example/live"));
        verify(!e.retargetStation("", "https://new.example/live"));
        verify(!e.retargetStation("https://new.example/live", ""));
        verify(!e.retargetStation("https://new.example/live", "https://new.example/live"));
        e.destroy();
    }

    function test_a_healed_feed_moves_its_podcast_alarm() {
        // "The newest episode of this show" names the show by feed address.
        // When the podcast engine heals a feed to a new address, an alarm
        // still pointing at the old one would search a feed that stopped
        // existing and ring silence.
        var e = makeEngine();
        e.addAlarm("Show", "podcast:https://old.example/rss", "", 7, 30, "daily", undefined, 55, true, "");
        e.addAlarm("Radio", "https://s.example/stream", "", 8, 0, "daily", undefined, 40, false, "");
        verify(e.retargetPodcastFeed("https://old.example/rss", "https://new.example/rss"));
        compare(e.alarms[0].url, "podcast:https://new.example/rss");
        compare(e.alarms[1].url, "https://s.example/stream");
        verify(JSON.parse(e.cfg.alarms)[0].url === "podcast:https://new.example/rss");
        // A feed no alarm names is not a change and must not rewrite the file.
        verify(!e.retargetPodcastFeed("https://nobody.example/rss", "https://x.example/rss"));
        e.destroy();
    }

    function test_remove_saves_and_rearms() {
        var e = makeEngine();
        e.addAlarm("Radio", "https://s.example/stream", "", 7, 30, "once", 2, 40, false, "");
        tc.execLog = [];
        e.removeAlarm(0);
        compare(e.alarms.length, 0);
        compare(JSON.parse(e.cfg.alarms).length, 0);
        // No keep-awake left: the re-arm only sweeps the old holder away.
        verify(_lastExec().indexOf(": ALARM_INHIBIT;") === 0);
        verify(_lastExec().indexOf("systemd-inhibit --what") === -1);
        e.destroy();
    }

    function test_a_due_alarm_fires_through_the_facade_and_advances() {
        var e = makeEngine();
        e.addAlarm("Radio", "https://s.example/stream", "", 7, 30, "daily", 3, 40, false, "");
        var l = e.alarms.slice();
        l[0].nextRun = Date.now() - 1000;          // due just now
        e.alarms = l;
        e._alarmTick();
        compare(tc.tzCalls, 1);                    // zone check first, always
        compare(tc.faded.length, 1);               // the station started
        compare(tc.faded[0].name, "Radio");
        verify(e._alarmFallbackArmed);             // the net is up behind it
        // Advanced BEFORE the side effect: daily rolls a day ahead and the
        // entry cannot re-fire on the next tick.
        verify(e.alarms[0].nextRun > Date.now());
        tc.faded = [];
        e._alarmTick();
        compare(tc.faded.length, 0);
        e.destroy();
    }

    function test_a_missed_alarm_reports_and_a_once_entry_retires() {
        var e = makeEngine();
        e.addAlarm("Radio", "https://s.example/stream", "", 7, 30, "once", 3, 40, false, "");
        var l = e.alarms.slice();
        l[0].nextRun = Date.now() - 2 * 60 * 60 * 1000;   // two hours: past the 1 h grace
        e.alarms = l;
        e._alarmTick();
        compare(tc.faded.length, 0);                   // never fired late
        compare(tc.notified.length, 1);
        verify(tc.notified[0].title.indexOf("missed") !== -1);
        compare(e.alarms.length, 0);                   // once = retired
        e.destroy();
    }

    function test_two_due_at_once_fire_one_and_name_the_other() {
        var e = makeEngine();
        e.addAlarm("First", "https://a.example/s", "", 7, 30, "daily", 3, 40, false, "");
        e.addAlarm("Second", "https://b.example/s", "", 7, 30, "daily", 3, 40, false, "");
        var l = e.alarms.slice();
        l[0].nextRun = Date.now() - 2000;
        l[1].nextRun = Date.now() - 1000;
        e.alarms = l;
        tc.notified = [];
        e._alarmTick();
        compare(tc.faded.length, 1);
        compare(tc.faded[0].name, "First");            // list order wins
        // Two words go out: the fire's own toast and the pile-up notice
        // naming the loser — the LOSER must be named somewhere.
        compare(tc.notified.length, 2);
        var named = false;
        for (var n = 0; n < tc.notified.length; n++)
            if (tc.notified[n].text && tc.notified[n].text.indexOf("Second") !== -1) named = true;
        verify(named);
        e.destroy();
    }

    function test_applytzretime_retimes_and_saves() {
        var e = makeEngine();
        e.addAlarm("Radio", "https://s.example/stream", "", 7, 30, "daily", 3, 40, false, "");
        var l = e.alarms.slice();
        l[0].nextRun = Date.now() + 1000;              // wrong instant, near future
        e.alarms = l;
        var before = e.alarms[0].nextRun;
        e.applyTzRetime(Date.now());
        verify(e.alarms[0].nextRun !== before);        // retimed to the wall clock
        compare(JSON.parse(e.cfg.alarms)[0].nextRun, e.alarms[0].nextRun);
        e.destroy();
    }

    function test_applytzretime_is_harmless_on_empty() {
        var e = makeEngine();
        tc.execLog = [];
        e.applyTzRetime(Date.now());
        compare(tc.execLog.length, 0);                 // no arm, no save, no throw
        e.destroy();
    }

    // ── the fire half: tonight's scenarios, pinned for good ──────────────

    function _fireStation(e) {
        e._alarmFire({ station: "Radio", url: "https://s.example/stream",
                       favicon: "", uuid: "", volumePct: 55 });
    }

    function test_a_station_that_streamed_stands_the_tone_down() {
        // The 2026-08-10 23:08 false positive, pinned: playing=true,
        // position=24917, mediaStatus=4 (Buffering) — a live stream sits
        // in Buffering forever, and the tone must NOT replace it.
        var e = makeEngine();
        _fireStation(e);
        compare(tc.faded.length, 1);                    // the station went out
        verify(e._alarmFallbackArmed);
        tc.playingNow = true;
        e.app.playMusicRef.mediaStatus = 4;             // BufferingMedia
        e.app.playMusicRef.position = 24917;
        var seqBefore = e.app._healSeq;
        e._fallbackTrigger();
        compare(tc.faded.length, 1);                    // no tone on top
        compare(e.app._healSeq, seqBefore);             // nothing torn down
        verify(!e._alarmFallbackArmed);                 // the net is spent
        e.destroy();
    }

    function test_a_station_that_never_started_gets_the_tone_loudly() {
        var e = makeEngine();
        _fireStation(e);
        tc.playingNow = true;
        e.app.playMusicRef.mediaStatus = 4;
        e.app.playMusicRef.position = 800;              // never really began
        var seqBefore = e.app._healSeq;
        e._fallbackTrigger();
        compare(tc.faded.length, 2);                    // the tone took over
        verify(String(tc.faded[1].hostname).indexOf("alarm-fallback") !== -1);
        verify(e.app._healSeq > seqBefore);             // heal legs retired
        compare(e.app._wantsPlaying, false);            // standing order ended
        verify(tc.timerLog.indexOf("heal.stop") !== -1);
        verify(tc.timerLog.indexOf("watchdog.stop") !== -1);
        e.destroy();
    }

    // ── a station that falls silent after it has played ──────────────────
    // Bench, 2026-11-12: the station held its connection and sent nothing 8 s
    // into the alarm. The check 25 s after the fire read playing=true,
    // position=7968 and stood the tone down, and the heal road then knocked
    // 30, 82 and 165 s into a silence nothing ended.

    // The alarm fired, the station played, and the check at 25 s let it be.
    // (Passed by hand, so the timer the fire started is still running; the
    // interval is what tells a later arming from it.)
    function _rings(e) {
        _fireStation(e);
        e._alarmFiredAt = Date.now() - 60000;           // a minute ago
        tc.playingNow = true;
        e.app.playMusicRef.mediaStatus = 4;
        e.app.playMusicRef.position = 23760;
        e._fallbackTrigger();
        compare(tc.faded.length, 1);
        verify(!e._alarmFallbackArmed);
        compare(e._fallbackIntervalForTest(), 25000);
    }

    // The heal road stopped the player and has the station in its hands.
    function _falls(e, atMs) {
        tc.playingNow = false;
        e.app.playMusicRef.mediaStatus = 2;
        e.app.playMusicRef.position = 0;
        e.stationFell(atMs);
    }

    function test_a_station_that_falls_while_the_alarm_rings_has_the_tone_asked_about_again() {
        var e = makeEngine();
        _rings(e);
        var t0 = Date.now();
        _falls(e, t0);
        verify(e._alarmFallbackArmed);
        verify(e._fallbackRunningForTest());
        compare(e._fallbackIntervalForTest(), 8000);
        compare(e._alarmFellAt, t0);
        compare(tc.faded.length, 1);                    // nothing sounds yet: the knock has its time
        e.destroy();
    }

    function test_a_station_that_stays_silent_through_the_grace_ends_in_the_tone() {
        var e = makeEngine();
        _rings(e);
        _falls(e, Date.now() - 8000);
        // The knock went out and the connection hangs: the player says it plays, at nothing.
        tc.playingNow = true;
        e.app.playMusicRef.mediaStatus = 4;
        var seqBefore = e.app._healSeq;
        e._fallbackTrigger();
        compare(tc.faded.length, 2);
        verify(String(tc.faded[1].hostname).indexOf("alarm-fallback") !== -1);
        verify(e.app._healSeq > seqBefore);             // the heal road is retired, the tone is the last word
        compare(e.app._wantsPlaying, false);
        verify(!e._alarmFallbackArmed);
        compare(e._alarmFellAt, 0);
        e.destroy();
    }

    function test_a_station_that_is_back_inside_the_grace_keeps_the_tone_away() {
        var e = makeEngine();
        _rings(e);
        _falls(e, Date.now() - 8000);
        tc.playingNow = true;
        e.app.playMusicRef.mediaStatus = 4;
        e.app.playMusicRef.position = 4250;             // knocked 2.5 s after the fall, first sound 1.25 s on
        var seqBefore = e.app._healSeq;
        e._fallbackTrigger();
        compare(tc.faded.length, 1);                    // no tone over a station that sounds
        compare(e.app._healSeq, seqBefore);
        compare(e.app._wantsPlaying, true);
        verify(!e._alarmFallbackArmed);
        compare(e._alarmFellAt, 0);
        // And the next silence is asked about the same way.
        var t1 = Date.now();
        _falls(e, t1);
        verify(e._alarmFallbackArmed);
        verify(e._fallbackRunningForTest());
        compare(e._fallbackIntervalForTest(), 8000);
        compare(e._alarmFellAt, t1);
        e.destroy();
    }

    function test_a_new_connection_that_has_hardly_played_is_not_the_station_back() {
        var e = makeEngine();
        _rings(e);
        _falls(e, Date.now() - 8000);
        tc.playingNow = true;
        e.app.playMusicRef.mediaStatus = 5;             // a burst filled the buffer
        e.app.playMusicRef.position = 2400;
        e._fallbackTrigger();
        compare(tc.faded.length, 2);
        verify(String(tc.faded[1].hostname).indexOf("alarm-fallback") !== -1);
        e.destroy();
    }

    function test_a_check_that_comes_before_the_knock_had_its_time_waits_for_it() {
        // The station fell 22 s after the fire; the first check is 3 s away
        // and the knock has only just gone out.
        var e = makeEngine();
        _fireStation(e);
        var t0 = Date.now();
        _falls(e, t0);
        compare(e._fallbackIntervalForTest(), 25000);   // the check on its way keeps its time
        verify(e._fallbackRunningForTest());
        e._fallbackTrigger();
        compare(tc.faded.length, 1);                    // no verdict yet
        verify(e._alarmFallbackArmed);
        verify(e._fallbackRunningForTest());
        verify(e._fallbackIntervalForTest() > 7000 && e._fallbackIntervalForTest() <= 8000, e._fallbackIntervalForTest());
        compare(e._alarmFellAt, t0);
        // With the grace over the verdict is passed: nothing plays.
        e._alarmFellAt = Date.now() - 8000;
        e._fallbackTrigger();
        compare(tc.faded.length, 2);
        e.destroy();
    }

    function test_a_station_dead_from_the_first_second_gets_the_tone_at_the_first_check_as_before() {
        var e = makeEngine();
        _fireStation(e);
        e._alarmFiredAt = Date.now() - 25000;
        _falls(e, Date.now() - 22000);                  // refused at once; the heal road took it 2.5 s later
        compare(e._fallbackIntervalForTest(), 25000);
        e._fallbackTrigger();
        compare(tc.faded.length, 2);
        verify(String(tc.faded[1].hostname).indexOf("alarm-fallback") !== -1);
        e.destroy();
    }

    function test_a_second_fall_inside_the_grace_moves_nothing() {
        var e = makeEngine();
        _rings(e);
        var t0 = Date.now();
        _falls(e, t0);
        _falls(e, t0 + 3000);                           // the knock was refused and the heal road is back
        compare(e._alarmFellAt, t0);
        compare(AL.wakeGraceLeftMs(e._alarmFellAt, t0 + 8000), 0);
        e.destroy();
    }

    function test_a_station_alarm_rings_from_its_fire_for_half_an_hour_or_until_it_is_answered() {
        var e = makeEngine();
        verify(!e.rings(Date.now()));
        var before = Date.now();
        _fireStation(e);
        var fired = e._alarmFiredAt;
        verify(fired >= before && fired <= Date.now());
        verify(e.rings(fired));
        verify(e.rings(fired + 1800000));
        verify(!e.rings(fired + 1800001));
        verify(!e.rings(fired - 1));                    // a clock set back
        e.standDown();
        compare(e._alarmFiredAt, 0);
        verify(!e.rings(fired + 1000));
        // The order alone does not ring, nor a fire time without the order.
        e._alarmStandingOrder = true;
        verify(!e.rings(fired + 1000));
        e._alarmStandingOrder = false;
        e._alarmFiredAt = fired;
        verify(!e.rings(fired + 1000));
        e.destroy();
    }

    function test_half_an_hour_after_the_fire_a_fall_is_the_heal_roads_alone() {
        var e = makeEngine();
        _rings(e);
        e._alarmFiredAt = Date.now() - 1800001;
        verify(e._alarmStandingOrder);                  // nobody answered, and the order still stands
        _falls(e, Date.now());
        verify(!e._alarmFallbackArmed);
        compare(e._alarmFellAt, 0);
        compare(e._fallbackIntervalForTest(), 25000);
        e._fallbackTrigger();
        compare(tc.faded.length, 1);
        // A second inside the half hour it is still the alarm's.
        e._alarmFiredAt = Date.now() - 1799000;
        _falls(e, Date.now());
        verify(e._alarmFallbackArmed);
        compare(e._fallbackIntervalForTest(), 8000);
        e.destroy();
    }

    function test_with_no_station_alarm_ringing_a_fall_arms_nothing() {
        var e = makeEngine();
        _falls(e, Date.now());                          // ordinary listening
        verify(!e._alarmFallbackArmed);
        verify(!e._fallbackRunningForTest());
        compare(e._alarmFellAt, 0);
        _rings(e);
        e.standDown();                                  // "I'm up"
        _falls(e, Date.now());
        verify(!e._alarmFallbackArmed);
        verify(!e._fallbackRunningForTest());
        compare(e._alarmFellAt, 0);
        e._fallbackTrigger();
        compare(tc.faded.length, 1);
        e.destroy();
        // The chime by choice and a podcast alarm leave no standing order.
        e = makeEngine();
        e._alarmFire({ station: "Chime", url: "chime:", volumePct: 40 });
        _falls(e, Date.now());
        compare(e._alarmFellAt, 0);
        verify(!e._fallbackRunningForTest());
        e.destroy();
        e = makeEngine();
        e.app._podDownloads = { "ep1.mp3": { title: "Ep 1", key: "k1", show: "Show", art: "", feed: "https://f.example/rss", at: 2 } };
        e._alarmFire({ station: "Show", url: "podcast:https://f.example/rss", volumePct: 40 });
        var faded = tc.faded.length, plays = tc.podPlays.length;
        _falls(e, Date.now());
        compare(e._alarmFellAt, 0);
        compare(e._fallbackIntervalForTest(), 25000);
        compare(tc.faded.length, faded);
        compare(tc.podPlays.length, plays);
        e.destroy();
    }

    function test_standing_down_forgets_the_fall() {
        var e = makeEngine();
        _rings(e);
        _falls(e, Date.now() - 8000);
        e.standDown();
        compare(e._alarmFellAt, 0);
        verify(!e._alarmFallbackArmed);
        verify(!e._fallbackRunningForTest());
        e._fallbackTrigger();
        compare(tc.faded.length, 1);
        e.destroy();
    }

    function test_the_next_alarm_begins_without_the_last_ones_fall() {
        var e = makeEngine();
        _fireStation(e);
        _falls(e, Date.now());
        _fireStation(e);
        compare(e._alarmFellAt, 0);
        compare(e._fallbackIntervalForTest(), 25000);
        verify(e._fallbackRunningForTest());
        // So the first check is the old one: Buffered alone stands the tone down.
        tc.playingNow = true;
        e.app.playMusicRef.mediaStatus = 5;
        e.app.playMusicRef.position = 1200;
        e._fallbackTrigger();
        compare(tc.faded.length, 2);                    // the two fires; no tone
        e.destroy();
    }

    function test_a_firing_alarm_outlives_a_spent_retry_budget() {
        // The hard constraint, driven end to end rather than grepped: a real
        // alarm fires through the engine, and ITS flag — not a literal — is
        // what the retry decision reads. The budget added for issue #13 stops
        // ordinary listening after three tries; a wake-up whose station dies
        // at 07:00 must still be knocking at 07:30, with the switch off and
        // the budget long spent. Anything else is an alarm that does not ring.
        var e = makeEngine();
        _fireStation(e);
        verify(e._alarmStandingOrder);                  // the alarm raised it
        compare(e.app._wantsPlaying, true);

        // Every refusal the ladder owns, asked with the alarm's own flag.
        verify(RL.shouldKnock(false, e._alarmStandingOrder, 0, 3));
        verify(RL.shouldKnock(true, e._alarmStandingOrder, 99, 3));
        verify(RL.shouldKnock(false, e._alarmStandingOrder, 99, 1));

        // And once the sleeper says "I'm up", the exemption goes with it —
        // the flag must not outlive the order it qualifies.
        e.standDown();
        verify(!e._alarmStandingOrder);
        verify(!RL.shouldKnock(false, e._alarmStandingOrder, 99, 3));
        e.destroy();
    }

    function test_the_chime_choice_rides_its_own_road() {
        var e = makeEngine();
        e._alarmFire({ station: "Tone", url: "chime:", volumePct: 50 });
        compare(tc.faded.length, 1);
        verify(String(tc.faded[0].hostname).indexOf("alarm-fallback") !== -1);
        compare(e.app._volumeOverridePct, 50);
        verify(!e._alarmFallbackArmed);                 // the tone IS the tone
        verify(tc.execLog[tc.execLog.length - 1].indexOf(": ALARM_UNMUTE;") === 0);
        e.destroy();
    }

    function test_a_confirmed_cast_route_silences_the_tone() {
        var e = makeEngine();
        _fireStation(e);
        e.app._casting = true;
        e._alarmCastConfirmed = true;                   // a device SAID it plays
        e.app._castLocalPlay = false;
        e._fallbackTrigger();
        compare(tc.faded.length, 1);                    // no tone: the room rings elsewhere
        e.destroy();
    }

    function test_podcast_alarm_plays_newest_and_arms_the_net() {
        var e = makeEngine();
        e.app._podDownloads = { "ep1.mp3": { title: "Ep 1", key: "k1",
                                             show: "Show", art: "", feed: "https://f.example/rss",
                                             at: 2 } };
        e._alarmFire({ station: "Show", url: "podcast:https://f.example/rss", volumePct: 40 });
        compare(tc.podPlays.length, 1);
        verify(e._alarmFallbackArmed);
        compare(e._fallbackIntervalForTest(), 25000);
        e.destroy();
    }

    function test_a_podcast_alarm_with_nothing_on_disk_chimes_fast() {
        var e = makeEngine();
        e._alarmFire({ station: "Show", url: "podcast:https://f.example/rss", volumePct: 40 });
        compare(tc.podPlays.length, 0);
        // The tone starts in the same call, as on the chime's own road. It
        // used to be left to the net 1.2 s later, which a radio left on
        // overnight talked out of ringing.
        compare(tc.faded.length, 1);
        verify(String(tc.faded[0].hostname).indexOf("alarm-fallback") !== -1);
        verify(!e._alarmFallbackArmed);                 // the tone IS the tone
        verify(!e._fallbackRunningForTest());
        e.destroy();
    }

    function _toneStarts() {
        var n = 0;
        for (var i = 0; i < tc.faded.length; i++)
            if (String(tc.faded[i].hostname).indexOf("alarm-fallback") !== -1) n++;
        return n;
    }

    function test_a_podcast_alarm_with_nothing_on_disk_chimes_over_what_was_playing() {
        // Seen with the real engine: radio left on overnight, seven hours
        // in, and the alarm said "waking with the chime" while the radio
        // played on at 5 %. The tone waited behind a check for sound, and
        // anything more than five seconds into a stream counted as sound.
        var states = [[false, 0], [true, 0], [true, 5000], [true, 5001], [true, 60000],
                      [true, 7 * 3600 * 1000]];
        for (var s = 0; s < states.length; s++) {
            var e = makeEngine();
            tc.playingNow = states[s][0];
            e.app.playMusicRef.position = states[s][1];
            e._alarmFire({ station: "Show", url: "podcast:https://f.example/rss", volumePct: 70 });
            // Whatever net the engine keeps gets its turn too.
            e._fallbackTrigger();
            var at = "playing=" + states[s][0] + " position=" + states[s][1];
            compare(_toneStarts(), 1, at + ": the tone");
            compare(tc.podPlays.length, 0, at);
            compare(e.app._volumeOverridePct, 70, at + ": the alarm's own volume");
            verify(!e.app._wantsPlaying, at + ": last night's order still stands");
            e.destroy();
        }
    }

    function test_a_podcast_alarm_with_nothing_on_disk_says_so_once() {
        // In a silent room it sent two notices, and the second spoke of a
        // station that could not start. A podcast alarm has no station.
        var e = makeEngine();
        e._alarmFire({ station: "Show", url: "podcast:https://f.example/rss", volumePct: 40 });
        e._fallbackTrigger();
        compare(tc.notified.length, 1);
        compare(tc.notified[0].text, "No downloaded episode of Show was on disk — waking with the chime.");
        e.destroy();
        // An alarm that lost its show's name still says what happened.
        e = makeEngine();
        e._alarmFire({ url: "podcast:https://f.example/rss" });
        e._fallbackTrigger();
        compare(tc.notified.length, 1);
        compare(tc.notified[0].text, "No downloaded episode of the show was on disk — waking with the chime.");
        compare(_toneStarts(), 1);
        e.destroy();
    }

    function test_the_chime_of_a_podcast_alarm_comes_at_a_volume_that_wakes() {
        var asked = [[undefined, 40], [0, 40], [5, 15], [15, 15], [100, 100], [500, 100]];
        for (var i = 0; i < asked.length; i++) {
            var e = makeEngine();
            tc.playingNow = true;
            e.app.playMusicRef.position = 60000;
            e._alarmFire({ station: "Show", url: "podcast:https://f.example/rss", volumePct: asked[i][0] });
            compare(e.app._volumeOverridePct, asked[i][1], "asked " + asked[i][0]);
            compare(_toneStarts(), 1, "asked " + asked[i][0]);
            e.destroy();
        }
    }

    function test_an_unconfirmed_cast_never_gags_the_tone() {
        // The regression the confirmation flag exists for, in the negative
        // direction the suite lacked: a speaker unplugged overnight leaves
        // the optimistic casting flag up with no acknowledgement behind it
        // - the tone MUST still sound. Proven missing by a shadow mutation
        // that swapped the confirmed argument for the flag and passed.
        var e = makeEngine();
        _fireStation(e);
        e.app._casting = true;
        e.app._castLocalPlay = false;
        e._fallbackTrigger();
        compare(tc.faded.length, 2);
        verify(String(tc.faded[1].hostname).indexOf("alarm-fallback") !== -1);
        e.destroy();
    }

    function test_yesterdays_cast_proof_cannot_vouch_for_todays_alarm() {
        var e = makeEngine();
        e._alarmCastConfirmed = true;       // yesterday's __CAST_OK__
        _fireStation(e);                    // today's alarm
        verify(!e._alarmCastConfirmed);     // the fire spends the proof
        e.app._casting = true;
        e.app._castLocalPlay = false;
        e._fallbackTrigger();
        compare(tc.faded.length, 2);        // and it cannot gag today's tone
        e.destroy();
    }

    function test_the_podcast_fire_wears_the_callers_badge_around_the_play() {
        // playLocalFile stands the net down for every caller EXCEPT the
        // alarm itself - the badge must be up exactly during the play call
        // and down again after, crash or not (the finally).
        var e = makeEngine();
        tc.engRef = e;
        e.app._podDownloads = { "ep1.mp3": { title: "Ep 1", key: "k1",
                                             show: "Show", art: "", feed: "https://f.example/rss",
                                             at: 2 } };
        e._alarmFire({ station: "Show", url: "podcast:https://f.example/rss", volumePct: 40 });
        compare(tc.firingSeen, true);
        verify(!e._alarmFiring);
        e.destroy();
    }

    function test_the_station_fire_arms_the_real_timer() {
        // The behavioral tests drive _fallbackTrigger by hand; this one
        // proves the wiring - the fire must leave the actual Timer running
        // or no verdict ever gets passed at all.
        var e = makeEngine();
        verify(!e._fallbackRunningForTest());
        _fireStation(e);
        verify(e._fallbackRunningForTest());
        e.standDown();
        verify(!e._fallbackRunningForTest());
        e.destroy();
    }

    function test_standdown_disarms_the_net() {
        var e = makeEngine();
        _fireStation(e);
        verify(e._alarmFallbackArmed);
        e.standDown();
        verify(!e._alarmFallbackArmed);
        e._fallbackTrigger();
        compare(tc.faded.length, 1);                    // a spent net stays quiet
        e.destroy();
    }

    function test_handleexec_owns_only_the_inhibit_ack() {
        var e = makeEngine();
        verify(e.handleExec(": ALARM_INHIBIT; x", ""));
        compare(e.handleExec(": REC_URL; x", ""), false);
        compare(e.handleExec(": PW_DRIFT; x", ""), false);
        e.destroy();
    }
}
