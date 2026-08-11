/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import QtMultimedia

import "AlarmLogic.js" as AlarmLogic
import "PodcastLogic.js" as PodcastLogic

// ── The alarm engine ─────────────────────────────────────────────────────────
// Owns the whole alarm feature now: the list, the 30 s tick, the zone
// retime, the keep-awake inhibit holder — and since the second slice, the
// FIRE paths (station, chime, podcast) with the wake-tone safety net. The
// player, the heal roads and the cast state stay main's; the engine works
// them through the app facade, which is also what makes every verdict in
// here drivable from the mock tests.
Item {
    id: engine

    // main.qml's root. Scheduling: exec, nextSeq, notify,
    // _schedApplyTzChange, _mprisRunDir, _mprisId. Fire: cancelSleepTimer,
    // _podHandoff, startWithFade, _castSetVolume, targetVolume, isPlaying,
    // _healClearPending, playPodcastEpisode, _podFileUrl; the writable
    // player-state properties (_volumeOverridePct, _castCurrentUrl, the
    // _preview*/_current* families, _wantsPlaying, _healRetryAttempts,
    // lastPlay, _orphanOrder, _healSeq, _previewSeq, _healRun); the reads
    // _casting, _castLocalPlay, _podDownloads, _podPlayed; and the object
    // refs healRetryTimerRef, netResumeTimerRef, healTimerRef,
    // connectWatchdogRef, playMusicRef, playMusicOutputRef,
    // stationsModelRef.
    required property var app
    // Plasmoid configuration in production; a plain object in tests.
    required property var cfg

    // ── Wake-up alarms ───────────────────────────────────────────────────────
    // Entries: { station, url, favicon, uuid, hh, mm,
    //            repeat: "once"|"daily"|"weekly",
    //            weekday: 0-6, volumePct, keepAwake, nextRun: epoch ms }.
    // uuid is the radio-browser identity when the station came from the
    // search — it gives a deleted station's alarm the byuuid heal road.
    // Same wall-clock scheduling as the recordings (AlarmLogic.js), but a
    // SEPARATE list on purpose: a recording entry means "capture the rest
    // of its window", an alarm means "start playing, loud enough to wake" —
    // mixing the two semantics in one list is how scheduler bugs are born.
    property var alarms: []

    // Engine's own copy — main keeps one too, for the six timestamp readers
    // in FullRepresentation that never touch this engine.
    function _pad2(n) { return ("0" + n).slice(-2); }

    function start() {
        // Alarms re-arm their keep-awake holder every start: the pid file
        // kill-and-rearm cycle also cleans up after a crashed session.
        _loadAlarms();
    }

    function _loadAlarms() {
        alarms = AlarmLogic.sanitizeAlarms(cfg.alarms);
    }

    function _saveAlarms() {
        cfg.alarms = JSON.stringify(alarms);
    }

    function addAlarm(stationName, url, favicon, hh, mm, repeat, weekday, volumePct, keepAwake, uuid) {
        if (!url) return;
        // One defaulted weekday for BOTH the stored entry and the schedule
        // math — feeding nextOccurrence the raw undefined made the computed
        // nextRun disagree with the weekday the entry then carried.
        var wd = weekday === undefined ? new Date().getDay() : weekday;
        var list = alarms.slice();
        list.push({
            "station": stationName || url,
            "url": url,
            "favicon": favicon || "",
            "uuid": (uuid || "").toString(),
            "hh": hh, "mm": mm,
            "repeat": repeat || "once",
            "weekday": wd,
            "volumePct": Math.max(15, Math.min(100, volumePct || 40)),
            "keepAwake": keepAwake === true,
            "nextRun": AlarmLogic.nextOccurrence(hh, mm, repeat || "once", wd, Date.now())
        });
        alarms = list;
        _saveAlarms();
        _alarmArmInhibit();
    }

    function removeAlarm(index) {
        if (index < 0 || index >= alarms.length) return;
        var list = alarms.slice();
        list.splice(index, 1);
        alarms = list;
        _saveAlarms();
        _alarmArmInhibit();
    }

    Timer {
        id: alarmTimer
        interval: 30000
        repeat: true
        running: engine.alarms.length > 0
        onTriggered: engine._alarmTick()
    }

    function _alarmTick() {
        var now = Date.now();
        // Zone check first, on the shared path — the fire scan below then
        // reads the corrected instants.
        app._schedApplyTzChange(now);
        var list = alarms.slice();
        var changed = false;
        var due = [];
        for (var i = list.length - 1; i >= 0; i--) {
            var a = list[i];
            var dec = AlarmLogic.fireDecision(a.nextRun, now, AlarmLogic.GRACE_MS);
            if (dec === "wait") continue;
            if (dec === "missed") {
                app.notify(i18n("Wake-up alarm missed"),
                           i18n("%1 was set for %2 — the computer was off or asleep at that time.",
                                a.station, _pad2(a.hh) + ":" + _pad2(a.mm)),
                           "dialog-warning");
            } else {
                due.push(a);
            }
            // The entry advances (or leaves) BEFORE any side effect — a fire
            // path that throws must never leave a due entry behind to re-fire
            // on every subsequent tick.
            var next = AlarmLogic.advance(a, now);
            if (next < 0) list.splice(i, 1);
            else a.nextRun = next;
            changed = true;
        }
        if (changed) {
            alarms = list;
            _saveAlarms();
            _alarmArmInhibit();
        } else if (_alarmInhibitUntil > 0 && now > _alarmInhibitUntil - 120000
                   && AlarmLogic.earliestKeepAwake(alarms) > 0) {
            // The 12 h-capped holder is about to let go while a keep-awake
            // alarm is still ahead — chain a fresh one so the coverage is
            // continuous all the way to the fire moment.
            _alarmArmInhibit();
        }
        if (due.length > 0) {
            // One player, one stream: the first due entry (list order — the
            // scan ran newest-index first) plays; the rest must not vanish
            // in silence, so their owner at least learns what happened.
            due.reverse();
            _alarmFire(due[0]);
            if (due.length > 1) {
                var others = [];
                for (var j = 1; j < due.length; j++) others.push(due[j].station);
                app.notify(i18n("Wake-up alarm"),
                           i18n("%1 came due at the same time — playing %2 instead.",
                                others.join(", "), due[0].station),
                           "clock");
            }
        }
    }

    // The alarm half of the shared zone-change road: main's
    // _schedApplyTzChange calls this, exactly as it calls the recording
    // engine's twin. shouldRetime: an entry missed under every possible
    // zone keeps its stale instant so the fire scan's "missed" road
    // reports and retires it — retiming would resurrect it on the wrong day.
    function applyTzRetime(now) {
        if (alarms.length === 0) return;
        var al = alarms.slice();
        for (var a = 0; a < al.length; a++)
            if (AlarmLogic.shouldRetime(al[a], now))
                al[a].nextRun = AlarmLogic.retimeForZone(al[a], now);
        alarms = al;
        _saveAlarms();
        _alarmArmInhibit();
    }

    // Fire = the reason this feature exists, so every step is belt and
    // braces: a wake-up must never end in silence.
    function _alarmFire(a) {
        // A podcast alarm wakes with the SHOW, not a stream: the newest
        // unheard downloaded episode — fully offline, the one wake-up no
        // dead WiFi can silence. Nobody else in the world does this.
        if ((a.url || "").indexOf("podcast:") === 0) { _alarmFirePodcast(a); return; }
        if ((a.url || "") === "chime:") { _alarmFireChime(a); return; }
        // The alarm outranks whatever the evening left behind: a sleep fade
        // mid-flight would drag the volume right back down, and a pending
        // sleep timer would stop the just-started station minutes later.
        app.cancelSleepTimer();
        // Last night's episode has to be handed over before the station takes
        // the player, exactly as _playStation and playLocalFile do it. Left
        // standing, the episode's key outlives it: the stall timer then files
        // the STATION's position under the episode's bookmark, and the connect
        // watchdog reads "a podcast is playing" and stops instead of healing —
        // so the one thing an alarm may never do, end in silence, is what the
        // recovery road would have done.
        app._podHandoff();
        alarmFallbackTimer.interval = 25000;   // a kick may have shortened it
        // ...and a sink left muted last night would turn the wake-up into
        // silence — unmute it, best-effort (no pactl / no PulseAudio is fine).
        app.exec(": ALARM_UNMUTE; pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null; true");
        // The alarm's own level as a one-shot override, so startWithFade's
        // fade-in target picks it up immediately — the debounced
        // setUserVolume path would lose the race against the fade, and
        // writing the config would permanently overwrite the level the
        // user chose last night. It REPLACES rather than raises: the
        // number in the alarm form is what the room gets, whether the
        // evening ended louder or quieter. (The word "floor" stood here
        // and was wrong — checked 2026-08-11; the only floor is the form's
        // own minimum of 15 %, which is what keeps an alarm from silence.)
        app._volumeOverridePct = Math.max(15, Math.min(100, a.volumePct || 40));
        app._volumeOverrideAtMs = Date.now();
        // If cast devices are checked, startWithFade routes the alarm to
        // them — waking up to the same bedroom speaker the evening ended on
        // is correct, and the fallback below knows local silence is fine.
        // But cast delivery starts UNPROVEN: only a fresh __CAST_OK__ from a
        // device upgrades it to confirmed, and the wake-tone gate trusts
        // nothing less. Clearing the last-pushed URL forces the re-push (and
        // with it the fresh acknowledgement) even when the bedtime stream is
        // the same one — that is exactly the route that dies overnight.
        _alarmCastConfirmed = false;
        app._castCurrentUrl = "";
        // The evening's last act may have been a search preview, and the
        // preview pair outlives the popup: left set, the alarm's own stream
        // inherits the preview's short connect leash, and the failure roads
        // would retry LAST NIGHT's candidate under this alarm's station
        // name. The alarm starts clean.
        app._previewUrl = "";
        app._previewCodec = "";
        app._previewUuid = "";
        // startWithFade is called directly (no _playStation), so the
        // origin/resolved pair would still describe LAST NIGHT's stream —
        // and an error on the alarm stream would then heal the wrong
        // station. Point both at the alarm's own URL.
        app._currentOrigUrl = a.url;
        app._currentUnwrappedUrl = a.url;
        app._currentResolvedUrl = a.url;
        // An alarm IS a standing order — whatever it takes, keep trying.
        // But the recovery roads replay lastPlay, which still points at last
        // night's station until the callLater below finds this one: clear it
        // and stop any retry armed by yesterday's outage, so a network edge
        // during the alarm window can only ever restart the alarm's own url,
        // never resurrect whatever played last evening.
        app._wantsPlaying = true;
        app._healRetryAttempts = 0;
        app.lastPlay = -1;
        app.healRetryTimerRef.stop();
        app.netResumeTimerRef.stop();
        // The order's own copy: recovery must survive the station having
        // been deleted from the list. Every road that used to look the
        // station up by row index falls back to this via _orderSubject —
        // without it, a mid-alarm stream death ended the wake-up for good.
        app._orphanOrder = { "name": a.station, "hostname": a.url,
                         "favicon": a.favicon || "",
                         "uuid": (a.uuid || "").toString() };
        app.startWithFade({ "name": a.station, "hostname": a.url,
                        "favicon": a.favicon || "", "active": true });
        // The floor must reach the DEVICES too: while casting, the local
        // output is muted and playMusicOutput's level is irrelevant — a
        // bedroom speaker left whisper-quiet last night would wake nobody.
        // Goes through the standard debounced path, so per-device balances
        // still apply on top.
        app._castSetVolume(app.targetVolume());
        _alarmFallbackArmed = true;
        alarmFallbackTimer.restart();
        // Keep the station list's playing-row marker honest when the alarm
        // station is in the visible list (same courtesy the heal path pays).
        // Deleted-station recovery itself rides app._orphanOrder (set above) —
        // the roads fall back to it via _orderSubject when no row answers.
        Qt.callLater(function() {
            for (var k = 0; k < app.stationsModelRef.count; k++) {
                if (app.stationsModelRef.get(k).hostname === a.url) {
                    app.lastPlay = k;
                    break;
                }
            }
        });
        app.notify(i18n("Wake-up alarm"), a.station, "clock");
    }

    // The wake tone: if the station has not become audibly alive within the
    // window (network down, stream dead, resolver hung), the bundled chime
    // takes over. An alarm that fails must fail LOUDLY. Disarmed by an
    // explicit stop or a manual station pick — either one means "I'm up".
    property bool _alarmFallbackArmed: false

    // Set by the CAST_PLAY dispatcher on a device's __CAST_OK__ — the only
    // evidence that "casting" is more than an optimistic flag. Reset by
    // every _alarmFire, so yesterday's proof cannot vouch for today's alarm.
    property bool _alarmCastConfirmed: false

    // The bundled chime's identity, resolved once — compared wherever the
    // tone needs special-casing (the infinite loop in startWithFade; file://
    // already keeps it off the cast branch).
    readonly property url _alarmToneUrl: Qt.resolvedUrl("../sounds/alarm-fallback.ogg")

    // While the alarm road itself starts a local track, playLocalFile's
    // "picking a track means I'm up" stand-down must hold its fire — the
    // alarm is the one caller that is NOT the user being awake.
    property bool _alarmFiring: false

    // The tone by CHOICE: the same road the fallback takes, arrived at on
    // purpose. A looping local file needs no heal roads and no standing
    // order — and nothing here may leave last night's stream in a state
    // to resurrect itself over the ringer.
    function _alarmFireChime(a) {
        app.cancelSleepTimer();
        app._podHandoff();
        app.exec(": ALARM_UNMUTE; pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null; true # " + app.nextSeq());
        app._volumeOverridePct = Math.max(15, Math.min(100, a.volumePct || 40));
        app._volumeOverrideAtMs = Date.now();
        _alarmCastConfirmed = false;
        app._castCurrentUrl = "";
        app._previewUrl = "";
        app._previewCodec = "";
        app._previewUuid = "";
        app._wantsPlaying = false;
        app._orphanOrder = null;
        app.healRetryTimerRef.stop();
        app.netResumeTimerRef.stop();
        app.lastPlay = -1;
        app.startWithFade({ "name": i18n("Wake-up alarm"), "hostname": _alarmToneUrl,
                        "favicon": "", "active": true });
        app.notify(i18n("Wake-up alarm"), a.station, "clock");
    }

    function _alarmFirePodcast(a) {
        app.cancelSleepTimer();
        // A local file needs no heal roads — and yesterday's standing order
        // must not be able to replay a station over the morning episode.
        app._wantsPlaying = false;
        app._orphanOrder = null;
        app.healRetryTimerRef.stop();
        app.netResumeTimerRef.stop();
        app.lastPlay = -1;
        // Stale cast state from the evening must not gag the chime: the
        // wake-tone gate trusts only a FRESH device acknowledgement, and a
        // podcast alarm plays locally by definition.
        _alarmCastConfirmed = false;
        app._castCurrentUrl = "";
        // The same two hardware guarantees the station road makes: the sink
        // may have been muted overnight, and the volume floor must reach the
        // fade target — playLocalFile is told not to stand either down.
        app.exec(": ALARM_UNMUTE; pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null; true # " + app.nextSeq());
        app._volumeOverridePct = Math.max(15, Math.min(100, a.volumePct || 40));
        app._volumeOverrideAtMs = Date.now();
        var feed = a.url.substring(8);
        var f = PodcastLogic.newestForAlarm(app._podDownloads, feed, app._podPlayed);
        if (f !== "") {
            var meta = app._podDownloads[f];
            var furl = app._podFileUrl(f);
            _alarmFiring = true;
            try {
                // Already on the air (fell asleep to it): playPodcastEpisode
                // would TOGGLE it off — raise the floor instead and let it be.
                if (!(app.isPlaying() && app.playMusicRef.source.toString() === furl))
                    app.playPodcastEpisode(furl, meta.title || f, meta.key || "",
                                       meta.show || a.station || "", meta.art || "",
                                       meta.feed || "");
                else
                    app.playMusicOutputRef.volume = app.targetVolume();
            } finally {
                _alarmFiring = false;
            }
            // Armed AFTER the play call — playLocalFile stops this very
            // timer on its way through, and a fallback armed before it was
            // a fallback already disarmed.
            _alarmFallbackArmed = true;
            alarmFallbackTimer.interval = 25000;
            alarmFallbackTimer.restart();
            app.notify(i18n("Wake-up alarm"), meta.title || a.station, "clock");
        } else {
            // Nothing of the show on disk: the chime takes over almost at
            // once — 25 seconds of silence at 07:00 helps nobody.
            _alarmFallbackArmed = true;
            alarmFallbackTimer.interval = 1200;
            alarmFallbackTimer.restart();
            app.notify(i18n("Wake-up alarm"),
                   i18n("No downloaded episode of %1 was on disk — waking with the chime.",
                        a.station || i18n("the show")),
                   "clock");
        }
    }

    Timer {
        id: alarmFallbackTimer
        interval: 25000
        repeat: false
        onTriggered: engine._fallbackTrigger()
    }

    // The tone's verdict, named so the tests can walk it — the exact road
    // tonight's false positive rode (playing=true, position=24917,
    // mediaStatus=Buffering: an audible station ruled dead by a status flag).
    function _fallbackTrigger() {
            if (!_alarmFallbackArmed) return;
            _alarmFallbackArmed = false;
            // The verdict this timer is about to pass, with the evidence it
            // passed it on — a wake tone replacing a station the sleeper
            // says was AUDIBLE needs this line to be judged (2026-08-10).
            console.log("[ARP] alarm fallback check — playing=" + app.isPlaying()
                        + " mediaStatus=" + app.playMusicRef.mediaStatus
                        + " position=" + app.playMusicRef.position
                        + " casting=" + app._casting);
            // Casting-only is a healthy route ONLY once a device actually
            // acknowledged the play command. The optimistic _casting flag
            // alone would let a speaker unplugged overnight silence the
            // alarm entirely — the one failure this tone exists to catch.
            if (AlarmLogic.castSilencesWakeTone(app._casting,
                                                _alarmCastConfirmed,
                                                app._castLocalPlay)) return;
            // "Audibly alive" is measured by audio having FLOWED, not by
            // Qt's status flag: a live stream plays for minutes sitting in
            // BufferingMedia (4), never reaching BufferedMedia — measured
            // 2026-08-10 23:08:46, playing=true position=24917 status=4,
            // and the tone replaced a station the sleeper could hear. Five
            // seconds of played media is a stream that STARTED; one that
            // dies later is the heal road's case (the standing order is
            // armed), not the tone's.
            if (app.isPlaying() && (app.playMusicRef.mediaStatus === MediaPlayer.BufferedMedia
                                || app.playMusicRef.position > 5000)) return;
            // The tone is the LAST word — nothing may replace it. A heal
            // audition launched a beat ago has an XHR in flight whose
            // callback would call startWithFade on the found stream and kill
            // the looping chime. Retire every heal leg (bump the generation,
            // stop the timers, drop the pending audition) and end the
            // standing-order replay so no road can start a station over the
            // tone. The person is asleep; the tone must not go quiet.
            app._healSeq++;
            app._healClearPending();
            app._healRun = null;
            // A preview retry rung still in flight holds the same power as
            // a heal audition — its startWithFade would replace the tone
            // just the same. Same bump, same reason.
            app._previewSeq++;
            app._previewUrl = "";
            app._previewCodec = "";
            app._previewUuid = "";
            app.healTimerRef.stop();
            app.healRetryTimerRef.stop();
            app.netResumeTimerRef.stop();
            app.connectWatchdogRef.stop();
            app._wantsPlaying = false;
            // A podcast alarm that never got going hands its episode over
            // here: the tone is taking the player, so the needle is filed
            // and the episode's identity retired before it can follow the
            // chime around.
            app._podHandoff();
            // file:// skips the cast branch in startWithFade — the tone
            // plays locally, which is exactly where the sleeper is. The tone
            // starts BEFORE the toast: the sleeper needs sound, not words,
            // and nothing is allowed to sit between them and it.
            app.startWithFade({ "name": i18n("Wake-up alarm"),
                            "hostname": _alarmToneUrl,
                            "favicon": "", "active": true });
            app.notify(i18n("Wake-up alarm"),
                   i18n("The station could not start — playing the built-in tone instead."),
                   "dialog-warning");
        }

    // Tests only: the net's window and whether it is armed to fire,
    // without exposing the Timer itself.
    function _fallbackIntervalForTest() { return alarmFallbackTimer.interval; }
    function _fallbackRunningForTest() { return alarmFallbackTimer.running; }

    // Every stand-down road in main (a station picked by hand, a stop, a
    // local track chosen while no alarm is the caller) says "I'm up" here.
    function standDown() {
        _alarmFallbackArmed = false;
        alarmFallbackTimer.stop();
    }

    // "Keep the computer awake" holder: one short-lived process group —
    // setsid + systemd-inhibit + sleep holds the inhibit fd until just past
    // the soonest keep-awake alarm, then everything exits by itself. No
    // daemon, nothing to leak. Re-arming kills the previous group first,
    // identity-checked: a pid file can survive a reboot and the number may
    // belong to an innocent process by then.
    readonly property string _alarmInhibitPidFile: app._mprisRunDir + "/arp-alarm-inhibit-" + app._mprisId + ".pid"

    // When the current inhibit holder lets go (epoch ms), 0 when none is
    // held. The holder is capped at 12 h (AlarmLogic.INHIBIT_MAX_S) so a
    // weekly alarm can't pin the machine awake for six days — _alarmTick
    // re-arms a fresh one as this deadline approaches.
    property double _alarmInhibitUntil: 0

    function _alarmArmInhibit() {
        var now = Date.now();
        var secs = AlarmLogic.inhibitSeconds(AlarmLogic.earliestKeepAwake(alarms), now);
        var pf = _alarmInhibitPidFile.replace(/'/g, "'\\''");
        var cmd = ": ALARM_INHIBIT; "
            + "if [ -f '" + pf + "' ]; then p=$(cat '" + pf + "' 2>/dev/null); "
            + "[ -n \"$p\" ] && ps -o cmd= -p \"$p\" 2>/dev/null | grep -q 'systemd-inhibit.*On Air' "
            + "&& kill -- -\"$p\" 2>/dev/null; rm -f '" + pf + "'; fi; ";
        if (secs > 0) {
            cmd += "command -v systemd-inhibit >/dev/null 2>&1 && { "
                + "setsid systemd-inhibit --what=sleep --who='On Air' "
                + "--why='Wake-up alarm' sleep " + secs + " >/dev/null 2>&1 & "
                + "echo $! > '" + pf + "'; }; ";
        }
        _alarmInhibitUntil = secs > 0 ? now + secs * 1000 : 0;
        app.exec(cmd + "true # " + app.nextSeq());
    }

    // Engine-owned shell round-trips. True = the command was ours.
    function handleExec(cmd, stdout) {
        if (cmd.indexOf(": ALARM_INHIBIT;") === 0) {
            return true; // fire-and-forget
        }
        return false;
    }
}
