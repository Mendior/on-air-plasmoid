// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// A station stopped sending and the widget went on reading "playing" over a
// silent room for as long as anyone watched (2026-11-12: 170 s, the position
// at 29976 ms). This stands main.qml's _streamDied up, word for word as
// main.qml has it, beside the real StandWatch and around stand-ins that
// only record, and walks what the three watches hand it: a saved station
// whose position stands, a heal's audition, the same audition heard through
// the relay's tap, a preview, and an order that lapsed overnight. What it
// proves is this copy; test_invariants holds main.qml to the same lines.
//
// And an alarm whose station fell silent 8 s in rang on over 188 s of nothing
// (bench, the same day). The head of main.qml's _tryHealStation stands here
// too, down to the line that tells the alarm, beside the real AlarmEngine:
// the knock has its eight seconds, a station that has not answered by then
// ends in the tone, and one that has is watched as closely the next time.
import QtQuick
import QtMultimedia
import QtTest

import "../../package/contents/ui" as Ui

Item {
    id: root

    property var log: []
    property bool isError: false
    property string _healPendingUrl: ""
    property string _previewUrl: ""
    property bool _tsPaused: false
    property bool _casting: false
    property string _podPlayingKey: ""
    property bool lapsed: false
    // What the alarm engine and the heal road's head read and write.
    property bool _wantsPlaying: false
    property string _currentOrigUrl: ""
    property bool _castLocalPlay: false
    property int _healSeq: 0
    property var _healRun: null
    property int _previewSeq: 0
    property string _previewCodec: ""
    property string _previewUuid: ""
    property var faded: []
    readonly property var playMusicRef: playMusic
    readonly property var healTimerRef: healTimer
    readonly property var healRetryTimerRef: restTimer
    readonly property var netResumeTimerRef: restTimer
    readonly property var connectWatchdogRef: restTimer

    function i18n(s) { return s; }
    function notify(title, text, icon) {}
    function _podHandoff() {}
    function startWithFade(station) { faded.push(station); }
    function _recoveryWanted() { return root._wantsPlaying && !root._tsPaused && !root._casting; }
    // As main.qml hands the watch's question to the engine.
    function _alarmRings(nowMs) { return alarmEngine.rings(nowMs); }
    function _orderSubject() { return { "hostname": root._currentOrigUrl }; }

    function isPlaying() { return playMusic.playbackState === MediaPlayer.PlayingState; }
    function _orderLapsed() { log.push("asked"); return lapsed; }
    // As main.qml translates the tap back to the station it carries.
    function _icyStreamTarget(src) {
        var s = (src || "").toString();
        return (timeshift.relay && timeshift.relayUrl !== "" && s === timeshift.relayUrl) ? timeshift.streamUrl : s;
    }
    function _healClearPending() { log.push("pending cleared"); _healPendingUrl = ""; }
    function _healAdvance() { log.push("ladder advanced"); }
    function _previewRetryByIdentity() { log.push("identity road"); }

    QtObject {
        id: playMusic
        property url source
        property real position: 0
        property int playbackState: MediaPlayer.StoppedState
        property int mediaStatus: MediaPlayer.BufferingMedia
        signal errorOccurred()
        // A stopped player stands at 0, as the real one does (bench: "play 0 media 2 pos 0" after the hand-over).
        function stop() { root.log.push("stop"); playbackState = MediaPlayer.StoppedState; position = 0; }
    }
    QtObject {
        id: timeshift
        property bool relay: false
        property string relayUrl: ""
        property bool shifted: false
        property string streamUrl: ""
        function disarm() { root.log.push("buffer ended"); }
    }
    QtObject { id: errorTimer; function restart() { root.log.push("error shown"); } }
    QtObject { id: healTimer; function restart() { root.log.push("heal armed"); } function stop() {} }
    QtObject { id: restTimer; function stop() {} }

    function _streamDied() {
        var audition = root._healPendingUrl !== "" && _icyStreamTarget(playMusic.source) === root._healPendingUrl;
        playMusic.stop();
        isError = true;
        errorTimer.restart();
        if (audition) {
            root._healClearPending();
            root._healAdvance();
        } else if (root._previewUrl !== "") {
            _previewRetryByIdentity();
        } else {
            healTimer.restart();
        }
    }
    Ui.StandWatch { id: standWatch; app: root; engine: timeshift; player: playMusic }

    // The head of main.qml's _tryHealStation, to the line that tells the
    // alarm. What follows it there is the knock, the lookup and the ladder.
    function _tryHealStation() {
        if (!_recoveryWanted() || isPlaying()) return;
        if (_orderLapsed()) return;
        if (root._previewUrl !== "") return;
        var st = _orderSubject();
        if (st === null) return;
        var orig = (st.hostname || "").toString();
        if (orig === "" || orig.indexOf("file://") === 0 || orig !== root._currentOrigUrl) return;
        alarmEngine.stationFell(Date.now());
        log.push("knock");
    }
    Ui.AlarmEngine { id: alarmEngine; app: root; cfg: ({ "alarms": "[]" }) }

    TestCase {
        name: "StandRoads"

        readonly property string saved: "http://s1.radio.ee/live.mp3"

        function init() {
            playMusic.playbackState = MediaPlayer.StoppedState;
            playMusic.source = "";
            playMusic.position = 0;
            playMusic.mediaStatus = MediaPlayer.BufferingMedia;
            timeshift.relay = false;
            timeshift.relayUrl = "";
            timeshift.streamUrl = "";
            root._healPendingUrl = "";
            root._previewUrl = "";
            root.lapsed = false;
            root.isError = false;
            root.log = [];
            standWatch._strikes = 0;
            alarmEngine.standDown();
            root._wantsPlaying = false;
            root._currentOrigUrl = "";
            root._healSeq = 0;
            root.faded = [];
        }

        // The address starts to play, sounds to stopMs and stands.
        // Returns the second the watch handed it over at, -1 when it did not.
        function standsAfter(url, stopMs) {
            playMusic.position = 0;
            playMusic.source = url;
            playMusic.playbackState = MediaPlayer.PlayingState;
            var t0 = Date.now();
            for (var t = 5000; t <= 120000; t += 5000) {
                playMusic.position = Math.min(t, stopMs);
                if (standWatch._look(t0 + t)) return t / 1000;
            }
            return -1;
        }
        function standsAfterHalfAMinute(url) { return standsAfter(url, 29976); }

        // An alarm fired on the saved station so long ago, and nobody has answered it.
        function rings(agoMs) {
            root._wantsPlaying = true;
            root._currentOrigUrl = saved;
            alarmEngine._alarmStandingOrder = true;
            alarmEngine._alarmFiredAt = Date.now() - (agoMs || 0);
        }

        function test_an_alarm_station_that_falls_silent_for_good_ends_in_the_tone() {
            rings();
            // Sound to 7968 ms, then a connection held open with nothing in it: seen moving last at 10 s, handed over at 30.
            compare(standsAfter(saved, 7968), 30)
            compare(root.log, ["asked", "buffer ended", "stop", "error shown", "heal armed"])
            // The heal timer's turn.
            root.log = [];
            root._tryHealStation();
            compare(root.log, ["asked", "knock"])
            verify(alarmEngine._alarmFallbackArmed)
            verify(alarmEngine._fallbackRunningForTest())
            compare(alarmEngine._fallbackIntervalForTest(), 8000)
            compare(root.faded.length, 0)
            // The knock is answered by a connection that sends nothing, and the eight seconds pass.
            playMusic.playbackState = MediaPlayer.PlayingState;
            alarmEngine._alarmFellAt = Date.now() - 8000;
            alarmEngine._fallbackTrigger();
            compare(root.faded.length, 1)
            verify(String(root.faded[0].hostname).indexOf("alarm-fallback") !== -1)
            verify(!root._wantsPlaying)
            verify(root._healSeq > 0)
        }

        function test_an_alarm_station_that_answers_the_knock_plays_on_and_its_next_silence_is_known_as_fast() {
            rings();
            compare(standsAfter(saved, 7968), 30)
            root._tryHealStation();
            // The new connection has played three seconds and more when the check comes.
            playMusic.playbackState = MediaPlayer.PlayingState;
            playMusic.position = 4250;
            alarmEngine._alarmFellAt = Date.now() - 8000;
            alarmEngine._fallbackTrigger();
            compare(root.faded.length, 0)
            verify(root._wantsPlaying)
            verify(!alarmEngine._alarmFallbackArmed)
            // It falls silent again: handed over as fast as the first time, and the tone is asked about once more.
            compare(standsAfter(saved, 7968), 30)
            compare(standWatch._strikes, 0)
            root._tryHealStation();
            verify(alarmEngine._alarmFallbackArmed)
            compare(alarmEngine._fallbackIntervalForTest(), 8000)
        }

        function test_with_nobody_to_wake_no_tone_is_armed_and_the_second_silence_waits_twice_as_long() {
            root._wantsPlaying = true;
            root._currentOrigUrl = saved;
            compare(standsAfter(saved, 7968), 30)
            root.log = [];
            root._tryHealStation();
            compare(root.log, ["asked", "knock"])
            verify(!alarmEngine._alarmFallbackArmed)
            verify(!alarmEngine._fallbackRunningForTest())
            compare(standWatch._strikes, 1)
            compare(standsAfter(saved, 7968), 50)
        }

        function test_half_an_hour_after_the_fire_the_widget_is_a_radio_again() {
            // The alarm's station still plays and nobody pressed anything; the network drops an hour in.
            rings(3600000);
            verify(alarmEngine._alarmStandingOrder)
            compare(standsAfter(saved, 7968), 30)
            root.log = [];
            root._tryHealStation();
            compare(root.log, ["asked", "knock"])
            verify(!alarmEngine._alarmFallbackArmed)
            verify(!alarmEngine._fallbackRunningForTest())
            compare(alarmEngine._alarmFellAt, 0)
            compare(standWatch._strikes, 1)
            // One second short of the half hour it is still an alarm.
            init();
            rings(1799000 - 30000);
            compare(standsAfter(saved, 7968), 30)
            compare(standWatch._strikes, 0)
            root._tryHealStation();
            verify(alarmEngine._alarmFallbackArmed)
        }

        function test_the_heal_road_tells_the_alarm_only_about_a_station_it_takes_in_hand() {
            rings();
            // The player says it plays: the heal turns back at its door and the watch has not spoken.
            playMusic.source = saved;
            playMusic.playbackState = MediaPlayer.PlayingState;
            root._tryHealStation();
            // A lapsed order, a preview and another station's address are not the alarm's fall either.
            playMusic.playbackState = MediaPlayer.StoppedState;
            root.lapsed = true;
            root._tryHealStation();
            root.lapsed = false;
            root._previewUrl = "http://found.example/live.mp3";
            root._tryHealStation();
            root._previewUrl = "";
            root._currentOrigUrl = "";
            root._tryHealStation();
            verify(!alarmEngine._alarmFallbackArmed)
            compare(alarmEngine._alarmFellAt, 0)
            compare(root.log.indexOf("knock"), -1)
        }

        function test_a_saved_station_that_stands_is_stopped_and_handed_to_the_heal() {
            verify(!standWatch.ticking)
            compare(standsAfterHalfAMinute(saved), 50)
            compare(root.log, ["asked", "buffer ended", "stop", "error shown", "heal armed"])
            verify(root.isError)
            verify(!root.isPlaying())
            verify(!standWatch.ticking)
        }

        function test_a_heals_audition_that_stands_advances_the_ladder() {
            root._healPendingUrl = "http://new.radio.ee/live.mp3";
            compare(standsAfterHalfAMinute("http://new.radio.ee/live.mp3"), 50)
            compare(root.log, ["asked", "buffer ended", "stop", "error shown", "pending cleared", "ladder advanced"])
        }

        function test_an_audition_heard_through_the_tap_is_still_the_audition() {
            // The relay is not this watch's, so the connect watchdog's hand-over is made by hand.
            timeshift.relay = true;
            timeshift.relayUrl = "http://127.0.0.1:34567/";
            timeshift.streamUrl = "http://new.radio.ee/live.flac";
            root._healPendingUrl = "http://new.radio.ee/live.flac";
            playMusic.source = "http://127.0.0.1:34567/";
            playMusic.playbackState = MediaPlayer.PlayingState;
            verify(!standWatch.ticking)
            root._streamDied();
            compare(root.log, ["stop", "error shown", "pending cleared", "ladder advanced"])
        }

        function test_a_preview_found_dead_takes_the_identity_road() {
            // A preview is not watched here either; the other two watches hand it over.
            root._previewUrl = "http://found.example/live.mp3";
            playMusic.source = "http://found.example/live.mp3";
            playMusic.playbackState = MediaPlayer.PlayingState;
            verify(!standWatch.ticking)
            root._streamDied();
            compare(root.log, ["stop", "error shown", "identity road"])
        }

        function test_another_stations_pending_address_is_not_this_ones_audition() {
            root._healPendingUrl = "http://new.radio.ee/live.mp3";
            compare(standsAfterHalfAMinute(saved), 50)
            compare(root.log, ["asked", "buffer ended", "stop", "error shown", "heal armed"])
        }

        function test_an_order_that_lapsed_overnight_is_left_to_its_own_door() {
            root.lapsed = true;
            compare(standsAfterHalfAMinute(saved), -1)
            // Asked at every look past the twenty seconds, and nothing else done.
            verify(root.log.length > 0)
            for (var i = 0; i < root.log.length; i++) compare(root.log[i], "asked")
            verify(root.isPlaying())
            verify(!root.isError)
        }

        function test_a_stream_that_plays_on_is_never_handed_over() {
            playMusic.source = saved;
            playMusic.playbackState = MediaPlayer.PlayingState;
            var t0 = Date.now();
            for (var t = 5000; t <= 3600000; t += 5000) {
                playMusic.position = t;
                verify(!standWatch._look(t0 + t))
            }
            compare(root.log.length, 0)
            verify(standWatch.ticking)
        }
    }
}
