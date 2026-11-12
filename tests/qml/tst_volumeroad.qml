// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The "Play on" menu's master row: its Volume slider and its Mute. Two
// reports stand behind this file. With the system default output selected
// and a television playing alone, the row turned this computer's master and
// the television heard nothing. And with this computer and a television
// playing together, the row on the default output moved this computer and
// left the television where it stood, while with an output pinned it moved
// both.
//
// This stands the row's own lines (FullRepresentation.qml) and main.qml's
// volume roads up around a room that only keeps its level and its mute, and
// devices that only write down what they are sent. No television was moved
// by any of it: what is asked of every case is which command went where,
// with which value. It proves this copy; test_invariants holds the two
// files to the same lines.
import QtQuick
import QtQuick.Controls as QQC2
import QtTest

import "../../package/contents/ui/CastLogic.js" as CastLogic
import "../../package/contents/ui/TransportLogic.js" as TransportLogic

Item {
    id: root
    width: 300
    height: 100

    QtObject {
        id: playMusicOutput
        property real volume: 0.8
        onVolumeChanged: root._ownMuted = TransportLogic.ownMute(root._ownMuted, false, volume)
    }
    QtObject { id: cfg; property string audioOutputDevice: ""; property int defaultVolume: 80 }
    // This computer's master as pactl has it. The widget only believes what it was last told.
    QtObject { id: room; property int pct: 60; property bool muted: false }
    property QtObject sync: QtObject {
        property bool _combineWantActive: false
        property bool _combineActive: false
        property var trims: ({})
        function trimOf(id) {
            var t = trims[id];
            return (typeof t === "number" && t >= 0.001 && t <= 1) ? t : 1.0;
        }
        function hasTrim(id) { return trims[id] !== undefined }
        // The device's own row in the menu; the engine debounces, this does not.
        // tst_syncengine asks the engine itself what "stored" keeps from the device.
        function setDeviceTrim(id, factor, stored) {
            var f = Math.max(stored === true ? 0.001 : 0.05, Math.min(1, factor));
            var m = {};
            for (var k in trims) m[k] = trims[k];
            if (f >= (stored === true ? 1 : 0.995)) delete m[id];
            else m[id] = stored === true ? f : Math.round(f * 100) / 100;
            trims = m;
            if (stored !== true && root.castTrimActive(id)) root.applyCastTrim(id);
        }
        function adoptTrim(key, factor) {
            if (trims[key] !== undefined) return;
            var f = Math.max(0.001, Math.min(1, factor));
            if (f >= 1) return;
            var m = {};
            for (var k in trims) m[k] = trims[k];
            m[key] = f;
            trims = m;
        }
    }

    property bool _casting: false
    property bool _castLocalPlay: false
    property var _castTargets: []
    // Who answered that it plays (CastLogic). Every device here has, unless a case says otherwise: who is asked
    // and what each answers is tst_castroads' walk, and init() puts this binding back.
    function everyonePlays() {
        var on = {};
        _castTargets.forEach(function (d) { on[d.uuid] = true; });
        return { "pending": {}, "on": on };
    }
    property var _castSession: everyonePlays()
    property int _pendingCastVolumePct: -1
    property int _pendingUserVolumePct: -1
    property bool _pendingUserVolumeStep: false
    property int _volumeOverridePct: -1
    property int _sinkMasterPct: 60
    property bool _sinkMasterMuted: false
    property bool _ownMuted: false
    property real _volumeBeforeSleepFade: -1

    // What the stand-ins saw.
    property var roomSets: []      // levels written to this computer's master
    property int roomMutes: 0      // times its mute was switched
    property var sent: []          // "<device> <level>", in the order sent
    property int castTimerRestarts: 0

    // ── stand-ins for pactl ──────────────────────────────────────────────
    function setSinkMaster(pct) {
        var p = Math.max(0, Math.min(100, Math.round(pct)));
        roomSets.push(p); _sinkMasterPct = p; room.pct = p;
        if (p > 0) { _sinkMasterMuted = false; room.muted = false; }
    }
    function toggleSinkMasterMute(tellDevices) {
        roomMutes++; room.muted = !room.muted;
        sinkAnswers("SINKVOL " + room.pct + " " + (room.muted ? "yes" : "no") + (tellDevices === true ? " devices" : ""));
    }
    // The two-second poll while the popup is open, and whatever moved the room from outside.
    function poll() { sinkAnswers("SINKVOL " + room.pct + " " + (room.muted ? "yes" : "no")) }

    // ── main.qml's own lines ─────────────────────────────────────────────
    function sinkAnswers(stdout) {
        var svM = (stdout || "").match(/SINKVOL (-?\d+) (yes|no)( devices)?/);
        if (svM) {
            var sv = parseInt(svM[1], 10);
            if (sv >= 0 && sv <= 200) root._sinkMasterPct = sv;
            root._sinkMasterMuted = svM[2] === "yes";
            if (svM[3] && root._casting) root._castSetVolume(root.castMaster());
        }
    }

    function targetVolume() {
        return TransportLogic.ownLevel(_pendingUserVolumePct, _volumeOverridePct, cfg.defaultVolume);
    }

    function masterRoadOf(dragRoad) {
        return TransportLogic.volumeRoad(_casting, _castLocalPlay, sync._combineWantActive || sync._combineActive,
                                         (cfg.audioOutputDevice || "") === "", dragRoad);
    }
    function castMaster() {
        return TransportLogic.castMaster(masterRoadOf(""), _sinkMasterPct, _sinkMasterMuted, _ownMuted, targetVolume());
    }

    function setUserVolume(v, fromStep) {
        var vol = Math.max(0, Math.min(1, v));
        playMusicOutput.volume = vol;
        _ownMuted = TransportLogic.ownMute(_ownMuted, true, vol);
        _pendingUserVolumeStep = fromStep === true;
        if (TransportLogic.muteDisplaces(_pendingUserVolumePct, vol)) cfg.defaultVolume = _pendingUserVolumePct;
        _pendingUserVolumePct = Math.round(vol * 100);
        if (_casting) _castSetVolume(castMaster());
    }

    function wheelStep(notch) {
        setUserVolume(TransportLogic.wheelLevel(playMusicOutput.volume, _volumeBeforeSleepFade, _pendingUserVolumePct, notch,
                                                _casting && !_castLocalPlay, targetVolume()), true);
    }

    // volumePersistTimer firing, a second after the last gesture.
    function saveTick() {
        if (root._pendingUserVolumePct > 0)
            cfg.defaultVolume = root._pendingUserVolumePct;
        root._pendingUserVolumePct = -1;
        root._volumeOverridePct = -1;
    }

    function _castSetVolume(v) {
        if (_castTargets.length === 0) return;
        _pendingCastVolumePct = Math.round(Math.max(0, Math.min(1, v)) * 100);
        castTimerRestarts++;
    }

    // What cast.py would be started with: each kind of device by its own command and address, the level last.
    function _castExec(tag, args) {
        var dlna = args[0] === "dlna-volume";
        var dev = _castTargets.filter(function (d) { return dlna ? d.location === args[1] : d.uuid === args[3]; })[0];
        var right = tag === "CAST_VOL" && dev !== undefined && (dlna ? dev.kind === "dlna"
            : args[0] === "volume" && dev.kind !== "dlna" && args[1] === dev.host && args[2] === dev.port);
        sent.push(right ? dev.uuid + " " + args[args.length - 1] : "wrong command: " + tag + " " + args.join(" "));
    }

    function _castTell(dev, master) {
        if (!CastLogic.plays(_castSession, dev.uuid)) return;
        var level = TransportLogic.deviceLevel(master, sync.trimOf(dev.uuid)).toFixed(3);
        if (dev.kind === "dlna") _castExec("CAST_VOL", ["dlna-volume", dev.location, level]);
        else _castExec("CAST_VOL", ["volume", dev.host, dev.port, dev.uuid, dev.deviceModel, level]);
    }

    function _castFlush() {
        if (_pendingCastVolumePct < 0 || _castTargets.length === 0) return;
        _castTargets.forEach(function (dev) { _castTell(dev, _pendingCastVolumePct / 100); });
        _castSession = CastLogic.owing(_castSession, _pendingCastVolumePct);
        _pendingCastVolumePct = -1;
    }

    // castVolumeTimer firing, 400 ms after the last level.
    function castTick() { root._castFlush() }

    function castTargetIndex(uuid) {
        for (var i = 0; i < _castTargets.length; i++)
            if (_castTargets[i].uuid === uuid) return i;
        return -1;
    }
    function castTrimActive(id) { return _casting && castTargetIndex(id) >= 0; }

    function applyCastTrim(uuid) {
        var ti = castTargetIndex(uuid);
        if (ti >= 0) _castTell(_castTargets[ti], castMaster());
    }

    // "This computer" in the menu, ticked or unticked; what starts and stops here is not this file's.
    function castToggleLocal() {
        if (_castTargets.length === 0) return;
        _castFlush();
        var was = masterRoadOf("");
        if (_castLocalPlay) {
            _castLocalPlay = false;
        } else {
            _castLocalPlay = true;
        }
        if (masterRoadOf("") !== was) _castTargets.forEach(function (d) {
            sync.setDeviceTrim(d.uuid, TransportLogic.rebalance(sync.trimOf(d.uuid), was, _sinkMasterPct, targetVolume()), true);
        });
    }

    // A joining device answers what level it stands at (CAST_ADOPT).
    function deviceAnswers(uuid, itsLevel) {
        if (sync.hasTrim(uuid)) return;
        var master = TransportLogic.castMaster(root.masterRoadOf(""), root._sinkMasterPct, false, false, root.targetVolume());
        var ratio = parseFloat(itsLevel) / Math.max(0.05, master);
        if (isFinite(ratio)) sync.adoptTrim(uuid, TransportLogic.balanceBelow(ratio));
    }

    // ── the row, as the output menu has it ───────────────────────────────
    Item {
        id: row
        anchors.fill: parent

        readonly property bool roomMode: root.masterRoadOf(masterVolumeSlider.dragRoad) === "sink"
        function gesture(kind, level) {
            var to = TransportLogic.masterGesture(kind, roomMode ? "sink" : "player", root._casting, root._castLocalPlay,
                                                  level, playMusicOutput.volume, root.targetVolume(), root._ownMuted)
            if (to.sink >= 0) root.setSinkMaster(to.sink)
            if (to.sinkMute) root.toggleSinkMasterMute(to.castFollows)
            if (to.player >= 0) root.setUserVolume(to.player)
            if (to.cast >= 0) root._castSetVolume(to.cast)
        }
        readonly property real shownVol:
            roomMode && root._sinkMasterPct >= 0
            ? Math.min(1, root._sinkMasterPct / 100.0)
            : playMusicOutput.volume
        readonly property bool shownMuted: (roomMode && root._sinkMasterMuted) || shownVol <= 0

        // The speaker button's onClicked.
        function muteClicked() { gesture("mute", 0) }

        QQC2.Slider {
            id: masterVolumeSlider
            x: 10; y: 30; width: 200; height: 30
            from: 0
            to: 1
            stepSize: 0.05
            value: parent.shownVol
            property string dragRoad: ""
            onPressedChanged: dragRoad = pressed ? (parent.roomMode ? "sink" : "player") : ""
            onMoved: parent.gesture("move", value)
        }
    }

    TestCase {
        name: "VolumeRoad"
        when: windowShown

        readonly property var tv: ({ "kind": "dlna", "uuid": "tv", "location": "http://tv.example/desc.xml" })
        readonly property var kitchen: ({ "kind": "cast", "uuid": "kitchen", "host": "192.0.2.7", "port": 8009 })

        function init() {
            cfg.audioOutputDevice = ""; cfg.defaultVolume = 80
            playMusicOutput.volume = 0.8
            room.pct = 60; room.muted = false
            root.sync._combineWantActive = false; root.sync._combineActive = false; root.sync.trims = ({})
            root._casting = false; root._castLocalPlay = false; root._castTargets = []
            root._castSession = Qt.binding(function() { return root.everyonePlays() })
            root._pendingCastVolumePct = -1; root._pendingUserVolumePct = -1; root._volumeOverridePct = -1
            root._sinkMasterPct = 60; root._sinkMasterMuted = false; root._ownMuted = false; root._volumeBeforeSleepFade = -1
            root.roomSets = []; root.roomMutes = 0; root.sent = []
            root.castTimerRestarts = 0
            // slide() below writes the value, which takes the row's binding with it.
            masterVolumeSlider.value = Qt.binding(function() { return row.shownVol })
        }
        function cleanup() { if (masterVolumeSlider.pressed) mouseRelease(masterVolumeSlider, 5, 15) }

        // The slider moved by hand to a level, as a click on the track or a key does it.
        function slide(v) { masterVolumeSlider.value = v; masterVolumeSlider.moved() }
        function casting(alone) { root._castTargets = [tv]; root._casting = true; root._castLocalPlay = !alone }
        function pinned() { cfg.audioOutputDevice = "alsa_output.usb-0d8c.analog-stereo" }
        function level() { return Math.round(playMusicOutput.volume * 100) }
        function last() { return root.sent.length ? root.sent[root.sent.length - 1] : "nothing sent" }

        // ── this computer alone, a device alone: as they were ────────────

        function test_this_computer_alone_on_the_default_sink_turns_the_rooms_knob() {
            slide(0.25)
            compare(root.roomSets, [25])
            compare(level(), 80, "the stream's own volume moved with the room's")
            row.muteClicked()
            compare(root.roomMutes, 1)
            compare(root.castTimerRestarts, 0)
            castTick()
            compare(root.sent, [])
        }

        function test_this_computer_alone_on_a_pinned_output_turns_its_own_stream() {
            pinned()
            slide(0.25)
            compare(level(), 25)
            compare(root.roomSets, [])
            row.muteClicked()
            compare(level(), 0)
            compare(root.roomMutes, 0)
            castTick()
            compare(root.sent, [])
        }

        function test_a_television_playing_alone_is_what_the_row_turns() {
            // The system default selected, cast only.
            casting(true)
            compare(row.roomMode, false)
            slide(0.25)
            compare(root.roomSets, [], "the slider turned this computer's master")
            castTick()
            compare(root.sent, ["tv 0.250"])
            row.muteClicked()
            compare(root.roomMutes, 0, "the mute switched this computer's master")
            castTick()
            compare(root.sent, ["tv 0.250", "tv 0.000"])
            compare(room.pct, 60)
            compare(room.muted, false)
        }

        function test_a_ticked_device_that_refused_the_stream_is_not_turned_by_the_row() {
            // The television plays; the kitchen speaker is ticked, refused the station and may be
            // playing a radio of its own. A Ruark in that place went from 10 to 6 (2026-11-12).
            casting(true)
            root._castTargets = [tv, kitchen]
            root._castSession = ({ "pending": {}, "on": { "tv": true }, "refused": { "kitchen": true } })
            slide(0.25)
            castTick()
            compare(root.sent, ["tv 0.250"])
            row.muteClicked()
            castTick()
            compare(root.sent, ["tv 0.250", "tv 0.000"])
            row.muteClicked()
            castTick()
            compare(root.sent, ["tv 0.250", "tv 0.000", "tv 0.250"])
            // Its own row in the menu: the balance is kept for it, and it is told nothing.
            root.sync.setDeviceTrim("kitchen", 0.5)
            compare(root.sync.trimOf("kitchen"), 0.5)
            compare(root.sent.length, 3)
            // The same row on the television that plays does reach it.
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent[3], "tv 0.125")
            // With this computer playing along, and on a pinned output: the same.
            root.sent = []
            pinned(); root._castLocalPlay = true
            slide(0.6)
            castTick()
            row.muteClicked()
            castTick()
            verify(root.sent.length > 0)
            compare(root.sent.filter(function (l) { return l.indexOf("tv ") !== 0 }), [])
        }

        function test_a_device_still_being_asked_is_not_turned_by_the_row_until_it_answers() {
            casting(true)
            root._castTargets = [tv, kitchen]
            root._castSession = CastLogic.tried(({ "pending": {}, "on": { "tv": true } }), "kitchen", 4)
            slide(0.25)
            castTick()
            compare(root.sent, ["tv 0.250"])
            // The level is kept for it in the record, to go out with its answer.
            compare(CastLogic.answered(root._castSession, "kitchen", 4, true, "ok").owed, 25)
        }

        function test_a_television_alone_with_an_output_pinned_is_turned_as_before() {
            pinned(); casting(true)
            slide(0.25)
            row.muteClicked()
            castTick()
            compare(root.sent, ["tv 0.000"])
            compare(root.roomSets, [])
            compare(root.roomMutes, 0)
        }

        function test_a_silent_sync_group_does_not_claim_the_row_from_the_television() {
            root.sync._combineActive = true
            casting(true)
            slide(0.4)
            compare(root.roomSets, [])
            castTick()
            compare(root.sent, ["tv 0.400"])
        }

        function test_a_sync_group_of_two_outputs_is_the_rooms_knob() {
            root.sync._combineActive = true
            pinned()
            slide(0.25); row.muteClicked()
            compare(root.roomSets, [25])
            compare(root.roomMutes, 1)
            compare(level(), 80)
            init()
            // Still being built counts as up: the wish is what routes the sound.
            root.sync._combineWantActive = true
            slide(0.5)
            compare(root.roomSets, [50])
        }

        function test_a_ticked_device_that_is_not_playing_is_never_sent_a_level() {
            // It may be serving another app.
            root._castTargets = [tv]; root._castLocalPlay = true
            slide(0.25); row.muteClicked(); row.muteClicked(); castTick()
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, [])
            compare(root._pendingCastVolumePct, -1)
            compare(root.castTimerRestarts, 0)
            init()
            root._castTargets = [tv]; pinned()
            slide(0.25); row.muteClicked(); row.muteClicked(); castTick()
            root.setUserVolume(0.3); castTick()
            compare(root.sent, [])
            compare(root.castTimerRestarts, 0)
        }

        // ── this computer and a device together ──────────────────────────

        function test_together_on_the_default_sink_the_slider_moves_both() {
            // The room at 60 %, the widget's own volume at 80 %, the television at half the master.
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            slide(0.5)
            compare(root.roomSets, [50])
            compare(level(), 80, "the slider turned the widget's own volume too, and this computer twice")
            castTick()
            compare(root.sent, ["tv 0.200"], "the television was left where it stood")
            // Twice the room is twice the television: the balance is kept.
            slide(1)
            castTick()
            compare(root.roomSets, [50, 100])
            compare(last(), "tv 0.400")
            compare(root.sync.trimOf("tv"), 0.5)
        }

        function test_together_with_an_output_pinned_the_slider_moves_both_as_before() {
            pinned(); casting(false); root.sync.trims = ({ "tv": 0.5 })
            slide(0.25); castTick()
            compare(level(), 25)
            compare(root.sent, ["tv 0.125"])
            compare(root.roomSets, [])
        }

        function test_together_in_a_sync_group_the_slider_moves_both() {
            root.sync._combineActive = true; pinned()
            casting(false)
            slide(0.5); castTick()
            compare(root.roomSets, [50])
            compare(root.sent, ["tv 0.400"])
        }

        function test_the_master_at_zero_and_up_again_finds_the_balance_it_left() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            slide(0); castTick()
            compare(root.roomSets, [0])
            compare(last(), "tv 0.000")
            slide(0.5); castTick()
            compare(last(), "tv 0.200")
            compare(root.sync.trimOf("tv"), 0.5)
        }

        function test_a_device_at_its_top_comes_down_with_the_master_and_keeps_its_balance() {
            // Full room, full widget volume, full balance: the device is at its maximum.
            casting(false); cfg.defaultVolume = 100; playMusicOutput.volume = 1
            slide(1); castTick()
            compare(last(), "tv 1.000")
            slide(0.5); castTick()
            compare(last(), "tv 0.500")
            slide(1); castTick()
            compare(last(), "tv 1.000")
            compare(root.sync.hasTrim("tv"), false, "the master wrote a balance; only the device's own row may")
        }

        function test_together_the_mute_silences_both_and_the_unmute_brings_both_back() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            row.muteClicked(); castTick()
            compare(room.muted, true)
            compare(root.sent, ["tv 0.000"], "the mute left the television playing")
            compare(row.shownMuted, true)
            row.muteClicked(); castTick()
            compare(room.muted, false)
            // 60 % of the room, 80 % of the widget's volume, half of that for the television.
            compare(root.sent, ["tv 0.000", "tv 0.240"])
            compare(room.pct, 60, "the mute moved the room's level")
            compare(level(), 80)
        }

        function test_the_television_follows_what_the_mute_answered_not_what_the_icon_showed() {
            // Muted from the keyboard a moment ago: the widget still believes the room sounds.
            casting(false)
            room.muted = true
            compare(row.shownMuted, false)
            row.muteClicked(); castTick()
            compare(room.muted, false)
            compare(root.sent, ["tv 0.480"], "this computer came back and the television was silenced")
        }

        function test_a_mute_a_moment_after_a_slider_move_comes_back_to_that_move_for_both() {
            casting(false)
            slide(0.25)            // the television's 400 ms have not passed
            row.muteClicked(); castTick()
            compare(root.sent, ["tv 0.000"])
            row.muteClicked(); castTick()
            compare(room.pct, 25)
            compare(last(), "tv 0.200")
            // And on the widget's own knob, where the save runs a second behind.
            init(); pinned(); casting(false)
            slide(0.2); row.muteClicked(); saveTick(); castTick()
            row.muteClicked(); castTick()
            compare(level(), 20, "the unmute went back to an older level")
            compare(last(), "tv 0.200")
        }

        function test_the_devices_own_row_moves_only_the_device_and_is_the_balance_from_then_on() {
            casting(false)
            root.sync.setDeviceTrim("tv", 0.25)
            compare(root.sent, ["tv 0.120"])
            compare(root.roomSets, [])
            compare(root.roomMutes, 0)
            compare(level(), 80)
            slide(1); castTick()
            compare(last(), "tv 0.200")
        }

        function test_the_devices_row_moved_under_a_mute_does_not_wake_the_device() {
            casting(false)
            row.muteClicked(); castTick()
            root.sent = []
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, ["tv 0.000"], "the balance row un-muted the television")
            row.muteClicked(); castTick()
            compare(last(), "tv 0.240")
            // The same on the widget's own knob.
            init(); pinned(); casting(false)
            row.muteClicked(); castTick(); root.sent = []
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, ["tv 0.000"], "the balance row un-muted the television")
            row.muteClicked(); castTick()
            compare(last(), "tv 0.400")
        }

        function test_a_cast_that_starts_under_a_mute_is_told_nothing_until_a_gesture() {
            // It comes in at the loudness it has, which is what its balance is read from.
            row.muteClicked()
            casting(false)
            castTick()
            compare(root.sent, [])
            deviceAnswers("tv", 0.24)
            compare(root.sync.trimOf("tv"), 0.5, "a muted master was taken for the level to measure the balance against")
            row.muteClicked(); castTick()
            compare(room.muted, false)
            compare(root.sent, ["tv 0.240"])
        }

        function test_a_cast_that_ended_before_the_mutes_answer_came_back_is_told_nothing() {
            // The click was for both; pactl answers a moment later, and by then the device is only ticked.
            casting(false)
            root._casting = false
            sinkAnswers("SINKVOL 60 yes devices")
            compare(root._sinkMasterMuted, true)
            compare(root.castTimerRestarts, 0, "a device that stopped playing was queued a level")
            castTick()
            compare(root.sent, [])
        }

        function test_the_room_moved_from_outside_does_not_move_the_device_by_itself() {
            casting(false)
            slide(0.5); castTick()
            root.sent = []
            // The keyboard's keys, another program: the slider follows the room.
            room.pct = 30; poll()
            compare(Math.round(row.shownVol * 100), 30)
            room.muted = true; poll()
            compare(row.shownMuted, true)
            castTick()
            compare(root.sent, [], "a poll of this computer's master sent the television a level")
            compare(root.castTimerRestarts, 1)
        }

        function test_the_m_key_the_wheel_and_the_desk_move_both_by_the_widgets_own_volume() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            // M: the widget's own volume to zero, and back.
            root.setUserVolume(playMusicOutput.volume > 0 ? 0 : root.targetVolume()); castTick()
            compare(last(), "tv 0.000")
            compare(root.roomMutes, 0)
            root.setUserVolume(playMusicOutput.volume > 0 ? 0 : root.targetVolume()); castTick()
            compare(last(), "tv 0.240")
            // A notch of the wheel, and a level named by MPRIS.
            root.setUserVolume(0.85, true); castTick()
            compare(last(), "tv 0.255")
            root.setUserVolume(0.4); castTick()
            compare(last(), "tv 0.120")
            compare(root.roomSets, [])
        }

        function test_two_devices_each_keep_their_own_balance() {
            root._castTargets = [tv, kitchen]; root._casting = true; root._castLocalPlay = true
            root.sync.trims = ({ "tv": 0.5, "kitchen": 0.25 })
            slide(1); castTick()
            compare(root.sent, ["tv 0.400", "kitchen 0.200"])
            root.sync.setDeviceTrim("kitchen", 1)
            compare(last(), "kitchen 0.800")
            compare(root.sent.length, 3, "one device's row moved the other")
        }

        function test_a_long_drag_sends_each_device_its_last_level_once() {
            root._castTargets = [tv, kitchen]; root._casting = true; root._castLocalPlay = true
            for (var i = 0; i <= 400; i++) slide((i % 21) / 20)
            castTick()
            compare(root.sent, ["tv 0.040", "kitchen 0.040"])
            compare(root.roomSets.length, 401)
            compare(root.roomSets[400], 5)
        }

        function test_a_device_joining_is_measured_against_the_master_it_will_follow() {
            casting(false)
            deviceAnswers("tv", 0.24)        // the room 60 %, the widget 80 %: the master is 0.48
            compare(root.sync.trimOf("tv"), 0.5)
            // One that is louder than the master cannot stay so: full balance, and the master's level at the next move.
            deviceAnswers("kitchen", 0.9)
            compare(root.sync.hasTrim("kitchen"), false)
            // A balance set by hand is never measured over.
            deviceAnswers("tv", 0.1)
            compare(root.sync.trimOf("tv"), 0.5)
        }

        // ── the listener's mute, and a zero the widget only passes through ─

        // What a start, the end of a fade and a calibration do to the stream: zero, and nobody muted.
        function park() { playMusicOutput.volume = 0 }
        // What ends it: the fade-in, the stop's restore, the calibration's.
        function lift() { playMusicOutput.volume = root.targetVolume() }
        // The M key, as the Playing page has it.
        function keyM() { root.setUserVolume(playMusicOutput.volume > 0 ? 0 : root.targetVolume()) }

        function test_a_click_on_the_slider_while_the_stream_stands_at_zero_sends_the_device_its_level() {
            casting(false); park()
            slide(0.5); castTick()
            compare(root.sent, ["tv 0.400"], "a zero the widget was passing through was taken for a mute")
        }

        function test_the_devices_row_moved_while_the_stream_stands_at_zero_sends_it_its_level() {
            casting(false); park()
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, ["tv 0.240"])
            // The same on the widget's own knob, and for a device that plays alone.
            init(); pinned(); casting(false); park()
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, ["tv 0.400"])
            init(); casting(true); park()
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, ["tv 0.400"])
        }

        function test_an_unmute_answered_while_the_stream_stands_at_zero_brings_the_device_back() {
            casting(false)
            row.muteClicked(); castTick()
            compare(root.sent, ["tv 0.000"])
            park()
            row.muteClicked(); castTick()
            compare(room.muted, false)
            compare(last(), "tv 0.480")
        }

        function test_a_mute_clicked_while_the_stream_stands_at_zero_is_still_a_mute() {
            casting(false); park()
            row.muteClicked(); castTick()
            compare(root.sent, ["tv 0.000"])
        }

        function test_the_listeners_own_mute_silences_the_device_on_both_knobs() {
            // The M key beside a device, on the room's knob.
            casting(false)
            keyM(); castTick()
            compare(root.sent, ["tv 0.000"])
            // The slider there moves the room, and the pair stays silent: the listener said so.
            slide(0.5); castTick()
            compare(last(), "tv 0.000")
            keyM(); castTick()
            compare(last(), "tv 0.400")
            // The speaker button on the widget's own knob.
            init(); pinned(); casting(false)
            row.muteClicked(); castTick()
            compare(root.sent, ["tv 0.000"])
            row.muteClicked(); castTick()
            compare(last(), "tv 0.800")
        }

        function test_the_devices_row_moved_under_the_listeners_mute_stores_and_stays_silent() {
            casting(false)
            keyM(); castTick(); root.sent = []
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, ["tv 0.000"], "the balance row un-muted the television")
            compare(root.sync.trimOf("tv"), 0.5)
            keyM(); castTick()
            compare(last(), "tv 0.240")
        }

        function test_a_device_joining_under_the_listeners_mute_is_measured_against_the_level_not_the_silence() {
            casting(false)
            keyM()
            deviceAnswers("tv", 0.24)
            compare(root.sync.trimOf("tv"), 0.5, "the listener's mute was taken for the level to measure the balance against")
        }

        function test_a_start_after_a_mute_brings_the_device_back_at_the_next_thing_it_is_told() {
            casting(false)
            keyM(); castTick()
            compare(root.sent, ["tv 0.000"])
            // Another station. The start writes the stream to zero, where it already is: the mute
            // stands until the fade lifts the stream, 10 to 20 ms later by the clock.
            park()
            root.sync.setDeviceTrim("tv", 0.5)
            compare(last(), "tv 0.000")
            lift()
            compare(root.sent.length, 2, "a start told the device something by itself")
            root.sync.setDeviceTrim("tv", 0.25)
            compare(last(), "tv 0.120")
        }

        function test_a_mute_that_a_start_lifted_is_not_back_at_the_next_zero() {
            casting(false)
            keyM(); park(); lift(); castTick()
            root.sent = []
            // A calibration, or the next start: zero again, and nobody muted this time.
            park()
            slide(0.5); castTick()
            compare(root.sent, ["tv 0.400"])
            root.sync.setDeviceTrim("tv", 0.5)
            compare(last(), "tv 0.200")
        }

        function test_the_first_gesture_after_an_alarm_does_not_send_a_pair_above_the_alarms_level() {
            // The alarm gives the room its own level and tells the devices that level past the room's master.
            half(); casting(false)
            root.sync.trims = ({ "tv": 0.5 })
            root._volumeOverridePct = 40; lift()
            root._castSetVolume(root.targetVolume()); castTick()
            compare(root.sent, ["tv 0.200"])
            var told = function() { return parseFloat(last().split(" ")[1]) }
            // The slider on the room's knob, wherever it is put.
            slide(1); castTick()
            verify(told() <= 0.2, "up to " + last())
            slide(0.5); castTick()
            verify(told() <= 0.2, "up to " + last())
            // The device's own row at the same balance, and the mute and back.
            root.sync.setDeviceTrim("tv", 0.5)
            verify(told() <= 0.2, "up to " + last())
            row.muteClicked(); row.muteClicked(); castTick()
            verify(told() <= 0.2, "up to " + last())
        }

        // ── the listener's level inside the second before it is saved ────

        // The wheel takes the widget from 80 % to 20 %, notch by notch, and the save has not come yet.
        function wheelDownTo20() { for (var i = 0; i < 12; i++) root.wheelStep(-0.05); castTick() }

        function test_the_rooms_slider_inside_that_second_works_from_the_level_the_wheel_just_set() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            wheelDownTo20()
            compare(level(), 20)
            compare(last(), "tv 0.060")
            slide(0.5); castTick()
            compare(last(), "tv 0.050", "the device was sent the product of a level saved a second ago")
        }

        function test_the_devices_row_inside_that_second_works_from_the_level_the_wheel_just_set() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            wheelDownTo20()
            root.sync.setDeviceTrim("tv", 0.25)
            compare(last(), "tv 0.030")
        }

        function test_an_unmute_inside_that_second_brings_the_device_back_at_the_level_the_wheel_just_set() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            wheelDownTo20()
            row.muteClicked(); castTick()
            compare(last(), "tv 0.000")
            row.muteClicked(); castTick()
            compare(last(), "tv 0.060")
        }

        function test_a_device_joining_inside_that_second_is_measured_against_the_level_the_wheel_just_set() {
            casting(false)
            wheelDownTo20()
            deviceAnswers("tv", 0.06)
            compare(root.sync.trimOf("tv"), 0.5)
        }

        function test_a_mute_inside_that_second_is_not_a_level_and_the_level_under_it_comes_back() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            wheelDownTo20()
            keyM(); castTick()
            compare(last(), "tv 0.000")
            root.sync.setDeviceTrim("tv", 0.25)
            compare(last(), "tv 0.000")
            keyM(); castTick()
            compare(level(), 20)
            compare(last(), "tv 0.030")
        }

        function test_after_the_save_the_level_is_the_same_one() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            wheelDownTo20(); saveTick()
            slide(0.5); castTick()
            compare(last(), "tv 0.050")
        }

        function test_the_wheel_during_a_sleep_fade_beside_a_device_counts_from_where_the_fade_began() {
            casting(false); root.sync.trims = ({ "tv": 0.5 }); cfg.defaultVolume = 60
            playMusicOutput.volume = 0.3; root._volumeBeforeSleepFade = 0.6      // the fade is half way down
            root.wheelStep(0.05); castTick()
            compare(last(), "tv 0.195")
            playMusicOutput.volume = 0.29                                        // the fade writes its own level again
            root.wheelStep(0.05); castTick()
            compare(last(), "tv 0.210")
        }

        function test_after_an_alarm_on_a_device_that_plays_alone_a_notch_counts_from_the_alarms_level() {
            // The alarm tells the device its own level; the widget's output, which nobody hears, still stands at 80 %.
            casting(true); root.sync.trims = ({ "tv": 0.5 })
            root._volumeOverridePct = 40
            root._castSetVolume(root.targetVolume()); castTick()
            compare(root.sent, ["tv 0.200"])
            root.wheelStep(-0.05); castTick()
            compare(last(), "tv 0.175", "one notch down sent the device up")
            // A second notch of the same burst counts from the first.
            root.wheelStep(-0.05); castTick()
            compare(last(), "tv 0.150")
        }

        function test_beside_this_computer_a_notch_counts_from_what_is_heard_as_it_did() {
            casting(false); root.sync.trims = ({ "tv": 0.5 })
            root.wheelStep(0.05); castTick()
            compare(level(), 85)
            compare(last(), "tv 0.255")
            // Also where the level on file is another one: what is heard here is what the notch is added to.
            init(); casting(false); root.sync.trims = ({ "tv": 0.5 })
            cfg.defaultVolume = 60
            root.wheelStep(0.05); castTick()
            compare(level(), 85)
        }

        // ── "This computer" ticked or unticked beside a device that plays ─

        // The room at 50 % under a widget at 80 %: a pair follows 0.40, a device alone 0.80.
        function half() { room.pct = 50; poll() }

        function test_this_computer_joining_leaves_the_television_where_it_stands() {
            half(); casting(true)
            root.sync.setDeviceTrim("tv", 0.25)
            compare(root.sent, ["tv 0.200"])
            root.sent = []
            root.castToggleLocal()
            compare(root._castLocalPlay, true)
            compare(root.sent, [], "a tick sent the television a level")
            compare(root.castTimerRestarts, 0, "a tick queued a level for the television")
            // 0.20 is half of what the pair follows.
            compare(root.sync.trimOf("tv"), 0.5)
            // And the next gesture moves it from there: the wheel halves the widget's volume, the television halves.
            setUserVolume(0.4, true); castTick()
            compare(root.sent, ["tv 0.100"])
        }

        function test_this_computer_leaving_does_not_send_the_television_up_at_the_next_gesture() {
            half(); casting(false)
            root.sync.setDeviceTrim("tv", 0.5)
            compare(root.sent, ["tv 0.200"])
            root.sent = []
            root.castToggleLocal()
            compare(root._castLocalPlay, false)
            compare(root.sent, [], "an untick sent the television a level")
            compare(root.castTimerRestarts, 0)
            compare(root.sync.trimOf("tv"), 0.25)
            // One wheel step down, 80 to 75: the television goes down with it, 0.200 to 0.188.
            setUserVolume(0.75, true); castTick()
            compare(root.sent, ["tv 0.188"])
        }

        function test_a_tick_and_an_untick_give_the_balance_back() {
            half(); casting(true)
            root.sync.trims = ({ "tv": 0.25 })
            root.castToggleLocal(); root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.25)
            compare(root.sent, [])
        }

        function test_a_television_louder_than_the_pair_comes_down_at_the_next_gesture_and_never_goes_up() {
            // At 0.80 of its scale while the pair follows 0.40: full balance is all a balance can be.
            half(); casting(true)
            root.castToggleLocal()
            compare(root.sync.hasTrim("tv"), false)
            compare(root.sent, [])
            slide(0.5); castTick()
            compare(root.sent, ["tv 0.400"])
        }

        function test_with_an_output_pinned_a_tick_changes_no_balance() {
            // The row is the widget's own volume before and after: there is nothing to read the balance against anew.
            half(); pinned(); casting(true)
            root.sync.trims = ({ "tv": 0.25 })
            root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.25)
            root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.25)
            compare(root.sent, [])
        }

        function test_a_ticked_device_that_is_not_playing_keeps_its_balance_through_a_tick() {
            half()
            root._castTargets = [tv]; root._casting = false; root._castLocalPlay = false
            root.sync.trims = ({ "tv": 0.25 })
            root.castToggleLocal()
            compare(root._castLocalPlay, true)
            compare(root.sync.trimOf("tv"), 0.25)
            compare(root.sent, [])
            // And with no device ticked the box does nothing at all.
            root._castTargets = []
            root.castToggleLocal()
            compare(root._castLocalPlay, true)
        }

        function test_this_computer_joining_under_a_mute_tells_the_television_nothing() {
            room.pct = 50; room.muted = true; poll()
            casting(true)
            root.sync.trims = ({ "tv": 0.25 })
            root.castToggleLocal(); castTick()
            compare(root.sent, [], "the tick silenced a television that was playing")
            // Read against the level the pair comes back to, not against the silence.
            compare(root.sync.trimOf("tv"), 0.5)
            row.muteClicked(); castTick()
            compare(room.muted, false)
            compare(root.sent, ["tv 0.200"])
        }

        function test_two_devices_each_stay_where_they_stand_through_a_tick() {
            half()
            root._castTargets = [tv, kitchen]; root._casting = true; root._castLocalPlay = false
            root.sync.trims = ({ "tv": 0.25, "kitchen": 0.5 })
            root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.5)
            compare(root.sync.hasTrim("kitchen"), false)
            compare(root.sent, [])
            setUserVolume(0.4, true); castTick()
            compare(root.sent, ["tv 0.100", "kitchen 0.200"])
        }

        function test_a_room_nobody_has_read_leaves_the_balance_through_a_tick() {
            casting(true)
            root._sinkMasterPct = -1
            root.sync.trims = ({ "tv": 0.25 })
            root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.25)
            // A room at zero is no level to measure against either.
            root.castToggleLocal(); root._sinkMasterPct = 0; root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.25)
            compare(root.sent, [])
        }

        // A level waits 400 ms for the device as a master; the tick changes the balance it will be multiplied by.

        function test_a_tick_while_a_level_still_waits_sends_it_as_it_was_asked() {
            // The wheel took the pair to 40 %: the television is due 0.4 x 0.5 x 0.5 = 0.100.
            half(); casting(false); root.sync.trims = ({ "tv": 0.5 })
            root.setUserVolume(0.4, true)
            root.castToggleLocal()
            castTick()
            compare(root.sent, ["tv 0.100"], "the level that waited was multiplied by the balance of after the tick")
            compare(root.sync.trimOf("tv"), 0.25)
        }

        function test_a_tick_the_other_way_while_a_level_waits_does_not_double_it() {
            half(); casting(true); root.sync.trims = ({ "tv": 0.25 })
            root.setUserVolume(0.4, true)
            root.castToggleLocal()
            castTick()
            compare(root.sent, ["tv 0.100"])
            compare(root.sync.trimOf("tv"), 0.5)
        }

        function test_a_tick_after_the_level_went_out_sends_nothing() {
            half(); casting(false); root.sync.trims = ({ "tv": 0.5 })
            root.setUserVolume(0.4, true); castTick()
            compare(root.sent, ["tv 0.100"])
            root.castToggleLocal(); castTick()
            compare(root.sent, ["tv 0.100"])
        }

        function test_a_tick_inside_both_windows_keeps_the_level_and_the_next_notch_moves_it_from_there() {
            // Inside the second before the save and inside the 400 ms before the device is told.
            half(); casting(false); root.sync.trims = ({ "tv": 0.5 })
            root.wheelStep(-0.05); root.wheelStep(-0.05)        // 80 to 70
            root.castToggleLocal(); castTick()
            compare(root.sent, ["tv 0.175"])                    // 0.7 x 0.5 x 0.5
            root.wheelStep(-0.05); castTick()                   // 65, and the device alone now: 0.65 x 0.25
            compare(last(), "tv 0.163")
        }

        function test_a_mute_that_still_waits_goes_out_as_a_mute_at_the_tick() {
            half(); casting(false); root.sync.trims = ({ "tv": 0.5 })
            keyM()
            root.castToggleLocal(); castTick()
            compare(root.sent, ["tv 0.000"])
        }

        function test_two_devices_are_each_sent_what_waited_for_them_at_the_tick() {
            half()
            root._castTargets = [tv, kitchen]; root._casting = true; root._castLocalPlay = true
            root.sync.trims = ({ "tv": 0.5, "kitchen": 0.25 })
            root.setUserVolume(0.4, true)
            root.castToggleLocal(); castTick()
            compare(root.sent, ["tv 0.100", "kitchen 0.050"])
        }

        function test_leaving_a_quiet_room_does_not_raise_the_television() {
            // Room 10 %, widget 80 %, balance 0.1: the television stands at 0.008.
            room.pct = 10; poll(); casting(false)
            root.sync.setDeviceTrim("tv", 0.1)
            compare(root.sent, ["tv 0.008"])
            root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.01, "the balance was held at the five per cent the row's slider starts at")
            // One notch down, 80 to 75: it must not go up.
            root.wheelStep(-0.05); castTick()
            verify(parseFloat(last().split(" ")[1]) <= 0.008, "one notch down sent it to " + last())
            // And back beside this computer it has the balance it had.
            root.castToggleLocal()
            compare(root.sync.trimOf("tv"), 0.1)
        }

        function test_a_device_that_joins_far_below_the_master_is_not_raised_by_its_first_move() {
            casting(false)
            deviceAnswers("tv", 0.01)       // the master is 0.48: its share is 0.0208333
            verify(root.sync.trimOf("tv") <= 0.01 / 0.48 && root.sync.trimOf("tv") > 0.0208, "kept " + root.sync.trimOf("tv"))
            slide(0.6); castTick()
            verify(parseFloat(last().split(" ")[1]) <= 0.01, "the move of a slider that did not move raised it to " + last())
        }

        // ── a drag keeps the knob it began on ────────────────────────────

        function test_a_cast_ending_under_the_pointer_does_not_hand_the_drag_to_the_rooms_master() {
            casting(true)
            mousePress(masterVolumeSlider, 20, 15)
            compare(masterVolumeSlider.pressed, true)
            mouseMove(masterVolumeSlider, 60, 15)
            verify(root._pendingCastVolumePct >= 0, "the drag did not reach the television")
            // The cast ends: the sleep timer, a Stop from the headset, another hand.
            root._casting = false
            root._pendingCastVolumePct = -1
            mouseMove(masterVolumeSlider, 180, 15)
            compare(root.roomSets, [], "the rest of the drag went to this computer's master")
            compare(root._pendingCastVolumePct, -1, "a device that stopped playing was sent a level")
            verify(level() > 60, "the drag stopped moving the level it began on")
            mouseRelease(masterVolumeSlider, 180, 15)
            compare(masterVolumeSlider.dragRoad, "")
            // The next gesture is a new one, and the room's again.
            slide(0.3)
            compare(root.roomSets, [30])
        }

        function test_together_a_cast_ending_under_the_pointer_leaves_the_rest_of_the_drag_to_this_computer() {
            casting(false)
            mousePress(masterVolumeSlider, 20, 15)
            mouseMove(masterVolumeSlider, 60, 15)
            verify(root.roomSets.length > 0 && root._pendingCastVolumePct >= 0)
            root._casting = false; root._pendingCastVolumePct = -1
            var before = root.roomSets.length
            mouseMove(masterVolumeSlider, 180, 15)
            verify(root.roomSets.length > before, "the drag stopped moving this computer")
            compare(root._pendingCastVolumePct, -1, "a device that stopped playing was sent a level")
            mouseRelease(masterVolumeSlider, 180, 15)
        }

        function test_a_cast_beginning_under_the_pointer_leaves_the_drag_on_the_rooms_knob() {
            mousePress(masterVolumeSlider, 20, 15)
            mouseMove(masterVolumeSlider, 60, 15)
            verify(root.roomSets.length > 0)
            casting(true)
            var before = level()
            mouseMove(masterVolumeSlider, 180, 15)
            compare(root._pendingCastVolumePct, -1, "a drag on the room's knob set the television's level")
            compare(level(), before)
            mouseRelease(masterVolumeSlider, 180, 15)
            slide(0.3); castTick()
            compare(root.sent, ["tv 0.300"])
        }

        function test_a_device_joining_this_computer_under_the_pointer_follows_the_rest_of_the_drag() {
            mousePress(masterVolumeSlider, 20, 15)
            mouseMove(masterVolumeSlider, 60, 15)
            compare(root._pendingCastVolumePct, -1)
            casting(false)
            mouseMove(masterVolumeSlider, 180, 15)
            verify(root._pendingCastVolumePct >= 0, "the rest of the drag left the device out")
            mouseRelease(masterVolumeSlider, 180, 15)
            castTick()
            // The room's knob stayed the knob, and the device is at the widget's 80 % of where it ended.
            compare(root.roomSets[root.roomSets.length - 1], room.pct)
            verify(room.pct > 60, "the drag did not go up")
            compare(root.sent, ["tv " + (0.8 * room.pct / 100).toFixed(3)])
        }

        function test_the_slider_moved_by_a_key_takes_the_road_of_that_moment() {
            // No press: nothing is held, the answer is asked afresh each time.
            casting(true)
            slide(0.5)
            compare(root._pendingCastVolumePct, 50)
            root._casting = false; root._pendingCastVolumePct = -1
            slide(0.45)
            compare(root.roomSets, [45])
            compare(root._pendingCastVolumePct, -1)
        }

        // ── the widget's own knob: mute and unmute ───────────────────────

        function test_mute_and_unmute_bring_the_television_back_to_its_level() {
            casting(true)
            cfg.defaultVolume = 35; playMusicOutput.volume = 0.35
            row.muteClicked(); castTick(); saveTick()
            compare(row.shownMuted, true)
            row.muteClicked(); castTick()
            compare(root.sent, ["tv 0.000", "tv 0.350"])
            compare(row.shownMuted, false)
            compare(cfg.defaultVolume, 35, "the mute was saved as the level")
        }

        function test_a_mute_a_moment_after_a_new_level_comes_back_to_that_level() {
            // 80 % saved; the slider to 20 %, and the mute before the save's
            // second is over. The unmute sent the television the 80 %.
            casting(true)
            slide(0.2)
            row.muteClicked()
            saveTick()
            row.muteClicked(); castTick()
            compare(level(), 20, "the unmute went back to an older level")
            compare(last(), "tv 0.200")
            // And when the unmute comes before the save has run at all.
            init(); casting(true)
            slide(0.2); row.muteClicked(); row.muteClicked()
            compare(level(), 20)
        }

        function test_an_unmute_from_a_slider_at_zero_finds_the_last_audible_level() {
            casting(true)
            cfg.defaultVolume = 35; playMusicOutput.volume = 0.35
            slide(0); saveTick()
            compare(cfg.defaultVolume, 35, "zero was saved as the level")
            row.muteClicked()
            compare(level(), 35)
        }

        function test_the_rooms_mute_is_the_rooms_own_switch() {
            slide(0.25)
            row.muteClicked()
            compare(row.shownMuted, true)
            compare(room.pct, 25)
            row.muteClicked()
            compare(row.shownMuted, false)
            compare(room.pct, 25)
            compare(level(), 80)
        }

        function test_the_row_shows_the_knob_it_turns() {
            compare(Math.round(row.shownVol * 100), 60)
            casting(true)
            compare(Math.round(row.shownVol * 100), 80)
            compare(Math.round(masterVolumeSlider.value * 100), 80)
            root._sinkMasterMuted = true
            compare(row.shownMuted, false, "a muted computer that plays nothing shows the television as muted")
            root._castLocalPlay = true
            compare(row.shownMuted, true)
            compare(Math.round(row.shownVol * 100), 60)
        }

        function test_a_level_off_the_scale_stays_on_it() {
            casting(true)
            root.setUserVolume(7); castTick()
            root.setUserVolume(-3); castTick()
            compare(root.sent, ["tv 1.000", "tv 0.000"])
            root.setSinkMaster(250); root.setSinkMaster(-5)
            compare(root.roomSets, [100, 0])
            // The room above its own 100 %, set from outside: the device is not sent more than full.
            init(); casting(false); cfg.defaultVolume = 100; playMusicOutput.volume = 1
            room.pct = 150; poll()
            row.muteClicked(); row.muteClicked(); castTick()
            compare(last(), "tv 1.000")
        }
    }
}
