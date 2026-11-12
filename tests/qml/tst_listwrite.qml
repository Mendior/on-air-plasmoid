// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The star and the trash write the station list, the write stops the
// player, and the writer starts again what was a row of the list or an
// audition. A My Music file or a podcast episode is neither: it was cut
// off by a change to a list it is not in. This stands the write, the
// change handler and the trash's afterwards up around a player that only
// counts, the way main.qml wires them, and asks two things of every
// case: what was stopped, and that nothing was started that was not on.
import QtQuick
import QtTest

import "../../package/contents/ui/TransportLogic.js" as TransportLogic

Item {
    id: root
    width: 100
    height: 100

    QtObject {
        id: playMusic
        property string source: ""
        property bool on: false
        property int stops: 0
        property int stopCalls: 0
        function stop() { stopCalls++; if (on) stops++; on = false }
    }
    QtObject { id: timeshift; property string bufPath: ""; property bool shifted: false }
    QtObject { id: cfg; property string servers: "[]" }
    ListModel { id: stationsModel }

    property string _previewUrl: ""
    property string _currentOrigUrl: ""
    property string _podPlayingKey: ""
    property string _podPlayingUrl: ""
    property string _alarmToneUrl: "file:///usr/share/onair/chime.ogg"
    property bool _wantsPlaying: false
    property bool _reorderKeepPlaying: false
    property var _pausedFile: null
    property int lastPlay: -1
    property var started: []
    property int sessionsEnded: 0

    function isPlaying() { return playMusic.on }
    function refreshServer(k) { started.push("row " + k); playMusic.source = stationsModel.get(k).hostname; playMusic.on = true }
    function previewStation(name, url) { started.push("audition " + url); playMusic.source = url; playMusic.on = true }
    function _tsSessionOver() { sessionsEnded++ }

    function reloadStationsModel(keepPlaying) {
        if (!keepPlaying) playMusic.stop();
        stationsModel.clear();
        var servers = JSON.parse(cfg.servers);
        for (var i = 0; i < servers.length; i++) stationsModel.append(servers[i]);
    }

    Connections {
        target: cfg
        function onServersChanged() {
            if (root._reorderKeepPlaying) {
                root._reorderKeepPlaying = false;
                reloadStationsModel(true);
            } else {
                var wasAudible = isPlaying(); playMusic.stop();
                reloadStationsModel();
                var listed = false;
                for (var si = 0; si < stationsModel.count && !listed; si++) listed = stationsModel.get(si).hostname === root._currentOrigUrl;
                if (wasAudible || !listed) { root._wantsPlaying = false; _tsSessionOver(); }
            }
        }
    }

    // The trash, from its write on.
    function removeStation(hostname) {
        var servers = JSON.parse(cfg.servers).filter(function(s) { return s.hostname !== hostname });
        const wasPlayingUrl = isPlaying() && root._previewUrl === "" && playMusic.source === root._currentOrigUrl
                              ? root._currentOrigUrl : "";
        const foreignPreview = isPlaying() && root._previewUrl !== "" && root._previewUrl !== hostname
                               ? { "name": "", "url": root._previewUrl } : null;
        const kept = _listWrite(servers); // → reload (stops playback, unless a file plays on)
        Qt.callLater(function() {
            if (kept) return;   // nothing stopped: nothing to start, and no row to light up
            if (wasPlayingUrl !== "" && wasPlayingUrl !== hostname) {
                for (var k = 0; k < stationsModel.count; k++) {
                    if (stationsModel.get(k).hostname === wasPlayingUrl) {
                        lastPlay = k;
                        refreshServer(k);
                        return;
                    }
                }
            }
            lastPlay = 0;
            if (foreignPreview) previewStation(foreignPreview.name, foreignPreview.url);
        });
    }

    // The star, as far as its write.
    function addStation(url) {
        var servers = JSON.parse(cfg.servers);
        servers.push({ "name": url, "hostname": url });
        _listWrite(servers);
    }

    function _listWrite(servers) {
        var out = JSON.stringify(servers);
        var kept = TransportLogic.listWriteKeepsSound({ "audible": isPlaying(), "preview": root._previewUrl !== "",
            "source": playMusic.source.toString(), "episode": root._podPlayingKey !== "" ? root._podPlayingUrl : "",
            "tone": root._alarmToneUrl.toString(), "bufferPath": timeshift.bufPath, "shifted": timeshift.shifted, "paused": root._pausedFile !== null });
        if (out === cfg.servers) return false;
        if (kept) _reorderKeepPlaying = true;
        cfg.servers = out;
        return kept;
    }

    TestCase {
        name: "ListWrite"
        when: windowShown

        readonly property string a: "http://a.example/live"
        readonly property string b: "http://b.example/live"
        readonly property string c: "http://c.example/live"
        readonly property string song: "file:///home/u/Music/OnAir/song.mp3"

        function init() {
            root._reorderKeepPlaying = false
            cfg.servers = JSON.stringify([{ "name": "A", "hostname": a }, { "name": "B", "hostname": b },
                                          { "name": "C", "hostname": c }])
            playMusic.on = false
            playMusic.source = ""
            playMusic.stops = 0
            timeshift.bufPath = ""
            timeshift.shifted = false
            root._previewUrl = ""
            root._currentOrigUrl = ""
            root._podPlayingKey = ""
            root._podPlayingUrl = ""
            root._wantsPlaying = false
            root._pausedFile = null
            playMusic.stopCalls = 0
            root.lastPlay = -1
            root.started = []
            root.sessionsEnded = 0
        }
        function settle() { wait(0); wait(0) }

        function playFile(url) { playMusic.source = url; playMusic.on = true; root.lastPlay = -1 }
        function playRow(k) {
            playMusic.source = stationsModel.get(k).hostname; playMusic.on = true
            root._currentOrigUrl = playMusic.source; root._wantsPlaying = true; root.lastPlay = k
        }

        function test_removing_a_station_leaves_a_my_music_file_playing() {
            playFile(song)
            root.removeStation(b); settle()
            compare(playMusic.stops, 0)
            verify(playMusic.on)
            compare(playMusic.source, song)
            compare(root.started.length, 0)
            compare(root.lastPlay, -1)          // no row lights up as the one playing
            compare(stationsModel.count, 2)
            verify(!root._reorderKeepPlaying)
        }

        function test_starring_a_result_leaves_a_my_music_file_playing() {
            playFile(song)
            root.addStation("http://new.example/live"); settle()
            compare(playMusic.stops, 0)
            verify(playMusic.on)
            compare(root.started.length, 0)
            compare(stationsModel.count, 4)
            verify(!root._reorderKeepPlaying)
        }

        function test_an_episode_plays_on_streamed_or_from_disk() {
            var ep = "https://cdn.example/show/ep1.mp3"
            root._podPlayingKey = "k1"; root._podPlayingUrl = ep
            playFile(ep)
            root.removeStation(a); settle()
            root.addStation("http://new.example/live"); settle()
            compare(playMusic.stops, 0)
            verify(playMusic.on)
            compare(root.started.length, 0)
            verify(!root._reorderKeepPlaying)
        }

        function test_a_station_untouched_by_the_removal_is_stopped_and_started_again_as_before() {
            playRow(2)
            root.removeStation(a); settle()
            compare(playMusic.stops, 1)
            compare(JSON.stringify(root.started), JSON.stringify(["row 1"]))
            compare(root.lastPlay, 1)
        }

        function test_removing_the_station_that_plays_ends_it_as_before() {
            playRow(1)
            root.removeStation(b); settle()
            compare(playMusic.stops, 1)
            verify(!playMusic.on)
            compare(root.started.length, 0)
            verify(!root._wantsPlaying)
            compare(root.sessionsEnded, 1)
        }

        function test_an_audition_is_stopped_and_given_back_as_before() {
            root._previewUrl = "http://try.example/live"
            playMusic.source = root._previewUrl; playMusic.on = true
            root.removeStation(a); settle()
            compare(playMusic.stops, 1)
            compare(JSON.stringify(root.started), JSON.stringify(["audition http://try.example/live"]))
        }

        function test_a_shifted_listen_ends_as_before() {
            playRow(0)
            timeshift.bufPath = "/run/user/1000/onair/ts-7.mka"
            timeshift.shifted = true
            playMusic.source = "file://" + timeshift.bufPath
            root.removeStation(a); settle()
            compare(playMusic.stops, 1)
            verify(!playMusic.on)
            compare(root.started.length, 0)
            compare(root.sessionsEnded, 1)
        }

        function test_with_nothing_playing_a_write_starts_nothing() {
            root.removeStation(a); settle()
            root.addStation("http://new.example/live"); settle()
            compare(playMusic.stops, 0)
            verify(!playMusic.on)
            compare(root.started.length, 0)
            verify(!root._reorderKeepPlaying)
        }

        function test_a_paused_file_stays_in_the_player_through_a_write() {
            // It does not sound, but the player holds it at its second, and
            // a stop under the pause would put the page's needle back at zero.
            playMusic.source = song; root._pausedFile = ({ "local": true, "sec": 42 })
            root.removeStation(b); settle()
            root.addStation("http://d.example/live"); settle()
            compare(playMusic.stopCalls, 0, "a list write stopped the player under a paused file")
            compare(playMusic.source, song)
            compare(root.started, [])
            compare(root.sessionsEnded, 0)
        }

        function test_a_pause_whose_file_left_the_player_keeps_nothing_there() {
            root._pausedFile = ({ "local": true, "sec": 42 })
            root.removeStation(b); settle()
            verify(playMusic.stopCalls >= 1)
            compare(root.started, [])
        }

        function test_the_next_write_after_a_kept_one_stops_a_station_again() {
            playFile(song)
            root.removeStation(a); settle()
            verify(!root._reorderKeepPlaying)
            playRow(0)                      // B, the first row now
            root.removeStation(b); settle()
            compare(playMusic.stops, 1)
            verify(!playMusic.on)
        }
    }
}
