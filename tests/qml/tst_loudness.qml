// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Loudness against stand-ins for the widget, the config, StreamKind, the
// timeshift engine and the player: what factor the output is given and
// when it moves, who is listened to and when, and what is left behind when
// a reading is ended.
import QtQuick
import QtTest

import "../../package/contents/ui" as Ui
import "../../package/contents/ui/LoudLogic.js" as LL

TestCase {
    id: tc
    name: "Loudness"

    readonly property string pop: "https://stream.example.org/pop"
    readonly property string jazz: "https://cdn.example.net/jazz?token=abc123"
    // A station at -8 LUFS comes down ten decibels, one at -12 six.
    readonly property real ten: Math.pow(10, -10 / 20)
    readonly property real six: Math.pow(10, -6 / 20)

    Component { id: loudComp; Ui.Loudness {} }

    Component {
        id: appComp
        QtObject {
            property var execLog: []
            property int seqN: 40
            // The real facade puts an export after the sentinel, so an ack
            // never equals the command that was sent.
            function exec(cmd) {
                var m = /^(:[^;]*;\s*)/.exec(String(cmd));
                execLog.push(m[1] + "export LC_ALL=C LANGUAGE=C; " + String(cmd).slice(m[1].length));
            }
            function nextSeq() { return ++seqN; }
            property string _icyUrlFile: "/run/user/1000/arp-icy-src-7"
            property string _currentOrigUrl: ""
            property string _previewUrl: ""
            property string _podPlayingKey: ""
            property bool _podStarting: false
            property int _volumeOverridePct: -1
            property bool _wantsPlaying: true
            property bool _tsPaused: false
            property string _healPendingUrl: ""
            property string _healBackupFor: ""
            property bool recording: false
            property bool _casting: false
            property bool _castLocalPlay: false
            property bool playing: false
            function isPlaying() { return playing; }
            // The relay's tap translated back to its station, as main.qml does it.
            property string tap: "http://127.0.0.1:34567/"
            property string tapOf: ""
            function _icyStreamTarget(src) { return String(src) === tap ? tapOf : String(src); }
        }
    }

    Component { id: cfgComp; QtObject { property string servers: "[]"; property string stationLoudness: "{}"; property bool evenLoudness: true } }
    Component { id: kindComp; QtObject { property bool busy: false } }
    Component { id: engineComp; QtObject { property string bufPath: "" } }
    Component { id: playerComp; QtObject { property url source } }

    function rows(hosts) {
        return JSON.stringify(hosts.map(function(h) { return { "name": "N", "hostname": h, "favicon": "", "active": true }; }));
    }

    // A widget with pop and jazz saved and the option on; readings: address -> LUFS, taken now.
    function rig(readings) {
        var r = { app: appComp.createObject(tc), cfg: cfgComp.createObject(tc), kind: kindComp.createObject(tc),
                  engine: engineComp.createObject(tc), player: playerComp.createObject(tc) };
        var m = "{}", u;
        for (u in readings) m = LL.withAnswer(m, u, readings[u], Date.now() / 1000);
        r.cfg.servers = rows([pop, jazz]);
        r.cfg.stationLoudness = m;
        r.l = loudComp.createObject(tc, { app: r.app, cfg: r.cfg, kind: r.kind, engine: r.engine, player: r.player });
        return r;
    }

    // What every start in main.qml does: the row is named, the player is
    // stopped and emptied, and then given the stream. It plays a moment later.
    function start(r, row, src) {
        r.app._currentOrigUrl = row;
        r.app.playing = false;
        r.player.source = "";
        r.player.source = src || row;
    }
    function plays(r) { r.app.playing = true; }
    function sounding(r, row) { start(r, row); plays(r); }

    // Walk the reading that is out from its write to the helper's answer.
    function answer(r, out) {
        var n = r.app.execLog.length;
        verify(n > 0 && r.app.execLog[n - 1].indexOf(": LD_URL;") === 0, "no reading is out")
        verify(r.l.handleExec(r.app.execLog[n - 1], "__LD_URL_OK__\n"))
        compare(r.app.execLog.length, n + 1)
        verify(r.app.execLog[n].indexOf(": LD_RUN;") === 0)
        verify(r.l.handleExec(r.app.execLog[n], out))
    }
    function kept(r, url) { return LL.lufsAt(r.cfg.stationLoudness, r.cfg.servers, url); }
    function still(r) { tryVerify(function() { return !r.l.easing; }, 4000) }

    // ── the factor ──────────────────────────────────────────────────────

    function test_a_loud_station_starts_at_its_factor() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        compare(r.l.gain, 1)
        start(r, pop);
        // In place before the player plays, and not on its way there.
        fuzzyCompare(r.l.gain, ten, 0.0005)
        verify(!r.l.easing)
        plays(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        verify(!r.l.easing)
        compare(r.l.subject, pop)
    }

    function test_a_station_nothing_is_known_of_and_a_quiet_one_play_as_they_are() {
        var r = rig({ "https://cdn.example.net/jazz?token=abc123": -21.1 });
        sounding(r, pop);
        compare(r.l.gain, 1)
        sounding(r, jazz);
        compare(r.l.gain, 1)
    }

    function test_with_the_option_off_every_station_plays_as_it_is() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        r.cfg.evenLoudness = false;
        sounding(r, pop);
        compare(r.l.gain, 1)
        compare(r.l.wanted, 0)
    }

    function test_a_switch_takes_the_new_stations_factor_with_the_new_station() {
        var r = rig({ "https://stream.example.org/pop": -8, "https://cdn.example.net/jazz?token=abc123": -12 });
        sounding(r, pop);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        // main.qml names the new row while the old station still sounds,
        // and stops the player in the same breath.
        r.app._currentOrigUrl = jazz;
        r.app.playing = false;
        r.player.source = "";
        compare(r.l.gain, 1)
        r.player.source = jazz;
        fuzzyCompare(r.l.gain, six, 0.0005)
        verify(!r.l.easing, "the new station starts on its way to its factor")
        plays(r);
        fuzzyCompare(r.l.gain, six, 0.0005)
        // And back, through a player that was never seen to stop.
        r.app._currentOrigUrl = pop;
        r.player.source = "";
        r.player.source = pop;
        fuzzyCompare(r.l.gain, ten, 0.0005)
        verify(!r.l.easing)
    }

    function test_an_audition_an_episode_and_a_file_play_as_they_are() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        sounding(r, pop);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        // An audition, of the saved address itself.
        r.app._previewUrl = pop;
        start(r, pop); plays(r);
        compare(r.l.gain, 1)
        verify(!r.l.easing)
        r.app._previewUrl = "";
        sounding(r, pop);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        // An episode, which can be a stream; the row named last is stale then.
        r.app._podStarting = true;
        start(r, pop, "https://pod.example/e1.mp3"); plays(r);
        compare(r.l.gain, 1)
        r.app._podStarting = false; r.app._podPlayingKey = "feed|e1";
        compare(r.l.gain, 1)
        r.app._podPlayingKey = "";
        // A file of the listener's, and the wake-up tone.
        start(r, pop, "file:///home/me/Music/a.flac"); plays(r);
        compare(r.l.gain, 1)
        compare(r.l.subject, "")
    }

    function test_a_listener_behind_live_keeps_the_stations_factor() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        sounding(r, pop);
        r.engine.bufPath = "/run/user/1000/onair-timeshift-7/buf-41";
        // Paused into the buffer and resumed from it.
        r.app.playing = false; r.app._tsPaused = true;
        r.player.source = "";
        r.player.source = "file:///run/user/1000/onair-timeshift-7/buf-41";
        fuzzyCompare(r.l.gain, ten, 0.0005)
        r.app._tsPaused = false; plays(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        verify(!r.l.easing)
        // Nobody is listened to off a file.
        verify(!r.l.mayAsk)
        // The relay's tap is the station too.
        r.app.tapOf = pop;
        start(r, pop, r.app.tap); plays(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
    }

    function test_an_alarm_is_heard_in_full() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        r.l.easeMs = 200;
        // The alarm sets its level, then starts its station.
        r.app._volumeOverridePct = 40;
        sounding(r, pop);
        compare(r.l.gain, 1)
        verify(!r.l.waiting, "a station is listened to on an alarm's morning")
        // The listener is up and takes the volume: the level is theirs
        // again, and the station eases down to where it always plays.
        r.app._volumeOverridePct = -1;
        verify(r.l.easing)
        compare(r.l.gain, 1)
        still(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        // An alarm ringing over a station that already plays: up, eased.
        r.app._volumeOverridePct = 60;
        verify(r.l.easing)
        still(r);
        compare(r.l.gain, 1)
    }

    function test_the_factor_stands_aside_while_a_device_plays_along() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        r.l.easeMs = 200;
        // Started together with a device: this computer plays in full from the first sound.
        r.app._casting = true; r.app._castLocalPlay = true;
        sounding(r, pop);
        compare(r.l.gain, 1)
        verify(!r.l.easing)
        // The device stops and this computer plays on: down, eased.
        r.app._casting = false;
        verify(r.l.easing)
        compare(r.l.gain, 1)
        still(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        // A device joins a station that plays here: up, eased.
        r.app._casting = true;
        verify(r.l.easing)
        fuzzyCompare(r.l.gain, ten, 0.0005)
        still(r);
        compare(r.l.gain, 1)
        // A station started here with no device is cut as ever, whatever the multi-room switch stands at.
        r.app._casting = false;
        sounding(r, pop);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        verify(!r.l.easing)
    }

    function test_a_station_is_still_read_while_a_device_plays_along() {
        var r = rig({});
        r.app._casting = true; r.app._castLocalPlay = true;
        sounding(r, pop);
        verify(r.l.waiting)
        r.l._begin();
        answer(r, "-8.0\n");
        // The number is kept, and nothing moves while the device is there.
        compare(kept(r, pop), -8)
        compare(r.l.gain, 1)
        verify(!r.l.easing)
        // It is there when the device has gone.
        r.l.easeMs = 200;
        r.app._casting = false;
        still(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
    }

    function test_a_reading_that_arrives_under_a_listener_is_eased_in() {
        var r = rig({});
        compare(r.l.easeMs, 8000)
        sounding(r, pop);
        r.l._begin();
        answer(r, "-8.0\n");
        compare(kept(r, pop), -8)
        compare(r.l.wanted, -10)
        // Nothing has moved yet: there is no step at the answer.
        verify(r.l.easing)
        compare(r.l.gain, 1)
        // Ten decibels in eight seconds, at one pace all the way: 1.25 dB a
        // second, half a decibel between two looks 400 ms apart, and five
        // of the ten gone at half time. (Counted in amplitude the first
        // half would take 3.6 dB and the last second 2.)
        var db = function() { return 20 * Math.log(r.l.gain) / Math.LN10; };
        var last = 0, biggest = 0, looks = 0, half = 1;
        while (r.l.easing && looks < 40) {
            wait(400); looks++;
            biggest = Math.max(biggest, last - db());
            verify(db() <= last + 1e-9, "the station came up on its way down")
            last = db();
            if (looks === 10) half = last;
        }
        verify(looks >= 18 && looks <= 24, "eased over " + (looks * 0.4) + " seconds")
        verify(biggest < 1.2, "a step of " + biggest + " dB")
        verify(half < -4.2 && half > -5.8, "after four seconds it stood at " + half + " dB")
        fuzzyCompare(r.l.gain, ten, 0.0005)
        compare(r.l.cutNow, -10)
    }

    function test_a_late_answer_is_kept_and_moves_nothing_that_plays() {
        var r = rig({ "https://cdn.example.net/jazz?token=abc123": -12 });
        sounding(r, pop);
        r.l._begin();
        // The listener moves on before the helper is done.
        sounding(r, jazz);
        fuzzyCompare(r.l.gain, six, 0.0005)
        answer(r, "-8.0\n");
        compare(kept(r, pop), -8)
        fuzzyCompare(r.l.gain, six, 0.0005)
        verify(!r.l.easing)
        // Its next start has the number.
        start(r, pop);
        fuzzyCompare(r.l.gain, ten, 0.0005)
    }

    function test_the_option_ticked_under_a_playing_station_is_eased() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        r.cfg.evenLoudness = false;
        r.l.easeMs = 300;
        sounding(r, pop);
        compare(r.l.gain, 1)
        r.cfg.evenLoudness = true;
        verify(r.l.easing)
        compare(r.l.gain, 1)
        still(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        r.cfg.evenLoudness = false;
        verify(r.l.easing)
        fuzzyCompare(r.l.gain, ten, 0.0005)
        // Ticked again half way: on from where it stands, not from an end.
        wait(150);
        var mid = r.l.gain;
        verify(mid > ten && mid < 1, "half way up it stood at " + mid)
        r.cfg.evenLoudness = true;
        verify(r.l.easing)
        verify(Math.abs(r.l.gain - mid) < 0.05, "it jumped from " + mid + " to " + r.l.gain)
        still(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        // With nothing playing there is nobody to ease it for.
        r.app.playing = false;
        r.cfg.evenLoudness = false;
        compare(r.l.gain, 1)
        verify(!r.l.easing)
    }

    function test_a_new_source_ends_an_ease_where_it_was_going() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        r.cfg.evenLoudness = false;
        sounding(r, pop);
        r.cfg.evenLoudness = true;
        verify(r.l.easing)
        // A stall recovery restarts the same station mid-ease.
        r.app.playing = false;
        r.player.source = "";
        r.player.source = pop;
        verify(!r.l.easing)
        fuzzyCompare(r.l.gain, ten, 0.0005)
    }

    function test_a_station_that_moved_keeps_its_factor_and_is_listened_to_again() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        var there = "https://new.example.org/pop";
        r.l.easeMs = 200;
        sounding(r, pop);
        // The heal plays the new address under the old row first.
        r.app._healPendingUrl = there;
        r.app.playing = false; r.player.source = ""; r.player.source = there; plays(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        verify(!r.l.mayAsk, "a stream from an address on trial is listened to as the saved one")
        // Then the row moves: its name first, the list a line later.
        r.app._healPendingUrl = "";
        r.app._currentOrigUrl = there;
        r.cfg.servers = JSON.stringify([{ "name": "N", "hostname": there, "prev": pop }, { "name": "N", "hostname": jazz }]);
        still(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        compare(r.l.subject, there)
        // The new address is read for itself, and the old number goes on serving until then.
        verify(r.l.waiting)
        r.l._begin();
        verify(r.app.execLog[0].indexOf("printf '%s' '" + there + "'") !== -1)
        answer(r, "-12.0\n");
        compare(kept(r, there), -12)
        still(r);
        fuzzyCompare(r.l.gain, six, 0.0005)
    }

    // ── who is listened to, and when ────────────────────────────────────

    function test_a_station_is_listened_to_once_it_has_sounded_for_a_while() {
        var r = rig({});
        compare(r.l.settleMs, 10000)
        r.l.settleMs = 400;
        start(r, pop);
        verify(!r.l.waiting, "the count runs before the station sounds")
        plays(r);
        verify(r.l.waiting)
        wait(250);
        compare(r.app.execLog.length, 0)
        // The same station from a new source, here the relay's tap handed
        // to a player that is not stopped first: the count starts again.
        r.app.tapOf = pop;
        r.player.source = r.app.tap;
        verify(r.l.mayAsk)
        wait(250);
        compare(r.app.execLog.length, 0, "asked 250 ms after a new source")
        tryVerify(function() { return r.app.execLog.length === 1; }, 1000)
        verify(r.app.execLog[0].indexOf(": LD_URL;") === 0)
        verify(r.app.execLog[0].indexOf("printf '%s' '" + pop + "' > '/run/user/1000/arp-icy-src-7.loud41'") !== -1)
        answer(r, "-9.6\n");
        // The helper was handed the file and the seconds, never the address.
        verify(r.app.execLog[1].indexOf("loudness.py' '/run/user/1000/arp-icy-src-7.loud41' 20 ") !== -1)
        verify(r.app.execLog[1].indexOf("example.org") === -1)
        compare(kept(r, pop), -9.6)
        // Known now: nobody is connected to a second time.
        wait(600);
        compare(r.app.execLog.length, 2)
    }

    function test_two_starts_in_a_row_ask_about_the_one_that_stayed() {
        var r = rig({});
        r.l.settleMs = 300;
        sounding(r, pop);
        wait(150);
        sounding(r, jazz);
        wait(200);
        compare(r.app.execLog.length, 0, "the first station was asked about after the listener left it")
        tryVerify(function() { return r.app.execLog.length === 1; }, 1000)
        verify(r.app.execLog[0].indexOf("printf '%s' '" + jazz + "'") !== -1)
    }

    function test_the_address_listened_to_is_the_one_that_plays() {
        var r = rig({});
        // A better bitrate was picked for the row, and the relay carries it.
        r.app.tapOf = "https://edge7.example.org/pop-320";
        start(r, pop, r.app.tap); plays(r);
        r.l._begin();
        verify(r.app.execLog[0].indexOf("printf '%s' 'https://edge7.example.org/pop-320' > ") !== -1, r.app.execLog[0])
        answer(r, "-8.0\n");
        // And the number is the row's.
        compare(kept(r, pop), -8)
        compare(LL.lufsAt(r.cfg.stationLoudness, "[]", "https://edge7.example.org/pop-320"), null)
    }

    function test_nobody_is_listened_to_when_the_rules_say_no() {
        var r = rig({});
        sounding(r, pop);
        verify(r.l.waiting)
        var off = [["_tsPaused", true, false], ["recording", true, false], ["_volumeOverridePct", 40, -1],
                   ["_healPendingUrl", "https://x.example/a", ""], ["_healBackupFor", pop, ""], ["playing", false, true],
                   ["_previewUrl", pop, ""], ["_currentOrigUrl", "https://unsaved.example/x", pop]];
        for (var i = 0; i < off.length; i++) {
            r.app[off[i][0]] = off[i][1];
            verify(!r.l.waiting, off[i][0])
            r.l._begin();
            compare(r.app.execLog.length, 0, off[i][0])
            r.app[off[i][0]] = off[i][2];
            verify(r.l.waiting, off[i][0] + " back")
        }
        r.cfg.evenLoudness = false;
        verify(!r.l.waiting)
        r.l._begin();
        compare(r.app.execLog.length, 0)
    }

    function test_the_question_what_the_stream_is_goes_first() {
        var r = rig({});
        sounding(r, pop);
        r.kind.busy = true;
        r.l._begin();
        compare(r.app.execLog.length, 0)
        verify(r.l.waiting, "nobody looks again once that question is over")
        r.kind.busy = false;
        r.l._begin();
        compare(r.app.execLog.length, 1)
    }

    function test_one_reading_at_a_time() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        compare(r.app.execLog.length, 1)
        r.l._begin();
        compare(r.app.execLog.length, 1, "asked again while the first was out")
        // Another station meanwhile waits its turn, and gets it at the answer.
        sounding(r, jazz);
        r.l._begin();
        compare(r.app.execLog.length, 1)
        verify(r.l.waiting)
        answer(r, "-8.0\n");
        verify(r.l.waiting)
        r.l._begin();
        compare(r.app.execLog.length, 3)
        verify(r.app.execLog[2].indexOf("printf '%s' '" + jazz + "' > '/run/user/1000/arp-icy-src-7.loud42'") !== -1)
    }

    function test_a_reading_that_never_came_home_does_not_stand_in_the_way_for_good() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        verify(r.l.handleExec(r.app.execLog[0], "__LD_URL_OK__\n"))
        // Inside the helper's own time it is waited for.
        r.l._askedAt = Date.now() - 50000;
        r.l._begin();
        compare(r.app.execLog.length, 2)
        // Past it, the reading is ended, by its own file, and the next look asks again.
        r.l._askedAt = Date.now() - 56000;
        r.l._begin();
        compare(r.app.execLog.length, 3)
        verify(r.app.execLog[2].indexOf(": LD_END;") === 0)
        verify(r.app.execLog[2].indexOf("rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 41") !== -1)
        verify(r.l.waiting)
        r.l._begin();
        compare(r.app.execLog.length, 4)
        verify(r.app.execLog[3].indexOf(".loud42'") !== -1)
    }

    // The map with these readings of pop, the newest of them taken `ago` seconds before now.
    function heard(r, readings, ago) {
        var e = {};
        e[pop] = [Math.floor(Date.now() / 1000) - ago, 0].concat(readings);
        r.cfg.stationLoudness = JSON.stringify(e);
    }

    function test_a_station_is_read_once_a_day_until_there_are_five() {
        var r = rig({ "https://stream.example.org/pop": -8 });
        r.l.easeMs = 200;
        sounding(r, pop);
        // Read today: however often it is started, it is not connected to again.
        r.l._begin();
        compare(r.app.execLog.length, 0)
        // The advert case. Yesterday's reading was the advert, today's is the programme.
        heard(r, [-8], 86400 + 5);
        fuzzyCompare(r.l.gain, ten, 0.0005)
        r.l._begin();
        compare(r.app.execLog.length, 1)
        answer(r, "-14.0\n");
        compare(LL.readingsAt(r.cfg.stationLoudness, pop), [-8, -14])
        // The quieter of the two decides, and the station comes up to where it belongs, eased.
        compare(kept(r, pop), -14)
        verify(r.l.easing)
        still(r);
        fuzzyCompare(r.l.gain, Math.pow(10, -4 / 20), 0.0005)
        r.l._begin();
        compare(r.app.execLog.length, 2, "read twice in one day")
        // The third day hears the advert again, and two of three decide.
        heard(r, [-8, -14], 86400 + 5);
        r.l._begin();
        answer(r, "-8.0\n");
        compare(LL.readingsAt(r.cfg.stationLoudness, pop), [-8, -14, -8])
        compare(kept(r, pop), -8)
        still(r);
        fuzzyCompare(r.l.gain, ten, 0.0005)
    }

    function test_five_readings_are_enough_for_a_month() {
        var r = rig({});
        heard(r, [-8, -9, -10, -11, -12], 2 * 86400);
        sounding(r, pop);
        fuzzyCompare(r.l.gain, Math.pow(10, -8 / 20), 0.0005)
        r.l._begin();
        compare(r.app.execLog.length, 0, "a sixth reading two days after the fifth")
        // Thirty-one days on the five still play the station, and one more is asked for.
        heard(r, [-8, -9, -10, -11, -12], 31 * 86400);
        fuzzyCompare(r.l.gain, Math.pow(10, -8 / 20), 0.0005)
        r.l._begin();
        compare(r.app.execLog.length, 1)
        r.l.easeMs = 200;
        answer(r, "-13.0\n");
        // It takes the oldest one's place.
        compare(LL.readingsAt(r.cfg.stationLoudness, pop), [-9, -10, -11, -12, -13])
        compare(kept(r, pop), -11)
        still(r);
        fuzzyCompare(r.l.gain, Math.pow(10, -7 / 20), 0.0005)
        r.l._begin();
        compare(r.app.execLog.length, 2)
    }

    function test_an_answer_that_is_no_number_is_not_asked_for_again_today() {
        var none = ["", "\n", "-70.0\n", "nan\n", "Traceback (most recent call last):\n", "-9.6\n-9.7\n"];
        for (var i = 0; i < none.length; i++) {
            var r = rig({});
            sounding(r, pop);
            r.l._begin();
            answer(r, none[i]);
            compare(kept(r, pop), null, JSON.stringify(none[i]))
            compare(r.l.gain, 1)
            var e = JSON.parse(r.cfg.stationLoudness)[pop];
            compare(e.length, 2)
            compare(e[0], 0)
            verify(Math.abs(e[1] - Date.now() / 1000) < 5, "tried at " + e[1])
            verify(r.l.waiting)
            r.l._begin();
            compare(r.app.execLog.length, 2, "asked again after " + JSON.stringify(none[i]))
        }
        // A day later it is.
        var r2 = rig({}), was = {};
        was[pop] = [0, Math.floor(Date.now() / 1000) - 86400 - 5];
        r2.cfg.stationLoudness = JSON.stringify(was);
        sounding(r2, pop);
        r2.l._begin();
        compare(r2.app.execLog.length, 1)
        // A station silent on its second day keeps the first day's reading,
        // plays by it, and is left alone for the rest of that day.
        var r3 = rig({});
        heard(r3, [-8], 86400 + 5);
        sounding(r3, pop);
        r3.l._begin();
        answer(r3, "-70.0\n");
        compare(LL.readingsAt(r3.cfg.stationLoudness, pop), [-8])
        fuzzyCompare(r3.l.gain, ten, 0.0005)
        verify(!r3.l.easing)
        r3.l._begin();
        compare(r3.app.execLog.length, 2)
    }

    function test_a_reading_is_kept_for_a_saved_station_only() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        // Removed from the list while the helper listened.
        r.cfg.servers = rows([jazz]);
        answer(r, "-8.0\n");
        compare(r.cfg.stationLoudness, "{}")
        // And every write drops what the list no longer holds.
        var r2 = rig({ "https://stream.example.org/pop": -8, "https://cdn.example.net/jazz?token=abc123": -12 });
        r2.cfg.servers = rows([jazz, "https://third.example/x"]);
        sounding(r2, "https://third.example/x");
        r2.l._begin();
        answer(r2, "-15.0\n");
        compare(Object.keys(JSON.parse(r2.cfg.stationLoudness)), [jazz, "https://third.example/x"])
    }

    function test_a_list_of_five_hundred_keeps_every_reading() {
        var hosts = [], m = "{}", i, r = rig({});
        for (i = 0; i < 500; i++) { hosts.push("https://s" + i + ".example.org/live"); m = LL.withAnswer(m, hosts[i], -8, Date.now() / 1000 - i); }
        r.cfg.servers = rows(hosts.concat([pop]));
        r.cfg.stationLoudness = m;
        sounding(r, pop);
        r.l._begin();
        answer(r, "-9.0\n");
        compare(Object.keys(JSON.parse(r.cfg.stationLoudness)).length, 501)
        start(r, hosts[499]);
        fuzzyCompare(r.l.gain, ten, 0.0005)
    }

    // ── what is left behind ─────────────────────────────────────────────

    function test_a_stop_ends_the_reading_and_removes_its_file() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        verify(r.l.handleExec(r.app.execLog[0], "__LD_URL_OK__\n"))
        compare(r.app.execLog.length, 2)
        // Stop takes the order down; the player fades out a moment later.
        r.app._wantsPlaying = false;
        compare(r.app.execLog.length, 3)
        verify(r.app.execLog[2].indexOf(": LD_END;") === 0)
        verify(r.app.execLog[2].indexOf("rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 41") !== -1, r.app.execLog[2])
        verify(r.l.handleExec(r.app.execLog[2], ""))
        // The helper comes home with nothing, having been ended: that is no
        // verdict on the station, and nothing is written down.
        verify(r.l.handleExec(r.app.execLog[1], ""))
        compare(r.cfg.stationLoudness, "{}")
        compare(r.app.execLog.length, 3)
        // Even a number that slipped out is nobody's by then.
        verify(r.l.handleExec(r.app.execLog[1], "-8.0\n"))
        compare(r.cfg.stationLoudness, "{}")
    }

    function test_a_reading_ended_between_its_two_commands_leaves_no_file() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        compare(r.app.execLog.length, 1)
        // Stop, before the address is even written down. The end's rm can
        // run ahead of the write, so the write's own ack sweeps once more.
        r.app._wantsPlaying = false;
        compare(r.app.execLog.length, 2)
        verify(r.app.execLog[1].indexOf("rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 41") !== -1)
        verify(r.l.handleExec(r.app.execLog[0], "__LD_URL_OK__\n"))
        compare(r.app.execLog.length, 3, "the helper was started for a reading that was ended, or its file was left")
        verify(r.app.execLog[2].indexOf(": LD_END;") === 0)
        verify(r.app.execLog[2].indexOf("rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 41") !== -1)
        // A new reading meanwhile is not touched by the old write's sweep.
        r.app._wantsPlaying = true;
        r.l._begin();
        compare(r.app.execLog.length, 4)
        verify(r.app.execLog[3].indexOf(".loud42'") !== -1)
        verify(r.l.handleExec(r.app.execLog[0], "__LD_URL_OK__\n"))
        compare(r.app.execLog.length, 5)
        verify(r.app.execLog[4].indexOf("rm -f '/run/user/1000/arp-icy-src-7.loud41'; true # 41") !== -1, "swept the reading in flight")
        answer_from(r, 3, "-8.0\n");
        compare(kept(r, pop), -8)
    }

    // The reading whose write is execLog[at], walked to its answer.
    function answer_from(r, at, out) {
        var n = r.app.execLog.length;
        verify(r.l.handleExec(r.app.execLog[at], "__LD_URL_OK__\n"))
        compare(r.app.execLog.length, n + 1)
        verify(r.app.execLog[n].indexOf(": LD_RUN;") === 0)
        verify(r.l.handleExec(r.app.execLog[n], out))
    }

    function test_no_reading_starts_inside_a_stops_fade() {
        var r = rig({});
        sounding(r, pop);
        verify(r.l.waiting)
        // Stop: the order is down at once, the player plays on for the
        // length of the fade. The count must not run out inside it.
        r.app._wantsPlaying = false;
        verify(!r.l.waiting, "the count runs on under a station that was stopped")
        r.l._begin();
        compare(r.app.execLog.length, 0, "a station was connected to after Stop")
        r.app.playing = false;
        compare(r.app.execLog.length, 0)
    }

    function test_a_switch_lets_the_reading_finish_and_a_pause_or_a_file_ends_it() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        sounding(r, jazz);
        compare(r.app.execLog.length, 1, "a switch ended the reading")
        // A pause into the buffer and a file of the listener's take the order down.
        r.app._wantsPlaying = false;
        compare(r.app.execLog.length, 2)
        verify(r.app.execLog[1].indexOf(": LD_END;") === 0)
        // Nothing in flight: an order taken down again ends nothing.
        r.app._wantsPlaying = true;
        r.app._wantsPlaying = false;
        compare(r.app.execLog.length, 2)
    }

    function test_unticking_the_option_ends_the_reading() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        r.cfg.evenLoudness = false;
        compare(r.app.execLog.length, 2)
        verify(r.app.execLog[1].indexOf(": LD_END;") === 0)
        r.cfg.evenLoudness = true;
        compare(r.app.execLog.length, 2)
    }

    function test_an_address_that_could_not_be_written_down_is_no_reading() {
        var r = rig({});
        sounding(r, pop);
        r.l._begin();
        verify(r.l.handleExec(r.app.execLog[0], "__LD_URL_FAIL__\n"))
        compare(r.app.execLog.length, 1, "the helper was started without its file")
        compare(r.cfg.stationLoudness, "{}")
        // The disk's fault is not the station's: the next look asks again.
        r.l._begin();
        compare(r.app.execLog.length, 2)
    }

    function test_only_its_own_commands_are_answered() {
        var r = rig({});
        verify(!r.l.handleExec(": SK_URL; export LC_ALL=C LANGUAGE=C; true # 3", ""))
        verify(!r.l.handleExec(": SK_RUN; export LC_ALL=C LANGUAGE=C; true # 3", "ogg"))
        verify(!r.l.handleExec("rm -f x", ""))
        verify(!r.l.handleExec("", ""))
        verify(!r.l.handleExec(null, null))
        verify(!r.l.handleExec(undefined))
        verify(!r.l.handleExec(7, 7))
        // Its own, with nothing in flight, are taken and do nothing.
        verify(r.l.handleExec(": LD_RUN; export LC_ALL=C LANGUAGE=C; true # 3", "-8.0\n"))
        verify(r.l.handleExec(": LD_END; export LC_ALL=C LANGUAGE=C; true # 3", ""))
        compare(r.cfg.stationLoudness, "{}")
        compare(r.app.execLog.length, 0)
        // A write nobody waits for is swept by its own number.
        verify(r.l.handleExec(": LD_URL; export LC_ALL=C LANGUAGE=C; true # 3", "__LD_URL_OK__\n"))
        compare(r.app.execLog.length, 1)
        verify(r.app.execLog[0].indexOf("rm -f '/run/user/1000/arp-icy-src-7.loud3'; true # 3") !== -1)
    }

    function test_a_widget_that_knows_no_place_for_the_file_asks_nobody() {
        var r = rig({});
        r.app._icyUrlFile = "";
        sounding(r, pop);
        r.l._begin();
        compare(r.app.execLog.length, 0)
        verify(r.l.handleExec(": LD_URL; export LC_ALL=C LANGUAGE=C; true # 3", "__LD_URL_OK__\n"))
        compare(r.app.execLog.length, 0)
    }

    function test_an_address_with_a_quote_a_space_and_a_token_stays_one_word() {
        var odd = "https://x.example/it's live/a b?token=s3cret&u=$(id)";
        var r = rig({});
        r.cfg.servers = rows([odd]);
        sounding(r, odd);
        r.l._begin();
        verify(r.app.execLog[0].indexOf("printf '%s' 'https://x.example/it'\\''s live/a b?token=s3cret&u=$(id)' > ") !== -1, r.app.execLog[0])
        answer(r, "-8.0\n");
        verify(r.app.execLog[1].indexOf("s3cret") === -1 && r.app.execLog[1].indexOf("x.example") === -1)
        compare(kept(r, odd), -8)
        start(r, odd);
        fuzzyCompare(r.l.gain, ten, 0.0005)
    }

    function test_an_engine_without_its_neighbours_stands_at_one() {
        var r = { l: loudComp.createObject(tc, {}) };
        compare(r.l.gain, 1)
        compare(r.l.wanted, 0)
        compare(r.l.subject, "")
        verify(!r.l.mayAsk)
        r.l._begin();
        r.l._end();
        verify(!r.l.handleExec(": SK_RUN; true # 3", ""))
    }
}
