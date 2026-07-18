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
            property var mediaDevs: ({ audioOutputs: [] })
            property var playerOutput: ({ volume: 0.5, device: null })
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
            property string deviceTrims: "{}"
            property string deviceChannels: "{}"
            property string syncExcluded: "{}"
            property string combinePrevOutput: ""
            property string combinePrevDefault: ""
            property int combineMasterPct: 100
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
            // Restore happens only when the default is still ours.
            verify(cmd.indexOf("[ \"$d\" = \"onair_combined_7\" ] && pactl set-default-sink 'usb_dac'") !== -1);
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
            // A wedged measurement dies INSIDE the guard window (60s - 10s).
            verify(cmd.indexOf(" timeout 50 python3 '") !== -1);
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
            // (10 + 2*14)s + 12s headroom.
            compare(r.e.verifySettleInterval(), 11000);
            compare(r.e.verifyGuardInterval(), 11000 + 38000 + 12000);
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
            compare(r.e.verifyGuardInterval(), 11000 + 38000 + 12000);
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
            compare(JSON.parse(r.cfg.syncOffsetMap)[btMac], 362);  // 213 + 149
            verify(r.e._verifyCorrected);
            verify(r.e._verifyPending);                 // round two armed
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

        function test_reflat_without_reference_adopts_and_stays_put() {
            var r = rig([dev(wired), dev(btSink)],
                        { syncOffsetMap: JSON.stringify({ "AA:BB:CC:DD:EE:FF": 300 }) });
            activate(r);
            // Calibrated before the mechanism existed: the first reading
            // becomes the reference, no shift is invented from thin air.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 500000\n", "");
            compare(r.e._lagForSink(btSink), 300);
            compare(JSON.parse(r.cfg.syncRefLatMap)["AA:BB:CC:DD:EE:FF"], 500);
            // An absent or suspended (0) reading changes nothing.
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "", "");
            r.e.handleExec(": PW_REFLAT S " + btMac + "; x", "REFLAT 0\n", "");
            compare(r.e._lagForSink(btSink), 300);
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
    }
}
