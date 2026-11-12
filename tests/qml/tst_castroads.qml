// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// A device was asked to play and answered that it could not (a Ruark R5se,
// UPnP 716, 2026-11-11), and the widget went on saying "Casting to Ruark
// R5se" over a silent room. This stands main.qml's _castPlay, _castPlayOn,
// _castAnswer, _castEnd, castToggleDevice and castDisconnect up, word for
// word as main.qml has them, around stand-ins that only record, and walks
// what a listener can meet: the only device refusing, one of two, a late
// answer of an older attempt, a stop before the answer, the one device
// that played being unticked beside one that refused. What it proves is
// this copy; test_invariants holds main.qml to the same lines.
import QtQuick
import QtTest

import "../../package/contents/ui/CastLogic.js" as CastLogic
import "../../package/contents/ui/TransportLogic.js" as TransportLogic

Item {
    id: root
    width: 100
    height: 100

    // The entries call i18n(); qmltestrunner has no KLocalizedContext.
    function i18n(s, a) { return a === undefined ? s : String(s).replace("%1", a); }
    function i18np(one, many, n) { return String(n === 1 ? one : many).replace("%1", n); }

    property var log: []
    property int _execSeq: 0
    property bool _casting: false
    property string _castCurrentUrl: ""
    property var _castTargets: []
    property bool _castLocalPlay: false
    property var _castSession: CastLogic.fresh()
    property string _castFailedName: ""
    property bool _castFailedRefused: false
    property string _podPlayingUrl: ""
    property bool playing: false
    // main.qml's player says this in its onPlayingChanged.
    onPlayingChanged: { root._castFailedName = ""; }
    property bool _tsPaused: false
    property string currentStation: "Station"
    property string streamUrl: "http://s.example/live"
    readonly property string _castName: { var on = CastLogic.carriers(_castSession, _castTargets);
        return on.length === 1 ? on[0].name : (on.length > 1 ? i18np("%1 device", "%1 devices", on.length) : ""); }

    // The footer's lines about the devices, as FullRepresentation.qml has them; "" is whatever it says below them.
    function footer() {
        if (root._casting || (root._castFailedName !== "" && !isPlaying())) {
            return root._casting ? i18n("Casting to %1", root._castName)
                 : root._castFailedRefused ? i18n("%1 cannot play this station", root._castFailedName)
                 : i18n("Could not cast to %1", root._castFailedName)
        }
        return "";
    }

    QtObject {
        id: playMusic
        property real position: 0
        property string source: ""
        // main.qml's player says this in its onSourceChanged.
        onSourceChanged: { root._castFailedName = ""; }
        function stop() { root.log.push("local stop"); root.playing = false; }
    }
    QtObject { id: timeshift; function disarm() { root.log.push("disarm"); } }
    QtObject { id: infoTimer; function stop() {} }
    QtObject { id: alarmEngine; property bool _alarmCastConfirmed: false }

    // The real one builds the shell line; what the answer is read from is
    // the sentinel, the quoted arguments and the number at the end.
    function _castExec(sentinel, argv) {
        var cmd = ": " + sentinel + "; python3 '/usr/share/x/cast.py'";
        for (var i = 0; i < argv.length; i++) cmd += " '" + String(argv[i]).replace(/'/g, "'\\''") + "'";
        cmd += " # " + (++_execSeq);
        log.push(cmd);
    }
    function _castContentType(url) { return "audio/mpeg"; }
    function castTargetIndex(uuid) {
        for (var i = 0; i < _castTargets.length; i++) if (_castTargets[i].uuid === uuid) return i;
        return -1;
    }
    property var said: []
    function notify(title, text, icon) { log.push("notify: " + title); said.push(text); }
    function _castAdoptTrim(dev) { log.push("adopt: " + dev.uuid); }
    function _castStopAll() { log.push("stop all"); }
    function _castStopDevice(dev) { log.push("stop: " + dev.uuid); }
    function _castStreamUrl() { return streamUrl; }
    function _castArt() { return ""; }
    function _stampPodPosition() { log.push("stamp"); }
    function _castResumeLocally() { log.push("resume locally"); }
    function isPlaying() { return playing; }

    function _castEnd() { _casting = false; _castCurrentUrl = ""; _castSession = CastLogic.ended(_castSession); }
    function castRefused(uuid) { return CastLogic.refusedBy(_castSession, uuid); }

    function _castPlayOn(dev, url, name, art) {
        // A podcast episode is not a stream: it has a duration and the
        // listener owns a position in it. Told nothing, the receiver was
        // sent it as LIVE — no scrubber, no seek, and the resume bookmark
        // dropped on the floor, so a device always started the episode from
        // zero. The position rides along and the receiver gets its own.
        var podPos = (root._podPlayingUrl !== "" && url === root._podPlayingUrl)
                     ? Math.max(0, Math.round(playMusic.position / 1000)) : -1;
        if (dev.kind === "dlna") {
            _castExec("CAST_PLAY", ["dlna-play", dev.location, url,
                                    _castContentType(url), name || "", art || ""]);
        } else {
            _castExec("CAST_PLAY", ["play", dev.host, dev.port, dev.uuid, dev.deviceModel,
                                    url, _castContentType(url), name || "", art || "",
                                    podPos >= 0 ? String(podPos) : ""]);
        }
        _castSession = CastLogic.tried(_castSession, dev.uuid, _execSeq); _castFailedName = "";
    }

    function _castPlay(url, name, art) {
        if (_castTargets.length === 0 || !url || url.indexOf("file://") === 0) return;
        _casting = true;
        _castCurrentUrl = url;
        for (var i = 0; i < _castTargets.length; i++)
            _castPlayOn(_castTargets[i], url, name, art);
    }

    function _castAnswer(cmd, stdout) {
        var castWhy = CastLogic.verdict(stdout);
        var castUuid = CastLogic.who(cmd, root._castTargets);
        var castAns = CastLogic.answered(root._castSession, castUuid, CastLogic.seqOf(cmd), castWhy.kind === "ok", castWhy.kind);
        // An attempt that was replaced or ended says nothing about what plays now.
        if (castAns.stale) return;
        root._castSession = castAns.session;
        var castIdx = root.castTargetIndex(castUuid);
        var castWho = castIdx >= 0 ? root._castTargets[castIdx].name : "";
        if (castWhy.kind === "ok") {
            // A device really took the stream — the wake-tone gate may now trust the casting route
            // (multi-device: any one confirmed speaker is enough to wake the room).
            alarmEngine._alarmCastConfirmed = true;
            // Playing. A level asked for while it was being asked goes out now; without one, a device with no stored
            // balance adopts the loudness it is at right now (see _castAdoptTrim).
            if (castIdx >= 0 && castAns.owed >= 0) root._castTell(root._castTargets[castIdx], castAns.owed / 100);
            else if (castIdx >= 0) root._castAdoptTrim(root._castTargets[castIdx]);
            return;
        }
        var castNo = castWhy.kind === "refused", castName = castWho || i18n("the device");
        if (castWhy.kind === "nolib") {
            // The library, not a distro's name for it: the package is python-pychromecast on Arch, python3-pychromecast
            // on Debian and Fedora, and naming one of them here would be wrong for everyone else. README carries the Arch name.
            notify(i18n("Casting needs pychromecast"), i18n("Install the pychromecast library to cast to your devices."), "dialog-warning");
        } else {
            // The device that answered is named, and a refusal of this address is not said as a device out of reach.
            console.warn("[ARP] cast: " + castWhy.log);
            notify(castNo ? i18n("%1 cannot play this station", castName) : i18n("Could not cast to %1", castName),
                   castNo ? i18n("The device refused this station's address. Another station may work.")
                          : i18n("The device could not play this station."), "dialog-error");
        }
        if (!castAns.carried) { root._castFailedName = root.isPlaying() ? "" : castWho; root._castFailedRefused = castNo; root._castEnd(); }
    }

    function castToggleDevice(dev) {
        var idx = castTargetIndex(dev.uuid);
        var targets = _castTargets.slice();
        if (idx >= 0) {
            // Stop only what WE started: a device can be checked while
            // nothing plays (or stay checked after a stop), and by the time
            // it is unchecked another app may be using it — the same rule
            // setUserVolume already lives by.
            if (root._casting) _castStopDevice(targets[idx]);
            targets.splice(idx, 1);
            _castTargets = targets;
            _castSession = CastLogic.left(_castSession, dev.uuid); _castFailedName = "";
            var resume = _casting && !_castLocalPlay;
            if (!CastLogic.carried(_castSession)) _castEnd();   // a refused device stays ticked: the last that played can leave with ticks up
            if (targets.length === 0) {
                // Multi-room dies with the last device: a leftover true here made the NEXT session's
                // first device start in multi-room mode nobody asked for.
                _castLocalPlay = false;
                if (resume) _castResumeLocally();
            }
            return;
        }
        // The devices are told FIRST, while the player still knows where the
        // episode stands and which cover is up — stopping local playback ahead
        // of _castPlay handed every receiver position 0 and no art. Local sound
        // goes quiet only if the device can take over (a file cannot be cast).
        var url = _castStreamUrl();
        var quiet = targets.length === 0 && !_castLocalPlay && isPlaying() && url !== "";
        targets.push(dev);
        _castTargets = targets;
        if (url !== "") {
            // Entering the casting state: devices checked earlier (while
            // nothing was playing) must start too, not just this one.
            if (!_casting) _castPlay(url, root.currentStation, _castArt());
            else _castPlayOn(dev, url, root.currentStation, _castArt());
        }
        if (quiet) {
            _stampPodPosition();
            timeshift.disarm(); root._tsPaused = false;   // nothing to shift on a TV
            playMusic.stop();
            playMusic.source = "";
            infoTimer.stop();
        }
    }

    // castVolumeTimer in main.qml: 400 ms after the last level it fires _castFlush. tick() is that.
    QtObject { id: castVolumeTimer; property int restarts: 0; function restart() { restarts++; } }
    function tick() { root._castFlush(); }
    // The engine's balance of a device, 1 where none is kept, and the master a device follows.
    property QtObject sync: QtObject { property var trims: ({}); function trimOf(id) { return trims[id] === undefined ? 1.0 : trims[id]; } }
    property real master: 0.5
    function castMaster() { return master; }
    property int _pendingCastVolumePct: -1

    function _castSetVolume(v) {
        if (_castTargets.length === 0) return;
        _pendingCastVolumePct = Math.round(Math.max(0, Math.min(1, v)) * 100);
        castVolumeTimer.restart();
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

    function applyCastTrim(uuid) {
        var ti = castTargetIndex(uuid);
        if (ti >= 0) _castTell(_castTargets[ti], castMaster());
    }

    function castDisconnect() {
        if (_castTargets.length === 0) return;
        if (_casting) _castStopAll();   // only what WE started
        var resume = _casting;
        _castTargets = [];
        _castLocalPlay = false;
        _castEnd(); _castSession = CastLogic.fresh(); _castFailedName = "";
        if (resume && !isPlaying()) _castResumeLocally();
    }

    readonly property var ruark: ({ "kind": "dlna", "uuid": "uuid:ruark", "name": "Ruark R5se",
                                    "location": "http://192.168.1.30:8080/desc.xml" })
    readonly property var tv: ({ "kind": "cast", "uuid": "cc-tv", "name": "Living room TV", "host": "192.168.1.20",
                                 "port": 8009, "deviceModel": "Chromecast" })

    TestCase {
        name: "CastRoads"

        function init() {
            root.log = [];
            root._execSeq = 0;
            root._casting = false;
            root._castCurrentUrl = "";
            root._castTargets = [];
            root._castLocalPlay = false;
            root._castSession = CastLogic.fresh();
            root._castFailedName = "";
            root._castFailedRefused = false;
            root._pendingCastVolumePct = -1;
            root.sync.trims = ({});
            root.master = 0.5;
            root.said = [];
            root.playing = false;
            root._tsPaused = false;
            root.streamUrl = "http://s.example/live";
            playMusic.source = "";
            alarmEngine._alarmCastConfirmed = false;
        }

        // The play commands that went out, oldest first.
        function plays() { return root.log.filter(function (l) { return l.indexOf(": CAST_PLAY;") === 0; }); }
        function notes() { return root.log.filter(function (l) { return l.indexOf("notify: ") === 0; }); }

        function test_the_only_device_refusing_ends_the_cast_and_says_so() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            verify(root._casting, "a device that is being asked does not count as casting");
            compare(root._castCurrentUrl, "http://s.example/live");
            compare(plays().length, 1);
            root._castAnswer(plays()[0], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._casting, false);
            compare(root._castFailedName, "Ruark R5se");
            // The address is forgotten, so the next start asks the device again.
            compare(root._castCurrentUrl, "");
            compare(notes(), ["notify: Could not cast to Ruark R5se"]);
            // Nothing was started here by itself, and the device stays ticked.
            verify(root.log.indexOf("resume locally") === -1);
            compare(root._castTargets.length, 1);
            compare(alarmEngine._alarmCastConfirmed, false);
        }

        function test_a_device_that_takes_the_stream_is_cast_to() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(root._casting, true);
            compare(root._castFailedName, "");
            compare(notes(), []);
            compare(alarmEngine._alarmCastConfirmed, true);
            verify(root.log.indexOf("adopt: uuid:ruark") !== -1);
        }

        function test_one_of_two_refusing_leaves_the_other_cast_to() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            compare(plays().length, 2);
            // The refusal comes first, while the television is still being asked.
            root._castAnswer(plays()[1], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._casting, true);
            compare(root._castFailedName, "");
            compare(notes(), ["notify: Could not cast to Ruark R5se"]);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(root._casting, true);
            compare(root._castCurrentUrl, "http://s.example/live");
        }

        function test_every_device_refusing_ends_the_cast() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_FAIL__ refused\n");
            compare(root._casting, true);
            root._castAnswer(plays()[1], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._casting, false);
            compare(root._castFailedName, "Ruark R5se");
            compare(notes().length, 2);
        }

        function test_a_late_refusal_of_an_older_attempt_does_not_end_the_new_one() {
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/one", "One", "");
            root._castPlay("http://s.example/two", "Two", "");
            compare(plays().length, 2);
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            compare(root._casting, true);
            // The first station's refusal comes home now: nobody's.
            root._castAnswer(plays()[0], "__CAST_FAIL__ refused\n");
            compare(root._casting, true);
            compare(root._castCurrentUrl, "http://s.example/two");
            compare(root._castFailedName, "");
            compare(notes(), []);
            // The same answer twice does nothing the second time.
            root.log = [];
            root._castAnswer(": CAST_PLAY; python3 'x' 'play' 'h' '8009' 'cc-tv' 'm' 'u' # 2", "__CAST_FAIL__\n");
            compare(root._casting, true);
            compare(root.log, []);
        }

        function test_an_older_refusal_that_comes_first_does_not_end_the_newer_attempt() {
            // Station one is asked for, the listener switches at once, and
            // one's refusal comes home before two has answered.
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/one", "One", "");
            root._castPlay("http://s.example/two", "Two", "");
            root._castAnswer(plays()[0], "__CAST_FAIL__ refused\n");
            compare(root._casting, true);
            compare(root._castCurrentUrl, "http://s.example/two");
            compare(notes(), []);
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            compare(root._casting, true);
            verify(root.log.indexOf("adopt: cc-tv") !== -1);
        }

        function test_an_answer_after_the_cast_was_ended_is_nobodys() {
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            root._castEnd();
            compare(root._casting, false);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(root._casting, false);
            compare(alarmEngine._alarmCastConfirmed, false);
            verify(root.log.indexOf("adopt: cc-tv") === -1);
            root._castAnswer(plays()[0], "__CAST_FAIL__\n");
            compare(notes(), []);
            compare(root._castFailedName, "");
        }

        function test_a_missing_library_is_said_in_its_own_words_and_ends_the_cast() {
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__NO_PYCHROMECAST__\n");
            compare(notes(), ["notify: Casting needs pychromecast"]);
            compare(root._casting, false);
            compare(root._castFailedName, "Living room TV");
        }

        function test_the_next_try_and_a_disconnect_take_the_refusal_down() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_FAIL__\n");
            compare(root._castFailedName, "Ruark R5se");
            // Play again: the device is asked again, and until it answers it counts.
            root._castPlay("http://s.example/live", "Station", "");
            compare(root._castFailedName, "");
            compare(root._casting, true);
            compare(plays().length, 2);
            root._castAnswer(plays()[1], "__CAST_FAIL__\n");
            compare(root._castFailedName, "Ruark R5se");
            // "This computer" only: the refusal goes with the devices, and nothing
            // that was not playing is started.
            root.log = [];
            root.castDisconnect();
            compare(root._castFailedName, "");
            compare(root._castTargets.length, 0);
            compare(root.log, []);
        }

        function stops() { return root.log.filter(function (l) { return l.indexOf("stop: ") === 0; }); }

        // Two devices are asked: the television plays, the Ruark refuses.
        function tvPlaysRuarkRefused() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], "__CAST_FAIL__ HTTP Error 500\n");
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(root._casting, true);
        }

        function test_the_one_device_that_played_leaving_ends_the_cast_beside_one_that_refused() {
            tvPlaysRuarkRefused();
            root.log = [];
            root.castToggleDevice(root.tv);
            // Nothing is asked and nothing plays: the Ruark's tick is no cast.
            compare(root._casting, false);
            compare(root._castCurrentUrl, "");
            compare(Object.keys(root._castSession.on).length + Object.keys(root._castSession.pending).length, 0);
            compare(root._castTargets.length, 1);
            compare(root._castTargets[0].uuid, "uuid:ruark");
            compare(stops(), ["stop: cc-tv"]);
            // Tidying the state starts no sound here, and brings no old word back.
            verify(root.log.indexOf("resume locally") === -1);
            compare(root._castFailedName, "");
        }

        function test_a_device_still_being_asked_leaving_ends_the_cast_beside_one_that_refused() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._casting, true);
            var asked = plays()[0];
            root.castToggleDevice(root.tv);
            compare(root._casting, false);
            // Its answer comes home after it left: nobody's.
            root._castAnswer(asked, "__CAST_OK__\n");
            compare(root._casting, false);
            compare(alarmEngine._alarmCastConfirmed, false);
            verify(root.log.indexOf("adopt: cc-tv") === -1);
        }

        function test_the_device_that_refused_leaving_does_not_touch_the_one_that_plays() {
            tvPlaysRuarkRefused();
            root.castToggleDevice(root.ruark);
            compare(root._casting, true);
            compare(root._castCurrentUrl, "http://s.example/live");
            verify(root._castSession.on["cc-tv"] === true);
            compare(root._castTargets.length, 1);
        }

        function test_this_computer_playing_along_goes_on_when_the_last_device_that_played_leaves() {
            root._castLocalPlay = true;
            root.playing = true;
            tvPlaysRuarkRefused();
            root.log = [];
            root.castToggleDevice(root.tv);
            compare(root._casting, false);
            // The listener's choice to hear it here too is not taken back,
            // and the player is not touched.
            compare(root._castLocalPlay, true);
            compare(root.log, ["stop: cc-tv"]);
        }

        function test_the_last_tick_leaving_brings_the_sound_home_as_before() {
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            root.log = [];
            root.castToggleDevice(root.tv);
            compare(root._casting, false);
            compare(root._castTargets.length, 0);
            compare(root.log, ["stop: cc-tv", "resume locally"]);
            // Playing along already: nothing to bring home, and multi-room ends.
            root._castTargets = [root.tv];
            root._castLocalPlay = true;
            root._castPlay("http://s.example/live", "Station", "");
            root.log = [];
            root.castToggleDevice(root.tv);
            compare(root.log, ["stop: cc-tv"]);
            compare(root._castLocalPlay, false);
            // A tick that never played leaves without a word to anybody.
            root._castTargets = [root.ruark];
            root.log = [];
            root.castToggleDevice(root.ruark);
            compare(root.log, []);
            compare(root._casting, false);
        }

        function test_a_file_that_never_sounds_still_takes_the_refusal_down() {
            // Refused in silence, then a file is picked that turns out to be
            // gone: the footer owes that file's error, not the Ruark's.
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._castFailedName, "Ruark R5se");
            playMusic.source = "file:///music/gone.mp3";
            compare(root._castFailedName, "");
            compare(root.playing, false);
            // An episode takes the player of this computer too, ticks or not.
            root._castFailedName = "Ruark R5se";
            playMusic.source = "https://pod.example/episode.mp3";
            compare(root._castFailedName, "");
        }

        function test_a_refusal_after_this_computer_went_quiet_for_the_device_is_said() {
            // Ticked while the station sounds here: the commands go out, this
            // computer goes quiet, and the refusal that comes home finds silence.
            root.playing = true;
            playMusic.source = "http://s.example/live";
            root.castToggleDevice(root.ruark);
            compare(root.playing, false);
            compare(playMusic.source, "");
            root._castAnswer(plays()[0], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._castFailedName, "Ruark R5se");
            compare(root._casting, false);
        }

        function test_unticking_the_device_that_refused_takes_its_word_down() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._castFailedName, "Ruark R5se");
            root.castToggleDevice(root.ruark);
            compare(root._castFailedName, "");
            compare(root._castTargets.length, 0);
        }

        function test_ticking_a_device_asks_it_and_quiets_this_computer() {
            root.playing = true;
            root.castToggleDevice(root.tv);
            compare(plays().length, 1);
            compare(root._casting, true);
            verify(root.log.indexOf("local stop") !== -1);
            // The second one is asked alone; the first is not asked again.
            root.castToggleDevice(root.ruark);
            compare(plays().length, 2);
            verify(plays()[1].indexOf("'dlna-play'") !== -1);
            // Nothing to send: the tick stands and nobody is asked.
            root.castDisconnect();
            root.log = [];
            root.streamUrl = "";
            root.castToggleDevice(root.tv);
            compare(root.log, []);
            compare(root._casting, false);
            compare(root._castTargets.length, 1);
        }

        function test_a_refusal_while_this_computer_plays_along_leaves_no_word_for_later() {
            // The station sounds here, so the footer has nothing to explain:
            // the notification said it, and a word kept now would come up
            // minutes later over a stop or a pause that has nothing to do with it.
            root._castTargets = [root.ruark];
            root._castLocalPlay = true;
            root.playing = true;
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._casting, false);
            compare(notes(), ["notify: Could not cast to Ruark R5se"]);
            compare(root._castFailedName, "");
        }

        function test_sound_starting_here_takes_the_refusal_down_for_good() {
            // Refused in silence, then a file from My Music is played here and paused.
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_FAIL__ HTTP Error 500\n");
            compare(root._castFailedName, "Ruark R5se");
            root.playing = true;
            compare(root._castFailedName, "");
            root.playing = false;
            compare(root._castFailedName, "", "the pause brought the old refusal back");
        }

        function test_what_is_no_answer_to_a_play_changes_nothing() {
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            var before = root.log.length;
            var odd = ["", ": CAST_PLAY; python3 'x' 'play' 'h' '8009' 'cc-tv' 'm' 'u'",
                       ": CAST_PLAY; python3 'x' 'play' 'h' '8009' 'cc-other' 'm' 'u' # 1",
                       ": CAST_PLAY; python3 'x' 'dlna-play' 'http://elsewhere/desc.xml' 'u' # 1",
                       ": CAST_STOP; python3 'x' 'stop' 'h' '8009' 'cc-tv' 'm' # 1"];
            for (var i = 0; i < odd.length; i++) {
                root._castAnswer(odd[i], "__CAST_FAIL__\n");
                root._castAnswer(odd[i], undefined);
            }
            compare(root._casting, true);
            compare(root.log.length, before);
            // An answer with no word in it is a refusal.
            root._castAnswer(plays()[0], "");
            compare(root._casting, false);
            compare(notes(), ["notify: Could not cast to Living room TV"]);
        }

        // ── what the listener is told ────────────────────────────────────
        // The helper's lines as it prints them (tests/test_cast_fault.py); the
        // first is the Ruark's answer to three addresses on 2026-11-12.

        readonly property string refusal: "__CAST_FAIL__ upnp=716 action=SetAVTransportURI http=500 Resource not found\n"
        readonly property string silence: "__CAST_FAIL__ reach=timeout action=SetAVTransportURI\n"

        function test_what_a_failed_cast_says_data() {
            var no = "The device refused this station's address. Another station may work.";
            var could = "The device could not play this station.";
            return [
                { tag: "the address is refused", out: refusal, title: "Ruark R5se cannot play this station", text: no },
                { tag: "refused at Play", out: "__CAST_FAIL__ upnp=716 action=Play http=500\n", title: "Ruark R5se cannot play this station", text: no },
                { tag: "a type it does not take", out: "__CAST_FAIL__ upnp=714 action=SetAVTransportURI http=500 Illegal MIME-type\n",
                  title: "Ruark R5se cannot play this station", text: no },
                { tag: "no answer in time", out: silence, title: "Could not cast to Ruark R5se", text: could },
                { tag: "no description", out: "__CAST_FAIL__ reach=nodesc renderer description unavailable\n",
                  title: "Could not cast to Ruark R5se", text: could },
                { tag: "a connection refused", out: "__CAST_FAIL__ reach=refused action=SetAVTransportURI\n",
                  title: "Could not cast to Ruark R5se", text: could },
                { tag: "a locked transport", out: "__CAST_FAIL__ upnp=705 action=Play http=500 Transport is locked\n",
                  title: "Could not cast to Ruark R5se", text: could },
                { tag: "a status and no code", out: "__CAST_FAIL__ action=SetAVTransportURI http=404\n", title: "Could not cast to Ruark R5se", text: could },
                { tag: "the line of before", out: "__CAST_FAIL__ HTTP Error 500\n", title: "Could not cast to Ruark R5se", text: could },
                { tag: "a Chromecast's wait", out: "__CAST_FAIL__ the device did not take the stream within 12s\n",
                  title: "Could not cast to Ruark R5se", text: could },
                { tag: "a receiver's failed load", out: "__CAST_FAIL__ load=104 action=play the receiver could not load the stream\n",
                  title: "Could not cast to Ruark R5se", text: could },
                { tag: "the sentinel alone", out: "__CAST_FAIL__\n", title: "Could not cast to Ruark R5se", text: could },
                { tag: "no word at all", out: "", title: "Could not cast to Ruark R5se", text: could }
            ];
        }
        function test_what_a_failed_cast_says(data) {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], data.out);
            // Whatever the reason, it is a failure: nothing is cast to.
            compare(root._casting, false);
            compare(notes(), ["notify: " + data.title]);
            compare(root.said, [data.text]);
            // The footer says the same as the notification's first line.
            compare(root.footer(), data.title);
        }

        function test_the_footer_follows_the_last_answer_and_not_an_older_one() {
            root._castTargets = [root.ruark];
            var answers = [refusal, silence, refusal, "__CAST_FAIL__\n", refusal];
            var words = ["Ruark R5se cannot play this station", "Could not cast to Ruark R5se", "Ruark R5se cannot play this station",
                         "Could not cast to Ruark R5se", "Ruark R5se cannot play this station"];
            for (var i = 0; i < answers.length; i++) {
                root._castPlay("http://s.example/live", "Station", "");
                // While it is being asked the old word is down.
                compare(root.footer(), "Casting to Ruark R5se");
                root._castAnswer(plays()[i], answers[i]);
                compare(root.footer(), words[i]);
            }
        }

        function test_a_missing_library_is_not_a_refusal_of_the_address() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], refusal);
            compare(root.footer(), "Ruark R5se cannot play this station");
            root.castDisconnect();
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], "__NO_PYCHROMECAST__\n");
            compare(root.footer(), "Could not cast to Living room TV");
            compare(root.said[1], "Install the pychromecast library to cast to your devices.");
        }

        function test_the_television_plays_and_the_ruark_refused_only_the_television_is_named() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            // Both are being asked.
            compare(root._castName, "2 devices");
            compare(root.footer(), "Casting to 2 devices");
            root._castAnswer(plays()[1], refusal);
            // The Ruark is still ticked, and it is not cast to.
            compare(root._castTargets.length, 2);
            compare(root._castName, "Living room TV");
            compare(root.footer(), "Casting to Living room TV");
            compare(notes(), ["notify: Ruark R5se cannot play this station"]);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(root.footer(), "Casting to Living room TV");
            // The Ruark is asked again with the next station and takes it: two again.
            root._castPlay("http://s.example/other", "Other", "");
            root._castAnswer(plays()[2], "__CAST_OK__\n");
            root._castAnswer(plays()[3], "__CAST_OK__\n");
            compare(root._castName, "2 devices");
            compare(root.footer(), "Casting to 2 devices");
            // The television out of reach this time: the one that plays is named.
            root._castPlay("http://s.example/third", "Third", "");
            root._castAnswer(plays()[4], silence);
            root._castAnswer(plays()[5], "__CAST_OK__\n");
            compare(root.footer(), "Casting to Ruark R5se");
            compare(notes()[1], "notify: Could not cast to Living room TV");
        }

        function test_the_last_device_that_played_leaving_ends_the_words_too() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], refusal);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(root.footer(), "Casting to Living room TV");
            root.castToggleDevice(root.tv);
            // The Ruark's tick is up and nothing is cast to: no "Casting to", and no old refusal.
            compare(root._casting, false);
            compare(root._castName, "");
            compare(root.footer(), "");
            compare(root._castTargets.length, 1);
        }

        function test_a_file_or_an_episode_played_and_paused_does_not_read_as_the_refusal() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], refusal);
            compare(root.footer(), "Ruark R5se cannot play this station");
            // A file from My Music: the player is handed it, plays, and is paused.
            playMusic.source = "file:///music/song.mp3";
            compare(root.footer(), "");
            root.playing = true;
            compare(root.footer(), "");
            root.playing = false;
            compare(root.footer(), "", "the pause brought the refusal back");
            // The same with an episode after a device that was out of reach.
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], silence);
            compare(root.footer(), "Could not cast to Ruark R5se");
            playMusic.source = "https://pod.example/episode.mp3";
            root.playing = true;
            root.playing = false;
            compare(root.footer(), "");
        }

        function test_a_refusal_while_this_computer_plays_along_is_notified_and_not_kept() {
            root._castTargets = [root.ruark];
            root._castLocalPlay = true;
            root.playing = true;
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], refusal);
            compare(notes(), ["notify: Ruark R5se cannot play this station"]);
            compare(root.footer(), "");
            root.playing = false;
            compare(root.footer(), "");
        }

        // ── the device's own row in the output menu ──────────────────────

        function test_a_device_that_refused_wears_its_mark_until_it_is_asked_again() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            verify(!root.castRefused("uuid:ruark"), "marked while it is still being asked");
            root._castAnswer(plays()[0], refusal);
            // The cast is over, the tick is up, and the row says why nothing plays there.
            compare(root._casting, false);
            compare(root._castTargets.length, 1);
            verify(root.castRefused("uuid:ruark"));
            // The next station is offered to it: no mark while it is asked, and its answer decides.
            root._castPlay("http://s.example/other", "Other", "");
            verify(!root.castRefused("uuid:ruark"));
            root._castAnswer(plays()[1], refusal);
            verify(root.castRefused("uuid:ruark"));
            root._castPlay("http://s.example/third", "Third", "");
            root._castAnswer(plays()[2], "__CAST_OK__\n");
            verify(!root.castRefused("uuid:ruark"));
            compare(root.footer(), "Casting to Ruark R5se");
        }

        function test_unticking_takes_the_mark_down_and_a_new_tick_starts_clean() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], refusal);
            verify(root.castRefused("uuid:ruark"));
            root.castToggleDevice(root.ruark);
            verify(!root.castRefused("uuid:ruark"));
            // Ticked again while nothing plays: nobody is asked, and nothing is said of it.
            root.streamUrl = "";
            root.castToggleDevice(root.ruark);
            compare(root._castTargets.length, 1);
            verify(!root.castRefused("uuid:ruark"));
        }

        function test_this_computer_only_takes_every_mark_down() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], refusal);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            verify(root.castRefused("uuid:ruark"));
            root.castDisconnect();
            verify(!root.castRefused("uuid:ruark"));
            root._castTargets = [root.ruark];
            verify(!root.castRefused("uuid:ruark"), "a tick put back found the old mark");
        }

        function test_only_the_device_that_refused_is_marked_and_the_other_leaving_does_not_unmark_it() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], refusal);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            verify(root.castRefused("uuid:ruark"));
            verify(!root.castRefused("cc-tv"));
            // The television is unticked: the cast ends, and the Ruark's row still says what it said.
            root.castToggleDevice(root.tv);
            compare(root._casting, false);
            verify(root.castRefused("uuid:ruark"));
            compare(root.footer(), "");
        }

        function test_a_stop_leaves_the_mark_and_the_next_station_takes_it_down() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[1], refusal);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            // What a stop does to the cast.
            root._castEnd();
            compare(root._casting, false);
            verify(root.castRefused("uuid:ruark"));
            root._castPlay("http://s.example/other", "Other", "");
            verify(!root.castRefused("uuid:ruark"));
        }

        function test_a_device_that_did_not_refuse_the_address_is_not_marked_data() {
            return [
                { tag: "no answer in time", out: silence },
                { tag: "no description", out: "__CAST_FAIL__ reach=nodesc renderer description unavailable\n" },
                { tag: "a locked transport", out: "__CAST_FAIL__ upnp=705 action=Play http=500 Transport is locked\n" },
                { tag: "the line of before", out: "__CAST_FAIL__ HTTP Error 500\n" },
                { tag: "a missing library", out: "__NO_PYCHROMECAST__\n" },
                { tag: "no word at all", out: "" },
                { tag: "taken", out: "__CAST_OK__\n" }
            ];
        }
        function test_a_device_that_did_not_refuse_the_address_is_not_marked(data) {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], data.out);
            verify(!root.castRefused("uuid:ruark"));
        }

        function test_a_refusal_that_is_nobodys_marks_nobody() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/one", "One", "");
            root._castPlay("http://s.example/two", "Two", "");
            // The first station's refusal, while the second is being asked.
            root._castAnswer(plays()[0], refusal);
            verify(!root.castRefused("uuid:ruark"));
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            verify(!root.castRefused("uuid:ruark"));
            // And one that comes home after the device was unticked.
            root._castPlay("http://s.example/three", "Three", "");
            root.castToggleDevice(root.ruark);
            root._castAnswer(plays()[2], refusal);
            verify(!root.castRefused("uuid:ruark"));
        }

        // ── who is sent a level ──────────────────────────────────────────
        // The widget's slider, its mute, the alarm's level and the room's mute all end in _castSetVolume
        // and, 400 ms later, in _castFlush; a device's own balance row ends in applyCastTrim. What the
        // row's gestures ask for is tst_volumeroad's; here is who is told.

        // The level commands that went out, oldest first, as "<device> <level>".
        function levels() {
            return root.log.filter(function (l) { return l.indexOf(": CAST_VOL;") === 0; }).map(function (l) {
                var level = / '([0-9.]+)' # \d+$/.exec(l);
                var who = l.indexOf(" 'dlna-volume' '" + root.ruark.location + "' ") !== -1 ? "ruark"
                        : l.indexOf(" 'volume' '192.168.1.20' '8009' 'cc-tv' 'Chromecast' ") !== -1 ? "tv" : "somebody else";
                return who + " " + (level ? level[1] : "no level");
            });
        }

        function test_a_move_a_mute_and_an_unmute_reach_only_the_device_that_plays() {
            tvPlaysRuarkRefused();
            // The slider moves.
            root._castSetVolume(0.3);
            compare(levels(), [], "a level went out before the timer");
            root.tick();
            compare(levels(), ["tv 0.300"]);
            // Mute is level zero, and unmute the level of before.
            root._castSetVolume(0);
            root.tick();
            root._castSetVolume(0.3);
            root.tick();
            compare(levels(), ["tv 0.300", "tv 0.000", "tv 0.300"]);
            compare(root._pendingCastVolumePct, -1);
            // The same with the refusal as the helper spells it now, and the Ruark first in the list.
            root.castDisconnect();
            root.log = [];
            root._castTargets = [root.ruark, root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], refusal);
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            root._castSetVolume(0.45);
            root.tick();
            compare(levels(), ["tv 0.450"]);
        }

        function test_devices_that_play_are_sent_every_level_as_before() {
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            root._castSetVolume(0.5);
            root.tick();
            compare(levels(), ["tv 0.500"]);
            // Its own balance is applied to what it is sent.
            root.sync.trims = ({ "cc-tv": 0.5 });
            root._castSetVolume(0.8);
            root.tick();
            compare(levels(), ["tv 0.500", "tv 0.400"]);
            // Two that play are both told, in the order they are listed in.
            root.castToggleDevice(root.ruark);
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            root.log = [];
            root._castSetVolume(1);
            root.tick();
            compare(levels(), ["tv 0.500", "ruark 1.000"]);
            // A tick of the timer with nothing waiting sends nothing.
            root.tick();
            compare(levels().length, 2);
        }

        function test_devices_that_all_refused_are_sent_nothing() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], silence);
            root._castAnswer(plays()[1], refusal);
            compare(root._casting, false);
            root._castSetVolume(0.3);
            root.tick();
            root._castSetVolume(0);
            root.tick();
            compare(levels(), []);
            // Nothing is kept waiting for them either.
            compare(root._pendingCastVolumePct, -1);
            root._castPlay("http://s.example/other", "Other", "");
            root._castAnswer(plays()[2], "__CAST_OK__\n");
            compare(levels(), []);
            verify(root.log.indexOf("adopt: cc-tv") !== -1);
        }

        function test_a_device_that_is_only_ticked_is_sent_nothing() {
            root._castTargets = [root.ruark, root.tv];
            root._castSetVolume(0.3);
            root.tick();
            root.applyCastTrim("uuid:ruark");
            root.applyCastTrim("cc-tv");
            compare(levels(), []);
            // And after a stop: the ticks are up, nothing is cast.
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            root._castEnd();
            root._castSetVolume(0.3);
            root.tick();
            compare(levels(), []);
        }

        function test_a_device_still_being_asked_is_sent_its_level_with_its_answer_and_not_before() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            root.log = root.log.filter(function (l) { return l.indexOf("adopt") === -1; });
            // The slider moves while the Ruark has not answered.
            root._castSetVolume(0.3);
            root.tick();
            compare(levels(), ["tv 0.300"]);
            // It takes the stream: now it is told, once, and the television is not told again.
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            compare(levels(), ["tv 0.300", "ruark 0.300"]);
            // The level that was asked for stands in for the loudness it had.
            verify(root.log.indexOf("adopt: uuid:ruark") === -1);
            // It is owed nothing after that.
            root._castPlay("http://s.example/other", "Other", "");
            root._castAnswer(plays()[2], "__CAST_OK__\n");
            root._castAnswer(plays()[3], "__CAST_OK__\n");
            compare(levels().length, 2);
        }

        function test_a_device_that_refuses_after_a_level_was_asked_for_never_gets_it() {
            root._castTargets = [root.tv, root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            root._castSetVolume(0.3);
            root.tick();
            root._castAnswer(plays()[1], refusal);
            compare(levels(), ["tv 0.300"]);
            // The next station, which it takes: it keeps the loudness it has, as a device that joins does.
            root.log = [];
            root._castPlay("http://s.example/other", "Other", "");
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            compare(levels(), []);
            verify(root.log.indexOf("adopt: uuid:ruark") !== -1);
        }

        function test_an_alarms_level_and_a_mute_reach_a_device_that_answers_after_the_timer_data() {
            return [ { tag: "the alarm's level", level: 0.9, sent: "ruark 0.900" }, { tag: "a mute", level: 0, sent: "ruark 0.000" },
                     { tag: "all the way up", level: 1, sent: "ruark 1.000" }, { tag: "past the top", level: 7, sent: "ruark 1.000" },
                     { tag: "below nothing", level: -3, sent: "ruark 0.000" } ];
        }
        function test_an_alarms_level_and_a_mute_reach_a_device_that_answers_after_the_timer(data) {
            // The alarm starts the station and asks for its level at once; the device answers later than the timer fires.
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castSetVolume(data.level);
            root.tick();
            compare(levels(), []);
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(levels(), [data.sent]);
        }

        function test_the_last_level_asked_for_is_the_one_a_late_device_gets() {
            root._castTargets = [root.ruark];
            root._castPlay("http://s.example/live", "Station", "");
            root._castSetVolume(0.2); root.tick();
            root._castSetVolume(0.6); root.tick();
            root._castSetVolume(0.4);
            // The third still waits for the timer when the answer comes: the device gets the second now...
            root._castAnswer(plays()[0], "__CAST_OK__\n");
            compare(levels(), ["ruark 0.600"]);
            // ...and the third when the timer fires.
            root.tick();
            compare(levels(), ["ruark 0.600", "ruark 0.400"]);
        }

        function test_a_level_owed_does_not_outlive_the_tick_or_the_cast_it_was_asked_under() {
            root._castTargets = [root.tv];
            root._castPlay("http://s.example/live", "Station", "");
            root._castSetVolume(0.3);
            root.tick();
            // Unticked before it answered, and ticked again.
            root.castToggleDevice(root.tv);
            root.castToggleDevice(root.tv);
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            compare(levels(), []);
            verify(root.log.indexOf("adopt: cc-tv") !== -1);
            // Asked, a level asked for, and the cast stopped before the answer.
            root.log = [];
            root._castPlay("http://s.example/other", "Other", "");
            root._castSetVolume(0.7);
            root.tick();
            root._castEnd();
            root._castPlay("http://s.example/third", "Third", "");
            root._castAnswer(plays()[1], "__CAST_OK__\n");
            compare(levels(), []);
        }

        function test_a_devices_own_balance_row_reaches_it_only_while_it_plays() {
            tvPlaysRuarkRefused();
            root.log = [];
            // The Ruark's balance is moved in the menu: stored by the engine, and nothing is sent to a device
            // that may be playing its own radio.
            root.applyCastTrim("uuid:ruark");
            compare(levels(), []);
            root.sync.trims = ({ "cc-tv": 0.5 });
            root.applyCastTrim("cc-tv");
            compare(levels(), ["tv 0.250"]);
            // While it is being asked again it is not told either.
            root._castPlay("http://s.example/other", "Other", "");
            root.applyCastTrim("cc-tv");
            root.applyCastTrim("uuid:ruark");
            compare(levels().length, 1);
            root.applyCastTrim("uuid:nobody");
            compare(levels().length, 1);
        }

        function test_four_hundred_moves_beside_a_device_that_refused() {
            tvPlaysRuarkRefused();
            root.log = [];
            for (var i = 0; i < 400; i++) { root._castSetVolume((i % 101) / 100); root.tick(); }
            var sent = levels();
            compare(sent.length, 400);
            compare(sent.filter(function (l) { return l.indexOf("tv ") !== 0; }), []);
        }

        function test_four_hundred_refusals_in_a_row_leave_one_name_and_no_cast() {
            root._castTargets = [root.ruark];
            for (var i = 0; i < 400; i++) {
                root._castPlay("http://s.example/live", "Station", "");
                root._castAnswer(plays()[i], "__CAST_FAIL__\n");
            }
            compare(root._casting, false);
            compare(root._castFailedName, "Ruark R5se");
            compare(Object.keys(root._castSession.pending).length, 0);
            compare(Object.keys(root._castSession.on).length, 0);
        }
    }
}
