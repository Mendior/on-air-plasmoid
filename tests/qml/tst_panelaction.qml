// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The panel icon's right-click entries against a stand-in for the widget:
// what each one reads, what it says and which road a click takes.
import QtQuick
import QtTest

import "../../package/contents/ui" as Ui

TestCase {
    id: tc
    name: "PanelAction"

    // The entries call i18n(); qmltestrunner has no KLocalizedContext.
    function i18n(s, a) {
        return a === undefined ? s : String(s).replace("%1", a);
    }

    Component { id: actionComp; Ui.PanelAction {} }

    Component {
        id: appComp
        QtObject {
            property string bigFace: "play"
            property bool canPlay: true
            property string _podPlayingKey: ""
            property bool _ownMuted: false
            property int sleepRemainingSec: 0
            property bool _casting: false
            property bool playing: false
            function isPlaying() { return playing; }
            property var log: []
            function transport(cmd) { log.push("transport:" + cmd); }
            function _mprisDispatch(cmd) { log.push("dispatch:" + cmd); }
            function setUserVolume(v) { log.push("volume:" + v); }
            function targetVolume() { return 0.6; }
            function startSleepTimer(s) { log.push("sleep:" + s); }
            function cancelSleepTimer() { log.push("wake"); }
        }
    }

    function entry(kind, app, stations) {
        var a = createTemporaryObject(actionComp, tc, { "kind": kind, "app": app, "stations": stations === undefined ? 3 : stations });
        verify(a !== null);
        return a;
    }

    function test_the_first_entry_says_and_does_what_the_big_button_does() {
        var app = createTemporaryObject(appComp, tc);
        var a = entry("key", app);
        compare(a.text, "Play");
        compare(a.icon.name, "media-playback-start");
        verify(a.enabled && a.visible);
        // The face changes under an open menu's entry.
        app.bigFace = "stop"; app.playing = true;
        compare(a.text, "Stop");
        compare(a.icon.name, "media-playback-stop");
        app.bigFace = "pause";
        compare(a.text, "Pause");
        // One road for every face: the big button's own.
        a.trigger();
        compare(app.log, ["transport:PlayPause"]);
        // Nothing to play: there, and greyed.
        app.bigFace = "play"; app.playing = false; app.canPlay = false;
        verify(!a.enabled && a.visible);
    }

    function test_next_station_takes_the_desks_next() {
        var app = createTemporaryObject(appComp, tc);
        var a = entry("next", app, 3);
        compare(a.text, "Next station");
        verify(a.visible);
        a.trigger();
        compare(app.log, ["dispatch:Next"]);
        // One station has no next one; an episode's Next is not a station.
        verify(!entry("next", app, 1).visible);
        app._podPlayingKey = "guid-a";
        verify(!a.visible);
    }

    function test_mute_goes_through_the_listeners_own_volume_and_back() {
        var app = createTemporaryObject(appComp, tc);
        var a = entry("mute", app);
        verify(!a.visible, "offered over a silent widget");
        app.playing = true;
        verify(a.visible);
        compare(a.text, "Mute");
        a.trigger();
        compare(app.log, ["volume:0"]);
        app._ownMuted = true;
        compare(a.text, "Unmute");
        a.trigger();
        compare(app.log, ["volume:0", "volume:0.6"]);
        // A device playing alone counts as sound.
        app.playing = false; app._ownMuted = false; app._casting = true;
        verify(a.visible);
    }

    function test_the_sleep_entry_starts_thirty_minutes_or_cancels() {
        var app = createTemporaryObject(appComp, tc);
        var a = entry("sleep", app);
        verify(!a.visible);
        app.playing = true;
        compare(a.text, "Sleep in 30 minutes");
        a.trigger();
        compare(app.log, ["sleep:1800"]);
        app.sleepRemainingSec = 1799;
        compare(a.text, "Cancel sleep timer");
        a.trigger();
        compare(app.log, ["sleep:1800", "wake"]);
        // A timer that runs is offered its cancelling over silence too.
        app.playing = false;
        verify(a.visible);
    }

    function test_an_entry_of_no_kind_and_one_without_a_widget_do_nothing() {
        var app = createTemporaryObject(appComp, tc);
        var none = entry("record", app);
        verify(!none.visible);
        compare(none.text, "");
        none.trigger();
        compare(app.log, []);
        // No widget yet (the entries are made before main.qml hands itself
        // over): a greyed Play, and nothing is read off what is not there.
        var lone = createTemporaryObject(actionComp, tc, { "kind": "key" });
        compare(lone.text, "Play");
        verify(!lone.enabled);
        verify(!createTemporaryObject(actionComp, tc, { "kind": "mute" }).visible);
    }
}
