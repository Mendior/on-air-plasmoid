// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The sync engine's state machine, driven end to end through a mock app and
// a mock config — the exact seam SyncEngine.qml was extracted to create.
// Everything here used to be untestable inside main.qml: enable/disable
// round-trips, superseded-generation acks, the loopback shell command
// construction (quoting, delays, channel maps), the calibration loudness
// math with its cubic fold-back, the join watchdog's kick cycle and the
// default-sink steal watch.
//
// The mocks are QtObjects, not plain JS objects: a JS object handed through
// createObject's initial properties is copied, and the engine would write
// into a twin the assertions never see.
import QtQuick
import QtTest

import "../../package/contents/ui"

Item {
    id: harness

    // Engine notifications call i18n(); qmltestrunner has no KLocalizedContext,
    // so the scope chain finds this stand-in (production resolves the real one
    // from the plasmoid context — main.qml defines no such function).
    function i18n(s) {
        var out = s;
        for (var i = 1; i < arguments.length; i++)
            out = out.replace("%" + i, arguments[i]);
        return out;
    }

    Component {
        id: engineComp
        SyncEngine {}
    }

    Component {
        id: mockAppComp
        QtObject {
            property var execLog: []
            property int seqN: 0
            property var notes: []
            property var lastOutputDevice: null
            property int btListed: 0
            property var castApplied: []
            property bool playing: false
            property bool anythingPlaying: false
            property bool thrifty: false
            property bool recording: false
            property bool alarmEngaged: false
            property var mediaDevs: ({ audioOutputs: [] })
            // A QtObject, not a plain JS object: the engine's volume observer
            // needs a real volumeChanged signal to fire, exactly as the live
            // AudioOutput does.
            property QtObject playerOutput: QtObject {
                property real volume: 0.5
                property var device: null
            }
            property real lastUserVolume: -1
            // Mirrors main.qml: only a deliberate gesture stamps the pending
            // pct, and it is stamped AFTER the volume write. The step flag
            // says whether it was a wheel step (folds during a park) or an
            // absolute level (applies as spoken).
            property int _pendingUserVolumePct: -1
            property bool _pendingUserVolumeStep: false
            function setUserVolume(v, fromStep) {
                lastUserVolume = v;
                playerOutput.volume = Math.max(0, Math.min(1, v));
                _pendingUserVolumeStep = fromStep === true;
                _pendingUserVolumePct = Math.round(playerOutput.volume * 100);
            }
            property string instanceId: "7"
            property string _btConnectingMac: ""
            property string _btPairingMac: ""
            property string _btPendingSinkName: ""
            // notifyThrows replays the 2026.18 disease: the autoDelete'd
            // KNotification self-destructed after its first close and every
            // later notify() threw mid-caller. The engine must survive it.
            property bool notifyThrows: false
            function exec(cmd) { execLog.push(cmd); }
            function nextSeq() { return ++seqN; }
            // The real facade's A2DP bounce, shared with main.qml's solo
            // kick. The engine only concatenates it, so the mock needs the
            // same shape — enough of it that the kick assertions still read
            // the profile names out of the command.
            function btProfileBounceShell(mac) {
                var macU = String(mac).replace(/:/g, "_");
                return "c=bluez_card." + macU
                     + "; p=$(timeout 3 pactl list cards | awk '/Name: bluez_card." + macU + "/{f=1}"
                     + " f && /Active Profile:/{print $3; exit}');"
                     + " timeout 5 pactl set-card-profile \"$c\" off >/dev/null 2>&1; sleep 1;"
                     + " timeout 5 pactl set-card-profile \"$c\" a2dp-sink >/dev/null 2>&1"
                     + " || timeout 5 pactl set-card-profile \"$c\" a2dp_sink >/dev/null 2>&1"
                     + " || { [ -n \"$p\" ] && timeout 5 pactl set-card-profile \"$c\" \"$p\" >/dev/null 2>&1; }; true";
            }
            function notify(t, x, i) {
                if (notifyThrows) throw new Error("the messenger died mid-sentence");
                notes.push({ title: t, text: x, icon: i });
            }
            function isPlaying() { return playing; }
            function setAudioOutputDevice(id) { lastOutputDevice = id; }
            function btList() { btListed++; }
            function _btValidMac(mac) { return /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(mac); }
            function castTrimActive(id) { return false; }
            function applyCastTrim(uuid) { castApplied.push(uuid); }
        }
    }

    Component {
        id: mockCfgComp
        QtObject {
            property int syncOffsetMs: 0
            property int syncVerifiedMs: -1
            property string syncOffsetMap: "{}"
            property string syncRefLatMap: "{}"
            property bool syncAutoCare: false
            // Mirrors config/main.xml's default: the sweep is on unless
            // someone turns it off.
            property bool syncUltrasonic: true
            // By-ear mode: the microphone road is refused entirely.
            property bool syncManualOnly: false
            property string syncMicName: ""
            property string deviceTrims: "{}"
            property string deviceChannels: "{}"
            property string syncExcluded: "{}"
            property string combinePrevOutput: ""
            property string combinePrevDefault: ""
            // 0 = never set, exactly as main.xml has it: the first enable then
        // inherits the machine's own level instead of ramping to full.
            property int combineMasterPct: 0
            property bool combineWanted: false
            property string audioOutputDevice: ""
        }
    }

    TestCase {
        name: "SyncEngine"

        readonly property string wired: "alsa_output.pci-0000_00_1f.3.analog-stereo"
        readonly property string wired2: "alsa_output.usb-dock.analog-stereo"
        readonly property string btSink: "bluez_output.AA_BB_CC_DD_EE_FF.1"
        readonly property string btMac: "AA:BB:CC:DD:EE:FF"

        function dev(id) { return { id: id, description: "desc of " + id }; }

        function rig(outputs, cfgProps) {
            var mock = createTemporaryObject(mockAppComp, harness);
            verify(mock !== null);
            mock.mediaDevs = { audioOutputs: outputs || [] };
            var cfg = createTemporaryObject(mockCfgComp, harness, cfgProps || {});
            verify(cfg !== null);
            var e = createTemporaryObject(engineComp, harness, { app: mock, cfg: cfg });
            verify(e !== null);
            return { e: e, mock: mock, cfg: cfg };
        }

        function activate(r) {
            // enable + a clean ack — the shortest path to a live engine.
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            var ok = r.e.handleExec(": PW_COMBINE " + r.e._combineLoadSeq + ";",
                                    "PREVDEF usb_dac\nNULL 77\nLB 101 " + wired
                                    + "\nLB 102 " + btSink + "\n", "");
            verify(ok);
            verify(r.e._combineActive);
            // The enable dispatches the master ramp; the real engine gets its
            // ack a beat later. Deliver it, or the engine stays in "the master
            // is mid-ramp" and every level it reads afterwards is suppressed.
            r.e.handleExec(": PW_RAMP; x", "", "");
            verify(!r.e._combineRamping);
        }

        // ── enable: command construction ──────────────────────────────────

        function test_enable_builds_the_load_command() {
            var r = rig([dev(wired), dev(btSink)], { syncOffsetMs: 200 });
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            compare(r.mock.execLog.length, 1);
            var cmd = r.mock.execLog[0];
            verify(cmd.indexOf(": PW_COMBINE 1;") === 0);
            verify(cmd.indexOf("module-null-sink") !== -1);
            verify(cmd.indexOf("sink_name=onair_combined_7") !== -1);
            verify(cmd.indexOf("pactl set-default-sink onair_combined_7") !== -1);
            // Polite flip only — the ramp runs from the generation-checked
            // ack, never from this shell (a superseded enable's shell must
            // not ramp the next generation's sink by name).
            verify(cmd.indexOf("set-sink-volume onair_combined_7 20%") !== -1);
            verify(cmd.indexOf("for rv in") === -1);
            // The same-name sweep makes the enable idempotent against a
            // racing disable's teardown — no same-named twins.
            verify(cmd.indexOf("for sw in $(pactl list short modules") !== -1);
            verify(cmd.indexOf("awk '/onair_combined_7([^0-9]|$)/") !== -1);
            // Braced loopbacks: a failed null sink skips them ALL, or pactl
            // would attach them to the default source — the microphone.
            verify(cmd.indexOf("&& { if pactl list short sinks") !== -1);
            // The slowest device sets the schedule: wired waits the full lag,
            // the lagging Bluetooth sink itself waits nothing extra.
            verify(cmd.indexOf("sink='" + wired + "' latency_msec=260") !== -1);
            verify(cmd.indexOf("sink='" + btSink + "' latency_msec=60") !== -1);
            verify(r.e._combineWantActive);
            verify(!r.e._combineActive);       // ack not in yet
        }

        function test_enable_quotes_hostile_sink_names() {
            var evil = "alsa_output.it's.analog";
            var r = rig([dev(evil), dev(btSink)]);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            verify(r.mock.execLog[0].indexOf("sink='alsa_output.it'\\''s.analog'") !== -1);
        }

        function test_enable_respects_channel_and_balance() {
            var r = rig([dev(wired), dev(btSink)],
                        { deviceChannels: JSON.stringify({ "AA:BB:CC:DD:EE:FF": "L" }) });
            r.e._loadDeviceChannels();
            r.e.setDeviceTrim(wired, 0.5);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cmd.indexOf("channels=1 channel_map=front-left") !== -1);   // the L pair half
            verify(cmd.indexOf("set-sink-input-volume \"$si\" 50%") !== -1);   // the balance
        }

        // ── the PW_COMBINE ack ────────────────────────────────────────────

        function test_the_ramp_runs_from_the_ack_and_ends_at_the_remembered_master() {
            // The room's master is what the volume keys trimmed all evening;
            // the ramp out of the polite 20% flip ends THERE, not at a 100%
            // the user never chose. Full passthrough only when nothing is
            // remembered.
            var r = rig([dev(wired), dev(btSink)], { combineMasterPct: 40 });
            activate(r);
            var ramp = "";
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_RAMP;") === 0) ramp = r.mock.execLog[i];
            verify(ramp !== "");
            verify(ramp.indexOf("set-sink-volume onair_combined_7 35%") !== -1);
            verify(ramp.indexOf("set-sink-volume onair_combined_7 40%") !== -1);
            verify(ramp.indexOf("100%") === -1);       // remembered beats blast
        }

        function test_disable_remembers_the_rooms_master_level() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.combineOutputsDisable();
            var un = r.mock.execLog[r.mock.execLog.length - 1];
            verify(un.indexOf(": PW_UNCOMBINE_DONE;") === 0);
            verify(un.indexOf("cm=$(pactl get-sink-volume onair_combined_7") !== -1);
            verify(un.indexOf("echo \"MASTER ${cm:-100}\"") !== -1);
            r.e.handleExec(": PW_UNCOMBINE_DONE;", "MASTER 40\n", "");
            compare(r.cfg.combineMasterPct, 40);
        }

        function test_a_mid_ramp_disable_does_not_persist_the_ramp_level() {
            // The ramp climbs through levels the user never chose; a disable
            // landing inside that window used to read one off the sink and
            // file it as "the level the room was left at".
            var r = rig([dev(wired), dev(btSink)]);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            r.e.handleExec(": PW_COMBINE " + r.e._combineLoadSeq + ";",
                           "PREVDEF usb_dac\nNULL 77\nLB 101 " + wired + "\n", "");
            verify(r.e._combineRamping);          // ramp dispatched, unacked
            r.e.combineOutputsDisable();
            var un = r.mock.execLog[r.mock.execLog.length - 1];
            verify(un.indexOf("MASTER") === -1);  // nothing read, nothing remembered
        }

        function test_the_master_read_defers_to_an_outstanding_park() {
            // Flags answer "is a measurement running NOW"; a cancelled run
            // clears them while its shell still owes the room its levels.
            // The park file outlives the flags — the read asks it too.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.combineOutputsDisable();
            var un = r.mock.execLog[r.mock.execLog.length - 1];
            verify(un.indexOf("onair_park_") !== -1);
            verify(un.indexOf("echo \"MASTER ${cm:-100}\"") !== -1);
        }

        function test_every_cancel_road_ends_the_measurement_process() {
            // Only the user's own button used to send the kill; the disable
            // and the resurrect cleared the flags and left calibrate.py
            // clicking into a room being torn down under it.
            var roads = [
                function(r) { r.e.calibrateCancel() },
                function(r) { r.e.combineOutputsDisable() },
                function(r) { r.e._combineResurrect() }
            ]
            for (var i = 0; i < roads.length; i++) {
                var r = rig([dev(wired), dev(btSink)])
                activate(r)
                r.e._calibrating = true
                var before = r.mock.execLog.length
                roads[i](r)
                var killed = false
                for (var j = before; j < r.mock.execLog.length; j++)
                    if (r.mock.execLog[j].indexOf(": PW_CALIBKILL;") === 0) killed = true
                verify(killed, "road " + i + " must issue the kill")
                verify(!r.e._calibrating)
            }
        }

        function test_a_first_enable_keeps_the_rooms_own_volume() {
            // The combined sink BECOMES the system output. With no
            // remembered master the ramp assumed 100%, so switching the
            // sync on put the whole machine at full scale — at night, the
            // whole house. The room's current level is inherited instead.
            // 0 = the key the real config has never been written to.
            var r = rig([dev(wired), dev(btSink)], { combineMasterPct: 0 })
            r.e._combineAvailable = true
            r.e.combineOutputsEnable()
            r.e.handleExec(": PW_COMBINE " + r.e._combineLoadSeq + ";",
                           "PREVDEF usb_dac\nPREVVOL 30\nNULL 77\nLB 101 " + wired + "\n", "")
            var ramp = ""
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_RAMP;") === 0) ramp = r.mock.execLog[i]
            verify(ramp !== "")
            verify(ramp.indexOf("onair_combined_7 30%") !== -1)   // ends where the room was
            verify(ramp.indexOf("100%") === -1)                   // never full blast
        }

        function test_an_unreadable_room_level_still_passes_sound() {
            // PREVVOL 0 means the level could not be read — acoustic
            // passthrough is the only safe answer there, not silence.
            var r = rig([dev(wired), dev(btSink)], { combineMasterPct: 0 })
            r.e._combineAvailable = true
            r.e.combineOutputsEnable()
            r.e.handleExec(": PW_COMBINE " + r.e._combineLoadSeq + ";",
                           "PREVDEF usb_dac\nPREVVOL 0\nNULL 77\nLB 101 " + wired + "\n", "")
            var ramp = ""
            for (var j = 0; j < r.mock.execLog.length; j++)
                if (r.mock.execLog[j].indexOf(": PW_RAMP;") === 0) ramp = r.mock.execLog[j]
            verify(ramp.indexOf("onair_combined_7 100%") !== -1)
        }

        function test_the_sync_wish_survives_a_login() {
            // The startup sweep tears the group down and nothing rebuilt it:
            // "all speakers" used to mean "until the next reboot". The wish
            // persists; the probe ack rebuilds; only the USER's off clears
            // it — a logout's teardown does not.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            compare(r.cfg.combineWanted, true);
            r.e.combineOutputsDisable(true);              // logout teardown
            compare(r.cfg.combineWanted, true);           // wish survives
            var r2 = rig([dev(wired), dev(btSink)], { combineWanted: true });
            r2.e.handleExec(": PW_PROBE;", "__PACTL_YES__\n", "");
            verify(r2.e._combineWantActive);              // the room is coming back
            var cmd = r2.mock.execLog[r2.mock.execLog.length - 1];
            verify(cmd.indexOf(": PW_COMBINE ") === 0);
            var r3 = rig([dev(wired), dev(btSink)]);
            activate(r3);
            r3.e.combineOutputsDisable();                 // the user's own off
            compare(r3.cfg.combineWanted, false);         // wish cleared
        }

        function test_resurrect_draws_the_same_generation_boundary_as_disable() {
            // A rebuild in flight when the sink dies acks as stale and keeps
            // its hands off the flags — the resurrect must reset them itself
            // or every later rebuild parks behind an ack that never comes.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._combineReloopBusy = true;
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink), dev("onair_combined_7")] };
            r.e.onOutputsChanged();
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink)] };
            r.e.onOutputsChanged();
            verify(!r.e._combineReloopBusy);
            verify(!r.e._combineReloopPending);
        }

        function test_disable_mid_measurement_does_not_remember_the_park() {
            // The verify parks the master at 100% for the clicks; a disable
            // landing inside that window must not write the PARK into
            // combineMasterPct — the next enable would ramp to a blast.
            var r = rig([dev(wired), dev(btSink)], { combineMasterPct: 40 });
            activate(r);
            r.e._verifyPending = true;
            r.e._verifyArmTimers();
            r.e.combineOutputsDisable();
            var un = "";
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_UNCOMBINE_DONE;") === 0) un = r.mock.execLog[i];
            verify(un !== "");
            verify(un.indexOf("MASTER") === -1);        // nothing to remember
            compare(r.cfg.combineMasterPct, 40);        // the real level stands
        }

        function test_the_verify_union_is_consumed_on_use() {
            // Last evening's frozen member set must not ride along in a later
            // cancel's unmute — the user may have silenced a speaker on
            // purpose since, and a clicks-phase cancel never muted anything.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._verifyPending = true;
            r.e._verifyArmTimers();
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_OK 3\n", "");
            compare(r.e._verifyMembers.length, 0);
        }

        function test_the_park_survives_a_logout_in_a_restore_file() {
            // A logout SIGTERMs the whole cgroup — the in-shell restore
            // never runs and the next session would play every speaker at
            // the 55/85% park. The saved levels go to a runtime file only a
            // COMPLETED restore deletes; startup replays the leftovers.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            var cal = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cal.indexOf("onair_park_7.sh") !== -1);
            verify(cal.indexOf("printf 'pactl set-sink-volume '\\''%s'\\'' %s\\n' \"$s0\"") !== -1);
            // XDG_RUNTIME_DIR only — the /tmp fallback was a world-writable
            // path that startup() then replays with sh (security fix).
            verify(cal.indexOf("rm -f \"$XDG_RUNTIME_DIR/onair_park_7.sh\"") !== -1);
            r.e._verifyPending = true;
            r.e._verifyArmTimers();
            r.e._verifyLaunch();
            var ver = r.mock.execLog[r.mock.execLog.length - 1];
            verify(ver.indexOf("onair_park_7.sh") !== -1);
            verify(ver.indexOf("printf 'pactl set-sink-mute '\\''%s'\\'' 0\\n' \"$w0\"") !== -1);
            var r2 = rig([]);
            r2.e.startup();
            var seen = false;
            for (var i = 0; i < r2.mock.execLog.length; i++)
                if (r2.mock.execLog[i].indexOf(": PW_PARKREST;") === 0
                    && r2.mock.execLog[i].indexOf("onair_park_7.sh") !== -1) seen = true;
            verify(seen);
        }

        function test_a_dead_null_sink_resurrects_the_group() {
            // A PipeWire restart (or a hand-typed unload) kills the combined
            // sink under a live group and NOTHING else notices — its name is
            // filtered out of the group math. Once the sink has been seen
            // alive and then goes missing, the engine rebuilds the whole
            // group; an unrelated device event BEFORE the sink ever appeared
            // must not read as a corpse.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            var before = r.mock.execLog.length;
            r.e.onOutputsChanged();                     // sink not seen yet
            verify(r.e._combineActive);                 // no false resurrect
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink), dev("onair_combined_7")] };
            r.e.onOutputsChanged();                     // seen alive
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink)] };
            r.e.onOutputsChanged();                     // and now it is gone
            verify(r.e._combineWantActive);             // fresh enable armed
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cmd.indexOf(": PW_COMBINE ") === 0);
            verify(cmd.indexOf("for sw in $(pactl list short modules") !== -1);
        }

        function test_ack_activates_and_remembers_the_previous_default() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            compare(r.e._combinePrevDefault, "usb_dac");
            compare(r.cfg.combinePrevDefault, "usb_dac");
            compare(r.e._combineLoopbackIds.length, 2);
        }

        function test_ack_never_adopts_our_own_sink_as_previous_default() {
            var r = rig([dev(wired), dev(btSink)]);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            r.e.handleExec(": PW_COMBINE 1;",
                           "PREVDEF onair_combined_7\nNULL 77\nLB 101 " + wired + "\n", "");
            compare(r.e._combinePrevDefault, "");
            compare(r.cfg.combinePrevDefault, "");
        }

        function test_stale_generation_ack_is_unloaded_not_adopted() {
            var r = rig([dev(wired), dev(btSink)]);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();        // generation 1 in flight
            var before = r.mock.execLog.length;
            var ok = r.e.handleExec(": PW_COMBINE 99;", "NULL 88\nLB 200 " + wired + "\n", "");
            verify(ok);
            verify(!r.e._combineActive);       // state untouched
            verify(r.e._combineWantActive);
            var cleanup = r.mock.execLog[before];
            verify(cleanup.indexOf(": PW_UNCOMBINE;") === 0);
            verify(cleanup.indexOf("unload-module 88") !== -1);
            verify(cleanup.indexOf("unload-module 200") !== -1);
        }

        function test_disable_during_load_clears_the_persisted_key_on_ack() {
            var r = rig([dev(wired), dev(btSink)]);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            r.cfg.combinePrevOutput = wired;   // as if a device had been chosen
            r.e.combineOutputsDisable();       // withdrawn while in flight
            r.e.handleExec(": PW_COMBINE 1;",
                           "PREVDEF usb_dac\nNULL 77\nLB 101 " + wired + "\n", "");
            verify(!r.e._combineActive);
            // The stale-key bug: this used to survive and re-point the system
            // default on every later login.
            compare(r.cfg.combinePrevOutput, "");
        }

        function test_all_lbmiss_enable_waits_instead_of_failing() {
            var r = rig([dev(wired), dev(btSink)]);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            r.e.handleExec(": PW_COMBINE 1;",
                           "PREVDEF usb_dac\nNULL 77\nLBMISS " + wired
                           + "\nLBMISS " + btSink + "\n", "");
            verify(r.e._combineActive);        // healthy build, waiting for its sinks
            compare(r.mock.notes.length, 0);   // no failure notification
            verify(r.e._combineLbRetries > 0); // retry pass armed
        }

        // ── disable: conditional default hand-back ────────────────────────

        function test_disable_hands_the_default_back_conditionally() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            var before = r.mock.execLog.length;
            r.e.combineOutputsDisable();
            var cmd = r.mock.execLog[before];
            verify(cmd.indexOf(": PW_UNCOMBINE_DONE;") === 0);
            verify(cmd.indexOf("d=$(pactl get-default-sink") !== -1);
            verify(cmd.indexOf("unload-module 77") !== -1);
            // Restore happens only when the default is still ours AND our
            // sink is really gone — a disable followed at once by an enable
            // rebuilds it under the same name, and this shell, still walking
            // its tail, must not take the default off the live new group.
            verify(cmd.indexOf("[ \"$d\" = \"onair_combined_7\" ]") !== -1);
            verify(cmd.indexOf("! pactl list short sinks 2>/dev/null | cut -f2 | grep -Fxq 'onair_combined_7'") !== -1);
            verify(cmd.indexOf("pactl set-default-sink 'usb_dac'") !== -1);
            // The persisted key survives until the teardown's own ack.
            compare(r.cfg.combinePrevDefault, "usb_dac");
            r.e.handleExec(": PW_UNCOMBINE_DONE; x", "", "");
            compare(r.cfg.combinePrevDefault, "");
        }

        // ── rebuilds: generation guard and retry budget ───────────────────

        function test_stale_reloop_ack_keeps_hands_off_the_busy_flag() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._combineReloopBusy = true;     // the live generation is rebuilding
            r.e._combineLoadSeq = 5;           // ...and the ack below is from gen 1
            var before = r.mock.execLog.length;
            r.e.handleExec(": PW_RELOOP 1; x", "LB 300 " + wired + "\n", "");
            verify(r.e._combineReloopBusy);    // untouched
            verify(r.mock.execLog[before].indexOf("unload-module 300") !== -1);
        }

        function test_matching_reloop_ack_adopts_and_clears_busy() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._combineReloopBusy = true;
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 300 " + wired + "\nLB 301 " + btSink + "\n", "");
            verify(!r.e._combineReloopBusy);
            verify(r.e._combineLoopbackIds.indexOf("300") >= 0);
        }

        function test_a_new_missing_sink_gets_a_fresh_retry_budget() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            for (var i = 0; i < 10; i++) r.e._combineHandleMiss("LBMISS sink_a");
            compare(r.e._combineLbRetries, 8); // budget exhausted against sink_a
            r.e._combineHandleMiss("LBMISS sink_b");
            compare(r.e._combineLbRetries, 1); // sink_b starts over
            r.e._combineHandleMiss("");
            compare(r.e._combineLbRetries, 0); // clean build resets everything
        }

        // ── calibration: the loudness math ────────────────────────────────

        function test_calibration_folds_the_real_sink_volume_back_in() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            // wired parked from 110%: it plays (110/55)^3 = 8× louder than the
            // parked click measured; bt parked from its true 55%.
            var out = "CALIBVOL " + wired + " 110% 110%\n"
                    + "CALIBVOL " + btSink + " 55% 55%\n"
                    + "CALIB_LVL " + wired + " 20000\n"
                    + "CALIB_LVL " + btSink + " 10000\n"
                    + "CALIB_OK 150\n";
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;", out, "");
            compare(r.cfg.syncOffsetMs, 150);
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 150);
            // wired: effective amp 20000*8=160000 vs bt 10000 → trim (1/16)^(1/3)
            fuzzyCompare(r.e.trimOf(wired), 0.4, 0.011);
            compare(r.e.trimOf(btMac), 1.0);   // the quietest is the reference
            compare(r.mock.notes.length, 1);
            compare(r.mock.notes[0].title, "Speakers calibrated");
        }

        function test_calibrate_builds_the_full_measurement_shell() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            verify(r.e._calibrating);
            compare(r.mock.playerOutput.volume, 0);        // stream muted for the clicks
            compare(r.e._calibVolumeBefore, 0.5);
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cmd.indexOf(": PW_CALIB ") === 0);
            verify(cmd.indexOf(" " + btMac + " P55 ;") !== -1); // mac + park level
            // Park, echo the real level for the loudness math, restore after.
            verify(cmd.indexOf("pactl set-sink-volume \"$s0\" 55%") !== -1);
            verify(cmd.indexOf("echo \"CALIBVOL $s0 ${v0:-55%}\"") !== -1);
            verify(cmd.indexOf("pactl set-sink-volume \"$s0\" ${v0:-55%}") !== -1);
            // The mic placeholder sits between the timing pair and the extras.
            verify(cmd.indexOf("\"$s1\" ''") !== -1);
            // A wedged measurement dies INSIDE the guard window (90s - 10s).
            // The base grew with the run: the timing pair is measured with
            // the inaudible sweep AND with the clicks, and the old 50 s cut
            // a healthy run off partway through.
            verify(cmd.indexOf(" timeout 80 python3 '") !== -1);
        }

        function test_a_dead_microphone_never_escalates_the_park() {
            // Every mic delivered exact zeros (a hardware touch-mute no
            // software flag reports): louder clicks cannot fix a deaf ear.
            // No 85% retry, a specific verdict, and the stream comes back.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            var before = r.mock.execLog.length;
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P55 ;",
                           "CALIB_FAIL microphone silent\n", "");
            verify(!r.e._calibrating);
            compare(r.mock.execLog.length, before);   // no louder retry launched
            var note = r.mock.notes[r.mock.notes.length - 1];
            verify(note.text.indexOf("pure silence") !== -1);
            fuzzyCompare(r.mock.playerOutput.volume, 0.5, 0.001);
        }

        function test_a_stand_in_microphone_is_credited() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P55 ;",
                           "CALIB_MIC Stub Webcam Microphone\n"
                           + "CALIB_LVL " + wired + " 10000\n"
                           + "CALIB_LVL " + btSink + " 10000\n"
                           + "CALIB_OK 200\n", "");
            var note = r.mock.notes[r.mock.notes.length - 1];
            compare(note.title, "Speakers calibrated");
            verify(note.text.indexOf("Measured with Stub Webcam Microphone") !== -1);
        }

        // ── Whose zero is it: the lag frame ───────────────────────────────
        // Only DIFFERENCES between the stored lags ever reach a speaker, so
        // the set carries a free constant — and three writers used to each
        // pick their own. The calibration measures everything against the
        // wired speaker and files the Bluetooth number as though that
        // speaker sat at zero, without ever writing the zero; the verify
        // only ever adds; the slider only ever touched the Bluetooth entry.
        // Measured on real hardware: a stale 154 left under a fresh 171 put
        // 17 ms of delay between two speakers the microphone had just timed
        // 156 ms apart, and every road out of that state made it worse.
        // A stale entry of 154 with a fresh measurement of 156 is the exact
        // shape of that room.

        function test_calibration_clears_the_reference_speakers_stale_lag() {
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: '{"' + wired + '":154,"' + btMac + '":171}' });
            activate(r);
            r.e.calibrateSync();
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P55 ;",
                           "CALIB_LVL " + wired + " 10000\n"
                           + "CALIB_LVL " + btSink + " 10000\n"
                           + "CALIB_REF " + wired + "\n"
                           + "CALIB_OK 156\n", "");
            var map = JSON.parse(r.cfg.syncOffsetMap);
            // Absent, not zero: that is how _lagForSink already reads a
            // speaker nobody has measured a lag for.
            compare(map[wired], undefined);
            compare(map[btMac], 156);
            // And the whole measured difference reaches the speakers —
            // without the reference line this landed at 2 ms.
            var s = r.e._combineRealSinks();
            compare(r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s), 156);
        }

        function test_the_verify_correction_lands_anchored_at_zero() {
            // The residuals are measured against the EARLIEST arrival, so
            // they are never negative and the correction can only push the
            // set upward. Unanchored it walks: this room went 145, 214, 267
            // while the sound stayed put.
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: '{"' + wired + '":154,"' + btMac + '":171}' });
            activate(r);
            r.e._verifyPending = true;
            r.e._verifyCorrected = false;
            var vOut = "VERIFY_LAG " + wired + " 0\n"
                     + "VERIFY_LAG " + btSink + " 139\n"
                     + "VERIFY_OK 139\n";
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", vOut, "");
            // Pass 1 only proposes — the map must not move on one reading.
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 171);
            verify(r.e._verifyPending);
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", vOut, "");
            var map = JSON.parse(r.cfg.syncOffsetMap);
            compare(map[wired], 0);
            compare(map[btMac], 156);   // 171 + 139, slid back down to the anchor
            var s = r.e._combineRealSinks();
            compare(r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s), 156);
        }

        function test_the_slider_sets_the_difference_not_one_end() {
            // The complaint that found all of this: typing 145 changed
            // nothing audible, because the wired member's own 154 subtracted
            // itself from every value the slider could write.
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: '{"' + wired + '":154,"' + btMac + '":171}' });
            activate(r);
            r.e.setSyncOffset(145);
            var map = JSON.parse(r.cfg.syncOffsetMap);
            compare(map[wired], 0);
            compare(map[btMac], 145);
            var s = r.e._combineRealSinks();
            compare(r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s), 145);
        }

        function test_anchoring_moves_the_numbers_and_not_the_sound() {
            // What makes the anchor safe to run after every write: sliding
            // the whole set by one constant is inaudible by construction.
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: '{"' + wired + '":154,"' + btMac + '":171}' });
            activate(r);
            var s = r.e._combineRealSinks();
            var before = r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s);
            var m = JSON.parse(r.cfg.syncOffsetMap);
            r.e._anchorLags(m, s);
            r.cfg.syncOffsetMap = JSON.stringify(m);
            compare(m[wired], 0);
            compare(m[btMac], 17);
            compare(r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s), before);
        }

        function test_an_already_anchored_frame_is_left_alone() {
            // A speaker with no entry reads as zero everywhere else, so a
            // healthy frame is already anchored and must not be rewritten —
            // otherwise every save would churn the config for nothing.
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: '{"' + btMac + '":145}' });
            activate(r);
            var m = JSON.parse(r.cfg.syncOffsetMap);
            r.e._anchorLags(m, r.e._combineRealSinks());
            compare(m[wired], undefined);
            compare(m[btMac], 145);
        }

        function test_verify_with_dead_mics_reports_honestly() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_FAIL microphone silent\n", "");
            verify(!r.e._verifyPending);
            var note = r.mock.notes[r.mock.notes.length - 1];
            compare(note.title, "Sync check");
            verify(note.text.indexOf("pure silence") !== -1);
        }

        function test_inaudible_clicks_escalate_the_park_once() {
            // A noisy room buries the 55% clicks (measured here: 1976 over a
            // floor of ~570). The failure handler retries ONCE at 85% —
            // stream still muted, original volume remembered, no premature
            // failure toast — and only the louder round's failure is final.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            compare(r.e._calibVolumeBefore, 0.5);
            var seq = r.e._calibRunSeq;
            r.e.handleExec(": PW_CALIB " + seq + " " + btMac + " P55 ;",
                           "CALIB_FAIL no click heard from the wired speaker\n", "");
            verify(r.e._calibrating);                        // retry in flight
            compare(r.e._calibParkPct, 85);
            compare(r.e._calibVolumeBefore, 0.5);            // not clobbered to 0
            compare(r.mock.playerOutput.volume, 0);          // still muted
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cmd.indexOf(" " + btMac + " P85 ;") !== -1);
            verify(cmd.indexOf("pactl set-sink-volume \"$s0\" 85%") !== -1);
            verify(cmd.indexOf("${v0:-85%}") !== -1);
            var lastNote = r.mock.notes[r.mock.notes.length - 1];
            verify(lastNote.text.indexOf("too quiet") !== -1);
            // The louder round failing too is the end of the road.
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P85 ;",
                           "CALIB_FAIL no click heard from the wired speaker\n", "");
            verify(!r.e._calibrating);
            compare(r.mock.notes[r.mock.notes.length - 1].title, "Calibration did not succeed");
            fuzzyCompare(r.mock.playerOutput.volume, 0.5, 0.001);  // stream restored
        }

        function test_an_unsettled_sweep_escalates_the_park_once() {
            // The sweep genuinely gains level with the park: its stream
            // compensation is capped at 171%, which a cubic 55% park cannot
            // fill and an 85% one can. So a sweep reading that would not
            // settle earns the same single louder pass the clicks get — and
            // both toasts name the actual problem instead of promising
            // clicks to a listener who asked for silence or blaming a
            // microphone that heard everything.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            var seq = r.e._calibRunSeq;
            r.e.handleExec(": PW_CALIB " + seq + " " + btMac + " P55 ;",
                           "CALIB_FAIL inaudible reading would not settle\n", "");
            verify(r.e._calibrating);                        // retry in flight
            compare(r.e._calibParkPct, 85);
            var rnote = r.mock.notes[r.mock.notes.length - 1];
            verify(rnote.text.indexOf("would not settle") !== -1);
            verify(rnote.text.indexOf("clicks") === -1);
            // The louder round failing the same way is the end of the road,
            // and the verdict talks about settling, not about microphones.
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P85 ;",
                           "CALIB_FAIL inaudible reading would not settle\n", "");
            verify(!r.e._calibrating);
            var fnote = r.mock.notes[r.mock.notes.length - 1];
            compare(fnote.title, "Calibration did not succeed");
            verify(fnote.text.indexOf("turned up") !== -1);
            fuzzyCompare(r.mock.playerOutput.volume, 0.5, 0.001);
        }

        function test_retry_that_cannot_launch_still_returns_the_music() {
            // The louder pass may refuse to arm — the Bluetooth member
            // vanished mid-run, which is the LIKELIEST reason no click was
            // heard. A toast promising "once more" over a stream nothing
            // will ever unmute is the silent-forever bug; the failure path
            // must run instead: volume restored, honest verdict.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            compare(r.e._calibVolumeBefore, 0.5);
            var seq = r.e._calibRunSeq;
            r.mock.mediaDevs = { audioOutputs: [dev(wired)] };   // JBL powered off
            r.e.handleExec(": PW_CALIB " + seq + " " + btMac + " P55 ;",
                           "CALIB_FAIL no click heard from the wired speaker\n", "");
            verify(!r.e._calibrating);                           // nothing armed
            fuzzyCompare(r.mock.playerOutput.volume, 0.5, 0.001); // music is back
            compare(r.mock.notes[r.mock.notes.length - 1].title, "Calibration did not succeed");
        }

        function test_level_fold_uses_the_runs_own_park() {
            // An escalated run parks at 85: a sink restored to 110% is
            // (110/85)^3 louder in playback than it measured — the fold must
            // use the run's park, not the historic 55.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            var out = "CALIBVOL " + wired + " 110%\n"
                    + "CALIBVOL " + btSink + " 85%\n"
                    + "CALIB_LVL " + wired + " 10000\n"
                    + "CALIB_LVL " + btSink + " 10000\n"
                    + "CALIB_OK 200\n";
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P85 ;", out, "");
            // wired eff = 10000*(110/85)^3 = 21670 vs bt 10000 → wired trims
            // to (10000/21670)^(1/3) ≈ 0.774
            fuzzyCompare(r.e.trimOf(wired), 0.77, 0.011);
            compare(r.e.trimOf(btMac), 1.0);
        }

        function test_verify_rides_at_known_levels() {
            // The deployed-path check must not inherit the evening's knobs:
            // combined master to acoustic passthrough, members to the park
            // the calibration measured at, trims to full — all restored in
            // the same shell.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._calibParkPct = 85;
            r.e._verifyPending = true;
            r.e._verifyMembers = [wired, btSink];
            r.e._verifyLaunch();
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(/^: PW_VERIFY \d+;/.test(cmd));
            verify(cmd.indexOf("pactl set-sink-volume onair_combined_7 100%") !== -1);
            verify(cmd.indexOf("pactl set-sink-volume onair_combined_7 ${cm:-100%}") !== -1);
            verify(cmd.indexOf("pactl set-sink-volume \"$w0\" 85%") !== -1);
            verify(cmd.indexOf("${y0:-85%}") !== -1);
            verify(cmd.indexOf("' verify '") !== -1);
        }

        function test_the_check_keeps_the_inaudible_promise_without_auto_care() {
            // The setting reads "measure with a tone too high to hear", and
            // the calibration has kept that promise for a while. The check
            // did not: it asked for _autoCareParked, which only the drift
            // probe ever sets, so every check that followed a manual
            // Calibrate fell back to audible clicks with the box ticked.
            var r = rig([dev(wired), dev(btSink)], { syncUltrasonic: true });
            activate(r);
            verify(!r.e._autoCareParked);
            r.e._verifyPending = true;
            r.e._verifyMembers = [wired, btSink];
            r.e._verifyLaunch();
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(/^: PW_VERIFY \d+;/.test(cmd));
            verify(cmd.indexOf("ONAIR_ULTRA_ONLY=1") !== -1);
        }

        function test_the_check_clicks_when_the_listener_asked_for_clicks() {
            var r = rig([dev(wired), dev(btSink)], { syncUltrasonic: false });
            activate(r);
            r.e._verifyPending = true;
            r.e._verifyMembers = [wired, btSink];
            r.e._verifyLaunch();
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cmd.indexOf("ONAIR_ULTRA_ONLY=1") === -1);
            verify(cmd.indexOf("ONAIR_NO_ULTRA=1") !== -1);
        }

        function test_an_inaudible_calibration_keeps_its_wired_reference() {
            // An inaudible run prints no level line for anyone
            // (CALIB_NOLEVELS), so the heard-map came back holding only the
            // Bluetooth member — and two checks later the healthy wired
            // reference had been ticked out of its own group. CALIB_REF
            // names the sink every other lag was timed against, which is
            // proof it was heard.
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            for (var i = 0; i < 2; i++) {
                r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                               "CALIB_BY sweep\nCALIB_NOLEVELS\nCALIB_REF " + wired
                               + "\nCALIB_OK 150\n", "");
                r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                               "VERIFY_BY clicks\nVERIFY_PARTIAL " + wired + "\n", "");
            }
            verify(r.e.syncDeviceIncluded(wired));
        }

        function test_anchor_keeps_an_entry_less_bluetooth_members_offset() {
            // A member with no entry is not a member at zero: a Bluetooth
            // sink without one deploys the global offset. Reading that
            // absence as zero let the anchor write an entry in and the
            // speaker lost the whole compensation it was playing with —
            // 250 ms of it, silently, on a map save nobody asked for.
            var m = {};
            m[wired2] = -60;
            var r = rig([dev(wired), dev(wired2), dev(btSink)],
                        { syncOffsetMs: 250, syncOffsetMap: JSON.stringify(m) });
            activate(r);
            var s = r.e._combineRealSinks();
            var before = r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s);
            var mm = JSON.parse(r.cfg.syncOffsetMap);
            r.e._anchorLags(mm, s);
            r.cfg.syncOffsetMap = JSON.stringify(mm);
            compare(r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s), before);
        }

        function test_sync_offset_persists_per_mac_and_rebuilds() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.setSyncOffset(250);
            compare(r.cfg.syncOffsetMs, 250);
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 250);
            var before = r.mock.execLog.length;
            wait(500);                          // the 300 ms rebuild debounce
            verify(r.mock.execLog.length > before);
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cmd.indexOf(": PW_RELOOP " + r.e._combineLoadSeq + ";") === 0);
            verify(cmd.indexOf("sink='" + wired + "' latency_msec=310") !== -1);
            verify(cmd.indexOf("sink='" + btSink + "' latency_msec=60") !== -1);
        }

        function test_calibration_failure_is_a_notification_not_a_crash() {
            var r = rig([]);
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;", "CALIB_FAIL no click heard\n", "");
            compare(r.mock.notes.length, 1);
            compare(r.mock.notes[0].icon, "dialog-warning");
        }

        function test_calibration_stores_wired_lags_and_arms_the_verify() {
            // CALIB_XLAG: the extras' clicks are timed too — a USB DAC in
            // the group gets its measured lag instead of an assumed zero,
            // in the same map the MACs live in.
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            var out = "CALIB_LVL " + wired + " 20000\n"
                    + "CALIB_XLAG " + wired2 + " 34\n"
                    + "CALIB_OK 150\n";
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;", out, "");
            var map = JSON.parse(r.cfg.syncOffsetMap);
            compare(map[btMac], 150);
            compare(map[wired2], 34);
            verify(r.e._verifyPending);        // the check-measure is armed
        }

        function test_a_screaming_messenger_cannot_stop_the_show() {
            // main.qml's notify() wraps the KNotification in a try/catch,
            // but the engine must not lean on that belt: state lands BEFORE
            // any toast. For a whole session the autoDelete'd notification
            // object read null and every notify threw — and because the
            // "Speakers calibrated" toast came before the verify arming,
            // the stream stayed parked at volume 0 with nothing left to
            // ever restore it. Music silent after every calibration.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;    // parked for the clicks
            r.mock.notifyThrows = true;
            var threw = false;
            try {
                r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                               "CALIB_LVL " + wired + " 20000\nCALIB_OK 150\n", "");
            } catch (e) { threw = true; }
            verify(threw);                     // the scream really happened
            verify(r.e._verifyPending);        // and the verify is armed anyway
            verify(r.e.verifySettleInterval() >= 8000);
            var threw2 = false;
            try {
                r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_OK 12\n", "");
            } catch (e2) { threw2 = true; }
            verify(threw2);
            compare(r.mock.playerOutput.volume, 0.5);  // the stream came back
            compare(r.cfg.syncVerifiedMs, 12);
            verify(!r.e._verifyPending);
        }

        function test_a_clipped_mic_is_reported_not_silently_swallowed() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            var out = "CALIB_LVL " + wired + " 20000\n"
                    + "CALIB_CLIP " + btSink + "\n"
                    + "CALIB_OK 150\n";
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;", out, "");
            verify(r.mock.notes[0].text.indexOf("clipped") !== -1);
        }

        function test_wired_lag_feeds_the_loopback_schedule() {
            var m = {};
            m[wired2] = 40;
            var r = rig([dev(wired), dev(wired2), dev(btSink)],
                        { syncOffsetMs: 200, syncOffsetMap: JSON.stringify(m) });
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            var cmd = r.mock.execLog[0];
            // Slowest is the bt sink at 200: the unmeasured wired waits the
            // full 200, the measured dock (40 ahead of nothing — it LAGS 40)
            // waits the 160 difference, the bt itself waits nothing extra.
            verify(cmd.indexOf("sink='" + wired + "' latency_msec=260") !== -1);
            verify(cmd.indexOf("sink='" + wired2 + "' latency_msec=220") !== -1);
            verify(cmd.indexOf("sink='" + btSink + "' latency_msec=60") !== -1);
        }

        function test_verify_verdict_reports_and_unmutes() {
            var r = rig([dev(wired), dev(btSink)]);
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;    // as the calibration left it
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_OK 12\n", "");
            compare(r.cfg.syncVerifiedMs, 12);
            compare(r.mock.playerOutput.volume, 0.5);
            compare(r.mock.notes[r.mock.notes.length - 1].title, "Sync verified");
            verify(!r.e._verifyPending);
        }

        function test_verify_timers_scale_with_the_group() {
            // The fixed 35 s guard fired mid-isolation on every 5-speaker
            // run — the arithmetic must come from the group size.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._verifyArmTimers();
            // n=2 members, 1 bluetooth: settle 8s + 3s, guard = settle +
            // (10 + 2*27)s + 12s headroom. The 27 is what one member costs
            // when it needs its retry round: two rounds of up to three
            // 0.6+3.2 s captures.
            compare(r.e.verifySettleInterval(), 11000);
            compare(r.e.verifyGuardInterval(), 11000 + 64000 + 12000);
        }

        function test_empty_jacks_step_aside_from_the_clicks() {
            // Jack detection said "not available" — nobody clicks into a
            // hole in the air, and the start note says who sat out. The
            // real room this comes from: two never-used front-panel jacks
            // took turns failing the verify, one alarming verdict per run.
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            r.e.handleExec(": PW_PORTS;", JSON.stringify([
                { name: wired2, active_port: "p",
                  ports: [{ name: "p", availability: "not available" }] },
                { name: wired, active_port: "q",
                  ports: [{ name: "q", availability: "availability unknown" }] }
            ]), "");
            verify(r.e.portUnplugged(wired2));
            verify(!r.e.portUnplugged(wired));   // unknown is not unplugged
            r.e.calibrateSync();
            var cal = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cal.indexOf(": PW_CALIB") === 0);
            verify(cal.indexOf(wired2) === -1);
            verify(cal.indexOf(wired) !== -1);
            var note = r.mock.notes[r.mock.notes.length - 1];
            compare(note.title, "Calibration started");
            verify(note.text.indexOf("desc of " + wired2) !== -1);
        }

        function test_silent_in_both_rounds_leaves_the_group_by_itself() {
            // Deaf through both rounds of a run is one strike, not a
            // verdict: a loud room can bury a healthy speaker's clicks.
            // Only a SECOND deaf run makes it a property of the output —
            // then it steps out, with a note saying how to come back.
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                           "CALIB_LVL " + wired + " 20000\nCALIB_OK 150\n", "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_PARTIAL " + wired2 + "\n", "");
            verify(r.e.syncDeviceIncluded(wired2));         // strike one: kept
            var warn = r.mock.notes[r.mock.notes.length - 1];
            verify(warn.text.indexOf("next calibration") !== -1);
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                           "CALIB_LVL " + wired + " 20000\nCALIB_OK 150\n", "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_PARTIAL " + wired2 + "\n", "");
            verify(!r.e.syncDeviceIncluded(wired2));        // strike two: out
            var note = r.mock.notes[r.mock.notes.length - 1];
            verify(note.text.indexOf("left out of the group") !== -1);
        }

        function test_a_heard_speaker_wipes_its_eviction_slate() {
            // One deaf run, then a run where the mic DID hear the speaker:
            // the strike is wiped — a later deaf run starts the count over
            // instead of finishing an old one.
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                           "CALIB_LVL " + wired + " 20000\nCALIB_OK 150\n", "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_PARTIAL " + wired2 + "\n", "");
            verify(r.e.syncDeviceIncluded(wired2));          // strike one
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                           "CALIB_LVL " + wired + " 20000\n"
                           + "CALIB_LVL " + wired2 + " 8000\nCALIB_OK 150\n", "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_OK 12\n", "");
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                           "CALIB_LVL " + wired + " 20000\nCALIB_OK 150\n", "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_PARTIAL " + wired2 + "\n", "");
            verify(r.e.syncDeviceIncluded(wired2));          // strike ONE again, not two
        }

        function test_disable_makes_the_running_calibrations_ack_stale() {
            // Disable mid-clicks bumps the run generation: the orphaned
            // shell's ack minutes later must not arm a verify against a dead
            // group — nor launch an unasked-for 85% run over whatever the
            // user is listening to by then.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync();
            var seq = r.e._calibRunSeq;
            r.e.combineOutputsDisable();
            var before = r.mock.execLog.length;
            var notesBefore = r.mock.notes.length;
            r.e.handleExec(": PW_CALIB " + seq + " " + btMac + " P55 ;",
                           "CALIB_FAIL no click heard\n", "");
            compare(r.mock.execLog.length, before);          // no 85% retry
            compare(r.mock.notes.length, notesBefore);       // no toast
            verify(!r.e._calibrating);
            verify(!r.e._verifyPending);
        }

        function test_a_speaker_too_loud_to_measure_is_not_evicted() {
            // A speaker so loud its clicks saturate the mic gets CALIB_XLAG
            // and CALIB_CLIP but no CALIB_LVL. It was heard as loudly as
            // physically possible — the eviction road must NOT then kick it
            // out as "silent through both rounds".
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                           "CALIB_LVL " + wired + " 20000\n"
                           + "CALIB_XLAG " + wired2 + " 30\n"
                           + "CALIB_CLIP " + wired2 + "\nCALIB_OK 150\n", "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_PARTIAL " + wired2 + "\n", "");
            verify(r.e.syncDeviceIncluded(wired2));   // kept, loud is not silent
            var note = r.mock.notes[r.mock.notes.length - 1];
            verify(note.text.indexOf("may be muted or off") !== -1);
        }

        function test_a_speaker_heard_in_round_one_is_not_thrown_out() {
            // The same partial verdict for a sink that DID click in round 1
            // is a real problem worth a warning — but not an eviction: a
            // muted amp or a walked-off Bluetooth speaker comes back.
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " ;",
                           "CALIB_LVL " + wired + " 20000\n"
                           + "CALIB_LVL " + wired2 + " 9000\nCALIB_OK 150\n", "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_PARTIAL " + wired2 + "\n", "");
            verify(r.e.syncDeviceIncluded(wired2));
            var note = r.mock.notes[r.mock.notes.length - 1];
            verify(note.text.indexOf("may be muted or off") !== -1);
        }

        function test_verify_clicks_ride_at_a_known_volume() {
            // The connect cap (or a night-time turn-down) leaves a sink at
            // 40% — through-path clicks at that level fall under the noise
            // gate and a healthy speaker reads as unheard. The check parks
            // every member at the calibration's 55% and restores the exact
            // levels in the same shell.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._verifyPending = true;
            // Members are frozen when the timers arm; the launch measures
            // exactly that set (guard budget and argv can't disagree).
            r.e._verifyArmTimers();
            r.e._verifyLaunch();
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(/^: PW_VERIFY \d+;/.test(cmd));
            verify(cmd.indexOf("pactl set-sink-volume \"$w0\" 55%") !== -1);
            verify(cmd.indexOf("pactl set-sink-volume \"$w1\" 55%") !== -1);
            verify(cmd.indexOf("${y0:-55%}") !== -1);   // the exact level returns
            verify(cmd.indexOf("${y1:-55%}") !== -1);
            verify(cmd.indexOf("' verify '") !== -1);
        }

        function test_empty_jack_does_not_inflate_the_verify_budget() {
            var r = rig([dev(wired), dev(wired2), dev(btSink)]);
            activate(r);
            r.e.handleExec(": PW_PORTS;", JSON.stringify([
                { name: wired2, active_port: "p",
                  ports: [{ name: "p", availability: "not available" }] }
            ]), "");
            r.e._verifyArmTimers();
            // Two measurable members (wired + bt), not three.
            compare(r.e.verifySettleInterval(), 11000);
            compare(r.e.verifyGuardInterval(), 11000 + 64000 + 12000);
        }

        function test_rebuild_holds_during_measurement_and_releases_after() {
            // A rebuild landing mid-verify unloads the loopback a click is
            // riding — nudges and retries must wait their turn.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            var before = r.mock.execLog.length;
            r.e._verifyPending = true;
            r.e._combineRebuildLoopbacks();
            compare(r.mock.execLog.length, before);   // nothing fired
            verify(r.e._rebuildHeld);
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_OK 3\n", "");
            var reloop = false;
            for (var i = before; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_RELOOP") === 0) reloop = true;
            verify(reloop);                            // held rebuild ran
            verify(!r.e._rebuildHeld);
        }

        function test_every_verdict_wears_the_unmute_belt() {
            // The script's own unmutes can be swallowed by a drowsy pactl —
            // the widget re-asserts them on every verdict, idempotently.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_OK 3\n", "");
            var belted = false;
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_UNMUTE;") === 0
                    && r.mock.execLog[i].indexOf("set-sink-mute '" + btSink + "' 0") !== -1)
                    belted = true;
            verify(belted);
        }

        function test_verify_partial_names_the_unheard_speaker() {
            // A speaker that DID click in round 1 but vanished in round 2
            // must fail the verify LOUDLY — a small spread computed from
            // the survivors is the same optimistic-signal disease the wake
            // tone was cured of. (A speaker silent in BOTH rounds takes the
            // eviction road instead — its own test below.)
            var r = rig([dev(wired), dev(btSink)]);
            r.e._calibHeard = (function() { var h = {}; h[btSink] = true; return h; })();
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_PARTIAL " + btSink + "\n", "");
            compare(r.cfg.syncVerifiedMs, -1);            // NOT confirmed
            compare(r.mock.playerOutput.volume, 0.5);     // volume still returns
            var note = r.mock.notes[r.mock.notes.length - 1];
            compare(note.icon, "dialog-warning");
            verify(note.text.indexOf("Could not hear") !== -1);
            verify(!r.e._verifyPending);
        }

        function test_verify_residual_feeds_back_and_reverifies_once() {
            // The closed loop: a measured through-path residual lands in the
            // speaker's stored lag, the loopbacks rebuild, and ONE more
            // verify runs — volume stays muted until the second verdict.
            var m = {}; m[btMac] = 213;
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify(m) });
            activate(r);
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 0\nVERIFY_LAG " + btSink + " 149\nVERIFY_OK 149\n", "");
            // The first reading proposes and stays muted for its twin.
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 213);
            verify(r.e._verifyPending);
            compare(r.mock.playerOutput.volume, 0);
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 0\nVERIFY_LAG " + btSink + " 149\nVERIFY_OK 149\n", "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 362);  // 213 + 149
            verify(r.e._verifyCorrected);
            verify(r.e._verifyPending);                 // confirming round armed
            compare(r.mock.playerOutput.volume, 0);     // still muted for it
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_OK 3\n", "");
            compare(r.cfg.syncVerifiedMs, 3);
            compare(r.mock.playerOutput.volume, 0.5);   // and now released
            verify(!r.e._verifyPending);
        }

        function test_verify_pathology_flushes_the_bluetooth_route() {
            // Past ~900 ms the number is not a lag but a stuck buffer —
            // more delay never cures it; a suspend/resume bounce does.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 0\nVERIFY_LAG " + btSink + " 2320\nVERIFY_OK 2320\n", "");
            var flushed = false;
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_FLUSH;") === 0
                    && r.mock.execLog[i].indexOf("suspend-sink '" + btSink + "'") !== -1)
                    flushed = true;
            verify(flushed);
            verify(r.e._verifyPending);                 // round two armed
        }

        function test_verify_failure_unmutes_without_extra_noise() {
            // The calibration verdict was already reported; a verify that
            // heard nothing must hand the volume back and stay quiet.
            var r = rig([dev(wired), dev(btSink)]);
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", "VERIFY_FAIL nothing heard\n", "");
            compare(r.cfg.syncVerifiedMs, -1);
            compare(r.mock.playerOutput.volume, 0.5);
            compare(r.mock.notes.length, 0);
            verify(!r.e._verifyPending);
        }

        function test_trim_moved_during_rebuild_lands_on_the_fresh_modules() {
            // The rebuild kills the module→sink map with the modules; a
            // slider moved mid-flight used to volume a corpse. The ack's
            // reconcile pass must bring the FRESH module to the stored value.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._combineRebuildLoopbacks();
            compare(r.e._combineModuleForKey(wired), "");   // map died with the flight
            r.e.setDeviceTrim(wired, 0.5);                  // dragged mid-rebuild
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + ";",
                           "LB 201 " + wired + "\nLB 202 " + btSink + "\n", "");
            wait(400);                                      // the 250 ms apply debounce
            var last = r.mock.execLog[r.mock.execLog.length - 1];
            verify(last.indexOf(": PW_TRIM;") === 0);
            verify(last.indexOf("m=201") !== -1);           // the fresh module id
            verify(last.indexOf("50%") !== -1);             // the stored balance
        }

        function test_trim_moved_during_enable_lands_on_the_adopted_modules() {
            var r = rig([dev(wired), dev(btSink)]);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            r.e.setDeviceTrim(wired, 0.6);                  // dragged mid-load
            r.e.handleExec(": PW_COMBINE " + r.e._combineLoadSeq + ";",
                           "PREVDEF usb_dac\nNULL 77\nLB 101 " + wired
                           + "\nLB 102 " + btSink + "\n", "");
            wait(400);
            var last = r.mock.execLog[r.mock.execLog.length - 1];
            verify(last.indexOf(": PW_TRIM;") === 0);
            verify(last.indexOf("m=101") !== -1);
            verify(last.indexOf("60%") !== -1);
        }

        function test_watchdog_queues_a_second_speaker() {
            // Two speakers connecting back to back: the single slot used to
            // be overwritten and the first speaker's watch silently died.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._btJoinWatchArm(btMac, "JBL");
            r.e._btJoinWatchArm("11:22:33:44:55:66", "Sony");
            compare(r.e._btJoinWatchMac, btMac);            // first keeps the slot
            compare(r.e._btJoinWatchQueue.length, 1);
            r.e._btJoinWatchStop();                         // first resolved
            compare(r.e._btJoinWatchMac, "11:22:33:44:55:66");
            compare(r.e._btJoinWatchQueue.length, 0);
        }

        function test_watchdog_stop_clears_a_stranded_kick_flag() {
            // A kick whose ack never lands used to leave _btKickInFlight
            // stuck true — every later watch's tick hold froze forever.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._btJoinWatchArm(btMac, "JBL");
            r.e._btKickInFlight = true;
            r.e._btJoinWatchStop();
            verify(!r.e._btKickInFlight);
        }

        // ── balance adoption (cast devices joining the group) ────────────

        function test_adopt_trim_keeps_a_remembered_choice() {
            var r = rig([]);
            r.e.adoptTrim("uuid-1", 0.6);
            fuzzyCompare(r.e.trimOf("uuid-1"), 0.6, 0.001);
            verify(r.e.hasTrim("uuid-1"));
            r.e.adoptTrim("uuid-1", 0.2);       // a stored balance always wins
            fuzzyCompare(r.e.trimOf("uuid-1"), 0.6, 0.001);
        }

        function test_adopt_trim_ignores_full_level_and_clamps() {
            var r = rig([]);
            r.e.adoptTrim("uuid-2", 1.0);       // full level = no entry
            verify(!r.e.hasTrim("uuid-2"));
            r.e.adoptTrim("uuid-3", 3.7);       // clamped into the valid range
            verify(!r.e.hasTrim("uuid-3"));     // ...which lands on full level
            r.e.adoptTrim("uuid-4", 0.001);
            fuzzyCompare(r.e.trimOf("uuid-4"), 0.05, 0.001);
        }

        // ── the join watchdog ─────────────────────────────────────────────

        function test_watchdog_kicks_once_then_waits_out_its_own_cure() {
            // Two wired devices make the sync; the WATCHED Bluetooth sink
            // never appears — the watchdog's reason to exist.
            var r = rig([dev(wired), dev(wired2)]);
            activate(r);
            r.e._btJoinWatchMac = btMac;
            r.e._btJoinWatchName = "JBL";
            for (var i = 0; i < 4; i++) r.e._btJoinWatchTick();
            compare(r.e._btJoinWatchTicks, 4);
            verify(r.e._btKickInFlight);
            var kick = r.mock.execLog[r.mock.execLog.length - 1];
            verify(kick.indexOf(": BT_KICK " + btMac + ";") === 0);   // MAC in sentinel
            // The kick is a PROFILE bounce now — measured on a real JBL
            // Flip 7, a software bluetoothctl disconnect can destroy the
            // pairing outright, so the link must never be touched.
            verify(kick.indexOf("set-card-profile") !== -1);
            verify(kick.indexOf("bluetoothctl disconnect") === -1);
            // Held while the kick is in flight — the countdown must not
            // starve the cure it started itself.
            r.e._btJoinWatchTick();
            compare(r.e._btJoinWatchTicks, 4);
            // A STALE kick's ack (some other MAC) must not touch this state.
            r.e.handleExec(": BT_KICK AA:BB:CC:DD:EE:00; x", "", "");
            compare(r.e._btJoinWatchTicks, 4);
            verify(r.e._btKickInFlight);
            // The matching kick's ack resets the window for the reconnect.
            r.e.handleExec(": BT_KICK " + btMac + "; x", "", "");
            compare(r.e._btJoinWatchTicks, 0);
            verify(!r.e._btKickInFlight);
            compare(r.mock.btListed, 1);
        }

        function test_watchdog_gives_up_with_a_note_after_the_window() {
            var r = rig([dev(wired), dev(wired2)]);
            activate(r);
            r.e._btJoinWatchMac = btMac;
            r.e._btJoinWatchName = "JBL";
            r.e._btJoinKicked = true;          // the kick already happened
            for (var i = 0; i < 15; i++) r.e._btJoinWatchTick();
            compare(r.e._btJoinWatchMac, "");  // watch stopped
            compare(r.mock.notes.length, 1);
            compare(r.mock.notes[0].title, "JBL did not join the sync");
        }

        function test_watchdog_holds_while_a_connect_is_in_flight() {
            var r = rig([dev(wired), dev(wired2)]);
            activate(r);
            r.e._btJoinWatchMac = btMac;
            r.mock._btConnectingMac = btMac;
            r.e._btJoinWatchTick();
            compare(r.e._btJoinWatchTicks, 0); // held, not counted
        }

        // ── idle teardown ─────────────────────────────────────────────────

        function test_idle_teardown_parks_and_sound_wakes_the_graph() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._idleTeardownTick();
            verify(!r.e._combineActive);            // parked...
            compare(r.cfg.combineWanted, true);     // ...but still wanted
            verify(r.e._combineIdleParked);
            // Sound comes back INSIDE the park's async tail — the wake must
            // queue for the unload ack, not race it for the default sink.
            var lenBefore = r.mock.execLog.length;
            r.mock.anythingPlaying = true;
            verify(r.mock.execLog.slice(lenBefore).join("\n").indexOf(": PW_COMBINE") === -1);
            verify(r.e._combineWakeQueued);
            // The tail lands — the queued wake takes the normal enable road.
            r.e.handleExec(": PW_UNCOMBINE_DONE;", "MASTER 80\n", "");
            verify(!r.e._combineIdleParked);
            var fresh = r.mock.execLog.slice(lenBefore).join("\n");
            verify(fresh.indexOf(": PW_COMBINE") !== -1);
        }

        function test_idle_teardown_waits_out_a_measurement() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._calibrating = true;
            r.e._idleTeardownTick();
            verify(r.e._combineActive);             // never parked mid-run
            r.e._calibrating = false;
            r.mock.anythingPlaying = true;
            r.mock.anythingPlaying = false;
            r.e._idleTeardownTick();
            verify(!r.e._combineActive);
        }

        // ── the automatic caretaker ───────────────────────────────────────

        function test_only_the_users_click_sweeps_stale_exclusions() {
            // Every speaker unticked, the wish still on from an earlier
            // evening: the startup probe and the resurrect knocks replay the
            // wish, and replaying it must not undo per-speaker choices that
            // were each an explicit act — the group would come back playing
            // on ALL of them with no gesture at all.
            var r = rig([dev(wired), dev(btSink)], { combineWanted: true });
            r.cfg.syncExcluded = JSON.stringify(_allExcluded(r));
            r.e._loadSyncExcluded();
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable();
            compare(r.mock.execLog.length, 0);
            verify(!r.e._combineWantActive);
            // The user's own click IS the explicit action of right now —
            // the sweep runs and the group builds.
            r.e.combineOutputsEnable(true);
            compare(r.cfg.syncExcluded, "{}");
            verify(r.e._combineWantActive);
            verify(r.mock.execLog.length > 0);
            verify(r.mock.execLog[0].indexOf(": PW_COMBINE") === 0);
        }

        function _allExcluded(r) {
            // Key exclusions exactly as the engine would: through its own
            // trim-key mapping, so the test cannot drift from the code.
            var m = {};
            var all = r.e._combineAllSinks();
            for (var i = 0; i < all.length; i++)
                m[r.e._trimKeyForSink(all[i])] = true;
            return m;
        }

        function test_switching_the_caretaker_off_stops_its_listening() {
            // Off has to mean off from the moment it is switched — the
            // periodic listening stops and the probe in flight is killed,
            // not merely forgotten.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.mock.execLog = [];
            r.cfg.syncAutoCare = false;
            verify(!r.e._verifyPending);
            verify(!r.e.verifySettleRunning());
            var killed = false;
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (String(r.mock.execLog[i]).indexOf("PW_DRIFTKILL") !== -1
                    || String(r.mock.execLog[i]).indexOf("kill") !== -1)
                    killed = true;
            verify(killed);
        }

        function test_a_hand_started_calibration_is_not_cancelled_by_the_switch() {
            // The switch governs the caretaker, not the user: a calibration
            // started by hand keeps going when auto-care is turned off.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.e.calibrateSync();
            verify(r.e._calibrating);
            verify(!r.e._autoCareParked);
            r.cfg.syncAutoCare = false;
            verify(r.e._calibrating);
        }

        function test_a_fresh_install_inherits_the_level_instead_of_blasting() {
            // The stored master starts at "never set". A fresh install must
            // then ramp to what the machine was ALREADY playing at, because
            // the combined sink becomes the system output — assuming full
            // scale hands the room a volume nobody asked for. The old
            // default of 100 made this branch unreachable.
            var r = rig([dev(wired), dev(btSink)]);
            compare(r.cfg.combineMasterPct, 0);
            r.e._combineAvailable = true;
            r.e.combineOutputsEnable(true);
            r.mock.execLog = [];
            r.e.handleExec(": PW_COMBINE " + r.e._combineLoadSeq + ";",
                           "PREVDEF usb_dac\nPREVVOL 35\nNULL 77\nLB 101 " + wired
                           + "\nLB 102 " + btSink + "\n", "");
            var ramp = "";
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_RAMP;") === 0) ramp = r.mock.execLog[i];
            verify(ramp !== "");
            // Ends where the machine was, not at full scale.
            verify(ramp.indexOf("35%") !== -1, ramp);
            verify(ramp.indexOf("100%") === -1, ramp);
        }

        function test_a_speaker_deaf_to_the_sweep_is_not_thrown_out() {
            // Measured on a real JBL: it plays music perfectly and carries
            // nothing at 18 kHz. Two inaudible checks in a row and the widget
            // ticked it out of its own group, with the user never touching
            // the box — the eviction rule was written for the AUDIBLE click,
            // where silence really does mean nothing audible behind it.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_BY sweep\nVERIFY_PARTIAL " + btSink + "\n", "");
            verify(r.e.syncDeviceIncluded(r.e._trimKeyForSink(btSink)));
            verify(r.e._ultraDeaf[btSink] === true);
            // The audible road keeps its teeth: two strikes there still mean
            // an output with nothing behind it.
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_BY clicks\nVERIFY_PARTIAL " + btSink + "\n", "");
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_BY clicks\nVERIFY_PARTIAL " + btSink + "\n", "");
            verify(!r.e.syncDeviceIncluded(r.e._trimKeyForSink(btSink)));
        }

        function test_a_member_that_lost_its_loopback_is_rebuilt() {
            // A Bluetooth sink that dies and comes back wears the SAME name,
            // so the group signature never changes — and the rebuild that
            // would re-attach its loopback never ran. The speaker then plays
            // nothing for the rest of the session while the group looks
            // healthy. Measured on a real JBL: worked alone, silent in the
            // group, one loopback where there should have been two.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            verify(!r.e._combineMemberMissingLoopback());
            // The BT sink's loopback dies with its transport: the module map
            // loses that pair while the device itself is still listed.
            var pairs = {};
            for (var k in r.e._combineLoopbackSinkByModule)
                if (r.e._combineLoopbackSinkByModule[k] !== btSink)
                    pairs[k] = r.e._combineLoopbackSinkByModule[k];
            r.e._combineLoopbackSinkByModule = pairs;
            verify(r.e._combineMemberMissingLoopback());
            // A device event with an unchanged signature must still rebuild.
            r.mock.execLog = [];
            r.e.onOutputsChanged();
            verify(r.e.offsetDebounceRunning());
        }

        function test_the_drift_check_needs_a_bluetooth_ear() {
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            verify(r.e._combineHasBtMember());
            // The speaker left with its sink: a wired-only room resamples
            // against the graph's own clock and drifts against nothing, so
            // the probe must not touch the microphone.
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(wired2)] };
            verify(!r.e._combineHasBtMember());
            r.mock.execLog = [];
            r.e._driftProbe();
            compare(r.mock.execLog.length, 0);
            // The Bluetooth ear is back — the same probe listens again.
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink)] };
            r.e._driftProbe();
            compare(r.mock.execLog.length, 1);
            verify(r.mock.execLog[0].indexOf(": PW_DRIFT;") === 0);
        }

        function test_the_drift_probe_names_the_members_for_the_sweep() {
            // The probe measures each speaker with the inaudible sweep
            // instead of correlating whatever the music carries — which it
            // can only do if it is told who the speakers ARE. Before this
            // it passed the group's name and nothing else, and answered
            // "too quiet to tell" on any material without a beat.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.mock.execLog = [];
            r.e._driftProbe();
            compare(r.mock.execLog.length, 1);
            var cmd = r.mock.execLog[0];
            verify(cmd.indexOf(": PW_DRIFT;") === 0);
            verify(cmd.indexOf(" drift ") > 0);
            verify(cmd.indexOf(wired) > 0);
            verify(cmd.indexOf(btSink) > 0);
            // Nothing switched the sweep off, so nothing opts out of it.
            compare(cmd.indexOf("ONAIR_NO_ULTRA"), -1);
        }

        function test_unticking_the_caretaker_stops_a_probe_already_sweeping() {
            // The probe writes its pid and nobody ever read it back, so
            // there was no road that could stop one already measuring.
            // _autoCareParked is set when the RESULT lands, which means it
            // is false for the whole time the probe is actually playing —
            // the one moment the switch most needs to reach it.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.mock.execLog = [];
            r.e._driftProbe();
            verify(r.mock.execLog[0].indexOf(": PW_DRIFT;") === 0);
            verify(!r.e._autoCareParked);
            r.cfg.syncAutoCare = false;
            var killed = false;
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf(": PW_DRIFTKILL;") === 0) killed = true;
            verify(killed);
        }

        function test_each_member_carries_the_delay_it_is_played_with() {
            // The sweep is aimed at the member sink and so goes round the
            // loopback holding that member back. Without the lag travelling
            // with it, a room in perfect tune measures the entire spread the
            // calibration cancels and the caretaker "confirms" a drift that
            // is not there, every six minutes, forever.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMs: 150 });
            activate(r);
            r.mock.execLog = [];
            r.e._driftProbe();
            var cmd = r.mock.execLog[0];
            // Each sink is followed by the delay its loopback ACTUALLY
            // carries: the slowest device sets the schedule and gets the
            // floor, everyone faster waits out the difference.
            verify(cmd.indexOf("'" + btSink + "' 60") > 0, cmd);
            verify(cmd.indexOf("'" + wired + "' 210") > 0, cmd);
        }

        function test_the_check_credits_what_is_deployed_not_what_the_map_says() {
            // A quiet fold writes the map and leaves the loopbacks alone
            // until a rebuild that costs the listener nothing. Between those
            // two moments the map is a promise and the room is a fact, and
            // the check has to add back the fact.
            //
            // Crediting the map is a feedback loop, and it ran: measured on
            // 2026-08-01 the map walked 207 -> 173 -> 150 while every
            // loopback still carried 207, because each fold's own step came
            // back to the next check looking like fresh drift in the same
            // direction and earned another fold. The room never moved.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMs: 150 });
            activate(r);
            // The map moves — as a fold would move it — with no rebuild.
            var m = {}; m[btMac] = 168;
            r.cfg.syncOffsetMap = JSON.stringify(m);
            r.mock.execLog = [];
            r.e._driftProbe();
            var cmd = r.mock.execLog[0];
            // Still the delays the loopbacks were built with, not the new map.
            verify(cmd.indexOf("'" + btSink + "' 60") > 0, cmd);
            verify(cmd.indexOf("'" + wired + "' 210") > 0, cmd);
            verify(cmd.indexOf("'" + wired + "' 228") < 0, cmd);
        }

        function test_a_speaker_deaf_to_the_band_is_not_played_into_twice() {
            // Opening a stream is not free even when nothing comes back: two
            // outputs on the reporting desk are UCM devices of ONE USB card,
            // and waking the second switches the card's output path with an
            // audible relay click — heard twice, seconds after a periodic
            // check, while the sweep itself measures clean.
            var r = rig([dev(wired), dev(wired2), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.mock.execLog = [];
            r.e._driftProbe();
            verify(r.mock.execLog[0].indexOf(wired2) > 0);

            // The probe reports which one was deaf; it must not be played
            // into again.
            r.e.handleExec(": PW_DRIFT;",
                           "DRIFT_DEAF " + wired2 + "\nDRIFT_PARTIAL 1\nDRIFT_EST 4\n", "");
            r.mock.execLog = [];
            r.e._driftProbe();
            compare(r.mock.execLog.length, 1, "teine probe ei k\u00e4ivitunud");
            compare(r.mock.execLog[0].indexOf(wired2), -1);
            verify(r.mock.execLog[0].indexOf(btSink) > 0);
            verify(r.mock.execLog[0].indexOf(wired) > 0);

            // Rebuilding the group asks the question again — a speaker
            // replugged into a live jack deserves a fresh hearing. Checked
            // on the memory itself: the rebuild also raises its own busy
            // flag, and the probe correctly refuses to run over it.
            // A rebuild with the SAME speakers — which is what dragging
            // the fine-tune slider causes — must not forget: a speaker deaf
            // at 145 ms is just as deaf at 200, and re-testing it would hand
            // back the relay click on every nudge.
            r.e._combineRebuildLoopbacks();
            compare(Object.keys(r.e._ultraDeaf).length, 1);
            // A speaker leaving the group does reopen the question.
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink)] };
            r.e._combineRebuildLoopbacks();
            compare(Object.keys(r.e._ultraDeaf).length, 0);
        }

        function test_a_flickering_device_list_cannot_become_a_second_timer() {
            // The check's running condition reads the device list, which is
            // rebuilt on every refresh. Restarting the early check on each
            // one turned "a probe every six minutes" into probes 33 to 104 s
            // apart, measured live — and every probe opens a stream on each
            // member, which broke up the audio.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.mock.execLog = [];
            r.e._driftProbe();
            compare(r.mock.execLog.length, 1);
            var stamped = r.e._lastDriftProbeMs;
            verify(stamped > 0);

            // The list churns: same speakers, new array. The early check
            // must NOT re-arm.
            for (var i = 0; i < 5; i++)
                r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink)] };
            compare(r.e._lastDriftProbeMs, stamped);

            // A deliberate tick still answers at once — someone is waiting.
            r.e.noteAutoCareEnabled();
            compare(r.e._lastDriftProbeMs, 0);
            verify(r.e._autoCareJustArmed);
        }

        function test_by_ear_mode_never_reaches_the_microphone() {
            // Hiding the button is a UI fact; this is the contract. Someone
            // who says "do not listen to my room" must have that hold even
            // if a caretaker was already armed when they said it.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncManualOnly: true });
            activate(r);
            r.mock.execLog = [];
            r.e.calibrateSync(55);
            compare(r.mock.execLog.length, 0);
            r.e._driftProbe();
            compare(r.mock.execLog.length, 0);
            // And the periodic timer does not even arm.
            verify(!r.e._driftTimerRunningForTest());
        }

        function test_a_correction_lands_on_the_number_people_read() {
            // The slider shows syncOffsetMs; corrections land in the map.
            // With ONE Bluetooth speaker there is no doubt which number the
            // slider stands for, so it must follow — otherwise a speaker
            // quietly retuned for a week still reads as the value typed once.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMs: 145 });
            activate(r);
            r.cfg.syncOffsetMap = JSON.stringify({ "AA:BB:CC:DD:EE:FF": 168 });
            r.e._mirrorTunedToSlider();
            compare(r.cfg.syncOffsetMs, 168);
            // Past the slider's own scale it stays put: a pinned slider
            // reads as a wrong number rather than a big one.
            r.cfg.syncOffsetMap = JSON.stringify({ "AA:BB:CC:DD:EE:FF": 1400 });
            r.e._mirrorTunedToSlider();
            compare(r.cfg.syncOffsetMs, 168);
        }

        function test_the_automatic_check_moves_the_number_people_read() {
            // End to end, the way a room does it: the check comes back with a
            // spread, the fold writes the map, and the slider — the only
            // number anyone actually reads — follows. The mirror was covered
            // on its own; the road from a verdict to that number was not, so
            // "does the automatic result move the number on screen" had no
            // answer in the suite at all.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMs: 234 });
            activate(r);
            r.e._verifyPending = true;
            var care = "VERIFY_LAG " + wired + " 0\n"
                     + "VERIFY_LAG " + btSink + " 60\n"
                     + "VERIFY_OK 60\n";
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", care, "");
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", care, "");
            // The map carries the twice-confirmed correction...
            var m = JSON.parse(r.cfg.syncOffsetMap);
            compare(m[btMac], 294);
            // ...and so does the number on the slider.
            compare(r.cfg.syncOffsetMs, 294);
        }

        function test_an_implausible_pair_does_not_blame_the_microphone() {
            // Measured on the home desk: the run refused a -174 ms pair and
            // the SAME stdout carried six clean captures from both speakers,
            // yet the widget answered "make sure the microphone is not
            // covered". The refusal is right; the advice was not.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.calibrateSync(85);          // already the louder pass — no retry road
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P85 ;",
                           "CALIB_SRC deadbeef1234\n"
                           + "CALIB_RAW sweep " + wired + " 1149.8 1135.0 1134.7\n"
                           + "CALIB_RAW sweep " + btSink + " 961.6 959.3 979.6\n"
                           + "CALIB_FAIL implausible result -174 ms\n", "");
            var inote = r.mock.notes[r.mock.notes.length - 1];
            compare(inote.title, "Calibration did not succeed");
            verify(inote.text.indexOf("microphone") === -1);
            verify(inote.text.indexOf("settle") !== -1);
            verify(!r.e._calibrating);
        }

        function test_an_unsteady_reading_is_not_a_deaf_speaker() {
            // The settle window refuses captures that scatter — but that
            // refusal must not land on the band-deaf shelf, which strikes
            // the member off the drift watch for the life of the group.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_BY sweep\nVERIFY_UNSTEADY " + btSink + "\n", "");
            compare(r.e._ultraDeaf[btSink], undefined);  // not shelved
            compare(r.cfg.syncVerifiedMs, -1);           // no verdict claimed
            verify(!r.e._verifyPending);
            compare(r.mock.playerOutput.volume, 0.5);    // music handed back
            var unote = r.mock.notes[r.mock.notes.length - 1];
            verify(unote.text.indexOf("would not settle") !== -1);
        }

        function test_three_checks_that_agree_correct_the_map_without_a_sound() {
            // The road that measures in the state the listener listens in —
            // music flowing, the link warm, nobody muted — may fix the room
            // itself. Sign pinned against the room: with the fine-tune at
            // 152 the Bluetooth speaker was heard 13 ms EARLY, and an
            // independent sweep put the ideal at 165, so the stored lag has
            // to come DOWN by 13. Getting this backwards would drive a tuned
            // room apart every few minutes, which is why it has its own test.
            var m0 = {}; m0[btMac] = 178;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var out = "DRIFT_EAR " + wired + " 1460\n"
                    + "DRIFT_EAR " + btSink + " 1447\n"
                    + "DRIFT_EST 13\n";
            r.e.handleExec(": PW_DRIFT;", out, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 178);
            r.e.handleExec(": PW_DRIFT;", out, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 178);   // two is not a median
            var quietFrom = r.mock.execLog.length;      // ignore the setup's own build
            r.e.handleExec(": PW_DRIFT;", out, "");     // three: the median stands
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 165);   // 178 - 13
            // The correction is stored, but the loopbacks are NOT swapped
            // under live music: the listener described a startling clatter
            // the first time one landed, so the new delay waits for a
            // rebuild that was going to happen anyway.
            verify(r.e.driftLastText.indexOf("next time the music pauses") !== -1);
            var swapped = false;
            for (var j = quietFrom; j < r.mock.execLog.length; j++)
                if (r.mock.execLog[j].indexOf("unload-module") !== -1) swapped = true;
            verify(!swapped);
            // And nothing was muted or parked on the way — the whole point.
            var muted = false;
            for (var i = 0; i < r.mock.execLog.length; i++)
                if (r.mock.execLog[i].indexOf("set-sink-mute") !== -1) muted = true;
            verify(!muted);
        }

        function test_the_check_says_which_number_it_measured() {
            // The reading used to be published as a distance only, so the
            // right value sat in the journal behind a subtraction the
            // listener had no reason to know how to do: "31 ms apart" and
            // a slider at 172 does not say whether to type 141 or 203.
            var m0 = {}; m0[btMac] = 172;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            r.e.handleExec(": PW_DRIFT;",
                           "DRIFT_EAR " + wired + " 1483\n"
                           + "DRIFT_EAR " + btSink + " 1452\n"
                           + "DRIFT_EST 31\n", "");
            verify(r.e.driftLastText.indexOf("141") !== -1);   // 172 - 31
        }

        function test_the_history_survives_the_switch_but_not_an_hour() {
            // Toggling auto-care used to discard the half-finished pair,
            // which punished the one gesture a listener makes when they want
            // the widget to hurry up. Age is what makes a reading stale.
            var m0 = {}; m0[btMac] = 172;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var p1 = "DRIFT_EAR " + wired + " 1483\nDRIFT_EAR " + btSink + " 1452\nDRIFT_EST 31\n";
            var p2 = "DRIFT_EAR " + wired + " 1476\nDRIFT_EAR " + btSink + " 1456\nDRIFT_EST 20\n";
            r.e.handleExec(": PW_DRIFT;", p1, "");
            r.cfg.syncAutoCare = false;                 // the listener fidgets
            r.cfg.syncAutoCare = true;
            r.e.handleExec(": PW_DRIFT;", p2, "");
            r.e.handleExec(": PW_DRIFT;", p2, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 152);   // 172 - 20
            // An hour-old reading is a different room; it may not take part.
            var r2 = rig([dev(wired), dev(btSink)],
                         { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r2);
            r2.e.handleExec(": PW_DRIFT;", p1, "");
            r2.e.handleExec(": PW_DRIFT;", p1, "");
            r2.e._driftHistoryAt = [Date.now() - 60 * 60 * 1000,
                                    Date.now() - 60 * 60 * 1000];
            r2.e.handleExec(": PW_DRIFT;", p2, "");
            compare(r2.e._driftHistory.length, 1);
            compare(JSON.parse(r2.cfg.syncOffsetMap)[btMac], 172);  // untouched
        }

        function test_a_reading_of_zero_is_never_half_a_correction() {
            // Caught live: a probe read the room exactly in step and the
            // next read +12; their average moved the map by six. "Nothing
            // to do" averaged with "a little" is noise in a correction's
            // clothes, and a tuned room that keeps being nudged wanders.
            var m0 = {}; m0[btMac] = 144;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            r.e.handleExec(": PW_DRIFT;",
                           "DRIFT_EAR " + wired + " 1455\nDRIFT_EAR " + btSink + " 1455\nDRIFT_EST 0\n", "");
            r.e.handleExec(": PW_DRIFT;",
                           "DRIFT_EAR " + wired + " 1449\nDRIFT_EAR " + btSink + " 1461\nDRIFT_EST 12\n", "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 144);   // untouched
        }

        function test_the_probe_after_a_deploying_rebuild_is_spent_not_stored() {
            // The reload that LANDS a correction re-rolls the Bluetooth
            // buffering the next probe measures, so that reading describes
            // the correction rather than the room. Live: -17 right after a
            // reload, 0 next. The fold itself moves nothing physical and
            // spends nothing — the spent-at-fold flag used to throw away a
            // valid reading of a room the fold had not touched yet.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var p1 = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1446\nDRIFT_EST 12\n";
            var p2 = "DRIFT_EAR " + wired + " 1435\nDRIFT_EAR " + btSink + " 1461\nDRIFT_EST 26\n";
            r.e.handleExec(": PW_DRIFT;", p1, "");
            r.e.handleExec(": PW_DRIFT;", p1, "");
            r.e.handleExec(": PW_DRIFT;", p1, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 137);    // 125 + 12
            // A promise was written; the room has not moved. Nothing spent.
            verify(!r.e._driftSkipNext);
            compare(r.e._driftHistory.length, 0);
            // The rebuild that deploys 137 is the moment the room changes.
            r.e._combineRebuildLoopbacks();
            verify(r.e._driftSkipNext);
            compare(r.e._driftHistory.length, 0);
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 301 " + wired + "\nLB 302 " + btSink + "\n", "");
            // The very next probe is spent, however loud it reads.
            r.e.handleExec(": PW_DRIFT;", p2, "");
            verify(!r.e._driftSkipNext);
            compare(r.e._driftHistory.length, 0);
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 137);
        }

        function test_an_undeployed_fold_is_not_compounded_by_the_next() {
            // The step is measured against what the loopbacks CARRY, so
            // folding it onto the map walked the map away while nothing
            // deployed: watched live 2026-08-02, 124 -> 170 -> 213 across
            // two folds of the same ~46 ms room, radio playing the whole
            // time so no rebuild ever landed them — and the eventual one
            // would have dropped the whole surplus on the room at once.
            // On the deployed base the fold is idempotent.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var p1 = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1446\nDRIFT_EST 12\n";
            for (var i = 0; i < 3; i++) r.e.handleExec(": PW_DRIFT;", p1, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 137);
            // No rebuild lands it; the room keeps reading the same 12 ms.
            for (var j = 0; j < 3; j++) r.e.handleExec(": PW_DRIFT;", p1, "");
            // 125 + 12 however many times it is computed — never 137 + 12.
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 137);
        }

        function test_a_rebuild_that_changes_nothing_spends_nothing() {
            // Same lags out, same room after: a reload with an unchanged
            // schedule is not a correction landing, and the half-finished
            // history is still about the room it describes.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var p1 = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1446\nDRIFT_EST 12\n";
            r.e.handleExec(": PW_DRIFT;", p1, "");
            compare(r.e._driftHistory.length, 1);
            r.e._combineRebuildLoopbacks();
            verify(!r.e._driftSkipNext);
            compare(r.e._driftHistory.length, 1);
        }

        function test_a_fold_under_a_transport_shift_writes_the_map_frame() {
            // A reconnect that moves the link arms a session shift, and the
            // deployed lag then carries map + shift. The map must stay clean
            // of the shift — every read adds it back — so a fold that writes
            // the deployed value raw doubles it at the next rebuild: map
            // 125, shift 150, a 12 ms residual has to land the map at 137,
            // never 287.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var sh = {}; sh[btMac] = 150;
            r.e._refLatShiftByMac = sh;
            // The recompensation rebuild deploys map + shift.
            r.e._combineRebuildLoopbacks();
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 301 " + wired + "\nLB 302 " + btSink + "\n", "");
            var p1 = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1446\nDRIFT_EST 12\n";
            r.e.handleExec(": PW_DRIFT;", p1, "");    // spent: the rebuild armed the skip
            for (var i = 0; i < 3; i++) r.e.handleExec(": PW_DRIFT;", p1, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 137);   // 275 - 150 + 12
        }

        function test_the_advertised_number_stays_in_the_map_frame_too() {
            // The advice is typed into the MAP, and the map re-adds the
            // session shift on every read. With the room deployed at
            // map 125 + shift 150, a 43 ms residual is 318 at the ear —
            // and 318 typed in would come back as 468.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var sh = {}; sh[btMac] = 150;
            r.e._refLatShiftByMac = sh;
            r.e._combineRebuildLoopbacks();
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 301 " + wired + "\nLB 302 " + btSink + "\n", "");
            var p = "DRIFT_EAR " + wired + " 1400\nDRIFT_EAR " + btSink + " 1443\nDRIFT_EST 43\n";
            r.e.handleExec(": PW_DRIFT;", p, "");     // spent by the rebuild's skip
            r.e.handleExec(": PW_DRIFT;", p, "");
            verify(r.e.driftLastText.indexOf("168") >= 0, r.e.driftLastText);
            verify(r.e.driftLastText.indexOf("318") === -1, r.e.driftLastText);
        }

        function test_folds_stay_idempotent_when_the_map_floor_is_not_zero() {
            // The anchor slides the whole map frame, and between a fold and
            // its rebuild the deployed lags keep the old one. Anchoring at
            // fold time let a second fold write an old-frame number next to
            // re-anchored entries: with the wired member at 25 the map
            // walked 21 -> 46 while the room never moved. The fold now
            // leaves the frame alone; a floor above zero deploys the same
            // sound, because only differences reach a speaker.
            var m0 = {}; m0[wired] = 25; m0[btMac] = 0;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var p1 = "DRIFT_EAR " + wired + " 1400\nDRIFT_EAR " + btSink + " 1446\nDRIFT_EST 46\n";
            for (var i = 0; i < 3; i++) r.e.handleExec(": PW_DRIFT;", p1, "");
            var m1 = JSON.parse(r.cfg.syncOffsetMap);
            compare(m1[btMac], 46);                    // deployed 0 + 46
            compare(m1[wired], 25);                    // frame untouched at fold
            // Nothing deployed it; the same readings fold to the same map.
            for (var j = 0; j < 3; j++) r.e.handleExec(": PW_DRIFT;", p1, "");
            var m2 = JSON.parse(r.cfg.syncOffsetMap);
            compare(m2[btMac], 46);
            compare(m2[wired], 25);
            // The slider mirrors the anchored-frame DIFFERENCE, the same
            // number setSyncOffset would write back — mirroring the lifted
            // absolute (46) made a one-tick nudge leap by the whole floor.
            compare(r.cfg.syncOffsetMs, 21);
            // The rebuild deploys it as-is — and the sound is the anchored
            // sound: the Bluetooth member held back 21 ms past the wired.
            r.e._combineRebuildLoopbacks();
            var m3 = JSON.parse(r.cfg.syncOffsetMap);
            compare(m3[wired], 25);
            compare(m3[btMac], 46);
            var s = r.e._combineRealSinks();
            compare(r.e._appliedDelayMs(wired, s) - r.e._appliedDelayMs(btSink, s), 21);
        }

        function test_the_fold_subtracts_the_shift_as_built_not_as_recorded() {
            // A re-roll can be recorded while a reloop is mid-flight: the
            // ledger says 400, the loopbacks still carry 0. Subtracting the
            // ledger's number would push the whole undeployed move into the
            // map; the fold subtracts what the room was BUILT with.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var sh = {}; sh[btMac] = 400;
            r.e._refLatShiftByMac = sh;                // recorded, NOT deployed
            var p1 = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1446\nDRIFT_EST 12\n";
            for (var i = 0; i < 3; i++) r.e.handleExec(": PW_DRIFT;", p1, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 137);   // 125 + 12
        }

        function test_a_members_built_shift_survives_a_rebuild_without_it() {
            // _builtLags keeps an absent member's entry, so the shift that
            // entry was baked with has to stay next to it. Wiping one side
            // of the pair hands the fold a deployed number whose shift it
            // cannot see — and the whole shift walks into the map on the
            // first fold after a leave-and-rejoin.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var sh = {}; sh[btMac] = 150;
            r.e._refLatShiftByMac = sh;
            r.e._combineRebuildLoopbacks();
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 301 " + wired + "\nLB 302 " + btSink + "\n", "");
            compare(r.e._builtShiftByMac[btMac], 150);
            // The speaker drops off the list for one rebuild.
            r.mock.mediaDevs = { audioOutputs: [dev(wired)] };
            r.e._combineRebuildLoopbacks();
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 303 " + wired + "\n", "");
            compare(r.e._builtShiftByMac[btMac], 150);
            // Back in range. The fold reads the retained deployed lag and
            // must subtract the shift it was built with, not zero.
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink)] };
            var p1 = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1446\nDRIFT_EST 12\n";
            r.e.handleExec(": PW_DRIFT;", p1, "");   // spent: the shift rebuild armed the skip
            for (var i = 0; i < 3; i++) r.e.handleExec(": PW_DRIFT;", p1, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 137);   // 275 - 150 + 12
        }

        function test_a_recompensation_waits_out_a_busy_reloop_instead_of_dying() {
            // The shift used to be recorded and the rebuild silently
            // skipped when a reloop was in flight — nothing ever
            // rescheduled it, and the room played the whole move out loud
            // until an unrelated rebuild happened by.
            var m0 = {}; m0[btMac] = 125;
            var ref = {}; ref[btMac] = 250;
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify(m0),
                          syncRefLatMap: JSON.stringify(ref) });
            activate(r);
            r.e._combineReloopBusy = true;
            r.e.handleExec(": PW_REFLAT S " + btMac + ";", "REFLAT 400000", "");
            compare(r.e._refLatShiftByMac[btMac], 150);
            // The debounce fires into the busy rebuild, which parks it.
            wait(400);
            compare(r.e._combineReloopPending, true);
        }

        function test_a_new_verify_run_forgets_the_last_runs_sat_out_set() {
            // The sat-out set belongs to its own ack. Carried into a fresh
            // launch, a guard timeout would skip the blanket unmute for a
            // member THIS run muted itself — the half-silenced machine the
            // blanket exists to prevent.
            var r = rig([dev(wired), dev(btSink)], {});
            activate(r);
            var so = {}; so[btSink] = true;
            r.e._verifySatOut = so;
            r.e._verifyPending = true;
            r.e._verifyLaunch();
            compare(JSON.stringify(r.e._verifySatOut), "{}");
        }

        function test_the_vote_compares_only_members_both_passes_measured() {
            // A member one pass sat out has ONE reading; the missing pass
            // did not measure zero. Fabricating the zero vetoed corrections
            // the twice-measured members had agreed on.
            var bt2 = "bluez_output.11_22_33_44_55_66.1";
            var mac2 = "11:22:33:44:55:66";
            var m0 = {}; m0[btMac] = 100; m0[mac2] = 100;
            var r = rig([dev(wired), dev(btSink), dev(bt2)],
                        { syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            r.e._verifyPending = true;
            r.e._verifyCorrected = false;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 0\nVERIFY_LAG " + bt2 + " 40\n"
                           + "VERIFY_OK 40\n", "");
            verify(r.e._verifyProposal !== null);
            // Pass 2 sees a third member pass 1 never measured.
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 0\nVERIFY_LAG " + bt2 + " 38\n"
                           + "VERIFY_LAG " + btSink + " 250\nVERIFY_OK 250\n", "");
            var map = JSON.parse(r.cfg.syncOffsetMap);
            compare(map[mac2], 139);      // 100 + mean(40, 38)
            compare(map[btMac], 100);     // one reading moves nothing
            for (var i = 0; i < r.mock.notes.length; i++)
                verify(r.mock.notes[i].text.indexOf("disagreed") === -1,
                       r.mock.notes[i].text);
        }

        function test_a_rebuild_over_a_shrunken_group_leaves_the_map_alone() {
            // A rebuild sees only who is connected RIGHT NOW. Anchoring that
            // subset would rewrite the survivors against a floor the absent
            // member never agreed to — a speaker walking out of Bluetooth
            // range for one rebuild came back to a calibration zeroed under
            // it. The rebuild deploys the map; it never edits it.
            var m0 = {}; m0[btMac] = 210;
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            r.mock.mediaDevs = { audioOutputs: [dev(btSink)] };
            r.e._combineRebuildLoopbacks();
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 210);
        }

        function test_an_answer_from_before_the_rebuild_cannot_spend_the_skip() {
            // A probe is out when a correction lands. Its answer describes
            // the room the rebuild just replaced — spending the skip on it
            // hands the NEXT reading, the one that measures the re-roll,
            // into a fresh history as a wrong-signed flyer with a veto.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            r.e._driftProbe();                         // out, guard running
            var m1 = {}; m1[btMac] = 150;
            r.cfg.syncOffsetMap = JSON.stringify(m1);
            r.e._combineRebuildLoopbacks();
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 301 " + wired + "\nLB 302 " + btSink + "\n", "");
            verify(r.e._driftSkipNext);
            var p = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1451\nDRIFT_EST 17\n";
            // The old probe's answer: dropped whole, the skip stays armed.
            r.e.handleExec(": PW_DRIFT;", p, "");
            verify(r.e._driftSkipNext);
            compare(r.e._driftHistory.length, 0);
            // The first post-rebuild reading is the re-roll; the skip eats it.
            r.e.handleExec(": PW_DRIFT;", p, "");
            verify(!r.e._driftSkipNext);
            compare(r.e._driftHistory.length, 0);
            // And the room's own readings count from here.
            r.e.handleExec(": PW_DRIFT;", p, "");
            compare(r.e._driftHistory.length, 1);
        }

        function test_a_stale_mark_dies_with_its_probe_not_with_the_next() {
            // The marked probe's answer may simply never come back (guard
            // timeout). The mark must not sit there and eat the NEXT
            // probe's answer — that would lose two readings per rebuild.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            r.e._driftProbe();                         // this one gets lost
            var m1 = {}; m1[btMac] = 150;
            r.cfg.syncOffsetMap = JSON.stringify(m1);
            r.e._combineRebuildLoopbacks();
            r.e.handleExec(": PW_RELOOP " + r.e._combineLoadSeq + "; x",
                           "LB 301 " + wired + "\nLB 302 " + btSink + "\n", "");
            verify(r.e._driftProbeStale);
            // No answer ever arrives; the next probe launches fresh.
            r.e._driftProbe();
            verify(!r.e._driftProbeStale);
            var p = "DRIFT_EAR " + wired + " 1434\nDRIFT_EAR " + btSink + " 1451\nDRIFT_EST 17\n";
            // Its answer is the first post-rebuild reading: the SKIP takes
            // it — it is not dropped as stale on the dead probe's account.
            r.e.handleExec(": PW_DRIFT;", p, "");
            verify(!r.e._driftSkipNext);
            r.e.handleExec(": PW_DRIFT;", p, "");
            compare(r.e._driftHistory.length, 1);
        }

        // ── verify: members the listener muted ────────────────────────────

        function test_a_sat_out_member_is_named_once_and_left_muted() {
            var r = rig([dev(wired), dev(btSink)], {});
            activate(r);
            var unmutesBefore = r.mock.execLog.filter(function(c) {
                return c.indexOf("PW_UNMUTE") !== -1; }).length;
            var vOut = "VERIFY_MUTED " + btSink + "\n"
                     + "VERIFY_LAG " + wired + " 0\nVERIFY_OK 10\n";
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", vOut, "");
            var mutedNotes = r.mock.notes.filter(function(n) {
                return n.text.indexOf("muted") !== -1; });
            compare(mutedNotes.length, 1);
            // The second pass says the same thing; the listener hears it once.
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", vOut, "");
            mutedNotes = r.mock.notes.filter(function(n) {
                return n.text.indexOf("muted") !== -1; });
            compare(mutedNotes.length, 1);
            // The cleanup's blanket unmute steps around the listener's mute.
            var unmutes = r.mock.execLog.filter(function(c) {
                return c.indexOf("PW_UNMUTE") !== -1; }).slice(unmutesBefore);
            verify(unmutes.length > 0);
            for (var i = 0; i < unmutes.length; i++) {
                verify(unmutes[i].indexOf(wired) !== -1, unmutes[i]);
                verify(unmutes[i].indexOf(btSink) === -1, unmutes[i]);
            }
        }

        function test_a_room_muted_whole_fails_with_one_honest_word() {
            var r = rig([dev(wired), dev(btSink)], {});
            activate(r);
            var notesBefore = r.mock.notes.length;
            var vOut = "VERIFY_MUTED " + wired + "\nVERIFY_MUTED " + btSink + "\n"
                     + "VERIFY_FAIL members muted\n";
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", vOut, "");
            // One toast, the verdict's own — not one per member, and not the
            // inaudible-tone misdiagnosis further down the handler.
            compare(r.mock.notes.length, notesBefore + 1);
            var note = r.mock.notes[r.mock.notes.length - 1];
            verify(note.text.indexOf("too many are muted") !== -1, note.text);
            // And neither leg is forced back on mid-phone-call.
            var unmutes = r.mock.execLog.filter(function(c) {
                return c.indexOf("PW_UNMUTE") !== -1; });
            for (var i = 0; i < unmutes.length; i++) {
                verify(unmutes[i].indexOf(wired) === -1, unmutes[i]);
                verify(unmutes[i].indexOf(btSink) === -1, unmutes[i]);
            }
        }

        function test_the_advertised_number_stands_on_the_deployed_lag() {
            // Seen live 2026-08-02: with a fold pending, the popup said
            // "measured 265" for a room whose right answer was 167 — a
            // listener typing that into the fine-tune would have done the
            // walking by hand.
            var m0 = {}; m0[btMac] = 125;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            // A fold is pending: the map moved, the loopbacks did not.
            var m1 = {}; m1[btMac] = 170;
            r.cfg.syncOffsetMap = JSON.stringify(m1);
            var p = "DRIFT_EAR " + wired + " 1400\nDRIFT_EAR " + btSink + " 1443\nDRIFT_EST 43\n";
            r.e.handleExec(": PW_DRIFT;", p, "");
            verify(r.e.driftLastText.indexOf("168") >= 0, r.e.driftLastText);  // 125 + 43
        }

        function test_a_single_flyer_cannot_cry_drift() {
            // Scatter is sd 21 ms: one reading over the line is a coin
            // toss, and the toast holds itself to the history's middle,
            // the same bar the fold does.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 3\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 4\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 30\n", "");
            compare(r.mock.notes.length, 0);    // median 4 — a tuned room
        }

        function test_the_age_window_follows_the_battery_cadence() {
            // Probes twelve minutes apart can never hold three readings
            // inside a fixed twenty-minute window — on battery the fold
            // and the notification were both structurally starved. The
            // window follows the cadence it has to feed.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            compare(r.e._driftPendingMaxAgeMs, 20 * 60 * 1000);
            r.mock.thrifty = true;
            compare(r.e._driftPendingMaxAgeMs, 30 * 60 * 1000);
        }

        function test_a_quiet_fold_needs_the_checks_to_agree_on_the_direction() {
            // Readings can report the same SPREAD for opposite reasons.
            // Agreeing on how far apart is not agreeing on which way, and a
            // room that cannot say which way is not out — it is unsettled.
            // All but one reading must point the same way.
            var m0 = {}; m0[btMac] = 178;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            var late = "DRIFT_EAR " + wired + " 1420\nDRIFT_EAR " + btSink + " 1460\nDRIFT_EST 40\n";
            var early = "DRIFT_EAR " + wired + " 1460\nDRIFT_EAR " + btSink + " 1420\nDRIFT_EST 40\n";
            r.e.handleExec(": PW_DRIFT;", late, "");
            r.e.handleExec(": PW_DRIFT;", early, "");
            r.e.handleExec(": PW_DRIFT;", late, "");
            r.e.handleExec(": PW_DRIFT;", early, "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 178);   // untouched
        }

        function test_a_wired_residual_is_never_folded() {
            // Measured live, twice in one evening: the verify read the
            // wired member 508 then 493 ms late minutes after the direct
            // calibration had timed the same room tight — a systematic
            // artifact that the two-pass vote happily confirms. Wired
            // chains do not re-roll; their residuals are evidence against
            // the reading, not numbers to persist.
            var mw = {}; mw[btMac] = 209;
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify(mw) });
            activate(r);
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;
            r.e._verifyPending = true;
            var wOut = "VERIFY_LAG " + wired + " 508\nVERIFY_LAG " + btSink + " 0\nVERIFY_OK 508\n";
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";", wOut, "");
            verify(r.e._verifyPending);                 // pass 1 proposed
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 493\nVERIFY_LAG " + btSink + " 0\nVERIFY_OK 493\n", "");
            var mwAfter = JSON.parse(r.cfg.syncOffsetMap);
            compare(mwAfter[btMac], 209);               // calibration stands
            compare(mwAfter[wired], undefined);         // no wired entry born
            verify(r.e._verifyCorrected);
            verify(!r.e._verifyPending);                // honest stop, no pass 3
            compare(r.mock.playerOutput.volume, 0.5);   // music handed back
            var wnote = r.mock.notes[r.mock.notes.length - 1];
            verify(wnote.text.indexOf("wired") !== -1);
        }

        function test_verify_passes_that_disagree_change_nothing() {
            // The 2026-07-29 inversion: one pass read a member 419 ms late
            // (two jittered captures agreeing on garbage) where the room
            // was ~30 ms out. Under the vote a reading like that has to
            // repeat itself, and one that cannot leaves the map alone.
            var m0 = {}; m0[btMac] = 150;
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            r.e._calibVolumeBefore = 0.5;
            r.mock.playerOutput.volume = 0;
            r.e._verifyPending = true;
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 419\nVERIFY_LAG " + btSink + " 0\nVERIFY_OK 419\n", "");
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 150);
            verify(r.e._verifyPending);
            r.e.handleExec(": PW_VERIFY " + r.e._calibRunSeq + ";",
                           "VERIFY_LAG " + wired + " 0\nVERIFY_LAG " + btSink + " 31\nVERIFY_OK 31\n", "");
            var mAfter = JSON.parse(r.cfg.syncOffsetMap);
            compare(mAfter[btMac], 150);                // nothing folded
            compare(mAfter[wired], undefined);          // no fabricated entry
            verify(r.e._verifyCorrected);               // and no third try
            verify(!r.e._verifyPending);
            compare(r.mock.playerOutput.volume, 0.5);   // music handed back
            var dnote = r.mock.notes[r.mock.notes.length - 1];
            compare(dnote.icon, "dialog-warning");
            verify(dnote.text.indexOf("disagreed") !== -1);
        }

        function test_a_speaker_that_drops_out_is_walked_back_in() {
            // The morning this was written, a JBL's A2DP transport died
            // mid-check and the group played on without it until a human
            // reconnected by hand. The join watchdog knew the cure — it was
            // only ever armed when a speaker CONNECTS, so a speaker that
            // LEAVES had nobody watching.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.onOutputsChanged();               // the group is seen intact
            compare(r.e._btJoinWatchMac, "");
            r.mock.mediaDevs = { audioOutputs: [dev(wired)] };   // transport dies
            r.e.onOutputsChanged();
            compare(r.e._btJoinWatchMac, btMac);
        }

        function test_a_speaker_the_listener_sat_out_is_left_alone() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e.onOutputsChanged();
            r.e.setSyncDeviceIncluded(btMac, false);
            r.mock.mediaDevs = { audioOutputs: [dev(wired)] };
            r.e.onOutputsChanged();
            compare(r.e._btJoinWatchMac, "");
        }

        function test_no_measurement_road_runs_over_a_recording() {
            // All three roads play into the room and park or mute speakers.
            // Only the periodic check refused during a recording; the two
            // that a person notices most did not, which was the wrong way
            // round. The hand-started one SAYS why — a button that silently
            // does nothing is its own bug.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.mock.recording = true;

            r.mock.execLog = [];
            r.mock.notes = [];
            r.e.calibrateSync(55);
            compare(r.mock.execLog.length, 0);
            verify(!r.e._calibrating);
            compare(r.mock.notes.length, 1);

            // The automatic one is held, not cancelled: the drift that armed
            // it is still real and the next check re-arms.
            r.e._verifyPending = true;
            r.mock.execLog = [];
            r.e._verifyLaunch();
            compare(r.mock.execLog.length, 0);
            verify(!r.e._verifyPending);

            // The periodic check keeps the refusal it always had.
            r.mock.execLog = [];
            r.e._driftProbe();
            compare(r.mock.execLog.length, 0);

            // Recording over: the hand-started road works again.
            r.mock.recording = false;
            r.mock.execLog = [];
            r.e.calibrateSync(55);
            verify(r.mock.execLog.length > 0);
        }

        function test_the_probe_and_the_loopbacks_use_one_delay_formula() {
            // Two places compute this and they must never drift apart — the
            // probe's number is only meaningful if it is the delay the
            // loopback really applies.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMs: 145 });
            activate(r);
            var members = r.e._combineRealSinks();
            var applied = [];
            for (var i = 0; i < members.length; i++)
                applied.push(r.e._appliedDelayMs(members[i], members));
            // The slowest member rides the floor and nobody is below it.
            compare(Math.min.apply(null, applied), r.e._loopbackFloorMs);
            // Whatever the lags, the ONE built into every real loopback
            // command is the same number.
            r.mock.execLog = [];
            r.e._combineRebuildLoopbacks();
            var built = r.mock.execLog.join(" ");
            for (var k = 0; k < members.length; k++) {
                if (built.indexOf(members[k]) === -1) continue;
                verify(built.indexOf("latency_msec=" + applied[k]) > 0,
                       "loopback for " + members[k] + " does not carry "
                       + applied[k] + ": " + built);
            }
        }

        function test_the_ultrasonic_switch_reaches_the_probe_without_orphaning_it() {
            // Whoever turns the sweep off because of a pet must have it off
            // on every road. The opt-out rides the environment, and it must
            // sit BEHIND the sentinel: this dispatcher matches on the
            // command's opening ": PW_x;", so anything in front of it
            // silently orphans the handler and the ack never lands.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncUltrasonic: false });
            activate(r);
            r.mock.execLog = [];
            r.e._driftProbe();
            compare(r.mock.execLog.length, 1);
            var cmd = r.mock.execLog[0];
            compare(cmd.indexOf(": PW_DRIFT;"), 0);
            verify(cmd.indexOf("ONAIR_NO_ULTRA=1") > 0);
            // And the handler still recognises its own command.
            verify(r.e.handleExec(": PW_DRIFT;", "DRIFT_QUIET\n", ""));
        }

        function test_the_number_on_screen_is_the_one_actually_in_force() {
            // The fine-tune slider shows the seed the user set; every
            // automatic correction lands in the per-device map instead. A
            // speaker the caretaker had been retuning for a week still read
            // as the original number and nothing on screen said otherwise.
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMs: 145 });
            activate(r);
            // Map agrees with the slider — one number is enough, so no line.
            r.cfg.syncOffsetMap = JSON.stringify({ "AA:BB:CC:DD:EE:FF": 145 });
            compare(r.e.autoTunedSummary(), "");
            // The caretaker has moved it. Now the screen has to admit that.
            r.cfg.syncOffsetMap = JSON.stringify({ "AA:BB:CC:DD:EE:FF": 168 });
            var s = r.e.autoTunedSummary();
            verify(s.indexOf("168") > 0);
            verify(s.indexOf("desc of " + btSink) === 0);
            // A wired speaker carries no per-device lag of its own and must
            // not be listed as "tuned" just for sitting at zero.
            verify(s.indexOf(wired) === -1);
        }

        function test_ticking_the_box_answers_now_not_in_six_minutes() {
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            verify(!r.e._autoCareJustArmed);
            compare(r.e.driftLastText, "");
            r.e.noteAutoCareEnabled();
            // Something in the line straight away: a checkbox that answers
            // in six minutes reads as a checkbox that does nothing.
            verify(r.e.driftLastText !== "");
            verify(r.e._autoCareJustArmed);
            // And the flag clears once the quick check has been spent, so a
            // later automatic arming waits out its full settle again.
            r.e._autoCareJustArmed = false;
            verify(!r.e._autoCareJustArmed);
        }

        function test_a_confirmed_drift_says_so_and_never_takes_the_music() {
            // The loud road does not start itself, whatever the number says.
            // It parks the music, mutes the speakers in turn and takes about
            // a minute; a listener does not get that in the middle of a song
            // because a reading crossed a line. Measured on this desk over
            // twenty consecutive checks, the check's own scatter is sd 21 ms,
            // so a single reading past the 25 ms threshold can be noise —
            // and on 2026-08-01 the minute of silence was started off two
            // readings pointing in OPPOSITE directions (-21 then +29), a pair
            // the quiet fold had just refused for exactly that reason.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            // No landings in these, so the quiet fold has nothing to work on
            // and the check can only speak.
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 80\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 85\n", "");
            verify(!r.e._verifyPending);
            compare(r.mock.notes.length, 0);
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 82\n", "");
            verify(!r.e._verifyPending);
            fuzzyCompare(r.mock.playerOutput.volume, 0.5, 0.001);
            compare(r.mock.notes.length, 1);
            compare(r.mock.notes[0].title, "Sync has drifted");
            // Once per spell, not once per check: a wandering link must not
            // nag every six minutes.
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 90\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 92\n", "");
            compare(r.mock.notes.length, 1);
            verify(!r.e._verifyPending);
        }

        function test_a_room_back_in_sync_earns_a_fresh_word_later() {
            // Said once per spell. A room that goes out, comes back and goes
            // out again is two pieces of news, and the listener hears both —
            // but a single spell of drift is one.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            for (var a = 0; a < 3; a++)
                r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 8" + a + "\n", "");
            compare(r.mock.notes.length, 1);
            // The room reads in step again — TWICE. One sub-25 reading is
            // as cheap as one flyer (scatter is sd 21 ms), and a room
            // sitting near the line crossed it both ways all evening,
            // opening a fresh "spell" for every upward crossing to toast
            // about. A single calm reading must not end the spell.
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 8\n", "");
            for (var b0 = 0; b0 < 3; b0++)
                r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 8" + b0 + "\n", "");
            compare(r.mock.notes.length, 1);    // still the same spell
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 8\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 9\n", "");
            // A fresh drift is a new event and gets its own word.
            for (var b = 0; b < 3; b++)
                r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 8" + b + "\n", "");
            compare(r.mock.notes.length, 2);
            verify(!r.e._verifyPending);
        }

        function test_one_wild_reading_cannot_move_the_room() {
            // A median, not a mean: measured here, one check in twelve comes
            // back a flyer (46 and 49 where the neighbours read 7). Averaging
            // hands that flyer a share of the correction; a median hands it
            // nothing, which is the whole reason the pair rule was dropped.
            var m0 = {}; m0[btMac] = 200;
            var r = rig([dev(wired), dev(btSink)],
                        { syncAutoCare: true, syncOffsetMap: JSON.stringify(m0) });
            activate(r);
            function probe(off) {
                return "DRIFT_EAR " + wired + " 1400\n"
                     + "DRIFT_EAR " + btSink + " " + (1400 + off) + "\n"
                     + "DRIFT_EST " + Math.abs(off) + "\n";
            }
            r.e.handleExec(": PW_DRIFT;", probe(20), "");
            r.e.handleExec(": PW_DRIFT;", probe(300), "");   // the flyer
            r.e.handleExec(": PW_DRIFT;", probe(22), "");
            // Median of 20, 22, 300 is 22 — and the mean would have been 114.
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 222);
        }

        function test_twin_window_stays_tight_just_over_the_threshold() {
            // The scaling must not read as a licence. Just over the 25 ms
            // floor a fifth of the reading is under 15, so the flat guard
            // still stands and a 30 against a 50 remains two guesses.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 30\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 50\n", "");
            verify(!r.e._verifyPending);
        }

        function test_the_caretaker_never_touches_the_volume() {
            // Three tests used to live here, all of them about surviving the
            // park: a wheel nudge folding onto the pre-park level, an
            // absolute gesture applying as spoken, a programmatic write not
            // being mistaken for a gesture. None of them can happen any more,
            // because the caretaker no longer parks anything. What is worth
            // keeping is the promise itself.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.mock.playerOutput.volume = 0.5;
            for (var i = 0; i < 6; i++)
                r.e.handleExec(": PW_DRIFT;", "DRIFT_EST " + (80 + i) + "\n", "");
            fuzzyCompare(r.mock.playerOutput.volume, 0.5, 0.001);
            verify(!r.e._autoCareParked);
            verify(!r.e._verifyPending);
        }


        function test_drift_ack_during_a_busy_state_never_arms_the_verify() {
            // The probe is out for up to 20 s. A manual calibration (or a
            // recording, or an alarm) starting inside that window must not
            // have the confirming ack hardware-mute speakers over it — the
            // calibration would measure silence and persist garbage lags.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 80\n", "");
            r.e._calibrating = true;
            verify(r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 85\n", ""));
            verify(!r.e._verifyPending);                  // consumed, not armed
            r.e._calibrating = false;
            r.mock.recording = true;
            verify(r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 84\n", ""));
            verify(!r.e._verifyPending);
        }


        function test_drift_quiet_or_small_resets_the_pending_sighting() {
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 80\n", "");
            // Silence between the sighting and its would-be twin retires it.
            r.e.handleExec(": PW_DRIFT;", "DRIFT_QUIET\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 82\n", "");
            verify(!r.e._verifyPending);        // first sight again
            // An in-sync reading does the same.
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 0\n", "");
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 81\n", "");
            verify(!r.e._verifyPending);
        }

        function test_drift_stale_ack_after_toggle_off_never_arms() {
            // The probe is out for up to 20 s — an ack landing after the
            // user toggled auto-care off (or the group died) must be
            // consumed without arming the audible verify, the same liveness
            // contract PW_CALIB/PW_VERIFY keep through their seq gates.
            var r = rig([dev(wired), dev(btSink)], { syncAutoCare: true });
            activate(r);
            r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 80\n", "");
            r.cfg.syncAutoCare = false;
            verify(r.e.handleExec(": PW_DRIFT;", "DRIFT_EST 85\n", ""));
            verify(!r.e._verifyPending);
            fuzzyCompare(r.mock.playerOutput.volume, 0.5, 0.001);
        }

        // ── the silent Bluetooth recompensation ───────────────────────────
        // A2DP buffering re-rolls on every transport (re)establishment;
        // the reported-latency probe shifts the applied lag against the
        // calibration-time reference — no clicks, no user, no staleness.

        function test_reflat_shift_recompensates_a_rerolled_transport() {
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 300 }),
                          syncRefLatMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 250 }) });
            activate(r);
            compare(r.e._lagForSink(btSink), 300);
            // The transport came back 150 ms deeper than at calibration.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 400000\n", "");
            compare(r.e._lagForSink(btSink), 450);
            // Inside the ±25 ms dead zone nothing moves — that band is the
            // transport's own measured jitter, not a re-roll.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 410000\n", "");
            compare(r.e._lagForSink(btSink), 450);
            // A fresh calibration snapshot retires the session shift and
            // becomes the new reference.
            r.e.handleExec(": PW_REFLAT C " + btMac + "; x", "REFLAT 400000\n", "");
            compare(r.e._lagForSink(btSink), 300);
            compare(JSON.parse(r.cfg.syncRefLatMap)["AA:BB:CC:DD:EE:FF"], 400);
        }

        function test_reflat_large_shift_needs_a_confirming_twin() {
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 300 }),
                          syncRefLatMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 250 }) });
            activate(r);
            // A codec-switch transient reads seconds-deep ONCE — a single
            // large reading must never move the room.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 2300000\n", "");
            compare(r.e._lagForSink(btSink), 300);
            // A contradicting follow-up replaces the pending one; still hold.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 900000\n", "");
            compare(r.e._lagForSink(btSink), 300);
            // The confirming twin (within 100 ms) makes it real.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 910000\n", "");
            compare(r.e._lagForSink(btSink), 960);   // 300 + (910 − 250)
        }

        function test_reflat_without_reference_adopts_only_a_twinned_reading() {
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 300 }) });
            activate(r);
            // Calibrated before the mechanism existed: a SINGLE reading is
            // never adopted — a codec-switch transient as the persisted
            // reference would drive every later shift from a lie.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 500000\n", "");
            verify(JSON.parse(r.cfg.syncRefLatMap)["AA:BB:CC:DD:EE:FF"] === undefined);
            // The confirming twin adopts; no shift is invented from thin air.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 505000\n", "");
            compare(JSON.parse(r.cfg.syncRefLatMap)["AA:BB:CC:DD:EE:FF"], 505);
            compare(r.e._lagForSink(btSink), 300);
        }

        function test_reflat_unusable_reading_retires_a_pending_sighting() {
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 300 }),
                          syncRefLatMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 250 }) });
            activate(r);
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 900000\n", "");
            // A suspended (0) reading between the sighting and its would-be
            // twin retires the sighting — minutes-later confirmation of a
            // stale transient must be impossible.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 0\n", "");
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 905000\n", "");
            compare(r.e._lagForSink(btSink), 300);   // first sight again, no move
        }

        function test_wake_from_park_arms_the_resurrect_insurance() {
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.e._idleTeardownTick();
            // The park's async tail: its unload ack lands before the wake.
            r.e.handleExec(": PW_UNCOMBINE_DONE;", "MASTER 80\n", "");
            verify(!r.e._combineActive);
            // The Bluetooth speaker auto-powered off during the park — the
            // wake's enable no-ops on a thin device list, but the resurrect
            // insurance is armed so the sink's return can retry it.
            r.mock.mediaDevs = { audioOutputs: [dev(wired)] };
            var lenBefore = r.mock.execLog.length;
            r.mock.anythingPlaying = true;
            verify(r.mock.execLog.slice(lenBefore).join("\n").indexOf(": PW_COMBINE") === -1);
            compare(r.e._resurrectTries, 6);
        }

        // ── the steal watch ───────────────────────────────────────────────

        function test_steal_watch_takes_back_only_just_appeared_sinks() {
            var r = rig([dev(wired), dev(btSink)]);
            r.e._combineDefaultStealWatch();   // startup seed, sync still off
            compare(r.e._defaultStealSuspects.length, 0);
            activate(r);
            r.e._combineDefaultStealWatch();   // same set: nothing new
            compare(r.e._defaultStealSuspects.length, 0);
            var newcomer = "bluez_output.11_22_33_44_55_66.1";
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink), dev(newcomer)] };
            r.e._combineDefaultStealWatch();
            compare(r.e._defaultStealSuspects.length, 1);
            compare(r.e._defaultStealSuspects[0], newcomer);
            var before = r.mock.execLog.length;
            wait(1400);                        // the deliberate WirePlumber-race delay
            verify(r.mock.execLog.length > before);
            var cmd = r.mock.execLog[r.mock.execLog.length - 1];
            verify(cmd.indexOf(": PW_STEALBACK;") === 0);
            verify(cmd.indexOf("[ \"$d\" = '" + newcomer + "' ] && pactl set-default-sink onair_combined_7") !== -1);
            compare(r.e._defaultStealSuspects.length, 0);
        }

        function test_steal_watch_is_inert_while_the_sync_is_off() {
            var r = rig([dev(wired)]);
            r.e._combineDefaultStealWatch();
            r.mock.mediaDevs = { audioOutputs: [dev(wired), dev(btSink)] };
            r.e._combineDefaultStealWatch();
            compare(r.e._defaultStealSuspects.length, 0);
        }

        // ── what a held or interrupted measurement owes the room ──────────

        function test_a_recording_between_arm_and_launch_gives_the_music_back() {
            // The arm pulls the player to 0 and says "music pauses for about
            // a minute". If a recording starts before the launch, the check
            // stands down — and used to walk away with the stream still at
            // 0, because the release rides on a verdict this road never
            // reaches. Silent for the rest of the session.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            r.mock.playerOutput.volume = 0.62;
            r.e._calibVolumeBefore = r.mock.playerOutput.volume;
            r.e._autoCareParked = true;
            r.mock.playerOutput.volume = 0;
            r.e._verifyPending = true;
            r.mock.recording = true;
            r.e._verifyLaunch();
            compare(r.e._verifyPending, false);
            compare(r.mock.playerOutput.volume, 0.62);
            compare(r.e._autoCareParked, false);
        }

        function test_a_hand_pressed_measurement_stops_the_caretakers_probe() {
            // The probe sets neither _calibrating nor _verifyPending, so the
            // guards at the top of calibrateSync never saw it: two processes
            // could sweep the same room at once, each hearing the other, and
            // the contaminated lag was the one that got stored.
            var r = rig([dev(wired), dev(btSink)]);
            activate(r);
            var before = r.mock.execLog.length;
            r.e.calibrateSync();
            var kills = 0, killAt = -1, calibAt = -1;
            for (var i = before; i < r.mock.execLog.length; i++) {
                if (r.mock.execLog[i].indexOf(": PW_DRIFTKILL;") === 0) {
                    kills++;
                    if (killAt < 0) killAt = i;
                }
                if (calibAt < 0 && r.mock.execLog[i].indexOf(": PW_CALIB ") === 0)
                    calibAt = i;
            }
            compare(kills, 1);
            // And BEFORE the measurement it is protecting, not after it.
            verify(calibAt >= 0);
            verify(killAt < calibAt);
        }

        function test_every_bluetooth_speaker_a_run_remeasured_gets_a_fresh_reference() {
            // Two Bluetooth speakers in the group. One comes back as
            // CALIB_OK, the other as a CALIB_XLAG line — both had their lag
            // rewritten by this run, so both need their transport reference
            // taken again. Only the headline one used to get it, and the
            // other went on being corrected against a calibration that no
            // longer existed.
            var bt2 = "bluez_output.11_22_33_44_55_66.1";
            var bt2Mac = "11:22:33:44:55:66";
            var r = rig([dev(wired), dev(btSink), dev(bt2)]);
            activate(r);
            r.e.calibrateSync();
            var before = r.mock.execLog.length;
            r.e.handleExec(": PW_CALIB " + r.e._calibRunSeq + " " + btMac + " P55 ;",
                           "CALIB_REF " + wired + "\n"
                           + "CALIB_XLAG " + bt2 + " 120\n"
                           + "CALIB_OK 156\n", "");
            var seen = {};
            for (var i = before; i < r.mock.execLog.length; i++) {
                var m = r.mock.execLog[i].match(/^: PW_REFLAT C ([0-9A-F:]{17})/);
                if (m) seen[m[1]] = true;
            }
            verify(seen[btMac] === true);
            verify(seen[bt2Mac] === true);
            // The wired reference is not Bluetooth and has no transport to ask.
            var wiredAsked = false;
            for (var j = before; j < r.mock.execLog.length; j++)
                if (r.mock.execLog[j].indexOf(": PW_REFLAT C " + wired) === 0) wiredAsked = true;
            compare(wiredAsked, false);
        }
    }
}
