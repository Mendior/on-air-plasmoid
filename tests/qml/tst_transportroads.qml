// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// An episode plays, the headset says Pause, and later Play: the first
// station of the list came on. Since 2026.44 a pause keeps the file, and
// the player pauses where it stands so the page goes on showing it. This
// stands main.qml's transport(), playLast(), the facts they are answered
// from, the row's tap and the doors of the roads that start sound by
// themselves up around a player that only counts, word for word as
// main.qml has them, and walks the roads a listener can take from a pause.
// Everything else here is a stand-in that leaves the state its real
// namesake leaves. What it proves is this copy; test_invariants holds
// main.qml to the same lines.
import QtQuick
import QtMultimedia
import QtTest

import "../../package/contents/ui/TransportLogic.js" as TransportLogic
import "../../package/contents/ui/PodcastLogic.js" as PodcastLogic

Item {
    id: root
    width: 100
    height: 100

    QtObject {
        id: playMusic
        property string source: ""
        property int playbackState: MediaPlayer.StoppedState
        property real position: 0
        property real duration: 1800000
        property bool seekable: true
        function stop() { playbackState = MediaPlayer.StoppedState; position = 0 }
        function pause() { root.log.push("pauses"); playbackState = MediaPlayer.PausedState }
        function play() { root.log.push("plays on"); playbackState = MediaPlayer.PlayingState }
    }
    QtObject {
        id: timeshift
        property string bufPath: "/run/user/1000/onair/ts-7.mka"
        property bool shifted: false
        property bool ready: false
    }
    QtObject { id: fadeOutAnimation; property bool running: false }
    QtObject { id: alarmEngine; property int stoodDown: 0; function standDown() { stoodDown++ } }
    ListModel { id: stationsModel }

    property var log: []
    property var bookmarks: ({})
    property var upNext: []
    property bool continuous: true
    property bool sleepFading: false
    property bool _casting: false
    property bool _wantsPlaying: false
    property bool _tsPaused: false
    readonly property bool tsPauseAvailable: timeshift.ready
    property bool _alarmFiring: false
    property int _volumeOverridePct: -1
    property string _previewUrl: ""
    property var _lastAudition: null
    property int lastPlay: -1
    property string currentStation: ""
    property string metadata: ""
    property string _alarmToneUrl: "file:///usr/share/onair/chime.ogg"
    property string _podPlayingKey: ""
    property string _podPlayingUrl: ""
    property string _podPlayingRawUrl: ""
    property string _podPlayingArt: ""
    property string _podPlayingShow: ""
    property string _currentEpisodeFeed: ""
    property string _podPendingSeekUrl: ""
    property int _podPendingSeekSec: 0
    property int deskWrites: 0

    function isPlaying() { return playMusic.playbackState === MediaPlayer.PlayingState }
    function _mprisQueueWrite() { deskWrites++ }
    function setPodcastRate(r) { log.push("rate " + r) }
    function setUserVolume(v) { log.push("volume " + v) }

    // ── main.qml's own lines: the kept file and the facts ───────────────
    property var _pausedFile: null
    on_PausedFileChanged: _mprisQueueWrite()
    readonly property var _nowPlays: ({ "audible": isPlaying(), "preview": _previewUrl !== "", "source": playMusic.source.toString(),
        "episode": _podPlayingKey !== "" ? _podPlayingUrl : "", "tone": _alarmToneUrl.toString(), "bufferPath": timeshift.bufPath, "shifted": timeshift.shifted,
        "casting": _casting, "stopping": fadeOutAnimation.running, "raw": _podPlayingRawUrl, "title": currentStation, "key": _podPlayingKey, "show": _podPlayingShow, "art": _podPlayingArt, "feed": _currentEpisodeFeed })
    readonly property var _keyFacts: [isPlaying(), _casting, _wantsPlaying, _tsPaused, timeshift.shifted, TransportLogic.ownFile(_nowPlays),
        _pausedFile !== null, TransportLogic.inPlace(_pausedFile, playMusic.playbackState === MediaPlayer.PausedState), _previewComing]
    readonly property bool _previewComing: TransportLogic.auditionComing(_previewUrl, _friendlyError)
    readonly property string bigFace: TransportLogic.face(_keyFacts, tsPauseAvailable)
    readonly property bool canPlay: TransportLogic.canPlay(isPlaying(), _casting, _tsPaused, timeshift.shifted, _lastAudition !== null, lastPlay, stationsModel.count, _pausedFile !== null)
    onCanPlayChanged: _mprisQueueWrite()
    readonly property bool onOrKept: playMusic.playbackState === MediaPlayer.PlayingState || _casting || _pausedFile !== null
    // The Stop beside the big button, as the Playing page asks for it.
    readonly property bool stopBeside: TransportLogic.stopOffered(isPlaying(), root._casting,
                                                                  root._wantsPlaying, root._tsPaused, root.tsShifted,
                                                                  root.bigFace === "pause", root._pausedFile !== null)
    readonly property bool tsShifted: timeshift.shifted

    // ── stand-ins ────────────────────────────────────────────────────────
    function _stampPodPosition() {
        if (root._podPlayingKey !== "" && isPlaying() && playMusic.position > 5000)
            root.bookmarks[root._podPlayingKey] = Math.round(playMusic.position / 1000);
    }
    function _flushPodPositions() {}
    function _abortSleepFade() { root.sleepFading = false }
    function _orderLapsed() { return false }
    function _sound(name, url) {
        root._friendlyError = "";               // startWithFade: a fresh attempt clears the sentence
        root._tsPaused = false;
        if (root._previewUrl === "") root._lastAudition = null;
        root.currentStation = name;
        playMusic.stop();
        playMusic.source = url;
        playMusic.playbackState = MediaPlayer.PlayingState;
    }
    function stopWithFade() {
        log.push("stop");
        _stampPodPosition();
        root._wantsPlaying = false;
        timeshift.shifted = false; timeshift.ready = false; root._tsPaused = false;
        root._pausedFile = null;
        alarmEngine.standDown(); root._volumeOverridePct = -1;
        root._previewUrl = ""; root._friendlyError = "";
        root._casting = false;
        if (fadeOutAnimation.running) return;   // the fade finishes the stop, see stopFades()
        playMusic.stop();
        playMusic.source = "";
        root.currentStation = "";
        root._podPlayingKey = ""; root._podPlayingUrl = ""; root._podPlayingRawUrl = "";
        root._podPlayingArt = ""; root._podPlayingShow = "";
    }
    function timeshiftPause() {
        if (timeshift.shifted) { playMusic.pause(); return true; }
        if (root._casting || root._podPlayingKey !== "" || !timeshift.ready) return false;
        log.push("park");
        root._wantsPlaying = false; root._tsPaused = true; playMusic.stop();
        return true;
    }
    function timeshiftResume() { log.push("park resumes"); root._tsPaused = false; root._wantsPlaying = true; playMusic.playbackState = MediaPlayer.PlayingState }
    function refreshServer(k) {
        log.push("station " + k);
        lastPlay = k; root._lastAudition = null; root._previewUrl = ""; root._wantsPlaying = true;
        _podHandoff();
        _sound(stationsModel.get(k).name, stationsModel.get(k).hostname);
    }
    function previewStation(name, url) {
        log.push("audition " + url);
        root._friendlyError = "";
        root._previewUrl = url; root._lastAudition = { "name": name, "url": url };
        _podHandoff();
        _sound(name, url);
    }
    // An audition on its way to sound: its address stands and nothing plays yet. On the relay road the player
    // is started when the tap is up, one to four seconds later; a plain one first asks where its playlist leads.
    function auditionArms(name, url) {
        log.push("audition arms " + url);
        root._friendlyError = "";
        root._previewUrl = url; root._lastAudition = { "name": name, "url": url }; root._wantsPlaying = false;
        _podHandoff();
        root._tsPaused = false; root.currentStation = name; playMusic.stop(); playMusic.source = "";
    }
    // The ladder's last word, as _previewRescueAudition says it when nothing is left to try: the
    // sentence goes up and the address is left standing, for the row's mark and the Playing page's star.
    property string _friendlyError: ""
    function lastWord(url) {
        if (root._previewUrl !== url) return;
        root._friendlyError = "The station did not answer. Try another result.";
    }
    // The late answer: the tap coming up, the playlist's address. It is dropped once the address is gone.
    function lateAnswer(name, url) {
        if (root._previewUrl !== url) return;
        log.push("audition sounds");
        _sound(name, url);
    }
    function _podPlayUpNextHead() {
        if (root.upNext.length === 0) return false;
        var e = root.upNext.shift();
        playPodcastEpisode(e, "Queued", "queued-" + e, "", "", "");
        return true;
    }
    // The wake-up, as AlarmEngine starts its station and its episode.
    function alarmFiresStation(k) { _podHandoff(); log.push("alarm"); root._wantsPlaying = true; lastPlay = k; _sound("Wake-up", stationsModel.get(k).hostname) }
    function alarmFiresEpisode(furl, key) {
        root._volumeOverridePct = 40;
        root._alarmFiring = true;
        if (!(isPlaying() && playMusic.source.toString() === furl)) playPodcastEpisode(furl, "Morning", key, "The Show", "", "");
        root._alarmFiring = false;
    }
    // The sleep timer's last tick.
    function sleepTimerEnds() { if (isPlaying() || _casting || _wantsPlaying) stopWithFade(); }
    // The star's and the trash's write, when the list is not kept playing.
    function listWriteStops() { playMusic.stop() }

    // ── main.qml's own lines: the roads ──────────────────────────────────
    function _podHandoff() {
        _stampPodPosition();
        _flushPodPositions();
        _podPlayingKey = "";
        _podPlayingUrl = "";
        _podPlayingRawUrl = "";
        _podPlayingArt = "";
        _podPlayingShow = "";
        _podPendingSeekUrl = "";
        _pausedFile = null;
        _currentEpisodeFeed = "";
    }

    function playPodcastEpisode(fileUrl, title, key, showTitle, showArt, feedUrl) {
        var raw = fileUrl.toString();
        var isThisOn = playMusic.source.toString() === raw || (_podPlayingRawUrl !== "" && _podPlayingRawUrl === raw);
        if (TransportLogic.rowTap(isThisOn, isPlaying(), _pausedFile !== null, root._alarmFiring)) { transport("PlayPause"); return; }
        playLocalFile(fileUrl, title);
        log[log.length - 1] = "episode " + key;
        root._currentEpisodeFeed = feedUrl; root._podPlayingKey = key; root._podPlayingRawUrl = raw;
        root._podPlayingUrl = playMusic.source; root._podPlayingArt = showArt; root._podPlayingShow = showTitle;
        if (root.bookmarks[key] > 8) { root._podPendingSeekUrl = playMusic.source; root._podPendingSeekSec = root.bookmarks[key] - 3; }
    }

    function playLocalFile(fileUrl, displayName) {
        var urlStr = fileUrl.toString();
        if (TransportLogic.rowTap(playMusic.source.toString() === urlStr, isPlaying(), _pausedFile !== null, root._alarmFiring)) { transport("PlayPause"); return; }
        _podHandoff();
        if (!root._alarmFiring) {
            alarmEngine.standDown();
            _volumeOverridePct = -1;
        }
        log.push("file " + urlStr);
        root._previewUrl = ""; lastPlay = -1; root._wantsPlaying = false;
        _sound(displayName, urlStr);
    }

    function playLast() {
        var pick = TransportLogic.bareplay(root._lastAudition !== null, lastPlay, stationsModel.count, root._pausedFile !== null);
        if (pick.what === "paused") {
            var held = root._pausedFile, sec = TransportLogic.needle(held.sec, playMusic.playbackState === MediaPlayer.PausedState,
                                                                     playMusic.position, _podPendingSeekUrl === playMusic.source.toString());
            root._pausedFile = null;   // first: the start would read a kept file as its own row tapped
            if (held.episode) playPodcastEpisode(held.url, held.title, held.key, held.show, held.art, held.feed);
            else playLocalFile(held.url, held.title);
            if (sec >= 0) { _podPendingSeekUrl = playMusic.source.toString(); _podPendingSeekSec = sec; }
        } else if (pick.what === "audition") {
            var a = root._lastAudition;
            previewStation(a.name, a.url, a.favicon, a.uuid, a.rawUrl, a.codec, a.bitrate);
        } else if (pick.what === "station") {
            refreshServer(pick.index);
        }
    }

    function transport(cmd) {
        var act = TransportLogic.keyFor(cmd, _keyFacts);
        if (act === "pause" && timeshiftPause()) return;
        if (act === "stop" || act === "pause") stopWithFade();
        else if (act === "keep") {
            _stampPodPosition(); _flushPodPositions(); alarmEngine.standDown(); _volumeOverridePct = -1; _abortSleepFade();
            root._pausedFile = TransportLogic.filePause(Object.assign({ "positionMs": playMusic.position, "seekSec": _podPendingSeekUrl === playMusic.source.toString() ? _podPendingSeekSec : -1 }, _nowPlays));
            playMusic.pause();
        } else if (act === "resume") timeshiftResume();
        else if (act === "unpause") { root._pausedFile = null; playMusic.play(); }
        else if (act === "bare") playLast();
    }

    function _mprisDispatch(cmd) {
        // Next, Previous, Seek and SetPosition go inside the episode that is
        // held, playing or paused, and never to a station over it: jumping
        // to the radio over a half-heard episode was the bridge's single
        // worst podcast habit. What moves the needle, and where to, is
        // TransportLogic.skipRoad and deskNeedle.
        var road = TransportLogic.skipRoad(_nowPlays, _pausedFile, playMusic.playbackState === MediaPlayer.PausedState, playMusic.seekable);
        var to = road === "skip" ? TransportLogic.deskNeedle(cmd, playMusic.position, playMusic.duration) : -1;
        if (to >= 0) {
            playMusic.position = to;
            // The second a pause keeps follows the needle, and the desk is told where it stands.
            if (_pausedFile !== null) _pausedFile = TransportLogic.keptAt(_pausedFile, to);
            _mprisQueueWrite();
        } else if (cmd === "Stop" || cmd === "Pause" || cmd === "PlayPause" || cmd === "Play") {
            transport(cmd);
        } else if (road === "station" && (cmd === "Next" || cmd === "Previous")) {
            var k = TransportLogic.stationStep(cmd, lastPlay, stationsModel.count);
            if (k >= 0) { lastPlay = k; refreshServer(k); }
        } else if (cmd.indexOf("Rate ") === 0) {
            var rr = parseFloat(cmd.substring(5));
            if (isFinite(rr) && _podPlayingKey !== "") setPodcastRate(rr);
        } else if (cmd.indexOf("Volume ") === 0) {
            var v = parseFloat(cmd.substring(7));
            if (!isNaN(v)) {
                setUserVolume(v);
            }
        }
    }

    function podcastSkip(deltaSec) {
        // A seekable EPISODE skips whatever its scheme — a streamed one is
        // as skippable as the file it would have been.
        var skipSrc = playMusic.source.toString();
        if (skipSrc.indexOf("file://") !== 0
            && !(root._podPlayingKey !== "" && skipSrc === root._podPlayingUrl)) return;
        playMusic.position = PodcastLogic.skipTarget(playMusic.position, deltaSec,
                                                     playMusic.duration);
        if (_pausedFile !== null) _pausedFile = TransportLogic.keptAt(_pausedFile, playMusic.position);
    }

    // The player's playing edge, as far as the header goes.
    Connections {
        target: playMusic
        function onPlaybackStateChanged() {
            if (!isPlaying() && root._pausedFile === null) {
                root.metadata = "";
            }
        }
    }

    // The three roads that go on with an episode by themselves, from their doors on.
    function stallTimerFires() {
        if (root._tsPaused || root._pausedFile !== null || _orderLapsed()) return;
        if (root._podPlayingKey !== ""
            && playMusic.source.toString() === root._podPlayingUrl) {
            var stSrc = playMusic.source;
            playMusic.stop();
            playMusic.source = "";
            playMusic.source = stSrc;
            playMusic.play();
        }
    }
    function playerErrs() {
        var pfSrc = playMusic.source.toString();
        if (root._podPlayingKey !== "" && pfSrc === root._podPlayingUrl) {
            root._podPlayingKey = ""; root._podPlayingUrl = ""; root._podPlayingRawUrl = "";
            if (root._pausedFile === null && root._podPlayUpNextHead()) return;
            if (root._pausedFile === null && root.continuous !== false) {
                playPodcastEpisode("file:///home/u/Podcasts/next.mp3", "Next", "guid-next", "", "", "");
                return;
            }
        }
    }
    function mediaEnds() {
        if (root._podPlayingKey === "" || playMusic.source.toString() !== root._podPlayingUrl) return;
        root._podPlayingKey = ""; root._podPlayingUrl = ""; root._podPlayingRawUrl = "";
        if (!fadeOutAnimation.running && root._pausedFile === null && !root._podPlayUpNextHead()
            && root.continuous !== false) {
            playPodcastEpisode("file:///home/u/Podcasts/next.mp3", "Next", "guid-next", "", "", "");
        }
    }

    // What the desk is told it may ask for, as _mprisWriteState works it out.
    function desk() {
        var road = TransportLogic.skipRoad(_nowPlays, _pausedFile, playMusic.playbackState === MediaPlayer.PausedState, playMusic.seekable);
        return { "canGoNext": road === "skip" || (road === "station" && stationsModel.count > 1),
                 "canGoPrevious": road === "skip" || (road === "station" && stationsModel.count > 1),
                 "canSeek": road === "skip" };
    }

    // What the desk is told, from the facts _mprisWriteState hands over.
    function status() { return TransportLogic.playbackStatus(isPlaying(), _casting, _tsPaused, timeshift.shifted, _pausedFile !== null) }

    TestCase {
        name: "TransportRoads"
        when: windowShown

        readonly property string disk: "file:///home/u/Podcasts/ep%201.mp3"
        readonly property string other: "file:///home/u/Podcasts/ep%202.mp3"
        readonly property string stream: "https://cdn.example/show/ep1.mp3?x=1"
        readonly property string song: "file:///home/u/Music/OnAir/song.flac"

        function init() {
            stationsModel.clear()
            stationsModel.append({ "name": "First FM", "hostname": "http://first.example/live" })
            stationsModel.append({ "name": "Second FM", "hostname": "http://second.example/live" })
            playMusic.playbackState = MediaPlayer.StoppedState; playMusic.source = ""; playMusic.position = 0
            playMusic.duration = 1800000; playMusic.seekable = true
            timeshift.shifted = false; timeshift.ready = false; fadeOutAnimation.running = false
            root._casting = false; root._wantsPlaying = false; root._tsPaused = false; root._alarmFiring = false
            root._previewUrl = ""; root._lastAudition = null; root.lastPlay = -1; root.currentStation = ""
            root._podPlayingKey = ""; root._podPlayingUrl = ""; root._podPlayingRawUrl = ""
            root._podPlayingArt = ""; root._podPlayingShow = ""; root._currentEpisodeFeed = ""
            root._podPendingSeekUrl = ""; root._podPendingSeekSec = 0
            root._pausedFile = null; root._volumeOverridePct = -1; root.sleepFading = false; root._friendlyError = ""
            root.metadata = ""; root.upNext = []; root.continuous = true
            root.bookmarks = ({})
            alarmEngine.stoodDown = 0
            root.log = []
            root.deskWrites = 0
        }

        // An episode already playing at a second, its resume seek landed.
        function episode(url, sec) {
            root.playPodcastEpisode(url, "Episode one", "guid-1", "The Show", "http://art.example/c.png", "http://feed.example/rss")
            root._podPendingSeekUrl = ""
            playMusic.position = sec * 1000
            root.log = []
        }
        function file(sec) { root.playLocalFile(song, "A song"); playMusic.position = sec * 1000; root.log = [] }
        function started() { return root.log.filter(function(e) { return ["stop", "park", "pauses"].indexOf(e) < 0 }) }
        function paused() { return playMusic.playbackState === MediaPlayer.PausedState }

        // ── the pause, and the two ways back ─────────────────────────────

        function test_a_pause_leaves_the_episode_in_the_player_where_it_stood() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            compare(root.log, ["pauses"])
            verify(paused())
            // The page reads these: the file, its name, its show and cover, its needle.
            compare(playMusic.source, disk)
            compare(playMusic.position, 754000)
            compare(root.currentStation, "Episode one")
            compare(root._podPlayingKey, "guid-1")
            compare(root._podPlayingShow, "The Show")
            compare(root._podPlayingArt, "http://art.example/c.png")
            compare(root.status(), "Paused")
            compare(root.bigFace, "play")
            compare(root.stopBeside, true, "a paused episode cannot be let go of from the page")
            compare(root.canPlay, true)
            compare(root.bookmarks["guid-1"], 754, "the place is not saved for a restart to find")
        }

        function test_play_after_the_pause_goes_on_in_place() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root._mprisDispatch("Play")
            compare(root.log, ["pauses", "plays on"], "Play after Pause did something else than go on")
            compare(playMusic.source, disk)
            compare(playMusic.position, 754000)
            compare(root._podPlayingKey, "guid-1")
            compare(root._pausedFile, null)
            compare(root.status(), "Playing")
            compare(root.bigFace, "pause")
        }

        function test_playpause_twice_and_the_widgets_own_button_go_the_same_way() {
            episode(disk, 300)
            root._mprisDispatch("PlayPause"); root._mprisDispatch("PlayPause")
            compare(root.log, ["pauses", "plays on"])
            init()
            // The Playing tab's button, Space and the panel's middle click.
            episode(disk, 300)
            root.transport("PlayPause"); root.transport("PlayPause")
            compare(root.log, ["pauses", "plays on"])
            compare(playMusic.position, 300000)
        }

        function test_a_my_music_file_pauses_and_goes_on() {
            file(42.7)
            root.metadata = "Tagged title\t"
            root._mprisDispatch("Pause")
            compare(root.status(), "Paused")
            compare(root.metadata, "Tagged title\t", "the pause wiped the track's own title off the header")
            root._mprisDispatch("Play")
            compare(root.log, ["pauses", "plays on"])
            compare(root.currentStation, "A song")
            compare(playMusic.position, 42700)
        }

        function test_an_episode_that_streams_is_opened_again_at_its_second() {
            // The server drops a connection nobody reads from, so it is not held to.
            episode(stream, 91)
            root._mprisDispatch("Pause")
            verify(paused())
            compare(root.bigFace, "play")
            root._mprisDispatch("Play")
            compare(started(), ["episode guid-1"])
            compare(playMusic.source, stream)
            compare(root._podPlayingShow, "The Show")
            compare(root._podPendingSeekUrl, stream)
            compare(root._podPendingSeekSec, 91)
            compare(root._pausedFile, null)
        }

        function test_a_paused_stream_moved_along_its_line_comes_back_where_it_was_moved_to() {
            episode(stream, 91)
            root._mprisDispatch("Pause")
            playMusic.position = 912300
            root._mprisDispatch("Play")
            compare(root._podPendingSeekSec, 912)
        }

        function test_a_paused_stream_dragged_to_its_start_comes_back_at_the_start() {
            // Its bookmark says 120 and the pause kept 120; the listener put the needle at zero.
            episode(stream, 120)
            root._mprisDispatch("Pause")
            compare(root.bookmarks["guid-1"], 120)
            playMusic.position = 0
            root._mprisDispatch("Play")
            compare(started(), ["episode guid-1"])
            compare(root._podPendingSeekUrl, stream)
            compare(root._podPendingSeekSec, 0, "the stream came back where the pause was made, not where the listener put it")
        }

        function test_a_paused_stream_half_a_second_in_comes_back_at_the_start_too() {
            episode(stream, 120)
            root._mprisDispatch("Pause")
            playMusic.position = 500
            root._mprisDispatch("Play")
            compare(root._podPendingSeekSec, 0)
        }

        function test_a_file_whose_pause_was_taken_out_of_the_player_is_started_again() {
            // A star or a trash click stops the player under the pause.
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root.listWriteStops()
            compare(root.status(), "Paused")
            root._mprisDispatch("Play")
            compare(started(), ["episode guid-1"])
            compare(root._podPendingSeekSec, 754)
            compare(radioStarts(), 0)
        }
        function radioStarts() { return root.log.filter(function(e) { return e.indexOf("station") === 0 || e.indexOf("audition") === 0 }).length }

        function test_a_pause_while_the_episode_still_loads_keeps_where_it_was_going() {
            root.bookmarks["guid-1"] = 600
            root.playPodcastEpisode(stream, "Episode one", "guid-1", "The Show", "", "http://feed.example/rss")
            compare(playMusic.position, 0)
            compare(root._podPendingSeekSec, 597)
            root._mprisDispatch("Pause")
            verify(root._pausedFile !== null, "the pause kept nothing")
            compare(root._pausedFile.sec, 597)
            root._mprisDispatch("Play")
            compare(root._podPendingSeekUrl, stream)
            compare(root._podPendingSeekSec, 597)
        }

        function test_a_second_pause_changes_nothing() {
            episode(disk, 754)
            root._mprisDispatch("Pause"); root._mprisDispatch("Pause")
            compare(root.log, ["pauses"])
            verify(root._pausedFile !== null, "the pause kept nothing")
            compare(root._pausedFile.sec, 754)
        }

        function test_the_pause_owes_what_any_silence_owes() {
            // The wake-up stands down and the sleep timer's fade lets go of the volume.
            episode(disk, 754)
            alarmEngine.stoodDown = 0; root._volumeOverridePct = 40; root.sleepFading = true
            root._mprisDispatch("Pause")
            compare(alarmEngine.stoodDown, 1, "a pause pressed to quiet the wake-up leaves its chime armed")
            compare(root._volumeOverridePct, -1)
            compare(root.sleepFading, false, "the sleep fade went on over the pause and left the volume down")
        }

        function test_what_a_stop_is_fading_out_is_stopped_by_a_second_press_too() {
            episode(disk, 754)
            fadeOutAnimation.running = true
            root._mprisDispatch("Stop")
            root._mprisDispatch("PlayPause")
            compare(root.log, ["stop", "stop"])
            compare(root._pausedFile, null)
        }

        // ── letting go of it ─────────────────────────────────────────────

        function test_stop_after_the_pause_ends_the_episodes_turn() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root._mprisDispatch("Stop")
            compare(root._pausedFile, null)
            compare(playMusic.source, "")
            compare(root.status(), "Stopped")
            compare(root.stopBeside, false)
            compare(started(), [], "a Stop started something")
            root.log = []
            // A bare Play with no file held is the answer it always was.
            root._mprisDispatch("Play")
            compare(started(), ["station 0"])
        }

        function test_a_station_picked_by_hand_ends_the_pause_for_good() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root.refreshServer(1)
            compare(root._pausedFile, null)
            compare(root.bigFace, "stop")
            root._mprisDispatch("Stop")
            root.log = []
            root._mprisDispatch("Play")
            compare(started(), ["station 1"], "the paused episode came back over the station that was picked")
            root._mprisDispatch("PlayPause"); root._mprisDispatch("PlayPause")
            compare(started().indexOf("episode guid-1"), -1)
        }

        function test_an_audition_ends_the_pause_too() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root.previewStation("Try FM", "http://try.example/live")
            compare(root._pausedFile, null)
            root._mprisDispatch("Stop"); root.log = []
            root._mprisDispatch("Play")
            compare(started(), ["audition http://try.example/live"])
        }

        // ── the rows ─────────────────────────────────────────────────────

        function test_a_tap_on_the_row_that_plays_pauses_it_and_a_second_tap_goes_on() {
            episode(disk, 754)
            root.playPodcastEpisode(disk, "Episode one", "guid-1", "The Show", "", "")
            compare(root.log, ["pauses"])
            compare(root.status(), "Paused")
            root.playPodcastEpisode(disk, "Episode one", "guid-1", "The Show", "", "")
            compare(root.log, ["pauses", "plays on"])
            compare(playMusic.position, 754000)
            init()
            file(42)
            root.playLocalFile(song, "A song"); root.playLocalFile(song, "A song")
            compare(root.log, ["pauses", "plays on"])
        }

        function test_a_tap_on_another_row_plays_that_one_and_ends_the_pause() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root.playPodcastEpisode(other, "Episode two", "guid-2", "The Show", "", "")
            compare(started(), ["episode guid-2"])
            compare(root._pausedFile, null)
            compare(playMusic.source, other)
            root._mprisDispatch("Stop"); root.log = []
            root._mprisDispatch("Play")
            compare(started().indexOf("episode guid-1"), -1)
            compare(started(), ["station 0"])
        }

        function test_a_tap_on_the_row_of_a_paused_stream_opens_it_again() {
            episode(stream, 91)
            root._mprisDispatch("Pause")
            root.playPodcastEpisode(stream, "Episode one", "guid-1", "The Show", "http://art.example/c.png", "http://feed.example/rss")
            compare(started(), ["episode guid-1"])
            compare(root._podPendingSeekSec, 91)
        }

        function test_a_row_tapped_many_times_only_ever_pauses_and_goes_on() {
            episode(disk, 100)
            for (var i = 0; i < 201; i++) root.playPodcastEpisode(disk, "Episode one", "guid-1", "The Show", "", "")
            compare(radioStarts(), 0)
            compare(root.log.filter(function(e) { return e !== "pauses" && e !== "plays on" }), [])
            compare(root.status(), "Paused")
        }

        // ── nothing goes on by itself ────────────────────────────────────

        function test_no_road_that_goes_on_by_itself_goes_on_over_a_pause() {
            root.upNext = [other]
            episode(stream, 754)
            root._mprisDispatch("Pause")
            root.log = []
            root.stallTimerFires()
            compare(root.log, [], "the stall retry played a paused episode")
            root.mediaEnds()
            compare(root.log, [], "the end of a paused episode started the next one")
            init(); root.upNext = [other]
            episode(stream, 754)
            root._mprisDispatch("Pause")
            root.log = []
            root.playerErrs()
            compare(root.log, [], "an error under a pause started the next episode")
            compare(root.upNext.length, 1, "the queue was eaten by a paused episode's error")
            compare(root.isPlaying(), false)
            // With nothing queued it is the show's next episode that must not start.
            init()
            episode(stream, 754)
            root._mprisDispatch("Pause")
            root.log = []
            root.playerErrs()
            compare(root.log, [], "an error under a pause started the show's next episode")
            // And the same roads do go on for an episode that plays.
            init(); root.upNext = [other]
            episode(stream, 754)
            root.mediaEnds()
            compare(started(), ["episode queued-" + other])
        }

        function test_an_alarm_over_a_paused_episode_ends_the_pause() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root.alarmFiresStation(1)
            compare(root._pausedFile, null)
            compare(root.status(), "Playing")
            root._mprisDispatch("Stop"); root.log = []
            root._mprisDispatch("Play")
            compare(started().indexOf("episode guid-1"), -1, "the episode came back after the alarm")
        }

        function test_the_wake_up_starts_the_paused_episode_by_its_own_road() {
            // The alarm wants the very episode that sits paused. It is its
            // start, with its volume floor, not a person's resume.
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root.log = []
            root.alarmFiresEpisode(disk, "guid-1")
            compare(root.log, ["episode guid-1"])
            compare(root._volumeOverridePct, 40, "the wake-up lost its volume floor to the resume")
            compare(root._pausedFile, null)
        }

        function test_the_sleep_timer_ending_over_a_pause_starts_nothing() {
            episode(disk, 754)
            root._mprisDispatch("Pause")
            root.log = []
            root.sleepTimerEnds()
            compare(root.log, [])
            compare(root.isPlaying(), false)
            compare(root.status(), "Paused")
        }

        function test_a_widget_that_just_started_holds_no_pause() {
            // The kept file lives in memory. After a restart the widget is
            // this: nothing held, nothing said to the desk, the bookmark on disk.
            compare(root._pausedFile, null)
            compare(root.status(), "Stopped")
            compare(root.bigFace, "play")
            compare(root.stopBeside, false)
            root._mprisDispatch("Pause"); root._mprisDispatch("Stop")
            compare(root.log, [])
        }

        // ── the face, the stop beside it and the desk, state by state ────

        function test_the_face_and_the_desk_say_the_same_thing_along_the_way() {
            compare([root.bigFace, root.stopBeside, root.status()], ["play", false, "Stopped"])
            episode(disk, 10)
            compare([root.bigFace, root.stopBeside, root.status()], ["pause", true, "Playing"])
            root.transport("PlayPause")
            compare([root.bigFace, root.stopBeside, root.status()], ["play", true, "Paused"])
            root.transport("PlayPause")
            compare([root.bigFace, root.stopBeside, root.status()], ["pause", true, "Playing"])
            root.transport("Stop")
            compare([root.bigFace, root.stopBeside, root.status()], ["play", false, "Stopped"])
            // Live radio with no buffer: the Stop it always was, and no second one.
            root.refreshServer(0)
            compare([root.bigFace, root.stopBeside, root.status()], ["stop", false, "Playing"])
            timeshift.ready = true
            compare([root.bigFace, root.stopBeside, root.status()], ["pause", true, "Playing"])
            root.transport("PlayPause")
            compare([root.bigFace, root.stopBeside, root.status()], ["play", true, "Paused"])
            root.transport("Stop")
            // A cast: the device's place is not known.
            root.refreshServer(0); playMusic.stop(); root._casting = true
            compare([root.bigFace, root.stopBeside, root.status()], ["stop", false, "Playing"])
            root.transport("Stop")
            root.previewStation("Try FM", "http://try.example/live")
            compare([root.bigFace, root.stopBeside, root.status()], ["stop", false, "Playing"])
        }

        function test_the_panel_names_a_paused_file_and_drops_it_with_the_pause() {
            compare(root.onOrKept, false)
            episode(disk, 10)
            compare(root.onOrKept, true)
            root.transport("Pause")
            compare(root.onOrKept, true, "a paused episode vanishes from the panel")
            root.transport("Stop")
            compare(root.onOrKept, false)
        }

        function test_the_desk_hears_of_the_pause_and_of_its_end() {
            episode(disk, 754)
            root.deskWrites = 0
            root._mprisDispatch("Pause")
            verify(root.deskWrites >= 1, "nothing told the desk the episode is paused")
            root.deskWrites = 0
            root._mprisDispatch("Stop")
            verify(root.deskWrites >= 1, "the desk still reads Paused after the Stop")
        }

        // ── the roads that must not change ───────────────────────────────

        function test_the_park_and_the_shifted_listen_keep_their_roads() {
            root.refreshServer(0); timeshift.ready = true; root.log = []
            root._mprisDispatch("Pause")
            compare(root.log, ["park"])
            compare(root._pausedFile, null)
            compare(root.status(), "Paused")
            root._mprisDispatch("Play")
            compare(root.log, ["park", "park resumes"])
            init()
            root.refreshServer(0); timeshift.shifted = true; playMusic.source = "file://" + timeshift.bufPath; root.log = []
            root._mprisDispatch("PlayPause"); root._mprisDispatch("PlayPause")
            compare(root.log, ["pauses", "plays on"])
            compare(root._pausedFile, null)
            init()
            // No buffer: a station's pause is the stop it was, and Play the station again.
            root.refreshServer(1); root.log = []
            root._mprisDispatch("Pause")
            compare(root.log, ["stop"])
            compare(root._pausedFile, null)
            compare(root.status(), "Stopped")
            root._mprisDispatch("Play")
            compare(started(), ["station 1"])
        }

        function test_an_audition_a_cast_and_the_wake_up_tone_stop_as_they_did() {
            root.previewStation("Try FM", "http://try.example/live"); root.log = []
            root._mprisDispatch("Pause")
            compare(root._pausedFile, null)
            compare(root.status(), "Stopped")
            root._mprisDispatch("Play")
            compare(started(), ["audition http://try.example/live"])
            init()
            // A file here while a device carries a station: everything stops.
            root.playLocalFile(song, "A song"); root._casting = true; root.log = []
            root._mprisDispatch("PlayPause")
            compare(root.log, ["stop"])
            compare(root._pausedFile, null)
            init()
            root._sound("Wake-up alarm", root._alarmToneUrl); root.log = []
            root._mprisDispatch("Pause")
            compare(root.log, ["stop"])
            compare(root._pausedFile, null)
        }

        function test_a_word_nobody_knows_and_an_empty_one_do_nothing() {
            episode(disk, 754)
            var words = ["", "pause", "Toggle", "Seek 5", "Play" + new Array(3000).join("y")]
            for (var i = 0; i < words.length; i++) root._mprisDispatch(words[i])
            root.transport(undefined); root.transport(null); root.transport(7)
            compare(root.log, [])
            compare(root.isPlaying(), true)
            compare(root._pausedFile, null)
        }

        // ── what the desk is told Play can do ────────────────────────────
        // With no station saved CanPlay read false whatever was on.

        // A Play in a state with nothing on: did it start anything?
        function playStarts() { root.log = []; root._mprisDispatch("Play"); return started().length > 0 }

        function test_with_no_station_saved_a_search_result_can_be_played() {
            stationsModel.clear()
            compare(root.canPlay, false)
            root.previewStation("Try FM", "http://try.example/live")
            compare(root.canPlay, true, "a search result plays and the desk is told Play can do nothing")
            root._mprisDispatch("Stop")
            compare(root.canPlay, true, "Play would bring the search result back and the desk's button is dark")
            compare(playStarts(), true)
            compare(started(), ["audition http://try.example/live"])
        }

        function test_with_no_station_saved_an_episode_or_a_file_can_be_played_while_it_is_held() {
            stationsModel.clear()
            episode(disk, 100)
            compare(root.canPlay, true)
            root._mprisDispatch("Pause")
            compare(root.canPlay, true)
            compare(playStarts(), true)
            root._mprisDispatch("Stop")
            // Let go of, with nothing saved: Play has nothing to start, and says so.
            compare(root.canPlay, false)
            compare(playStarts(), false)
            root.playLocalFile(song, "A song")
            compare(root.canPlay, true)
            root._mprisDispatch("Stop")
            compare(root.canPlay, false)
        }

        function test_one_station_is_enough_and_the_desk_hears_when_the_list_fills() {
            stationsModel.clear()
            root.deskWrites = 0
            compare(root.canPlay, false)
            compare(playStarts(), false)
            stationsModel.append({ "name": "Only FM", "hostname": "http://only.example/live" })
            compare(root.canPlay, true)
            verify(root.deskWrites >= 1, "the first station was saved and nothing told the desk Play works now")
            compare(playStarts(), true)
            compare(root.log, ["station 0"])
        }

        function test_what_the_desk_is_told_is_what_a_play_then_does() {
            // Every stopped state these roads can reach: the capability and
            // the action have to give the same answer.
            var lists = [0, 1, 2]
            var priors = ["nothing", "station", "audition", "episode paused", "episode stopped", "file paused", "parked"]
            for (var l = 0; l < lists.length; l++) {
                for (var b = 0; b < priors.length; b++) {
                    init()
                    while (stationsModel.count > lists[l]) stationsModel.remove(stationsModel.count - 1)
                    var was = priors[b]
                    if (was === "station" || was === "parked") {
                        if (lists[l] === 0) continue
                        root.refreshServer(0)
                        if (was === "parked") { timeshift.ready = true; root._mprisDispatch("Pause") } else root._mprisDispatch("Stop")
                    } else if (was === "audition") {
                        root.previewStation("Try FM", "http://try.example/live"); root._mprisDispatch("Stop")
                    } else if (was === "episode paused") {
                        episode(disk, 100); root._mprisDispatch("Pause")
                    } else if (was === "episode stopped") {
                        episode(disk, 100); root._mprisDispatch("Stop")
                    } else if (was === "file paused") {
                        root.playLocalFile(song, "A song"); playMusic.position = 9000; root._mprisDispatch("Pause")
                    }
                    compare(root.isPlaying(), false)
                    var told = root.canPlay
                    compare(playStarts(), told, was + " with " + lists[l] + " station(s) saved")
                }
            }
        }

        function test_pressing_through_a_long_run_never_puts_a_station_over_the_episode() {
            episode(disk, 100)
            for (var i = 0; i < 200; i++) {
                root.transport("PlayPause")
                if (root.isPlaying()) playMusic.position = (100 + i) * 1000
            }
            compare(radioStarts(), 0)
            compare(root._podPlayingKey, "guid-1")
            compare(root.log.filter(function(e) { return e !== "pauses" && e !== "plays on" }), [])
        }

        // ── an audition on its way to sound ──────────────────────────────

        readonly property string tryUrl: "http://try.example/live.flac"
        function arming() { root.auditionArms("Try FM", tryUrl); root.log = [] }
        function sounds() { return playMusic.playbackState === MediaPlayer.PlayingState }

        function test_stop_half_a_second_into_an_audition_is_silence() {
            arming()
            root._mprisDispatch("Stop")
            compare(root.log, ["stop"], "the press was ignored: nothing was audible yet")
            root.lateAnswer("Try FM", tryUrl)
            verify(!sounds(), "the audition came up after the stop")
            compare(root.status(), "Stopped")
            compare(root._previewUrl, "")
        }

        function test_pause_in_that_window_is_silence_too() {
            arming()
            root._mprisDispatch("Pause")
            compare(root.log, ["stop"])
            root.lateAnswer("Try FM", tryUrl)
            verify(!sounds())
        }

        function test_the_widgets_own_button_takes_the_coming_audition_down_and_says_so() {
            arming()
            compare(root.bigFace, "stop", "the button shows a Play over an audition that is already starting")
            root.transport("PlayPause")
            compare(root.log, ["stop"])
            root.lateAnswer("Try FM", tryUrl)
            verify(!sounds())
            compare(root.bigFace, "play")
        }

        function test_a_play_in_that_window_does_not_start_the_audition_a_second_time() {
            arming()
            root._mprisDispatch("Play")
            compare(root.log, [], "the audition was started again while it was starting")
            root.lateAnswer("Try FM", tryUrl)
            verify(sounds())
            compare(root.log, ["audition sounds"])
        }

        function test_an_audition_that_is_left_alone_comes_up_and_stops_as_it_did() {
            arming()
            root.lateAnswer("Try FM", tryUrl)
            verify(sounds())
            compare(root.bigFace, "stop")
            root._mprisDispatch("Stop")
            verify(!sounds())
            // And a Play brings it back, as after any stopped audition.
            root.log = []
            root._mprisDispatch("Play")
            compare(started(), ["audition " + tryUrl])
        }

        function test_stop_after_an_audition_ended_by_itself_starts_nothing() {
            // Its roads gave up and took the address with them.
            arming(); root.lateAnswer("Try FM", tryUrl)
            playMusic.stop(); root._previewUrl = ""; root.log = []
            root._mprisDispatch("Stop")
            root._mprisDispatch("Pause")
            compare(root.log, [])
            verify(!sounds())
            // The player fell silent and the address still stands, a rung of its retry still to come.
            init(); arming(); root.lateAnswer("Try FM", tryUrl)
            playMusic.stop(); root.log = []
            root._mprisDispatch("Stop")
            compare(root.log, ["stop"])
            root.lateAnswer("Try FM", tryUrl)
            verify(!sounds(), "a late rung started the audition after the stop")
        }

        function test_the_face_and_the_press_agree_all_the_way_through_an_audition() {
            var steps = [function() { arming() }, function() { root.lateAnswer("Try FM", tryUrl) },
                         function() { root.transport("PlayPause") }, function() { root.transport("PlayPause") }]
            for (var i = 0; i < steps.length; i++) {
                steps[i]()
                var face = root.bigFace, was = sounds() || root._previewUrl !== ""
                root.log = []
                var act = TransportLogic.keyFor("PlayPause", root._keyFacts)
                compare(face === "play", act === "bare" || act === "unpause" || act === "resume", "step " + i + ": " + face + " over " + act)
                compare(face !== "play", was, "step " + i)
            }
        }

        // ── an audition that is over ─────────────────────────────────────

        readonly property string otherUrl: "http://other.example/live.flac"
        function dead() { arming(); root.lastWord(tryUrl); root.log = [] }

        function test_an_audition_that_failed_at_once_leaves_an_idle_widget() {
            dead()
            compare(root.bigFace, "play", "the button reads Stop over a widget that is silent and has nothing coming")
            compare(root.status(), "Stopped")
            root._mprisDispatch("Stop")
            root._mprisDispatch("Pause")
            compare(root.log, [], "a stop was run over nothing")
            compare(root._friendlyError !== "", true, "the sentence was taken down by a press that had nothing to stop")
        }

        function test_the_rungs_are_on_their_way_however_long_they_take_and_the_last_word_ends_it() {
            arming()
            compare(root.bigFace, "stop")
            // A rung fails, the next is asked, minutes pass: nothing sounds and nothing has been said yet.
            compare(TransportLogic.keyFor("Stop", root._keyFacts), "stop")
            root.lastWord(tryUrl)
            compare(root.bigFace, "play")
            compare(TransportLogic.keyFor("Stop", root._keyFacts), "none")
        }

        function test_stop_in_the_middle_of_the_rungs_ends_them_and_no_word_is_said_later() {
            arming()
            root._mprisDispatch("Stop")
            compare(root.log, ["stop"])
            root.lateAnswer("Try FM", tryUrl)
            root.lastWord(tryUrl)
            verify(!sounds())
            compare(root._friendlyError, "")
            compare(root.bigFace, "play")
        }

        function test_after_the_last_word_one_press_of_the_button_tries_the_result_again() {
            dead()
            root.transport("PlayPause")
            compare(root.log, ["audition " + tryUrl], "the press was spent on stopping a widget that was already silent")
            verify(sounds())
        }

        function test_after_the_last_word_a_play_from_the_desk_tries_the_result_again() {
            dead()
            root._mprisDispatch("Play")
            compare(root.log, ["audition " + tryUrl], "the desk's Play did nothing over a dead result")
        }

        function test_after_the_last_word_another_result_is_on_its_way_from_its_click() {
            dead()
            root.auditionArms("Other FM", otherUrl); root.log = []
            compare(root._friendlyError, "", "the dead result's sentence stands over the next one")
            compare(root.bigFace, "stop")
            root._mprisDispatch("Stop")
            compare(root.log, ["stop"], "the last result's word hid the one that was coming")
            root.lateAnswer("Other FM", otherUrl)
            verify(!sounds())
        }

        function test_an_audition_that_sounded_and_died_is_on_its_way_again_until_its_ladder_ends() {
            arming(); root.lateAnswer("Try FM", tryUrl)
            verify(sounds())
            // The stream dies: the player stops, the address stands, the ladder asks the directory.
            playMusic.stop(); root.log = []
            compare(root.bigFace, "stop")
            compare(TransportLogic.keyFor("Stop", root._keyFacts), "stop")
            // It finds the station again...
            root.lateAnswer("Try FM", tryUrl)
            verify(sounds())
            // ...or it does not, and says so.
            playMusic.stop(); root.lastWord(tryUrl); root.log = []
            compare(root.bigFace, "play")
            root._mprisDispatch("Stop")
            compare(root.log, [])
        }

        function test_a_result_parked_in_its_buffer_comes_back_out_of_it() {
            // It sounds through the relay, so it has a buffer, and a pause parks it there.
            arming(); root.lateAnswer("Try FM", tryUrl); timeshift.ready = true; root.log = []
            root._mprisDispatch("Pause")
            compare(root.log, ["park"])
            compare(root._previewUrl, tryUrl)
            compare(root.bigFace, "play", "the button reads Stop over a result that is parked")
            root._mprisDispatch("Pause")
            compare(root.log, ["park"], "a second pause stopped the parked result")
            root.transport("PlayPause")
            compare(root.log, ["park", "park resumes"], "the press threw the parked result away")
            // And from the desk.
            root._mprisDispatch("Pause"); root.log = []
            root._mprisDispatch("Play")
            compare(root.log, ["park resumes"])
        }

        function test_a_sentence_with_no_address_under_it_is_nothing_on_its_way() {
            dead()
            root._previewUrl = ""       // the wake-up alarm takes the address and leaves the sentence
            compare(root.bigFace, "play")
            compare(TransportLogic.keyFor("Stop", root._keyFacts), "none")
        }

        function test_a_station_that_connects_keeps_its_standing_order_and_its_roads() {
            root.refreshServer(0); playMusic.stop(); root.log = []
            compare(root._wantsPlaying, true)
            root._mprisDispatch("Stop")
            compare(root.log, ["stop"])
        }

        // ── Next, Previous, Seek and SetPosition from the desk ───────────

        function pos() { return Math.round(playMusic.position / 1000) }
        function pausedAt(url, sec) { episode(url, sec); root._mprisDispatch("Pause"); root.log = [] }

        function test_next_over_a_paused_episode_goes_on_inside_it_and_starts_no_station() {
            pausedAt(disk, 120)
            root._mprisDispatch("Next")
            compare(radioStarts(), 0, "a station came on over the paused episode")
            compare(pos(), 150)
            verify(paused(), "the skip took the pause away")
            compare(root.status(), "Paused")
            compare(root._pausedFile.sec, 150, "the kept second stayed behind the needle")
            root._mprisDispatch("Play")
            compare(root.log, ["plays on"])
            compare(pos(), 150)
        }

        function test_previous_seek_and_setposition_move_a_paused_episode_and_leave_it_paused() {
            pausedAt(disk, 120)
            root._mprisDispatch("Previous")
            compare(pos(), 105)
            root._mprisDispatch("Seek 30000000")
            compare(pos(), 135)
            root._mprisDispatch("Seek -5000000")
            compare(pos(), 130)
            root._mprisDispatch("SetPos 180000000")
            compare(pos(), 180)
            verify(paused())
            compare(root._pausedFile.sec, 180)
            compare(radioStarts(), 0)
            compare(root.log, [])
        }

        function test_a_paused_stream_moved_from_the_desk_is_opened_again_where_it_was_moved_to() {
            pausedAt(stream, 120)
            root._mprisDispatch("Next")
            compare(pos(), 150)
            root._mprisDispatch("Play")
            compare(started(), ["episode guid-1"])
            compare(root._podPendingSeekSec, 150)
        }

        function test_the_desk_is_told_where_a_paused_needle_went() {
            pausedAt(disk, 120)
            var before = root.deskWrites
            root._mprisDispatch("Next")
            verify(root.deskWrites > before, "the desk goes on reading the place the pause was made at")
        }

        function test_the_popups_skip_under_a_pause_moves_the_kept_second_too() {
            pausedAt(disk, 120)
            root.podcastSkip(30)
            compare(pos(), 150)
            compare(root._pausedFile.sec, 150)
            // Taken out of the player afterwards, it is opened again where it was skipped to.
            root.listWriteStops()
            root._mprisDispatch("Play")
            compare(root._podPendingSeekSec, 150)
        }

        function test_an_episode_held_by_its_record_alone_refuses_all_four_and_starts_no_station() {
            pausedAt(disk, 754)
            root.listWriteStops()
            var cmds = ["Next", "Previous", "Seek 30000000", "SetPos 180000000"]
            for (var i = 0; i < cmds.length; i++) root._mprisDispatch(cmds[i])
            compare(root.log, [], "a command over a held episode started or stopped something")
            compare(root.status(), "Paused")
            compare(root._pausedFile.sec, 754)
            root._mprisDispatch("Play")
            compare(started(), ["episode guid-1"])
            compare(root._podPendingSeekSec, 754)
        }

        function test_after_a_stop_next_and_previous_choose_stations_as_they_did() {
            pausedAt(disk, 120)
            root._mprisDispatch("Stop")
            root.log = []
            root._mprisDispatch("Next")
            compare(root.log, ["station 0"])
            root._mprisDispatch("Next")
            root._mprisDispatch("Previous")
            root._mprisDispatch("Previous")
            compare(root.log, ["station 0", "station 1", "station 0", "station 1"])
        }

        function test_an_episode_that_ended_under_its_pause_is_still_held() {
            pausedAt(disk, 120)
            root.mediaEnds()
            playMusic.stop()
            compare(root._podPlayingKey, "")
            root._mprisDispatch("Next")
            root._mprisDispatch("Previous")
            compare(root.log, [], "a station came on over an episode a pause still keeps")
            compare(root.status(), "Paused")
        }

        function test_next_near_the_end_and_previous_near_the_start_park_at_the_ends() {
            pausedAt(disk, 1790)
            root._mprisDispatch("Next")
            compare(pos(), 1800)
            verify(paused())
            compare(radioStarts(), 0)
            init(); pausedAt(disk, 5)
            root._mprisDispatch("Previous")
            compare(pos(), 0)
            verify(paused())
            // And while it plays, the same ends.
            init(); episode(disk, 1790)
            root._mprisDispatch("Next")
            compare(pos(), 1800)
        }

        function test_setposition_past_the_end_parks_there_and_below_zero_is_refused() {
            pausedAt(disk, 120)
            root._mprisDispatch("SetPos 9000000000000")
            compare(pos(), 1800)
            root._mprisDispatch("SetPos -1000000")
            compare(pos(), 1800)
            verify(paused())
            init(); pausedAt(disk, 120)
            root._mprisDispatch("SetPos -1000000")
            compare(pos(), 120)
            compare(root._pausedFile.sec, 120)
        }

        function test_an_episode_that_cannot_be_sought_is_left_where_it_stands_and_starts_no_station() {
            pausedAt(stream, 120)
            playMusic.seekable = false
            var cmds = ["Next", "Previous", "Seek 30000000", "SetPos 180000000"]
            for (var i = 0; i < cmds.length; i++) root._mprisDispatch(cmds[i])
            compare(pos(), 120)
            compare(root.log, [])
            // And while it plays.
            init(); episode(stream, 120); playMusic.seekable = false
            for (i = 0; i < cmds.length; i++) root._mprisDispatch(cmds[i])
            compare(pos(), 120)
            compare(root.log, [])
        }

        function test_an_episode_a_device_carries_is_not_put_under_a_station() {
            episode(stream, 120)
            root._casting = true; playMusic.stop()
            root._mprisDispatch("Next")
            root._mprisDispatch("Previous")
            compare(root.log, [], "the radio came on over an episode that plays on a device")
        }

        function test_a_music_file_and_a_parked_station_go_to_the_next_station_paused_as_playing() {
            file(40)
            root._mprisDispatch("Next")
            compare(root.log, ["station 0"])
            init(); file(40)
            root._mprisDispatch("Pause"); root.log = []
            root._mprisDispatch("Next")
            compare(root.log, ["station 0"])
            // A seat in the buffer, parked: the next station, as when the station plays.
            init(); root.refreshServer(0); root.log = []
            timeshift.ready = true
            root._mprisDispatch("Pause"); root.log = []
            root._mprisDispatch("Next")
            compare(root.log, ["station 1"])
        }

        function test_a_long_run_of_next_over_a_paused_episode_never_reaches_a_station() {
            pausedAt(disk, 120)
            for (var i = 0; i < 100; i++) root._mprisDispatch(i % 3 === 2 ? "Previous" : "Next")
            compare(radioStarts(), 0)
            verify(paused())
            verify(pos() >= 0 && pos() <= 1800)
        }

        function test_what_the_desk_is_told_it_may_ask_is_what_each_command_then_does() {
            var states = {
                "an episode playing": function() { episode(disk, 120) },
                "an episode paused in place": function() { pausedAt(disk, 120) },
                "a streamed episode paused": function() { pausedAt(stream, 120) },
                "an episode held by its record": function() { pausedAt(disk, 120); root.listWriteStops() },
                "an episode that ended under its pause": function() { pausedAt(disk, 120); root.mediaEnds(); playMusic.stop() },
                "an episode that cannot be sought": function() { episode(stream, 120); playMusic.seekable = false },
                "an episode on a device": function() { episode(stream, 120); root._casting = true; playMusic.stop() },
                "a music file paused": function() { file(40); root._mprisDispatch("Pause") },
                "nothing on, two stations": function() {}
            }
            var asks = [["Next", "canGoNext"], ["Previous", "canGoPrevious"], ["Seek 30000000", "canSeek"], ["SetPos 60000000", "canSeek"]]
            for (var name in states) {
                for (var i = 0; i < asks.length; i++) {
                    init(); states[name](); root.log = []
                    var may = root.desk()[asks[i][1]], was = playMusic.position
                    root._mprisDispatch(asks[i][0])
                    var did = playMusic.position !== was || radioStarts() > 0
                    compare(did, may, name + ": " + asks[i][0])
                }
            }
        }

        function test_a_seek_nobody_can_read_moves_nothing() {
            pausedAt(disk, 120)
            var words = ["Seek", "Seek ", "Seek abc", "SetPos", "SetPos x", "Seek NaN", "SetPos Infinity", "Nextt", "next", ""]
            for (var i = 0; i < words.length; i++) root._mprisDispatch(words[i])
            compare(pos(), 120)
            compare(root.log, [])
            compare(root._pausedFile.sec, 120)
        }

        function test_rate_and_volume_from_the_desk_go_where_they_went() {
            pausedAt(disk, 120)
            root._mprisDispatch("Rate 1.5")
            root._mprisDispatch("Volume 0.4")
            compare(root.log, ["rate 1.5", "volume 0.4"])
            compare(pos(), 120)
        }
    }
}
