/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick

// ── The whole-room sync engine ───────────────────────────────────────────────
// One null sink feeds one loopback per real hardware output, each with a real
// buffer delay — plus everything that keeps that honest: per-speaker balances
// and channel modes, exclusions, microphone calibration, the Bluetooth join
// watchdog, and the etiquette around the system default sink.
//
// The engine deliberately imports nothing but QtQuick: every touch on the
// outside world goes through `app` (main.qml's facade — exec/notify/player/
// devices/cast) and every setting through `cfg`. That boundary is what lets
// tests drive the whole state machine with a mock app and a plain object.
Item {
    id: engine

    // main.qml's root item. The engine uses exactly this contract of it:
    // exec(cmd), nextSeq(), notify(title, text, icon), isPlaying(),
    // setAudioOutputDevice(id), mediaDevs, playerOutput, instanceId,
    // btList(), _btValidMac(mac), _btConnectingMac, _btPairingMac,
    // _btPendingSinkName, castTrimActive(id), applyCastTrim(uuid).
    required property var app
    // Plasmoid's configuration object in production; a plain object in tests.
    required property var cfg

    // Seconds to allow verify per member. calibrate.py measures each one in
    // two rounds of up to three captures, and a capture is a 0.6 s warm-up
    // plus a 3.2 s recording — so a member that needs its retry round costs
    // about 25 s, and a Bluetooth one a little more for its wake-up sleeps.
    // The old 14 killed the process partway through exactly that retry, which
    // exists because real speakers (a JBL Flip, per calibrate.py) sleep
    // through the first round. Both the budget and the guard timer read this,
    // so the two cannot drift apart again.
    readonly property int _verifySecondsPerMember: 27

    // Everything the engine started at startup() — availability probe, the
    // crash sweep, restore-key consumption, the steal-watch seed and the
    // persisted per-device maps.
    function startup() {
        _loadDeviceTrims();
        _loadDeviceChannels();
        _loadSyncExcluded();
        app.exec(": PW_PROBE; command -v pactl >/dev/null 2>&1 && echo __PACTL_YES__; true");
        // A measurement whose shell died with a previous session leaves the
        // python clicking into the room with nobody holding its leash — the
        // one phantom no UI could stop. Orphans only (reparented to init):
        // a run belonging to a LIVE session keeps its parent and is spared.
        // Anchored: pgrep -f matches the WHOLE command line, so the
        // unanchored pattern also hit the `timeout` and `sh -c` wrappers
        // that merely carry the script's path in their arguments.
        app.exec(": PW_ORPHANS; for p in $(pgrep -f '^python3 .*calibrate\\.py' 2>/dev/null); do"
                 + " [ \"$(ps -o ppid= -p \"$p\" 2>/dev/null | tr -d ' ')\" = 1 ] && kill \"$p\" 2>/dev/null; done; true");
        // A session that died mid-measurement left its park levels (and the
        // verify's hardware mutes) behind — the restore file it never got
        // to delete puts the room back the way the user had it.
        // XDG_RUNTIME_DIR only — never a world-writable /tmp fallback: this
        // file is REPLAYED with sh at startup, so a predictable shared path
        // would let another local user pre-plant commands (or a symlink to
        // redirect the park writes). /run/user/<uid> is 0700 and ours; with
        // no runtime dir the park recovery is simply skipped.
        app.exec(": PW_PARKREST; d=\"$XDG_RUNTIME_DIR\"; f=" + _parkFile + ";"
                 + " [ -n \"$d\" ] && [ -f \"$f\" ] && { sh \"$f\" 2>/dev/null; rm -f \"$f\"; }; true");
        refreshPortStates();
        // A crashed session can orphan the combined-output module — PipeWire
        // keeps it loaded forever. Sweep THIS instance's modules at startup
        // (per-instance sink name; a second widget's live combine survives),
        // plus the suffix-less name pre-2026.14 versions used.
        //
        // The persisted restore keys are consumed HERE, unconditionally: they
        // are only meaningful for the session that wrote them. An aborted
        // enable used to leave combinePrevOutput set forever, and the old
        // fallback then re-pointed the system default at every single login.
        var prevOutCfg = cfg.combinePrevOutput || "";
        if ((cfg.audioOutputDevice || "").indexOf("onair_combined") !== -1)
            cfg.audioOutputDevice = prevOutCfg;
        cfg.combinePrevOutput = "";
        var prevDefCfg = cfg.combinePrevDefault || "";
        // A crash inside the load window never persisted PREVDEF — the user's
        // chosen output is a strictly better guess than WirePlumber's pick.
        if (prevDefCfg === "" && prevOutCfg !== "") prevDefCfg = prevOutCfg;
        cfg.combinePrevDefault = "";
        // Sweep and default-restore share ONE shell: the default must be read
        // BEFORE the sweep destroys the combined sink (WirePlumber re-points
        // it the moment the sink dies), and the restore runs only when the
        // default was still ours — a default the user holds elsewhere is not
        // touched at startup.
        var restoreDefCmd = "";
        if (prevDefCfg !== "")
            restoreDefCmd = " case \"$d\" in onair_combined*) pactl set-default-sink '"
                            + prevDefCfg.replace(/'/g, "'\\''") + "' 2>/dev/null;; esac;";
        app.exec(": PW_COMBINE_CLEAN; d=$(pactl get-default-sink 2>/dev/null);"
                        + " for m in $(pactl list short modules 2>/dev/null"
                        + " | awk '/" + _combineSinkName + "([^0-9]|$)|onair_combined([^_0-9]|$)/ {print $1}'); do"
                        + " pactl unload-module \"$m\"; done;" + restoreDefCmd + " true");
        // Seed the steal-watch snapshot (sync is never active this early, so
        // this only records the current sink set — no suspects, no action).
        _combineDefaultStealWatch();
    }

    // Device set changed (Bluetooth (dis)connect, HDMI plug) — the routing
    // half stays in main.qml; this is the engine's share of the event.
    function onOutputsChanged() {
        _combineDefaultStealWatch();
        _combineTryRoute();
        refreshPortStates();
        // The combined sink itself can die under a live group — a PipeWire
        // restart, a hand-typed unload — and NOTHING else notices: its name
        // is filtered out of the group math, so no signature ever changes.
        // Worse than silence: the next rebuild's loopbacks would resolve
        // ".monitor" against a name that no longer exists, and pactl then
        // attaches them to the DEFAULT SOURCE — the microphone, live to the
        // room. Rebuild the whole group instead; the enable shell's own
        // same-name sweep clears whatever half survived.
        // A resurrect that found no sinks yet (a PipeWire restart empties
        // the whole device list for a beat) keeps knocking on the next few
        // device events until the hardware is back.
        if (_resurrectTries > 0 && !_combineActive && !_combineWantActive) {
            _resurrectTries--;
            combineOutputsEnable();
        }
        // Death needs a birth certificate first: the check only trusts a
        // MISSING sink after having seen it alive in this same device list —
        // an unrelated device event landing between the ack and the fresh
        // sink's propagation into mediaDevices must not read as a corpse.
        if (_combineActive) {
            var couts = app.mediaDevs.audioOutputs;
            var cAlive = false;
            for (var cx = 0; cx < couts.length; cx++)
                if (String(couts[cx].id).indexOf(_combineSinkName) !== -1) { cAlive = true; break; }
            if (cAlive) {
                _combineSinkSeen = true;
            } else if (_combineSinkSeen) {
                _combineSinkSeen = false;
                _combineResurrect();
                return;
            }
        }
        // A Bluetooth member that LEAVES. Its sink does not come back on its
        // own — the link itself is down, so there is nothing for the missing-
        // loopback check below to find and nothing for the signature to
        // compare: the speaker is simply gone from the device list and the
        // group plays on without it. Measured on this desk at 06:13:08, the
        // JBL's A2DP transport terminated mid-check ("terminated
        // unexpectedly" from the far end) and it took a human reconnect to
        // bring it back. The join watchdog already knows how to walk a
        // Bluetooth speaker in — it was only ever armed when one CONNECTS.
        if (_combineActive) _btWatchLostMembers();
        // A hardware sink came or went while the combined output is live —
        // rebuild the loopbacks for the CURRENT set. Snapshot-compared, or
        // the null sink's own appearance would trigger a rebuild and double
        // every loopback.
        if (_combineActive
            && _combineGroupSignature() !== _combineSinksSnapshot)
            syncOffsetDebounce.restart();
        // The signature is built from NAMES, and a Bluetooth sink that dies
        // and comes back wears the same one. So a speaker whose transport
        // failed — its loopback dying with the sink — rejoined the device
        // list without changing a single character of the signature, and
        // nothing ever rebuilt: the group played on without it, silently,
        // for the rest of the session. Measured on this desk exactly so, a
        // JBL that worked alone and never in the group. The membership the
        // loopbacks ACTUALLY implement is the honest thing to compare.
        if (_combineActive && !_combineReloopBusy && !syncOffsetDebounce.running
            && _combineMemberMissingLoopback())
            syncOffsetDebounce.restart();
    }

    // A group member with no loopback feeding it — the state the signature
    // cannot see. The map is written by every build and cleared with the
    // group, so "in the group but not in the map" is exactly the hole.
    function _combineMemberMissingLoopback() {
        var fed = {};
        for (var mod in _combineLoopbackSinkByModule)
            fed[_combineLoopbackSinkByModule[mod]] = true;
        var members = _combineRealSinks();
        for (var i = 0; i < members.length; i++) {
            if (fed[members[i]]) continue;
            // A sink that is not registered yet is the LBMISS retry's job,
            // not this one — only a member the system can see right now
            // counts as missing.
            var outs = app.mediaDevs.audioOutputs;
            for (var o = 0; o < outs.length; o++)
                if (String(outs[o].id) === members[i]) return true;
        }
        return false;
    }

    // The null sink vanished under a live group. Reset the module
    // bookkeeping (the ids died with the daemon that owned them) and run a
    // fresh enable — membership, trims and lags all come from config, so
    // the room comes back as it was. One-shot by construction: the moment
    // _combineActive drops, this path is unreachable until the new
    // generation's ack raises it again.
    property int _resurrectTries: 0
    // True once the live combined sink has been observed in mediaDevices —
    // the death check's precondition.
    property bool _combineSinkSeen: false

    function _combineResurrect() {
        _combineLoopbackIds = [];
        _combineLoopbackSinkByModule = {};
        _combineNullId = "";
        _combineActive = false;
        _combineWantActive = false;
        // The same generation boundary the disable draws: a rebuild that was
        // in flight when the sink died will ack as stale and deliberately
        // keep its hands off these flags — a leftover busy would otherwise
        // park every rebuild of the resurrected group behind an ack that is
        // never coming, and sliders, device changes and calibrations would
        // all silently no-op for the rest of the session.
        _combineReloopBusy = false;
        _combineReloopPending = false;
        combineLbRetry.stop();
        // A measurement mid-flight measures a dead group — same cancel the
        // disable does, generation bump included. The isolation's hardware
        // mutes sit on REAL sinks that are (or will be) back: lift them.
        if (_calibrating || _verifyPending) _calibAbort(false);
        _resurrectTries = 6;
        combineOutputsEnable();
    }

    // Every engine-owned shell round-trip lands here from main.qml's exec
    // handler; true = the command was ours and is fully handled.
    function handleExec(cmd, stdout, stderr) {
        if (cmd.indexOf(": PW_RAMP;") === 0) {
            // The ramp's own end is the only honest "the master is where the
            // room wants it" moment — see _combineRamping.
            _combineRamping = false;
            return true;
        }
        if (cmd.indexOf(": PW_UNCOMBINE;") === 0 || cmd.indexOf(": PW_COMBINE_CLEAN;") === 0
            || cmd.indexOf(": PW_TRIM;") === 0 || cmd.indexOf(": PW_STEALBACK;") === 0
            || cmd.indexOf(": PW_PARKREST;") === 0
            || cmd.indexOf(": PW_CALIBKILL;") === 0 || cmd.indexOf(": PW_DRIFTKILL;") === 0
            || cmd.indexOf(": PW_ORPHANS;") === 0) {
            return true; // fire-and-forget
        }
        // The kick-abort's own disconnect landed — only the menu wants to
        // know; the user-disconnect handler (parked wishes, in-flight state)
        // is deliberately NOT on this road.
        // Combined local output: pactl availability probe
        if (cmd.indexOf(": PW_PROBE;") === 0) {
            _combineAvailable = (stdout || "").indexOf("__PACTL_YES__") !== -1;
            // The room comes back the way it was left: the wish persisted,
            // the sweep has cleared the old body, and the remembered master
            // keeps the return from being a blast. The device list can
            // still be empty this early — the resurrect knocks ride the
            // next few device events until the hardware is standing.
            if (_combineAvailable && cfg.combineWanted
                && !_combineActive && !_combineWantActive) {
                _resurrectTries = 6;
                combineOutputsEnable();
            }
            return true;
        }
        // Jack detection: which sinks' active ports report "not available"
        // (nothing physically plugged in). Only that exact answer counts —
        // "availability unknown" (S/PDIF, most desktop line-outs) proves
        // nothing either way and is left alone.
        if (cmd.indexOf(": PW_PORTS;") === 0) {
            var pm = {};
            try {
                var sinksJ = JSON.parse(stdout || "[]");
                for (var pi = 0; pi < sinksJ.length; pi++) {
                    var sj = sinksJ[pi];
                    if (!sj || !sj.name || !sj.active_port || !sj.ports) continue;
                    for (var pj = 0; pj < sj.ports.length; pj++)
                        if (sj.ports[pj].name === sj.active_port
                            && String(sj.ports[pj].availability) === "not available")
                            pm[sj.name] = true;
                }
            } catch (e) {}
            _portUnplugged = pm;
            _portRev++;
            return true;
        }
        // Combined local output created — route onto it when its sink
        // shows up in mediaDevices (usually instantly).
        if (/^: PW_COMBINE \d+;/.test(cmd)) {
            var pwOut = stdout || "";
            var nullM = pwOut.match(/^NULL (\d+)/m);
            // What was the default before this load switched it? ANY
            // combined name — this instance's, another's, a superseded
            // enable's from a fast toggle, a pre-2026.14 leftover — means
            // there is nothing real to restore: persisting it would point
            // the default at a dead node on the next disable.
            var prevDefM = pwOut.match(/^PREVDEF (\S+)/m);
            var prevDef = (prevDefM && prevDefM[1].indexOf("onair_combined") !== 0)
                          ? prevDefM[1] : "";
            var restoreDef = prevDef !== ""
                ? "pactl set-default-sink '" + prevDef.replace(/'/g, "'\\''") + "' 2>/dev/null; " : "";
            var lbIds = [];
            var lbPairs = {};
            var lbRe = /LB (\d+)(?: (\S+))?/g, lbM;
            while ((lbM = lbRe.exec(pwOut)) !== null) {
                lbIds.push(lbM[1]);
                if (lbM[2]) lbPairs[lbM[1]] = lbM[2];
            }
            // A load from a superseded enable (enable→disable→enable
            // while it was in flight): its modules are strays next to
            // the current generation's — unload them, touch no state.
            var seqM = cmd.match(/^: PW_COMBINE (\d+);/);
            if (!seqM || parseInt(seqM[1], 10) !== _combineLoadSeq
                || _combineActive) {
                var stale = lbIds.slice();
                if (nullM) stale.push(nullM[1]);
                var uns = "";
                for (var sui = 0; sui < stale.length; sui++)
                    uns += "pactl unload-module " + stale[sui] + " 2>/dev/null; ";
                // A live OR WANTED instance keeps the default it owns —
                // a pending re-enable (wanted, not yet acked) must not
                // have its default stolen back by the superseded load.
                if (uns !== "") app.exec(": PW_UNCOMBINE; " + uns
                    + ((_combineActive || _combineWantActive) ? "" : restoreDef) + "true");
                // This superseded ack carries the ONLY surviving copy of the
                // user's real default: a fast enable→disable→re-enable means
                // the re-enable's own get-default-sink already read THIS
                // load's combined sink and filtered it to empty. Stash it so
                // the live generation's ack can adopt it — or, when the acks
                // arrived REORDERED and the live generation is already up
                // with an empty PREVDEF of its own, hand it over directly:
                // without it the eventual disable has nothing to restore and
                // WirePlumber picks the default on its own.
                if (prevDef !== "") {
                    if (_combineWantActive && !_combineActive) {
                        _combinePrevDefaultFallback = prevDef;
                    } else if (_combineActive && _combinePrevDefault === "") {
                        _combinePrevDefault = prevDef;
                        cfg.combinePrevDefault = prevDef;
                    }
                }
                return true;
            }
            // Fatal only when the null sink itself failed, or when no
            // loopback loaded AND none was even skipped: an all-LBMISS
            // build (every sink still registering — a Bluetooth-only
            // group right after connect) is a healthy build waiting for
            // its sinks, and the retry pass below walks them in.
            if (!nullM || (lbIds.length === 0 && pwOut.indexOf("LBMISS") === -1)) {
                // Nothing usable came up — take down whatever half did.
                var junk = lbIds.slice();
                if (nullM) junk.push(nullM[1]);
                var unj = "";
                for (var ji = 0; ji < junk.length; ji++)
                    unj += "pactl unload-module " + junk[ji] + " 2>/dev/null; ";
                if (unj !== "" || (nullM && restoreDef !== ""))
                    app.exec(": PW_UNCOMBINE; " + unj
                                    + (nullM ? restoreDef : "") + "true");
                // A duplicate enable's failure (sink name already taken)
                // must not clobber the LIVE instance's state — the box
                // would read unchecked with the sink still running and
                // disable early-returning on the cleared intent.
                if (_combineActive) return true;
                // A failure the user already walked away from (ticked off
                // inside the load's round-trip) is nobody's news — the
                // intent is withdrawn, the box is empty, a warning toast
                // about it would only confuse.
                var wasWanted = _combineWantActive;
                _combineWantActive = false;
                _combinePrevOutput = "";
                // The persisted copy too — a stale key here used to make
                // the startup restore fire on every later login.
                cfg.combinePrevOutput = "";
                if (wasWanted)
                    app.notify(i18n("Could not combine the outputs"),
                               ((stderr || "").split("\n")[0] || i18n("pactl refused to create the combined output.")).substring(0, 120),
                               "dialog-warning");
                return true;
            }
            _combineNullId = nullM[1];
            _combineLoopbackIds = lbIds;
            _combineLoopbackSinkByModule = lbPairs;
            if (!_combineWantActive) {
                // Turned off while loading — honor the user's last word.
                var unw = _combineUnloadCmd();
                if (unw !== "" || restoreDef !== "")
                    app.exec(": PW_UNCOMBINE; " + unw + restoreDef + "true");
                _combinePrevOutput = "";
                // The persisted copy too, or the startup restore would
                // re-point the system default on every later login.
                cfg.combinePrevOutput = "";
                return true;
            }
            _combineActive = true;
            _resurrectTries = 0;
            // Graph bring-up is a fresh Bluetooth operating point — read
            // every member's reported latency once the transport settles,
            // so a link that came back off its calibration recompensates
            // before the listener ever hears it.
            refLatProbeTimer.restart();
            // The sighting is recorded HERE too: the sink usually registers
            // before this ack (the same shell created it), so the death
            // check's "seen alive" precondition would otherwise wait for a
            // later device event that may never mention the sink at all —
            // measured live: a hand-killed null sink was never resurrected
            // because no event after activation had carried its birth.
            var bcOuts = app.mediaDevs.audioOutputs;
            for (var bc = 0; bc < bcOuts.length; bc++)
                if (String(bcOuts[bc].id).indexOf(_combineSinkName) !== -1) {
                    _combineSinkSeen = true;
                    break;
                }
            // If our own PREVDEF read back as a combined name (empty after
            // the filter) — a superseded load had already switched the
            // default before this generation looked — adopt the real default
            // a superseded ack stashed for us. Otherwise it is lost forever.
            if (prevDef === "" && _combinePrevDefaultFallback !== "")
                prevDef = _combinePrevDefaultFallback;
            _combinePrevDefaultFallback = "";
            _combinePrevDefault = prevDef;
            cfg.combinePrevDefault = prevDef;
            // The ramp out of the polite 20% flip, from HERE and not from
            // the load shell: this ack is generation-checked, so a
            // superseded enable's shell can never ramp the next
            // generation's freshly-parked sink by name. It ends at the
            // room's remembered master (captured by the last disable's
            // teardown), 100% = acoustic passthrough only when nothing is
            // remembered — a room the volume keys trimmed to 40% last
            // evening comes back at 40%, not at a blast. 20% on the cubic
            // curve is −42 dB, and the widget's own slider rides the
            // stream, not the master: a room left parked there read as
            // "the speakers don't play" (measured live on a running JBL).
            // Nothing remembered yet? Then the room's CURRENT level is the
            // honest starting point, not full scale: the combined sink
            // becomes the system output, so assuming 100% hands the machine
            // a volume nobody asked for. Only a room whose level could not
            // be read at all falls back to acoustic passthrough.
            // The stored level starts at 0 on purpose — "never set" — so
            // this branch is reachable on a fresh install. It used to default
            // to 100, which made the whole inheritance below dead code and
            // handed the first enable a full-scale ramp: the very thing the
            // read-back exists to prevent.
            var prevVolM = pwOut.match(/^PREVVOL (\d+)/m);
            var inherited = prevVolM ? parseInt(prevVolM[1], 10) : 0;
            var rampTo = Math.max(10, Math.min(100,
                cfg.combineMasterPct || (inherited > 0 ? inherited : 100)));
            var rampCmd = "";
            var rampSteps = [35, 50, 65, 80, 90, 100].filter(function(rs) { return rs < rampTo; });
            rampSteps.push(rampTo);
            for (var rp = 0; rp < rampSteps.length; rp++)
                rampCmd += "pactl set-sink-volume " + _combineSinkName + " "
                         + rampSteps[rp] + "% 2>/dev/null; sleep 0.12; ";
            // The ramp climbs through half a dozen levels the user never
            // chose. A disable landing inside that window read one of them
            // off the sink and filed it as "the level the room was left at",
            // and each such round shrank the memory again.
            _combineRamping = true;
            rampGuard.restart();
            app.exec(": PW_RAMP; " + rampCmd + "true # " + app.nextSeq());
            _combinePendingRoute = true;
            _combineTryRoute();
            _combineHandleMiss(pwOut);
            // Balances moved during the load round-trip were stored but not
            // audible — the build baked the values from enable time. Bring
            // the room to the STORED state now that the modules are known.
            _trimReconcile(lbPairs);
            // The rows are clickable from the moment the switch flips,
            // which is BEFORE this ack lands — an untick or a channel
            // flip made inside the load round-trip is not in the build
            // that just arrived, and nothing else would ever revisit it.
            if (_combineGroupSignature() !== _combineSinksSnapshot)
                syncOffsetDebounce.restart();
            return true;
        }
        // Loopbacks swapped under the live null sink (slider / sink set
        // changed) — adopt the fresh module ids.
        if (cmd.indexOf(": PW_RELOOP") === 0) {
            var rlIds = [];
            var rlPairs = {};
            var rlRe = /LB (\d+)(?: (\S+))?/g, rlM;
            while ((rlM = rlRe.exec(stdout || "")) !== null) {
                rlIds.push(rlM[1]);
                if (rlM[2]) rlPairs[rlM[1]] = rlM[2];
            }
            // A rebuild from a superseded enable-generation (its ack
            // outlived a disable→re-enable): its modules are strays, and
            // the CURRENT generation's serialization state is not its to
            // touch — clearing the busy flag here would let two rebuilds
            // of the live generation overlap.
            var rlSeqM = cmd.match(/^: PW_RELOOP (\d+);/);
            if (!rlSeqM || parseInt(rlSeqM[1], 10) !== _combineLoadSeq) {
                var unrl = "";
                for (var rsi = 0; rsi < rlIds.length; rsi++)
                    unrl += "pactl unload-module " + rlIds[rsi] + " 2>/dev/null; ";
                if (unrl !== "") app.exec(": PW_UNCOMBINE; " + unrl + "true");
                return true;
            }
            _combineReloopBusy = false;
            // Disabled-while-rebuilding must win over a queued rebuild:
            // the pending branch used to run first, adopt the fresh ids
            // into a rebuild that early-returns on !_combineActive, and
            // strand the modules for the whole session.
            if (!_combineActive) {
                _combineReloopPending = false;
                var unr = "";
                for (var ri = 0; ri < rlIds.length; ri++)
                    unr += "pactl unload-module " + rlIds[ri] + " 2>/dev/null; ";
                if (unr !== "") app.exec(": PW_UNCOMBINE; " + unr + "true");
                return true;
            }
            if (_combineReloopPending) {
                _combineReloopPending = false;
                _combineLoopbackIds = _combineLoopbackIds.concat(rlIds);
                // The map rides along even on this road: the queued rebuild
                // can be HELD (a verify in flight) instead of running now,
                // and a verify launched with an empty map loses its pre2
                // full-level trims — a balance-trimmed loopback then eats
                // the click on the cubic curve and a healthy speaker reads
                // back as unheard.
                _combineLoopbackSinkByModule = rlPairs;
                _combineRebuildLoopbacks();
                return true;
            }
            _combineLoopbackIds = _combineLoopbackIds.concat(rlIds);
            _combineLoopbackSinkByModule = rlPairs;
            _combineHandleMiss(stdout || "");
            // Same reconciliation as the enable ack: a slider moved during
            // the rebuild flight resolved against module ids that were
            // being unloaded — the fresh modules now get the stored value.
            _trimReconcile(rlPairs);
            return true;
        }
        // Disable's teardown ran to completion — only now is the persisted
        // default-restore key spent. Guarded: an enable inside the ack's
        // round-trip owns the key again and must keep it. The teardown also
        // read the room's master level on its way out — that is what the
        // volume keys were trimming all evening, and the next enable's ramp
        // ends there instead of at a full-blast 100% the user never chose.
        if (cmd.indexOf(": PW_UNCOMBINE_DONE;") === 0) {
            var mM = (stdout || "").match(/^MASTER (\d+)/m);
            if (mM) cfg.combineMasterPct = Math.max(10, Math.min(100, parseInt(mM[1], 10)));
            if (!_combineActive && !_combineWantActive)
                cfg.combinePrevDefault = "";
            // The park's unload has fully landed — a wake that arrived
            // mid-tail can now take the clean road.
            _combineParkTail = false;
            parkTailGuard.stop();
            if (_combineWakeQueued && _combineIdleParked
                && cfg.combineWanted === true && !_combineActive && !_combineWantActive
                && _appPlaying)
                _combineWakeFromPark();
            else _combineWakeQueued = false;
            return true;
        }
        // Microphone calibration finished — apply and remember the lag.
        if (cmd.indexOf(": PW_CALIB") === 0) {
            // Drop a stale ack from a superseded run (its untimeout'd restore
            // pactl hung past the guard and only exited now, mid-next-run):
            // it is not this generation's, so it touches nothing.
            var calSeqM = cmd.match(/^: PW_CALIB (\d+) /);
            if (!calSeqM || parseInt(calSeqM[1], 10) !== _calibRunSeq) return true;
            _calibrating = false;
            calibGuardTimer.stop();
            // Every token is read at the START of its own line. The script
            // prints one device-supplied string (CALIB_MIC's description),
            // and an unanchored search would have found a forged token
            // sitting INSIDE it — a speaker naming itself a measurement.
            var okM = (stdout || "").match(/^CALIB_OK (\d+)/m);
            var macM = cmd.match(/^: PW_CALIB \d+ ([0-9A-F:]{17}) /);
            // The park level this very run measured at — the sentinel
            // carries it so a louder retry's levels fold with the right
            // reference (pre-park commands default to the historic 55).
            var parkM = cmd.match(/ P(\d+) ;/);
            var calPark = parkM ? Math.max(1, parseInt(parkM[1], 10)) : 55;
            // The run's whole story goes to the journal, verdict or not:
            // which stimulus timed the pair, which build of calibrate.py
            // measured, and every raw capture behind the number. The 44 ms
            // mis-credit of 2026-07-28 took a day to explain because none
            // of this was written down — the road was a guess, the code
            // build had to be dug out of filesystem timestamps, and the
            // captures were simply gone.
            var calBy = (stdout || "").match(/^CALIB_BY (\S+)/m);
            var calSrc = (stdout || "").match(/^CALIB_SRC (\S+)/m);
            var calFail = (stdout || "").match(/^CALIB_FAIL (.+)$/m);
            var calRaw = (stdout || "").match(/^CALIB_RAW .+$/gm) || [];
            console.log("[ARP] sync: calibration "
                        + (okM ? "verdict " + okM[1] + " ms"
                               : "no verdict" + (calFail ? " (" + calFail[1] + ")" : ""))
                        + (calBy ? ", timed by " + calBy[1] : "")
                        + (calSrc ? ", code " + calSrc[1] : "")
                        + ((stdout || "").indexOf("CALIB_NOLEVELS") !== -1
                           ? ", balance left as it was (inaudible run)" : "")
                        + (calRaw.length > 0 ? "; " + calRaw.join(" | ") : ""));
            if (okM) {
                // Same ceiling as calibrate.py's own sanity window — a
                // 600 ms television is a real measurement, not an error,
                // and clamping it to 500 would report a made-up number.
                var calMs = Math.max(0, Math.min(900, parseInt(okM[1], 10)));
                cfg.syncOffsetMs = calMs;
                try {
                    var calMap = JSON.parse(cfg.syncOffsetMap || "{}");
                    // The run's reference speaker is this frame's zero, and
                    // it has to be SAID so — every other number the run
                    // produced is a difference against it. Whatever that
                    // sink was carrying belongs to an older frame, and
                    // leaving it there quietly eats the compensation:
                    // measured on this desk, a stale 154 under a fresh 171
                    // left 17 ms of delay between two speakers the
                    // microphone had just measured 156 ms apart, and the
                    // room reported itself calibrated while it was a sixth
                    // of a second out. Cleared rather than set to zero —
                    // absent already reads as zero in _lagForSink, and an
                    // explicit 0 would be one more number to keep honest.
                    var calRefM = (stdout || "").match(/^CALIB_REF (\S+)/m);
                    if (calRefM) delete calMap[_btMacOfSink(calRefM[1]) || calRefM[1]];
                    if (macM) calMap[macM[1]] = calMs;
                    // Wired/extra sinks measured in the same run: CALIB_XLAG
                    // is each one's real lag against the wired reference — a
                    // USB DAC or an HDMI TV stops being assumed zero. Same
                    // map; negative = faster than the reference. A SECOND
                    // Bluetooth member arrives here too, and it must be keyed
                    // by MAC like the verify fold does: _lagForSink reads a
                    // bluez sink only by MAC, so a lag filed under the sink
                    // name would be written once and never read again.
                    var xRe = /^CALIB_XLAG (\S+) (-?\d+)/gm, xM;
                    while ((xM = xRe.exec(stdout || "")) !== null)
                        calMap[_btMacOfSink(xM[1]) || xM[1]] =
                            Math.max(-100, Math.min(900, parseInt(xM[2], 10)));
                    _anchorLags(calMap, _combineRealSinks());
                    cfg.syncOffsetMap = JSON.stringify(calMap);
                } catch (e) {}
                // Snapshot the transport's reported latency as the
                // reference this fresh number was measured under — the
                // silent recompensation shifts against it from now on.
                // EVERY Bluetooth speaker this run re-measured, not just the
                // headline one. A second Bluetooth member arrives as a
                // CALIB_XLAG line and its lag was just rewritten above — but
                // its reference stayed at the old reading and its session
                // shift was never retired, so _lagForSink went on adding a
                // correction measured against a calibration that no longer
                // exists. One stale speaker in a group of two is the whole
                // group out of step.
                var calBtMacs = {};
                if (macM) calBtMacs[macM[1]] = true;
                var xbRe = /^CALIB_XLAG (\S+) -?\d+/gm, xbM;
                while ((xbM = xbRe.exec(stdout || "")) !== null) {
                    var xbMac = _btMacOfSink(xbM[1]);
                    if (xbMac !== "") calBtMacs[xbMac] = true;
                }
                for (var cbm in calBtMacs) {
                    // The probe stores the new reference and retires the
                    // shift — but its answer comes back a beat later, and
                    // the rebuild plus the verify below launch NOW. A stale
                    // shift riding through that gap deploys the fresh lag
                    // plus a correction measured against a calibration that
                    // no longer exists, and the verify then folds the
                    // mismatch into the map. Retire it before anything is
                    // built; the probe's own retire stays as the idempotent
                    // second hand.
                    if (_refLatShiftByMac[cbm] !== undefined) {
                        console.log("[ARP] sync: retiring " + _refLatShiftByMac[cbm]
                                    + " ms transport shift for " + cbm
                                    + " with the fresh calibration");
                        var mSh = {};
                        for (var kSh in _refLatShiftByMac)
                            if (kSh !== cbm) mSh[kSh] = _refLatShiftByMac[kSh];
                        _refLatShiftByMac = mSh;
                    }
                    _refLatProbe(cbm, true);
                }
                // Loudness matching, from the same run: each level line is
                // one speaker's click peak at the microphone, all taken at
                // the same sink volume. The QUIETEST speaker becomes the
                // reference (nothing is ever boosted — no headroom games)
                // and louder ones are trimmed down to it. Software volumes
                // are cubic in PulseAudio/PipeWire, so a linear amplitude
                // ratio lands as its cube root.
                // Each sink's REAL (restored) volume, echoed by the same
                // run before it parked everything at 55%.
                var volBySink = {};
                var cvRe = /^CALIBVOL (\S+) (\d+)%/gm, cvM;
                while ((cvM = cvRe.exec(stdout || "")) !== null)
                    volBySink[cvM[1]] = Math.max(1, parseInt(cvM[2], 10));
                // Who actually made a sound this run: every CALIB_LVL line
                // is a click the microphone heard from that sink, and the
                // CALIB_OK itself proves the Bluetooth member spoke. The
                // verify's partial verdict reads this to tell a shy speaker
                // from an output with nothing behind it.
                var heard = {};
                if (macM) {
                    var rsAll = _combineRealSinks();
                    for (var hi = 0; hi < rsAll.length; hi++)
                        if (_btMacOfSink(rsAll[hi]) === macM[1]) heard[rsAll[hi]] = true;
                }
                // A LOUD speaker whose every click saturated the microphone
                // gets a timing fix (CALIB_XLAG) and a clip flag (CALIB_CLIP)
                // but NO level line — the mic could not measure an amplitude
                // it was already pinned above. Both are the strongest proof a
                // speaker was heard, so they count for the heard-map too;
                // without them the verify's eviction kicked the loudest
                // speaker in the room out as "silent through both rounds".
                // The wired reference, when the run measured it inaudibly.
                // CALIB_REF names the sink every other lag was timed
                // against, so the sweep provably reached it — but an
                // inaudible run prints no level line for anyone
                // (CALIB_NOLEVELS), and without this the reference was the
                // one member missing from the map. The verify's eviction
                // then read that absence as "silent through both rounds"
                // and ticked the healthy wired speaker out of its own group.
                var refHeardM = (stdout || "").match(/^CALIB_REF (\S+)/m);
                if (refHeardM) heard[refHeardM[1]] = true;
                var hxRe = /^CALIB_XLAG (\S+) -?\d+/gm, hxM;
                while ((hxM = hxRe.exec(stdout || "")) !== null) heard[hxM[1]] = true;
                var hcRe = /^CALIB_CLIP (\S+)/gm, hcM;
                while ((hcM = hcRe.exec(stdout || "")) !== null) heard[hcM[1]] = true;
                var lvls = [], lvlRe = /^CALIB_LVL (\S+) (\d+)/gm, lvlM;
                while ((lvlM = lvlRe.exec(stdout || "")) !== null) {
                    heard[lvlM[1]] = true;
                    var lvlAmp = parseInt(lvlM[2], 10);
                    if (lvlAmp <= 0) continue;
                    // The clicks compared the speakers at an equal park —
                    // pure sensitivity. Playback runs at each sink's own
                    // restored level, so that level is folded back in
                    // (software volumes are cubic) or the trims would
                    // equalize a room the user never actually hears.
                    var calVol = volBySink[lvlM[1]] !== undefined ? volBySink[lvlM[1]] : calPark;
                    lvls.push({ sink: lvlM[1],
                                amp: lvlAmp * Math.pow(calVol / calPark, 3) });
                }
                _calibHeard = heard;
                // A speaker the microphone heard clears its eviction slate —
                // strikes accumulate only across runs that stayed deaf to it.
                for (var hh in heard) delete _verifyPartialStrikes[hh];
                var leveled = false;
                var trimsReplaced = false;
                var masterLifted = 0;
                if (lvls.length >= 2) {
                    var refAmp = lvls[0].amp;
                    for (var li = 1; li < lvls.length; li++)
                        if (lvls[li].amp < refAmp) refAmp = lvls[li].amp;
                    // The quietest speaker is the ceiling — nothing is ever
                    // boosted, because a boost is where clipping comes from.
                    // So matching always means pulling the LOUD ones down,
                    // and the room ends quieter than it started.
                    var deepestTrim = 1;
                    for (var lj = 0; lj < lvls.length; lj++) {
                        var trimKey = _trimKeyForSink(lvls[lj].sink);
                        var newTrim = Math.pow(refAmp / lvls[lj].amp, 1 / 3);
                        var applied = Math.max(0.05, Math.min(1, newTrim));
                        if (applied < deepestTrim) deepestTrim = applied;
                        // The measurement wins — that is what the button
                        // promises — but replacing a balance somebody set
                        // by hand must never happen without a word.
                        if (_deviceTrims[trimKey] !== undefined
                            && Math.abs(trimOf(trimKey) - applied) > 0.05)
                            trimsReplaced = true;
                        setDeviceTrim(trimKey, newTrim);
                    }
                    leveled = true;
                    // Give the loudness back on the master, which is what a
                    // human doing this with an SPL meter does next: level the
                    // channels, then bring the whole room back up. Only as far
                    // as the master's own headroom reaches — at 100% there is
                    // nothing left to give and the toast says so instead of
                    // pretending. The lift is reported, not silent: the levels
                    // the user hears did change.
                    if (deepestTrim < 0.99) {
                        var curMaster = Math.max(10, Math.min(100, cfg.combineMasterPct || 100));
                        var wantMaster = Math.min(100, Math.round(curMaster / deepestTrim));
                        if (wantMaster > curMaster + 1) {
                            cfg.combineMasterPct = wantMaster;
                            masterLifted = wantMaster - curMaster;
                            app.exec(": PW_MASTERLIFT; pactl set-sink-volume "
                                     + _combineSinkName + " " + wantMaster + "% 2>/dev/null;"
                                     + " true # " + app.nextSeq());
                        }
                    }
                }
                _combineRebuildLoopbacks();
                // The check-measure: with the rebuilt loopbacks live, click
                // through the combined sink and hear the room's ACTUAL
                // residual spread — a bad calibration gets caught here, not
                // at 7 AM. The stream stays muted until the verdict, for the
                // same reason the calibration muted it: program audio drowns
                // the clicks. Armed BEFORE any notification: a toast that
                // throws must never be what stands between the parked stream
                // and the verify pass that restores it. NOT armed against a
                // dead group: a run whose sync was disabled mid-clicks keeps
                // its honest measurement in the map, but a verify would park
                // and mute sinks the user has already routed back to.
                if (!_combineActive) {
                    _calibRestoreVolume();
                    return true;
                }
                _verifyPending = true;
                _verifyArmTimers();
                var calText = leveled
                    ? i18n("The Bluetooth speaker trails by %1 ms, and every speaker's loudness was matched at the microphone — all set and remembered.", calMs)
                    : i18n("The Bluetooth speaker trails by %1 ms — the delay is set and remembered for this device.", calMs);
                if (trimsReplaced)
                    calText += " " + i18n("Balance levels set earlier were replaced by the measured ones.");
                // Matching means the loud speakers came DOWN to the quietest
                // one, so the room is quieter than it was. Say which of the
                // two happened next — the level the user hears is theirs.
                if (leveled) {
                    calText += " " + (masterLifted > 0
                        ? i18n("The speakers were matched to the quietest one and the group's volume was raised by %1% to make up for it.", masterLifted)
                        : i18n("The speakers were matched to the quietest one, so the room is quieter than before — turn the volume up if you want it back."));
                }
                // A saturated mic cannot measure loudness honestly — those
                // speakers kept their old balance, and the user should know
                // why (and how to fix it) instead of wondering.
                var clipped = [];
                var clRe = /^CALIB_CLIP (\S+)/gm, clM;
                while ((clM = clRe.exec(stdout || "")) !== null) clipped.push(clM[1]);
                if (clipped.length > 0)
                    calText += " " + i18n("The microphone clipped on %1 — that balance was left unchanged; lower the speaker's volume and calibrate again.", clipped.join(", "));
                // The default mic delivered exact zeros (a hardware mute the
                // system cannot see) and another one stepped in — say which,
                // or the user wonders why their good mic was "ignored".
                // The measured winner is remembered by NAME, so every later
                // check listens through the same ear the calibration chose
                // instead of re-deciding from the desktop default. A name
                // that stops existing simply falls back to a fresh pick.
                var micN = (stdout || "").match(/^CALIB_MICNAME (\S{1,200})$/m);
                if (micN && /^[A-Za-z0-9._:+-]+$/.test(micN[1]))
                    cfg.syncMicName = micN[1];
                var micM = (stdout || "").match(/^CALIB_MIC (.+)/m);
                if (micM)
                    calText += " " + i18n("Measured with %1 — the default microphone stayed silent.", micM[1].trim());
                app.notify(i18n("Speakers calibrated"), calText, "audio-input-microphone");
            } else {
                // Every microphone in the room delivered exact zeros — a
                // hardware mute (the touch button on the mic itself) that no
                // software flag reports. Louder clicks cannot fix a deaf
                // ear, so this failure never escalates the park.
                // Asked to measure with a tone nobody hears, on a room that
                // cannot carry one. The clicks would work — that is exactly
                // what the listener said they did not want — so the run
                // stops and hands the choice back.
                if ((stdout || "").indexOf("inaudible unavailable") !== -1) {
                    _calibRestoreVolume();
                    if (_rebuildHeld) { _rebuildHeld = false; _combineRebuildLoopbacks(); }
                    app.notify(i18n("Calibration did not succeed"),
                               i18n("The inaudible tone did not reach the microphone from these speakers. Move the microphone closer, or turn off \"Measure with a tone too high to hear\" to measure with the audible clicks."),
                               "audio-input-microphone");
                    return true;
                }
                if ((stdout || "").indexOf("microphone silent") !== -1) {
                    _calibRestoreVolume();
                    if (_rebuildHeld) { _rebuildHeld = false; _combineRebuildLoopbacks(); }
                    app.notify(i18n("Calibration did not succeed"),
                               i18n("Every microphone delivered pure silence. A mic's own mute button is invisible to the system — check the light on the microphone itself, or set a working microphone as the default."),
                               "dialog-warning");
                    return true;
                }
                // Inaudible clicks at the polite park are a ROOM property,
                // not a verdict: fans plus a sensitive microphone bury a 55%
                // click that an 85% one clears with room to spare (measured
                // here: 1976 vs 6550 over a floor of ~570). One louder pass
                // before giving up; the stream stays muted across the retry
                // so no music blasts between the rounds. Readings that were
                // heard but scattered past the settle rule earn the louder
                // pass too, on either road: scattered clicks are noise peaks
                // outshouting quiet bursts, and the sweep genuinely gains
                // level with the park — its stream compensation is capped at
                // 171%, which a 55% park cannot fill (a cubic 55% needs 6x)
                // and an 85% one can.
                if (calPark < 85 && _combineActive
                    && ((stdout || "").indexOf("no click heard") !== -1
                        || (stdout || "").indexOf("would not settle") !== -1)) {
                    // The louder pass may refuse to launch (the Bluetooth
                    // member vanished mid-run — the very reason no click was
                    // heard — or a rebuild emptied the group): only a retry
                    // that actually ARMED may keep the stream muted. Anything
                    // else falls through to the failure path, which gives the
                    // room its music back; a toast promising "once more"
                    // over a stream nothing will ever unmute is the exact
                    // silent-forever bug the guard timer exists to prevent.
                    calibrateSync(85);
                    if (_calibrating) {
                        // Name the stimulus the retry actually plays — the
                        // clicks wording on a sweep run would promise noise
                        // to a listener who asked for silence.
                        app.notify(i18n("Calibration"),
                                   (stdout || "").indexOf("inaudible") !== -1
                                       ? i18n("The inaudible reading would not settle at this level — trying once more, louder.")
                                       : i18n("The clicks were too quiet for this room — trying once more, louder."),
                                   "audio-input-microphone");
                        return true;
                    }
                }
                _calibRestoreVolume();
                // A rebuild requested during the failed calibration (the user
                // unticked a speaker mid-run) was held — release it now, or
                // it is dropped for the whole session and the room keeps the
                // old routing. Success releases it via the verify's unmute;
                // failure has no verify, so it must release its own.
                if (_rebuildHeld) { _rebuildHeld = false; _combineRebuildLoopbacks(); }
                // Three different failures used to share one sentence about
                // the microphone, and two of them were being told a lie.
                //
                // An implausible pair is the loudest example, caught on the
                // home desk: six clean captures from both speakers sat in
                // the same stdout as the refusal, and the widget still said
                // "check the microphone". That reading — the Bluetooth
                // speaker timed 174 ms AHEAD of the wired one — is what a
                // freshly re-rolled A2DP stream looks like before it
                // settles, and the same room's own check contradicted it by
                // ~370 ms twelve minutes later. Waiting is the cure, so say
                // so; the refusal itself is correct and stays.
                if ((stdout || "").indexOf("implausible result") !== -1)
                    app.notify(i18n("Calibration did not succeed"),
                               i18n("The two speakers timed impossibly far apart, so nothing was changed. A speaker that has just reconnected usually needs a minute to settle — try again shortly."),
                               "dialog-warning");
                // An unsettled reading is its own story: the microphone
                // heard the speakers fine, the captures just disagreed —
                // "check the microphone" advice would send the user the
                // wrong way after the louder pass already failed.
                else if ((stdout || "").indexOf("would not settle") !== -1)
                    app.notify(i18n("Calibration did not succeed"),
                               i18n("The reading would not settle even with the speakers turned up — nothing was changed. Trying again usually does it."),
                               "dialog-warning");
                else
                    app.notify(i18n("Calibration did not succeed"),
                               i18n("Make sure the microphone is not covered and both speakers can be heard, then try again."),
                               "dialog-warning");
            }
            return true;
        }
        // The verify pass came back — the room's measured residual. Anything
        // under ~30 ms fuses to the ear (and arrivals under ~8 ms fuse in
        // the measurement itself); above that the calibration deserves
        // another run.
        if (cmd.indexOf(": PW_VERIFY") === 0) {
            // Generation gate, same contract as PW_CALIB's: a verify whose
            // run was cancelled (disable bumps the seq) or superseded must
            // not stop the FRESH run's guard, feed its stale VERIFY_LAG
            // residuals into the map, or unmute members in the middle of
            // the next measurement's isolation.
            var vSeqM = cmd.match(/^: PW_VERIFY (\d+);/);
            if (!vSeqM || parseInt(vSeqM[1], 10) !== _calibRunSeq) return true;
            verifyGuardTimer.stop();
            if (!_verifyPending) return true;
            _verifyPending = false;
            // A member the check sat out because the LISTENER muted it. Not
            // deaf, not partial — but a verdict that quietly excludes a
            // speaker reads as covering it, so each one is named. When the
            // whole run failed for it, the failure branch below speaks once
            // instead of a notification per member.
            var vMutedFail = (stdout || "").indexOf("VERIFY_FAIL members muted") !== -1;
            var vMutedRe = /^VERIFY_MUTED (\S+)$/gm, vMutedHit;
            var vSat = {};
            while ((vMutedHit = vMutedRe.exec(stdout || "")) !== null) {
                console.log("[ARP] sync: " + vMutedHit[1]
                            + " is muted — sat this check out");
                vSat[vMutedHit[1]] = true;
                if (!vMutedFail && !_verifyMutedSaid[vMutedHit[1]]) {
                    _verifyMutedSaid[vMutedHit[1]] = true;
                    app.notify(i18n("Sync check"),
                               i18n("%1 is muted, so the check skipped it. Unmute it and check again to include it.",
                                    outputDescription(vMutedHit[1])),
                               "dialog-information");
                }
            }
            _verifySatOut = vSat;
            var vM = (stdout || "").match(/^VERIFY_OK (\d+)/m);
            cfg.syncVerifiedMs = vM ? parseInt(vM[1], 10) : -1;
            // The verify's whole story goes to the journal, same contract
            // as the calibration's: the 419 ms garbage pair that inverted
            // this room on 2026-07-29 left no trace of what either pass
            // had measured, and the fold below was the only witness.
            var vLagRaw = (stdout || "").match(/^VERIFY_LAG .+$/gm) || [];
            var vByM = (stdout || "").match(/^VERIFY_BY (\S+)/m);
            console.log("[ARP] sync: verify verdict "
                        + (vM ? vM[1] + " ms" : "no verdict")
                        + (vByM ? ", by " + vByM[1] : "")
                        + (vLagRaw.length > 0 ? "; " + vLagRaw.join(" | ") : "")
                        + "; shifts " + JSON.stringify(_refLatShiftByMac));
            // THE CLOSED LOOP. A Bluetooth path's buffering is re-rolled on
            // every stream lifecycle (measured live: the same speaker sat
            // 213 ms one session, 2.3 s the next after a codec switch, and
            // 149 ms EARLY after a flush) — so a stored number is only an
            // opening bid. The verify measured every speaker through the
            // deployed path; feed each one's residual back into its stored
            // lag, rebuild, and verify ONCE more. Small residuals converge
            // in one pass; a residual past 900 ms is not a lag but a stuck
            // buffer, cured by bouncing the sink, not by waiting longer.
            if (vM && !_verifyCorrected && parseInt(vM[1], 10) > 25) {
                var vSpreadNow = parseInt(vM[1], 10);
                var lagRe = /^VERIFY_LAG (\S+) (\d+)/gm, lagM;
                var residuals = {};
                while ((lagM = lagRe.exec(stdout || "")) !== null)
                    residuals[lagM[1]] = parseInt(lagM[2], 10);
                var vText, vIcon;
                if (vSpreadNow <= 900) {
                    // ONE reading may not move the map. The machinery has
                    // always run a second pass — it just reported instead of
                    // voting, and a single pair of captures agreeing on
                    // garbage (spawn jitter reads as a member arriving late)
                    // rewrote a healthy room in one stroke. The reading that
                    // wants to change the map now has to happen twice.
                    if (!_verifyProposal) {
                        _verifyProposal = { spread: vSpreadNow, residuals: residuals };
                        _verifyUnmuteAll();
                        _verifyPending = true;
                        _verifyArmTimers();
                        app.notify(i18n("Sync check"),
                                   i18n("The speakers were %1 ms apart — measuring once more to confirm.", vSpreadNow),
                                   "audio-input-microphone");
                        return true;
                    }
                    var vProp = _verifyProposal;
                    _verifyProposal = null;
                    // Only members BOTH passes measured get a vote or a
                    // fold. A member one pass sat out (muted mid-chain, a
                    // port gone) has a single reading, and the pass that
                    // never saw it did not measure zero — fabricating one
                    // vetoed corrections the members measured twice had
                    // agreed on.
                    var vKeys = {}, vAgree = true, vAny = false;
                    for (var pk in vProp.residuals)
                        if (residuals[pk] !== undefined) { vKeys[pk] = true; vAny = true; }
                    if (!vAny) vAgree = false;
                    for (var vk in vKeys) {
                        var vr1 = vProp.residuals[vk] || 0, vr2 = residuals[vk] || 0;
                        // Same window the caretaker's twin confirmation
                        // uses: flat where the number is small, 20% where
                        // it is large enough to be unambiguous.
                        if (Math.abs(vr1 - vr2) > Math.max(25, Math.round(0.2 * Math.max(vr1, vr2)))) {
                            vAgree = false;
                            break;
                        }
                    }
                    if (!vAgree) {
                        console.log("[ARP] sync: verify passes disagree — "
                                    + JSON.stringify(vProp.residuals) + " then "
                                    + JSON.stringify(residuals) + " — nothing changed");
                        _verifyCorrected = true;
                        _verifyUnmuteAll();
                        _calibRestoreVolume();
                        _trimReconcile(_combineLoopbackSinkByModule);
                        app.notify(i18n("Sync check"),
                                   i18n("Two measurements disagreed about the room, so nothing was changed. If the speakers sound apart, press Calibrate."),
                                   "dialog-warning");
                        return true;
                    }
                    _verifyCorrected = true;
                    // Write the corrected map BEFORE unmuting: _verifyUnmuteAll
                    // releases any rebuild held during the measurement, and a
                    // rebuild that fires here must carry the NEW delays — or
                    // the confirming pass measures the old ones and reports
                    // "still N apart". What lands is the MEAN of the two
                    // agreed passes — inside the window they are the same
                    // reading, and the average sheds half of either one's
                    // capture noise.
                    var vFolded = 0;
                    try {
                        var vMap = JSON.parse(cfg.syncOffsetMap || "{}");
                        var vBefore = cfg.syncOffsetMap || "{}";
                        for (var vs in vKeys) {
                            var vMean = Math.round(((vProp.residuals[vs] || 0)
                                                    + (residuals[vs] || 0)) / 2);
                            if (vMean === 0) continue;
                            // The closed loop exists because a BLUETOOTH
                            // path's buffering re-rolls per stream — that is
                            // the sentence this whole block opens with. A
                            // wired chain does not re-roll, and on this desk
                            // the verify read the wired member 508 then 493
                            // ms late minutes after the direct calibration
                            // had measured the same room tight three times —
                            // a systematic artifact of the measurement, not
                            // the room, and it repeats, so the vote above
                            // waves it through. A residual sitting on a
                            // wired member is a reason to distrust the
                            // reading, never a number to persist.
                            // What this stopgap COSTS, said out loud because
                            // nothing else here says it: a residual on the
                            // wired line has three causes, not one. The
                            // wired chain got slower, the measurement woke
                            // that speaker late (the artifact this refusal
                            // is aimed at), or the BLUETOOTH chain got
                            // FASTER — the "149 ms EARLY after a flush" case
                            // named a few lines above. The third one is
                            // real and is now uncorrectable. Retire this
                            // refusal once the verify stops waking a member
                            // mid-measurement; the honest successor folds
                            // the difference onto the Bluetooth member,
                            // since only differences ever mattered and
                            // _anchorLags normalises either form.
                            if (_btMacOfSink(vs) === "") {
                                console.log("[ARP] sync: verify residual "
                                            + vMean + " ms sits on wired " + vs
                                            + " — not a re-rolling chain, not folded");
                                continue;
                            }
                            var vKey = _btMacOfSink(vs);
                            var vOld = parseInt(vMap[vKey], 10);
                            if (!isFinite(vOld)) {
                                // No stored entry does NOT mean the member
                                // played at zero: _lagForSink deploys its
                                // fallback — for Bluetooth the global offset
                                // plus the silent REFLAT shift. The residual
                                // folds onto what the room actually played,
                                // or the "correction" jumps the speaker.
                                //
                                // What goes back into the map is REFERENCE-
                                // time, though, because _lagForSink adds the
                                // shift again on every read. Seeding with the
                                // deployed value wrote the shift in twice:
                                // bench with syncOffsetMs 500 and a 340 ms
                                // shift, the pair went from 500 ms apart to
                                // 840 where 540 was intended, and the sibling
                                // branch above (a stored entry) landed on
                                // target from the same inputs.
                                vOld = Math.max(0, Math.min(2000, cfg.syncOffsetMs || 0));
                            }
                            var vStep = Math.max(-600, Math.min(600, vMean));
                            vMap[vKey] = Math.max(-100, Math.min(2000, vOld + vStep));
                            vFolded++;
                        }
                        if (vFolded > 0) {
                            _anchorLags(vMap, _combineRealSinks());
                            cfg.syncOffsetMap = JSON.stringify(vMap);
                            console.log("[ARP] sync: verify fold, twice-confirmed — map "
                                        + vBefore + " -> " + cfg.syncOffsetMap);
                            _mirrorTunedToSlider();
                        }
                    } catch (e) {}
                    if (vFolded === 0) {
                        // The whole confirmed difference sat on wired
                        // members. An honest stop: a rebuild would change
                        // nothing and the "adjusted" toast would be a lie.
                        _verifyUnmuteAll();
                        _calibRestoreVolume();
                        _trimReconcile(_combineLoopbackSinkByModule);
                        app.notify(i18n("Sync check"),
                                   i18n("The room still reads %1 ms apart, but the difference sits on the wired speaker's road, which does not drift by itself — nothing was changed. If the speakers sound apart, press Calibrate.", vSpreadNow),
                                   "dialog-warning");
                        return true;
                    }
                    vText = i18n("The speakers were %1 ms apart — adjusted from the measurement, checking once more.", vSpreadNow);
                    vIcon = "audio-input-microphone";
                } else {
                    // Bounce the Bluetooth members: suspend/resume flushes a
                    // wedged buffer where more delay never could. One pass is
                    // enough here — the flush changes no stored number, so
                    // there is nothing a second reading could vote on.
                    _verifyCorrected = true;
                    var bounce = "";
                    var vSinks = _combineRealSinks();
                    for (var vb = 0; vb < vSinks.length; vb++)
                        if (vSinks[vb].indexOf("bluez_") === 0) {
                            var vEsc = vSinks[vb].replace(/'/g, "'\\''");
                            bounce += "pactl suspend-sink '" + vEsc + "' 1; "
                                    + "pactl suspend-sink '" + vEsc + "' 0; ";
                        }
                    if (bounce !== "")
                        app.exec(": PW_FLUSH; " + bounce + "true # " + app.nextSeq());
                    vText = i18n("A speaker's route was stuck %1 ms behind — flushed it, checking once more.", vSpreadNow);
                    vIcon = "dialog-warning";
                }
                // Now unmute — the corrected map is already written, so the
                // held rebuild this releases carries the new delays. Re-arm
                // pass 2 before the toast (state before speech).
                _verifyUnmuteAll();
                _combineRebuildLoopbacks();
                _verifyPending = true;
                _verifyArmTimers();
                app.notify(i18n("Sync check"), vText, vIcon);
                return true;
            }
            // Every terminal verdict below is the end of the measurement —
            // unmute the members the isolation muted (idempotent when the
            // script already unmuted) and restore the parked stream. The
            // correction path above owns its own unmute so its released
            // rebuild can carry the fresh delays. Re-assert the balances
            // too: the launch raised our loopback sink-inputs to full for
            // the clicks, and a balance the user dragged DURING the ~40 s
            // measurement was overwritten by the shell's launch-time
            // restore — reconciling against the stored trims is idempotent
            // when nothing moved.
            _verifyUnmuteAll();
            _calibRestoreVolume();
            _trimReconcile(_combineLoopbackSinkByModule);
            // Other audio (a browser video, another player) reads as extra
            // arrivals and would make the verdict a dice roll — the script
            // discards polluted recordings and says why.
            // Muting silenced so much of the group that nothing was left to
            // compare. The room stays unverified and the reason is the
            // listener's own mute switch, so say that, not "deaf".
            if (vMutedFail) {
                app.notify(i18n("Sync check"),
                           i18n("The check compares speakers, and too many are muted to compare. Unmute them and check again."),
                           "dialog-warning");
                return true;
            }
            if ((stdout || "").indexOf("VERIFY_FAIL room not quiet") !== -1) {
                app.notify(i18n("Sync check"),
                           i18n("This speaker does not carry the inaudible test tone, so the check needed the audible one — and the room was too noisy for it. Pause other audio and try again."),
                           "dialog-warning");
                return true;
            }
            // The mic went hardware-mute between the rounds (its own touch
            // button — no software flag reports it): the calibration stands,
            // the check just could not listen.
            // The check was asked to stay inaudible and this chain cannot
            // carry the sweep. Clicking anyway is what the setting exists to
            // prevent, so the run stops and says what would let it measure.
            // (A CALIB_NOLEVELS log used to sit here too, but that token
            // only ever arrives with a CALIBRATION's stdout — the line was
            // dead in this handler and lives in the PW_CALIB one now.)
            if ((stdout || "").indexOf("VERIFY_FAIL inaudible unavailable") !== -1) {
                _verifyPending = false;
                verifyGuardTimer.stop();
                _verifyUnmuteAll();
                _calibRestoreVolume();
                app.notify(i18n("Sync check skipped"),
                           i18n("The speakers here do not carry the inaudible tone to the microphone. Move the microphone closer, or turn off \"Measure with a tone too high to hear\" to use the audible clicks."),
                           "audio-input-microphone");
                driftLastText = i18n("Auto-check: cannot measure without a sound you would hear");
                return true;
            }
            if ((stdout || "").indexOf("VERIFY_FAIL microphone silent") !== -1) {
                app.notify(i18n("Sync check"),
                           i18n("Every microphone delivered pure silence. A mic's own mute button is invisible to the system — check the light on the microphone itself, or set a working microphone as the default."),
                           "dialog-warning");
                return true;
            }
            // Heard, but the captures would not settle: an honest
            // non-verdict, not a diagnosis. Before this branch existed the
            // tightened settle window filed the same moment under PARTIAL,
            // and PARTIAL under the sweep means "band-deaf" — a shelf a
            // healthy speaker then sits on for the life of the group, with
            // the drift watch no longer looking at it.
            var uM = (stdout || "").match(/^VERIFY_UNSTEADY (\S+)/m);
            if (uM) {
                console.log("[ARP] sync: verify reading from " + uM[1]
                            + " would not settle — nothing changed");
                app.notify(i18n("Sync check"),
                           i18n("The reading from %1 would not settle, so nothing was changed. Trying again usually does it.", outputDescription(uM[1])),
                           "audio-input-microphone");
                return true;
            }
            // A speaker the presence phase could not hear: the room is NOT
            // confirmed, and saying so honestly beats a soothing verdict
            // computed from the survivors — the calibration itself stands.
            var pM = (stdout || "").match(/^VERIFY_PARTIAL (\S+)/m);
            if (pM) {
                // Silent through BOTH rounds of the same run — the loud
                // calibration clicks straight at the sink and the check
                // through the deployed path both heard nothing. That is not
                // a shy speaker, that is an output with nothing audible
                // behind it (an unused S/PDIF port, a dead amp). It leaves
                // the group by itself instead of spoiling every verdict —
                // the row stays in the list, one tick brings it back.
                // TWO strikes, not one: the room-adaptive gates get honest
                // failures in a loud room too, and one noisy run must not
                // silently kick a healthy speaker out of the group — the
                // empty-jack filter already catches the true holes-in-the-
                // air before any click is spent on them.
                // A silence under the INAUDIBLE sweep says nothing about the
                // speaker: a codec that stops before 18 kHz is ordinary, and
                // this rule was written for the audible click ("an output
                // with nothing audible behind it"). Evicting on it is how a
                // healthy Bluetooth speaker ended up ticked out of its own
                // group with the user never touching the box — measured
                // here, exactly that, on a JBL that plays music perfectly.
                // The band-deaf list already remembers those; that is the
                // right shelf for this fact.
                if ((stdout || "").indexOf("VERIFY_BY sweep") !== -1) {
                    if (!_ultraDeaf[pM[1]]) {
                        _ultraDeaf[pM[1]] = true;
                        _ultraDeafSig = _combineGroupSignature();
                    }
                    console.log("[ARP] sync: " + pM[1] + " does not carry the inaudible"
                                + " band — kept in the group, measured with the others");
                    return true;
                }
                if (_calibHeard[pM[1]] === undefined) {
                    var evStrikes = (_verifyPartialStrikes[pM[1]] || 0) + 1;
                    _verifyPartialStrikes[pM[1]] = evStrikes;
                    if (evStrikes >= 2) {
                        delete _verifyPartialStrikes[pM[1]];
                        setSyncDeviceIncluded(_trimKeyForSink(pM[1]), false);
                        app.notify(i18n("Sync check"),
                                   i18n("%1 stayed silent through both rounds — it was left out of the group. Tick it back in the speaker list any time.",
                                        outputDescription(pM[1])),
                                   "dialog-information");
                    } else {
                        app.notify(i18n("Sync check"),
                                   i18n("%1 made no sound the microphone could hear. If it stays silent on the next calibration too, it will be left out of the group.",
                                        outputDescription(pM[1])),
                                   "dialog-warning");
                    }
                    return true;
                }
                app.notify(i18n("Sync check"),
                           i18n("Could not hear %1 during the check — the speaker may be muted or off. The calibration was kept.",
                                outputDescription(pM[1])),
                           "dialog-warning");
                return true;
            }
            if (vM) {
                var vSpread = parseInt(vM[1], 10);
                if (vSpread <= 30)
                    app.notify(i18n("Sync verified"),
                               i18n("Every speaker arrives within %1 ms at the microphone — in step to the ear.", vSpread),
                               "audio-input-microphone");
                else
                    app.notify(i18n("Sync check"),
                               i18n("The speakers still arrive %1 ms apart. Calibrate once more, or nudge the delay slider.", vSpread),
                               "dialog-warning");
            }
            return true;
        }
        // Watchdog's one-shot connection cycle finished — the sink's
        // appearance (or not) flows back through the normal watch ticks;
        // only the menu's Connected states need refreshing here. Unless
        // the user clicked Disconnect while the cycle was mid-flight:
        // its reconnect phase just reverted their choice — undo that.
        if (cmd.indexOf(": PW_DRIFT;") === 0) {
            // One answer retires one probe. Whichever branch below handles
            // this ack, the stale mark belonged to THIS probe and must not
            // survive to eat the next one's answer.
            var deStale = _driftProbeStale;
            _driftProbeStale = false;
            // Liveness gate, kin of the seq gates on PW_CALIB/PW_VERIFY: the
            // probe is out for up to 20 s, and a stale ack must not arm the
            // audible verify after the user toggled auto-care off or the
            // group died. Consume without acting.
            if (cfg.syncAutoCare !== true || !_combineActive) {
                // Consumed without acting — but the popup is still showing
                // "listening…" from the launch, and a word that never ends
                // reads as a check that hung. Retire it.
                driftGuardTimer.stop();
                if (driftLastText.indexOf("…") !== -1) driftLastText = "";
                return true;
            }
            // The same busy states that gate the probe's LAUNCH gate its
            // ack: a manual calibration, a recording or an alarm that began
            // inside the probe's window must not have an automatic verify
            // hardware-muting speakers over it — the calibration would
            // measure silence and persist garbage lags.
            if (_calibrating || _verifyPending || _combineReloopBusy
                || _btKickInFlight || app.recording === true
                || app.alarmEngaged === true) {
                driftGuardTimer.stop();
                driftLastText = i18n("Auto-check %1: skipped, something else was using the speakers",
                                     Qt.formatTime(new Date(), "hh:mm"));
                return true;
            }
            driftGuardTimer.stop();
            var deWhen = Qt.formatTime(new Date(), "hh:mm");
            var deM = (stdout || "").match(/^DRIFT_EST (\d+)/m);
            // The whole verdict, not its first line: DRIFT_PARTIAL now comes
            // out ahead of DRIFT_EST, and logging only line one hid the
            // number the check exists to produce.
            console.log("[ARP] sync: auto-care result — "
                        + ((stdout || "").trim().replace(/\n/g, " | ") || "no output"));
            // A speaker the sweep could not reach is a speaker whose drift
            // nobody is watching. It does not stop the check any more, but
            // it must not pass unmentioned either.
            var dPart = (stdout || "").match(/^DRIFT_PARTIAL (\d+)/m);
            if (dPart)
                console.log("[ARP] sync: " + dPart[1] + " speaker(s) do not carry the"
                            + " inaudible band — measured without them");
            // A rebuild landed while this probe was out, so every number in
            // this answer describes the room that was just replaced — the
            // deaf list included, since the group itself may have changed.
            // Dropped whole. The skip stays armed for the first reading of
            // the room as it now stands.
            if (deStale) {
                driftLastText = i18n("Auto-check %1: settling after the adjustment", deWhen);
                return true;
            }
            // Remember them by name and stop PLAYING into them. Opening a
            // stream is not free even when nothing comes back: two of the
            // outputs on this desk are UCM devices of ONE USB card, and
            // waking the second switches the card's output path with an
            // audible relay click. Reported twice, seconds after a periodic
            // check, while the sweep itself measures clean.
            var dDeaf = /^DRIFT_DEAF (.+)$/gm;
            var dHit, dLearned = false;
            while ((dHit = dDeaf.exec(stdout || "")) !== null) {
                if (!_ultraDeaf[dHit[1]]) { _ultraDeaf[dHit[1]] = true; dLearned = true; }
            }
            if (dLearned) {
                // Stamped with the group it was learned about, so a rebuild
                // that only moved a delay does not throw it away.
                _ultraDeafSig = _combineGroupSignature();
                console.log("[ARP] sync: will not play the sweep into those again"
                            + " while this group stands");
            }
            // A member that answered but never twice the same. Saying "too
            // quiet" there is a lie the listener can hear through — the room
            // was not quiet, the reading simply would not settle. Naming it
            // is also what stops the next question: a number that changes by
            // 130 ms between rounds is not a room that changed.
            if (/^DRIFT_UNSTEADY /m.test(stdout || "")) {
                driftLastText = i18n("Auto-check %1: reading would not settle — the microphone may be too far from the speakers", deWhen);
                return true;
            }
            if (!deM) {   // quiet / no signal — nothing to remember
                driftLastText = i18n("Auto-check %1: too quiet to tell", deWhen);
                return true;
            }
            var deMs = parseInt(deM[1], 10);
            // Where each speaker actually landed, which the spread throws
            // away. This is the road that measures in the state the listener
            // listens in — music flowing, the Bluetooth link warm, nobody
            // muted — and on this desk it put the ideal fine-tune within a
            // millisecond while the button, measuring a silent room and a
            // cold link minutes earlier, was fifteen out.
            var deEars = {}, deEarRe = /^DRIFT_EAR (\S+) (-?\d+)/gm, deEarM;
            while ((deEarM = deEarRe.exec(stdout || "")) !== null)
                deEars[deEarM[1]] = parseInt(deEarM[2], 10);
            // The probe right after a fold measures the fold's own re-roll.
            // Spend it: it may report, but it may not become half of the
            // next correction.
            if (_driftSkipNext) {
                _driftSkipNext = false;
                // The correction moved the room; everything measured before
                // it describes a room that no longer exists.
                _driftHistory = [];
                _driftHistoryAt = [];
                _driftEstHistory = [];
                driftLastText = i18n("Auto-check %1: settling after the adjustment", deWhen);
                return true;
            }
            // Every reading joins the history, in step or not: the median is
            // taken over what the room has been doing, and throwing away the
            // small readings would bias it away from zero.
            var deNow = Date.now();
            var deH = [], deHA = [], deHE = [];
            for (var dhi = 0; dhi < _driftHistory.length; dhi++) {
                // Stale readings describe a different afternoon.
                if (deNow - _driftHistoryAt[dhi] > _driftPendingMaxAgeMs) continue;
                deH.push(_driftHistory[dhi]);
                deHA.push(_driftHistoryAt[dhi]);
                deHE.push(_driftEstHistory[dhi]);
            }
            deH.push(deEars);
            deHA.push(deNow);
            // The spread rides along by value: the passive road reports an
            // estimate with no landings at all, and the toast's own median
            // has to hear those readings too.
            deHE.push(deMs);
            while (deH.length > _driftHistoryMax) {
                deH.shift(); deHA.shift(); deHE.shift();
            }
            _driftHistory = deH;
            _driftHistoryAt = deHA;
            _driftEstHistory = deHE;
            // The quiet correction costs nothing — no muting, no parked
            // music, nothing anyone hears — so it is worth making even below
            // the line where the ear stops caring. "In sync" and "exactly in
            // sync" are the same minute of silence to the listener and a
            // measurable difference to the room.
            if (_driftFoldEars()) {
                // A room just put back in step deserves to be told again if
                // it ever drifts for real.
                _driftHintShown = false;
                _driftCalmStreak = 0;
                return true;
            }
            if (deMs < 25) {

                // Back in step, so a later drift is worth mentioning again.
                // Said once per spell, never once per session: a room that
                // goes out, comes back and goes out again is two pieces of
                // news, and the listener hears about both. But a spell ends
                // when the room STAYS back — two readings in a row — not on
                // the first sub-25 number the scatter happens to produce.
                _driftCalmStreak++;
                if (_driftCalmStreak >= 2) _driftHintShown = false;
                var deSugIn = _driftSuggestion(deEars);
                driftLastText = deSugIn >= 0
                    ? i18n("Auto-check %1: in sync — measured %2 ms", deWhen, deSugIn)
                    : i18n("Auto-check %1: in sync", deWhen);
                return true;
            }
            // "still" and the target, because the number right above it in
            // the popup is the delay being APPLIED (234 ms on this desk) and
            // this one is the error that REMAINS (404). Two numbers of the
            // same unit, one under the other, and nothing said which was
            // which — the listener read them as two answers to one question.
            var deSug = _driftSuggestion(deEars);
            driftLastText = deSug >= 0
                ? i18n("Auto-check %1: %2 ms apart — measured %3 ms", deWhen, deMs, deSug)
                : i18n("Auto-check %1: still %2 ms apart (0 = in step)", deWhen, deMs);
            _driftCalmStreak = 0;
            // The quiet fold above has already had this reading and declined:
            // too few in the history yet, the room cannot agree which way it
            // is out, or there is no wired member to measure against. Nothing
            // louder happens as a result — the listener is simply told, once.
            if (_driftHistory.length < _driftHistoryMin) {
                return true;
            }
            // The loud road NEVER starts itself. It parks the music, mutes the
            // speakers in turn and takes about a minute, and a listener does
            // not get that in the middle of a song because a number crossed a
            // line. The line is not even a firm one: measured on this desk
            // over twenty consecutive checks, the check's own scatter is
            // sd 21 ms, so a single reading over the 25 ms threshold can be
            // noise — and on 2026-08-01 one such pair started the minute of
            // silence off two readings that pointed in OPPOSITE directions
            // (-21 then +29). The quiet fold had already refused that same
            // pair, correctly, for exactly that reason.
            //
            // What is left is honest: the check corrects silently whenever it
            // can, and when it cannot it says so once and the listener
            // chooses when to spend the minute. The button is right there.
            //
            // Said on the strength of the HISTORY's middle, the same bar the
            // fold holds itself to. This reading alone crossed 25, but with
            // sd 21 ms one crossing is a coin toss, and a tuned room's
            // single flyer was toasting "audibly apart" at a listener whose
            // speakers were fine.
            var deSpr = _driftEstHistory.slice().sort(function(a, b) { return a - b; });
            var deSprMed = deSpr.length % 2
                ? deSpr[(deSpr.length - 1) / 2]
                : 0.5 * (deSpr[deSpr.length / 2 - 1] + deSpr[deSpr.length / 2]);
            if (deSprMed >= 25 && !_driftHintShown) {
                _driftHintShown = true;
                console.log("[ARP] sync: program material shows " + deMs
                            + " ms split — saying so, not interrupting");
                app.notify(i18n("Sync has drifted"),
                           i18n("The speakers are audibly apart again — run Calibrate when convenient."),
                           "audio-speakers");
            }
            return true;
        }
        if (cmd.indexOf(": PW_REFLAT ") === 0) {
            var rlM = cmd.match(/^: PW_REFLAT ([CS]) ([0-9A-F:]{17})/);
            if (!rlM) return true;
            var rlUs = (stdout || "").match(/^REFLAT (\d+)/m);
            var rlMs = rlUs ? Math.round(parseInt(rlUs[1], 10) / 1000) : -1;
            // A suspended sink reports 0; anything past 3 s is not a report.
            // Either way an unusable reading also RETIRES a pending first
            // sighting — a stale one from minutes ago must not later stand
            // as the "confirming twin" of a fresh transient.
            if (rlMs <= 0 || rlMs > 3000) {
                if (_refLatPending[rlM[2]] !== undefined) {
                    var mz = {};
                    for (var kz in _refLatPending)
                        if (kz !== rlM[2]) mz[kz] = _refLatPending[kz];
                    _refLatPending = mz;
                }
                return true;
            }
            if (rlM[1] === "C") {
                // Calibration context: this reading IS the reference the
                // stored lag was measured under — and a fresh calibration
                // retires any session shift for the device.
                try {
                    var refC = JSON.parse(cfg.syncRefLatMap || "{}");
                    refC[rlM[2]] = rlMs;
                    cfg.syncRefLatMap = JSON.stringify(refC);
                } catch (e) {}
                if (_refLatShiftByMac[rlM[2]] !== undefined) {
                    var m0 = {};
                    for (var k0 in _refLatShiftByMac)
                        if (k0 !== rlM[2]) m0[k0] = _refLatShiftByMac[k0];
                    _refLatShiftByMac = m0;
                }
                return true;
            }
            var refV;
            try { refV = JSON.parse(cfg.syncRefLatMap || "{}")[rlM[2]]; } catch (e) {}
            if (refV === undefined || Math.abs(rlMs - refV) > 300) {
                // Anything CONSEQUENTIAL needs a second opinion — a large
                // move against the reference, and equally the ADOPTION of a
                // first-ever reference: a codec switch can read seconds-deep
                // for a beat, and persisting that transient as the reference
                // would drive every later shift from a lie. Two consecutive
                // readings within 100 ms make it real; the retry probe is
                // armed only on FIRST sight, so an oscillating transport
                // cannot turn this into a drumbeat.
                var pend = _refLatPending[rlM[2]];
                if (pend === undefined || Math.abs(pend - rlMs) > 100) {
                    var mp = {};
                    for (var kp in _refLatPending) mp[kp] = _refLatPending[kp];
                    mp[rlM[2]] = rlMs;
                    _refLatPending = mp;
                    if (pend === undefined) refLatProbeTimer.restart();
                    return true;
                }
            }
            if (_refLatPending[rlM[2]] !== undefined) {
                var mc = {};
                for (var kc in _refLatPending)
                    if (kc !== rlM[2]) mc[kc] = _refLatPending[kc];
                _refLatPending = mc;
            }
            if (refV === undefined) {
                // Calibrated before this mechanism existed: adopt the now
                // twin-confirmed reading as the reference — future re-rolls
                // correct relative to here.
                try {
                    var refA = JSON.parse(cfg.syncRefLatMap || "{}");
                    refA[rlM[2]] = rlMs;
                    cfg.syncRefLatMap = JSON.stringify(refA);
                } catch (e) {}
                return true;
            }
            var shift = Math.max(-1500, Math.min(1500, rlMs - refV));
            // Inside the transport's own ±20 ms wander (measured): not
            // actionable — a rebuild would re-roll more than it fixes.
            if (Math.abs(shift) < 25) shift = 0;
            var prevShift = _refLatShiftByMac[rlM[2]] || 0;
            if (Math.abs(shift - prevShift) < 25) return true;
            // A recompensation rebuilds the loopbacks, and the rebuild's own
            // suspend-flush RE-ROLLS the very buffering this reading measured
            // — so a correction can hand the next probe a fresh reason to
            // correct again, and the room quietly re-rolls itself in a loop.
            // One recompensation per speaker per two minutes: a real move
            // (codec switch, reconnect) is still caught within a breath, a
            // drumbeat cannot start.
            var nowRl = Date.now();
            if (nowRl - (_refLatActedAt[rlM[2]] || 0) < 120000) return true;
            var ma = {};
            for (var ka in _refLatActedAt) ma[ka] = _refLatActedAt[ka];
            ma[rlM[2]] = nowRl;
            _refLatActedAt = ma;
            var m1 = {};
            for (var k1 in _refLatShiftByMac) m1[k1] = _refLatShiftByMac[k1];
            m1[rlM[2]] = shift;
            _refLatShiftByMac = m1;
            console.log("[ARP] sync: " + rlM[2] + " transport latency moved "
                        + shift + " ms vs calibration — recompensating");
            // A LARGE drift gets one quiet word per session: the automatic
            // trim covers the REPORTED share of the move, but 50+ ms means
            // the link is far from where the mic last measured it, and only
            // a fresh calibration sees the whole chain.
            if (Math.abs(shift) >= 50 && !_refLatHintShown) {
                _refLatHintShown = true;
                app.notify(i18n("Speaker timing drifted"),
                           i18n("A Bluetooth speaker came back noticeably off its calibration — the sync compensated automatically. Recalibrate when convenient for exact ears."),
                           "audio-speakers");
            }
            // A reloop already in flight is no reason to drop the
            // recompensation on the floor: the rebuild path parks it in
            // _combineReloopPending and the reloop's own ack releases it.
            // Skipping here instead left the shift recorded but never
            // deployed — later probes of the same transport return early
            // on the unchanged-shift check, so nothing ever rescheduled
            // it, and the room played the whole move out loud until some
            // unrelated rebuild happened by.
            if (_combineActive && !syncOffsetDebounce.running)
                syncOffsetDebounce.restart();
            return true;
        }
        if (cmd.indexOf(": BT_KICK ") === 0) {
            // The MAC is in the sentinel: an EARLIER kick's ack (speaker A)
            // landing after the watchdog moved on to speaker B must not clear
            // B's in-flight flags or reset B's ticks. Only the ack whose MAC
            // still matches the current kick owns that state.
            var kickM = cmd.match(/^: BT_KICK ([0-9A-F:]{17});/);
            var ackMac = kickM ? kickM[1] : "";
            if (ackMac !== _btKickMac) return true;    // stale kick's ack
            _btKickInFlight = false;
            // An aborted kick needs NO undo anymore: the profile bounce
            // never connects anything — the device was connected before the
            // kick and still is, with its audio profile back on. The old
            // abort-disconnect is gone with the cycle it undid (and could
            // itself destroy a pairing, same as the cycle).
            if (!_btKickAbort && _btJoinWatchMac !== "" && _btJoinWatchMac === _btKickMac)
                _btJoinWatchTicks = 0; // fresh window for the renegotiation
            _btKickMac = "";
            _btKickAbort = false;
            app.btList();
            return true;
        }
        return false;
    }

    // ── Group volume: one master, per-device balance ─────────────────────────
    // The volume slider stays the MASTER for everything at once; each device
    // additionally carries a balance factor (0.05–1.0) so a boomy soundbar
    // and quiet desk speakers can hold their relative levels while one
    // slider drives the room: effective = master × balance.
    //
    // WHERE the balance is applied decides whether the sync survives:
    //   • the master stays ON THE STREAM (app.playerOutput.volume) — upstream
    //     of the combined sink, so a master move is baked into the samples
    //     and arrives at every local speaker delayed exactly like the music
    //     itself. Moving the master can never smear the sync.
    //   • a local balance goes on OUR loopback's sink-input — never on the
    //     sink, which belongs to the user (and, on Bluetooth, to the
    //     speaker's own AVRCP buttons); other applications are not touched.
    //   • a network device gets master × balance pushed as its device
    //     volume — wall-clock only; its buffer sits seconds away by nature.
    // Keyed by the most stable id each device has: Cast/DLNA uuid, Bluetooth
    // MAC, plain sink name for wired outputs. Kept across restarts.
    property var _deviceTrims: ({})
    // UI rebind tick — bindings can't observe key writes inside a JS object.
    property int _trimRev: 0

    function _loadDeviceTrims() {
        try {
            var m = JSON.parse(cfg.deviceTrims || "{}");
            _deviceTrims = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            _deviceTrims = {};
        }
        _trimRev++;
    }

    function trimOf(id) {
        var t = _deviceTrims[id];
        return (typeof t === "number" && t >= 0.05 && t <= 1) ? t : 1.0;
    }

    // Balance key for a local sink: the Bluetooth MAC when there is one (the
    // sink NAME can change between connects, the MAC never), the sink name
    // for wired outputs.
    function _trimKeyForSink(sink) {
        return _btMacOfSink(sink) || String(sink);
    }

    // ── Stereo pairs (per-speaker channel in the combined output) ───────────
    // A speaker in the group can play the full stereo (default), only the
    // LEFT or only the RIGHT channel — two speakers set L and R become a
    // true stereo pair — or a MONO mix of both for a speaker that stands
    // alone in another room. Implemented as the loopback's own channel map;
    // measured on PipeWire: channels=1 with an explicit position takes
    // exactly that source channel (full level, zero bleed) and
    // channel_map=mono is an equal L+R downmix. Duplicate-position maps
    // (front-left,front-left) are NOT used — pactl half-drops them.
    // Keyed like the balances: Bluetooth MAC, sink name for wired.
    property var _deviceChannels: ({})
    property int _chanRev: 0

    function _loadDeviceChannels() {
        try {
            var m = JSON.parse(cfg.deviceChannels || "{}");
            _deviceChannels = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            _deviceChannels = {};
        }
        _chanRev++;
    }

    // "S" stereo (the default — no entry), "L", "R", "M" mono mix.
    function channelOf(id) {
        var c = _deviceChannels[id];
        return (c === "L" || c === "R" || c === "M") ? c : "S";
    }

    function setDeviceChannel(id, mode) {
        var m = {};
        for (var k in _deviceChannels) m[k] = _deviceChannels[k];
        if (mode === "L" || mode === "R" || mode === "M") m[id] = mode;
        else delete m[id];
        _deviceChannels = m;
        _chanRev++;
        cfg.deviceChannels = JSON.stringify(m);
        // The map is baked into the loopback itself — swap them live.
        if (_combineActive) syncOffsetDebounce.restart();
    }

    // One click walks the modes — a row of four buttons per speaker would
    // bury the sync section.
    function cycleDeviceChannel(id) {
        var order = ["S", "L", "R", "M"];
        setDeviceChannel(id, order[(order.indexOf(channelOf(id)) + 1) % 4]);
    }

    function setDeviceTrim(id, factor) {
        var f = Math.max(0.05, Math.min(1, factor));
        var m = {};
        for (var k in _deviceTrims) m[k] = _deviceTrims[k];
        if (f >= 0.995) delete m[id]; // full level = no entry, the default
        else m[id] = Math.round(f * 100) / 100;
        _deviceTrims = m;
        _trimRev++;
        trimsPersistTimer.restart();
        // Live targets follow the slider immediately (debounced): the
        // matching loopback's sink-input locally, the device volume for a
        // casting network target. Idle devices just keep the stored value.
        if (_combineActive) {
            var mod = _combineModuleForKey(id);
            if (mod !== "") {
                _trimPendingLocal[mod] = Math.round(trimOf(id) * 100);
                trimApplyTimer.restart();
            }
        }
        if (app.castTrimActive(id)) {
            _trimPendingCast[id] = true;
            trimApplyTimer.restart();
        }
    }

    Timer {
        id: trimsPersistTimer
        interval: 1000
        repeat: false
        onTriggered: cfg.deviceTrims = JSON.stringify(_deviceTrims)
    }

    // One debounce for both directions — a slider drag lands as a single
    // pactl call / volume command per device, not one per pixel.
    property var _trimPendingLocal: ({})  // loopback module id → percent
    property var _trimPendingCast: ({})   // device uuid → true

    Timer {
        id: trimApplyTimer
        interval: 250
        repeat: false
        onTriggered: {
            var cmd = "";
            for (var mod in _trimPendingLocal)
                cmd += _sinkInputVolCmd(mod, _trimPendingLocal[mod]);
            _trimPendingLocal = {};
            if (cmd !== "") app.exec(": PW_TRIM; " + cmd + "true # " + app.nextSeq());
            for (var uuid in _trimPendingCast)
                app.applyCastTrim(uuid);
            _trimPendingCast = {};
        }
    }

    // Set OUR loopback's sink-input to a percentage — resolved by owner
    // module id at apply time, because load-module does not print the
    // sink-input id. Only ever touches inputs owned by modules we loaded.
    // moduleId is either digits (parsed from a pactl echo) or the literal
    // "$id" when baked into the same shell round that loaded the module.
    function _sinkInputVolCmd(moduleId, pct) {
        var mod = String(moduleId) === "$id"
                  ? "\"$id\"" : String(moduleId).replace(/\D/g, "");
        var p = Math.max(5, Math.min(100, Math.round(pct)));
        if (mod === "") return "";
        return "si=$(pactl list sink-inputs 2>/dev/null | awk -v m=" + mod
             + " '/^Sink Input #/{si=substr($3,2)} $1==\"Owner\" && $2==\"Module:\" && $3==m {print si; exit}');"
             + " [ -n \"$si\" ] && pactl set-sink-input-volume \"$si\" " + p + "% 2>/dev/null; ";
    }

    // Which loopback module serves the sink behind a balance key ("" = none).
    property var _combineLoopbackSinkByModule: ({})

    // Bring every freshly-adopted loopback to the STORED balance. The build
    // bakes balances as of the moment its shell leaves; a slider moved
    // during the round-trip is persisted but lands on module ids that are
    // dying — this runs on the ack, when the live ids are finally known.
    // Only trimmed speakers are queued (full level is the loopback's own
    // default), so the quiet path stays quiet.
    function _trimReconcile(pairs) {
        var queued = false;
        for (var mod in pairs) {
            var pct = Math.round(trimOf(_trimKeyForSink(pairs[mod])) * 100);
            if (pct < 100) {
                _trimPendingLocal[mod] = pct;
                queued = true;
            }
        }
        if (queued) trimApplyTimer.restart();
    }

    function _combineModuleForKey(key) {
        for (var mod in _combineLoopbackSinkByModule)
            if (_trimKeyForSink(_combineLoopbackSinkByModule[mod]) === key) return mod;
        return "";
    }

    // Whether a device already carries a stored balance — the cast side asks
    // before adopting a joining device's current loudness as its balance.
    function hasTrim(id) {
        return _deviceTrims[id] !== undefined;
    }

    // Adopt a joining network device's measured loudness as its balance:
    // its level / master ratio, stored only when no balance exists (a
    // remembered choice — or one set during the read's round-trip — always
    // wins) and only when it differs meaningfully from full level.
    function adoptTrim(key, factor) {
        if (_deviceTrims[key] !== undefined) return;
        var f = Math.max(0.05, Math.min(1, Math.round(factor * 100) / 100));
        if (f >= 0.995) return;
        var m = {};
        for (var k in _deviceTrims) m[k] = _deviceTrims[k];
        m[key] = f;
        _deviceTrims = m;
        _trimRev++;
        trimsPersistTimer.restart();
    }

    // Description of a local output for the balance rows (falls back to the
    // raw sink name — better than an empty label if the device just left).
    function outputDescription(sinkId) {
        var outs = app.mediaDevs.audioOutputs;
        for (var i = 0; i < outs.length; i++)
            if (String(outs[i].id) === String(sinkId)) return outs[i].description;
        return String(sinkId);
    }

    // ── Combined local output (every speaker in sync) ────────────────────────
    // PipeWire's module-combine-sink plays one stream on several sinks at
    // once with latency compensation: the faster (wired) outputs are delayed
    // to match the slowest (typically Bluetooth, 100–250 ms), so all local
    // speakers play together instead of echoing. Session-scoped by design —
    // the module is unloaded on disable and orphans are swept at startup.
    // Network devices (Cast/DLNA) can NOT join this: they pull the stream
    // themselves and expose no latency control; Cast-to-Cast sync is what
    // Google Home speaker groups are for.
    property bool _combineAvailable: false   // pactl (pipewire-pulse) present?
    // Intent vs acknowledgement: _combineWantActive flips synchronously with
    // the user's toggle; _combineActive only once pactl has confirmed the
    // module. Gating on the ack alone dropped a disable clicked during the
    // load round-trip — the module then landed anyway, routed itself and
    // stayed on against an unchecked box.
    property bool _combineWantActive: false
    property bool _combineActive: false

    // ── Idle teardown ────────────────────────────────────────────────────
    // The combined graph (null-sink, loopback resamplers, a held Bluetooth
    // link) costs real CPU and battery on an old laptop even while nothing
    // plays — per-quantum wakeups that round to zero on a desktop are a
    // constant 1-3% there, and the audio devices never suspend. After long
    // idleness the graph is taken down THROUGH the normal disable road
    // (fromTeardown=true keeps combineWanted); the next play — a click, a
    // heal replay, a wake-up alarm — brings it back through the normal
    // enable road, sound flowing on the restored default sink meanwhile.
    property bool _combineIdleParked: false
    readonly property bool _appPlaying: app.anythingPlaying === true

    Timer {
        id: idleTeardownTimer
        interval: 15 * 60 * 1000
        repeat: false
        onTriggered: _idleTeardownTick()
    }

    // True from the park's disable dispatch until its PW_UNCOMBINE_DONE ack
    // lands — a wake inside that window would race the unload shell for the
    // default sink and the remembered master level, so it queues instead.
    property bool _combineParkTail: false
    property bool _combineWakeQueued: false
    // True while the enable's volume ramp is walking the master upward.
    property bool _combineRamping: false

    Timer {
        id: rampGuard
        // The ramp is fire-and-forget; if its ack is lost the flag would
        // suppress the master memory forever. Its own steps take under a
        // second — this only ever fires when something ate the answer.
        interval: 8000
        repeat: false
        onTriggered: _combineRamping = false
    }

    function _idleTeardownTick() {
        if (!_combineActive || cfg.combineWanted !== true) return;
        if (_appPlaying) return;
        // Never park under a measurement, a mid-cure watchdog, a kick or an
        // in-flight loopback rebuild — each owns audio state the disable
        // road would fight over (a surviving PW_RELOOP shell would attach
        // fresh loopbacks to whatever became the default source).
        if (_calibrating || _verifyPending || _btKickInFlight
            || _btJoinWatchMac !== "" || _combineReloopBusy) {
            idleTeardownTimer.restart();
            return;
        }
        console.log("[ARP] sync: idle — parking the combined graph");
        _combineIdleParked = true;
        _combineParkTail = true;
        parkTailGuard.restart();
        combineOutputsDisable(true);
    }

    Timer {
        id: parkTailGuard
        // The tail flag is cleared by the unload's ack — and ONLY by it. An
        // ack that never comes (a wedged pactl, a shell that died with its
        // session) left the flag standing, and from then on every wake was
        // queued behind an event already in the past: sound returned and the
        // speakers stayed dark for the rest of the session. Generous enough
        // that a slow-but-honest unload always wins the race.
        interval: 15000
        repeat: false
        onTriggered: {
            if (!_combineParkTail) return;
            console.log("[ARP] sync: park tail never acked — releasing the wake");
            _combineParkTail = false;
            if (_combineWakeQueued && _combineIdleParked
                && cfg.combineWanted === true && !_combineActive && !_combineWantActive
                && _appPlaying)
                _combineWakeFromPark();
            else _combineWakeQueued = false;
        }
    }

    function _combineWakeFromPark() {
        _combineIdleParked = false;
        _combineWakeQueued = false;
        console.log("[ARP] sync: sound is back — waking the combined graph");
        // Same insurance the startup probe carries: if the enable no-ops on
        // a thin device list (the Bluetooth speaker auto-powered off during
        // the park), the resurrect knocks retry it as sinks reappear —
        // otherwise the graph stayed down for the whole session with the
        // wish still set.
        _resurrectTries = 6;
        combineOutputsEnable();
    }

    on_AppPlayingChanged: {
        if (_appPlaying) {
            idleTeardownTimer.stop();
            if (_combineIdleParked && cfg.combineWanted === true && !_combineActive
                && !_combineWantActive) {
                // Inside the park-disable's async tail the unload shell is
                // still running — queue the wake for its ack instead of
                // racing it for the default sink and the master memory.
                if (_combineParkTail) _combineWakeQueued = true;
                else _combineWakeFromPark();
            }
        } else if (_combineActive && cfg.combineWanted === true) {
            idleTeardownTimer.restart();
        }
    }

    on_CombineActiveChanged: {
        if (_combineActive) {
            _combineIdleParked = false;
            if (!_appPlaying) idleTeardownTimer.restart();
        } else {
            idleTeardownTimer.stop();
        }
    }
    property string _combineNullId: ""
    property var _combineLoopbackIds: []
    property string _combineSinksSnapshot: ""
    property bool _combinePendingRoute: false
    // The specific output that was selected before combining, so switching
    // the sync mode off restores it instead of dumping to the default.
    property string _combinePrevOutput: ""
    // The sink that was the system default before the sync took it over —
    // restored on disable, and from config after a crash.
    property string _combinePrevDefault: ""
    // Per-instance suffix (the stable applet id, same as MPRIS uses): the
    // startup sweep may only reclaim THIS instance's orphans — a second
    // widget or a plasmoidviewer run must not tear down a live combine.
    readonly property string _combineSinkName: "onair_combined_" + app.instanceId

    // Only real hardware ends. Virtual sinks (an equalizer's effect input,
    // other apps' null sinks) either double the audio through their own
    // output path — audible phasing no delay can ever fix — or lead nowhere.
    // This is the FULL candidate list; the group itself (_combineRealSinks)
    // additionally honors the user's per-speaker in/out choice. The UI lists
    // from here so an excluded speaker keeps its row — otherwise there would
    // be no way to bring it back.
    function _combineAllSinks() {
        var outs = app.mediaDevs.audioOutputs;
        var res = [];
        for (var i = 0; i < outs.length; i++) {
            var oid = String(outs[i].id);
            // bluez_output = PipeWire, bluez_sink = plain PulseAudio — the
            // combine must take Bluetooth along on both stacks.
            if (/^(alsa_output|bluez_output|bluez_sink)/.test(oid)
                && oid.indexOf("onair_combined") === -1)
                res.push(oid);
        }
        return res;
    }

    function _combineRealSinks() {
        var all = _combineAllSinks();
        var res = [];
        for (var i = 0; i < all.length; i++)
            if (syncDeviceIncluded(_trimKeyForSink(all[i]))) res.push(all[i]);
        return res;
    }

    // What the loopback set is BUILT from: the group's sinks and each one's
    // channel mode. Anything that changes this signature obsoletes the live
    // loopbacks — compared after device changes AND when an enable's ack
    // lands, because the user can untick a speaker or flip a channel inside
    // the load round-trip and the ack would otherwise adopt a stale build
    // that nothing ever revisits.
    function _combineGroupSignature() {
        var sinks = _combineRealSinks();
        var sig = [];
        for (var i = 0; i < sinks.length; i++)
            sig.push(sinks[i] + ":" + channelOf(_trimKeyForSink(sinks[i])));
        return sig.join("|");
    }

    // ── Per-speaker in/out of the group ─────────────────────────────────────
    // "Everything except the bedroom" is a real evening — a speaker can sit
    // out of the group without disconnecting it. Stored as an EXCLUSION set:
    // absent means in, so a brand-new speaker always joins by default.
    property var _syncExcluded: ({})
    property int _exclRev: 0

    function _loadSyncExcluded() {
        try {
            var m = JSON.parse(cfg.syncExcluded || "{}");
            _syncExcluded = (m && typeof m === "object" && !Array.isArray(m)) ? m : {};
        } catch (e) {
            _syncExcluded = {};
        }
        _exclRev++;
    }

    function syncDeviceIncluded(id) {
        return _syncExcluded[id] !== true;
    }

    function setSyncDeviceIncluded(id, on) {
        var m = {};
        for (var k in _syncExcluded) m[k] = _syncExcluded[k];
        if (on) delete m[id];
        else m[id] = true;
        _syncExcluded = m;
        _exclRev++;
        cfg.syncExcluded = JSON.stringify(m);
        if (_combineActive) syncOffsetDebounce.restart();
    }

    function _btMacOfSink(sinkId) {
        var m = String(sinkId).match(/^bluez_(?:output|sink)\.([0-9A-Fa-f_]{17})/);
        return m ? m[1].replace(/_/g, ":").toUpperCase() : "";
    }

    // The measured/tuned lag of one sink. Bluetooth: its own calibration if
    // the device has one (keyed by MAC — a JBL and AirPods lag differently),
    // the global slider value otherwise. Wired: its own CALIB_XLAG if the
    // calibration heard it (keyed by sink name; may be negative when the
    // sink runs AHEAD of the reference), zero otherwise — the pre-XLAG
    // behaviour.
    // Session-scoped correction on top of the stored calibration: how far
    // the Bluetooth transport's PipeWire-reported latency has moved since
    // the calibration that produced the stored number. A2DP buffering is
    // re-rolled on every transport (re)establishment — measured live: the
    // same speaker 213 ms one session, 2.3 s after a codec switch — and
    // the stored lag is only the opening bid. The probe below reads the
    // report silently (no clicks, no interruption) and the rebuild applies
    // the shift, so "fine yesterday, doubled today" corrects itself.
    property var _refLatShiftByMac: ({})
    // When each speaker last had its compensation acted on — the brake on
    // the flush→re-roll→compensate loop.
    property var _refLatActedAt: ({})
    // A large reading waiting for its confirming twin (mac → ms).
    property var _refLatPending: ({})
    // One drift hint per session — a wandering link must not nag.
    property bool _refLatHintShown: false

    // ── Automatic care (opt-in): the inaudible drift check, and only that ──
    // Every few minutes while music plays, calibrate.py plays its inaudible
    // sweep into each member of ONE recording and reads where they land —
    // nothing audible, nothing stored, nothing leaves the machine. Two
    // checks that agree correct the map quietly.
    //
    // It used to arm ONE automatic verify as well, and that verify parks the
    // music, mutes the speakers in turn and takes about a minute. It is gone.
    // Automatic is fine as long as it is silent; two minutes of dead air in
    // the middle of a song is not something a widget gets to decide for the
    // person listening. When the quiet road cannot fix it, it says so and the
    // listener presses the button.
    // No flag gates an automatic verify any more, because there is no
    // automatic verify: the loud road is the listener's to start.
    property bool _driftHintShown: false
    // Consecutive in-step readings. Re-arming the drift toast took ONE,
    // and one is exactly as cheap as one flyer: a room sitting near the
    // 25 ms line crossed it both ways all evening (scatter is sd 21 ms)
    // and every downward crossing opened a fresh "spell" for the next
    // upward one to toast about. Two in a row is a room that is back,
    // not a reading that wobbled.
    property int _driftCalmStreak: 0
    // The caretaker's last word, for the popup — silence would read as
    // "is this thing even on?", and trust needs a heartbeat.
    property string driftLastText: ""

    Timer {
        id: driftMonitorTimer
        // Six minutes on the wall, twelve on battery: the probe is cheap
        // but not free, and on a laptop the group is usually one speaker
        // that was just calibrated anyway.
        interval: (app.thrifty === true ? 12 : 6) * 60 * 1000
        repeat: true
        running: cfg.syncAutoCare === true && cfg.syncManualOnly !== true
                 && _combineActive
                 && app.anythingPlaying === true
                 && _combineHasBtMember()
        onTriggered: _driftProbe()
        // The first heartbeat comes early: 45 s into the music the fade-in
        // is long over and the listener gets a "yes, it is running" line
        // without waiting out the full period.
        // The running condition above reads the device list, and that list is
        // rebuilt on every refresh — so this signal fires far more often than
        // a speaker actually joining or music actually starting. Restarting
        // the early check on each one turned "a probe every six minutes" into
        // probes 33 to 104 s apart (measured live), and every probe opens a
        // stream on each member: that is what was breaking up the audio.
        // One early check per settled stretch, not one per flicker.
        onRunningChanged: {
            if (!running) { driftFirstCheck.stop(); return; }
            if (Date.now() - _lastDriftProbeMs < 5 * 60 * 1000) return;
            driftFirstCheck.restart();
        }
    }

    Timer {
        id: driftFirstCheck
        // 45 s when the check arms itself (music started, the speaker
        // joined): no one is watching, and on the passive fallback road a
        // fade-in would be measured as "too quiet". 2 s when the user just
        // ticked the box — then someone IS watching, and the sweep plays
        // its own signal, so the music's level stops mattering.
        interval: _autoCareJustArmed ? 2000 : 45000
        repeat: false
        onTriggered: {
            _autoCareJustArmed = false;
            _driftProbe();
        }
    }

    // Set by the checkbox itself, not inferred from the config value: the
    // same value turns true when a saved setting loads at startup, and
    // that is not someone waiting at the popup for an answer.
    property bool _autoCareJustArmed: false
    // When a probe last really went out. The early check reads this so a
    // flickering device list cannot turn it into a second poll timer.
    property double _lastDriftProbeMs: 0

    // Tests only: whether the periodic check is actually armed. The timer's
    // running condition carries four gates and asserting on the flags one
    // by one would not prove the timer agreed with them.
    function _driftTimerRunningForTest() { return driftMonitorTimer.running; }

    function noteAutoCareEnabled() {
        _autoCareJustArmed = true;
        // A deliberate tick outranks the quiet period above — the person is
        // standing at the popup waiting for an answer.
        _lastDriftProbeMs = 0;
        // Something in the line immediately, because a checkbox that
        // answers in six minutes reads as a checkbox that does nothing.
        driftLastText = i18n("Auto-check: listening…");
        if (driftMonitorTimer.running) driftFirstCheck.restart();
    }

    // Drift needs a Bluetooth ear to happen to: wired members resample
    // against the graph's own clock, while a BT link buffers behind a clock
    // of its own — that wander is what the passive check exists to catch.
    // Without a BT member in the group the capture could only ever confirm
    // silence, so the microphone stays untouched.
    function _combineHasBtMember() {
        var s = _combineRealSinks();
        for (var i = 0; i < s.length; i++)
            if (_btMacOfSink(s[i]) !== "") return true;
        return false;
    }

    function _driftProbe() {
        // Never over a measurement, a recovery cure, a recording or an
        // alarm — the check must be invisible, in every sense. And never
        // without a BT member (the timer gate, re-checked here in case the
        // speaker left between the arm and the tick).
        if (_calibrating || _verifyPending || _combineReloopBusy
            || _btKickInFlight || app.recording === true
            || app.alarmEngaged === true) return;
        if (!_combineHasBtMember()) return;
        if (cfg.syncManualOnly === true) return;
        _lastDriftProbeMs = Date.now();
        console.log("[ARP] sync: auto-care listening (periodic drift check)");
        // What each member is credited with, spelled out. A check that
        // reported 151 ms on a room whose RAW spread is 158 had to have
        // given every member the same delay — which taken away leaves the
        // bare hardware difference and reads as a room in ruins. If two
        // members show the same number below, that is the bug, visible at
        // a glance instead of inferred from an arithmetic coincidence.
        var dDbg = _combineRealSinks();
        var dSay = [];
        for (var dd = 0; dd < dDbg.length; dd++)
            dSay.push(outputDescription(dDbg[dd]).substring(0, 18)
                      + "=" + Math.round(_deployedDelayMs(dDbg[dd], dDbg)) + "ms"
                      + "(lag " + Math.round(_lagForSink(dDbg[dd])) + ")");
        console.log("[ARP] sync: delays credited — " + dSay.join(", "));
        var script = Qt.resolvedUrl("calibrate.py").toString().substring(7).replace(/'/g, "'\\''");
        // Each member is named so the sweep can measure it one at a time,
        // and each goes out with the delay it is ALREADY being played with.
        // That second half is not decoration: the sweep is aimed straight
        // at the member sink and so goes round the loopback carrying the
        // compensation, timing the bare hardware. Take those arrivals at
        // face value and a room in perfect tune reports the whole spread
        // the calibration exists to cancel — measured here, 1 ms of real
        // error read as 299 — and the caretaker sets an automatic re-verify
        // going every six minutes forever.
        var dAll = _combineRealSinks();
        // Anything already proved deaf to the band is left alone: playing
        // into it can only cost a relay click and a wasted capture.
        var dMembers = [];
        for (var dk = 0; dk < dAll.length; dk++)
            if (!_ultraDeaf[dAll[dk]]) dMembers.push(dAll[dk]);
        if (dMembers.length < 2) {
            // Putting the deaf ones back was the whole promise undone. In a
            // two-speaker room — the ordinary case — one deaf member leaves
            // one that can hear, and this line handed the sweep straight
            // back to the speaker just proved unable to carry it. Measured
            // on this desk: the same JBL was re-learned as deaf at 17:17,
            // 17:18 and 17:37, so it was being played into on every check,
            // and an 18 kHz sweep pushed through a codec that cannot hold
            // it is exactly where an audible artefact comes from. That is
            // the beeping that kept arriving with the radio playing.
            // Nothing measurable left means nothing to play: say so.
            console.log("[ARP] sync: fewer than two members carry the"
                        + " inaudible band — nothing to compare, not playing");
            driftLastText = i18n("Auto-check %1: only one speaker can hear the inaudible tone — nothing to compare",
                                 Qt.formatTime(new Date(), "hh:mm"));
            return;
        }
        var dArgv = "";
        for (var di = 0; di < dMembers.length && di < 8; di++)
            // The delay comes from the WHOLE group, not the measured subset:
            // the schedule's floor is set by the slowest device in the room,
            // deaf or not.
            dArgv += " '" + String(dMembers[di]).replace(/'/g, "'\\''") + "'"
                   + " " + Math.round(_deployedDelayMs(dMembers[di], dAll));
        // Eight is the verify's ceiling too. A bigger group takes the
        // passive road rather than running past its leash halfway through
        // and reporting nothing — said out loud, because a check that
        // quietly measures less than it claims is worse than one that fails.
        if (dMembers.length > 8) {
            dArgv = "";
            console.log("[ARP] sync: " + dMembers.length + " speakers is past the"
                        + " sweep's limit of 8 — using the passive check");
        }
        // Warm-up capture plus one per member, each a 3.2 s recording with
        // its play and analysis around it — measured at about 8 s a head.
        // The passive road needs only its own 8 s window, so this budget
        // covers both roads with the fallback still inside it.
        var dBudget = 14 + Math.min(8, dMembers.length) * 8;
        // The word in the popup gets the same budget as the probe. A shell
        // that dies with its leash, or an ack lost across a plasmashell
        // restart, used to leave "listening…" standing as the last thing the
        // check ever said — indistinguishable from one that hung.
        driftLastText = i18n("Auto-check: listening…");
        // A fresh launch measures the room as it stands now. If the LAST
        // probe was marked stale and its answer never came back (guard
        // timeout), the mark must not carry over and eat this one's.
        _driftProbeStale = false;
        driftGuardTimer.interval = (dBudget + 15) * 1000;
        driftGuardTimer.restart();
        app.exec(": PW_DRIFT;" + _ultraEnv()
                 + _calibRunCmd(dBudget, script,
                                " drift " + _combineSinkName + " " + _micArg() + dArgv,
                                _driftPidFile)
                 + " true # " + app.nextSeq());
    }

    Timer {
        id: driftGuardTimer
        repeat: false
        onTriggered: {
            driftLastText = i18n("Auto-check %1: no answer came back",
                                 Qt.formatTime(new Date(), "hh:mm"));
        }
    }

    function _lagForSink(sinkId) {
        var mac = _btMacOfSink(sinkId);
        try {
            var map = JSON.parse(cfg.syncOffsetMap || "{}");
            if (mac !== "") {
                if (map[mac] !== undefined)
                    return Math.max(0, Math.min(2000, (parseInt(map[mac], 10) || 0)
                                                      + (_refLatShiftByMac[mac] || 0)));
            } else if (map[sinkId] !== undefined) {
                var w = parseInt(map[sinkId], 10);
                // The verify loop's corrections may push past the direct
                // calibration's own 900 ms sanity window — a through-path
                // lag includes loopback buffering the direct click never saw.
                if (isFinite(w)) return Math.max(-100, Math.min(2000, w));
            }
        } catch (e) {}
        return mac !== ""
               ? Math.max(0, Math.min(2000, (cfg.syncOffsetMs || 0)
                                            + (_refLatShiftByMac[mac] || 0)))
               : 0;
    }

    // What each speaker is ACTUALLY delayed by, when that has drifted away
    // from the fine-tune slider's number. The slider shows the seed the
    // user set; every automatic correction lands in the per-device map
    // instead, so a room the caretaker has been quietly retuning for a week
    // still showed the original number and nothing else. Empty string when
    // the two agree — no line is better than a line that says nothing.
    function autoTunedSummary() {
        var s = _combineRealSinks();
        var seed = cfg.syncOffsetMs || 0;
        var out = [];
        for (var i = 0; i < s.length; i++) {
            if (_btMacOfSink(s[i]) === "") continue;
            var lag = _lagForSink(s[i]);
            // Under 5 ms is the map agreeing with the slider, not a tune.
            if (Math.abs(lag - seed) < 5) continue;
            out.push(i18n("%1: %2 ms", outputDescription(s[i]), lag));
        }
        return out.join("  ·  ");
    }

    // Read one Bluetooth sink's PipeWire-reported latency. forCalib stores
    // it as the calibration-time REFERENCE; otherwise the ack compares the
    // reading against the reference and arms a corrective rebuild when the
    // transport has genuinely moved. Silent — no clicks, no interruption.
    function _refLatProbe(mac, forCalib) {
        if (!app._btValidMac(mac)) return;
        var macU = mac.replace(/:/g, "_");
        // pactl shows "Latency: 0" for a RUNNING bluez sink (measured live
        // on this very hardware — the whole mechanism was silently inert on
        // it). The truth lives in the NODE's SPA Latency param (minNs),
        // which only pw-dump serves; printed in µs so the ack's µs→ms
        // handler stays as it is. Plain-PulseAudio systems have no pw-dump:
        // no REFLAT line, and the recompensation stays politely inert.
        var py = 'import json,sys;'
               + 'd=json.load(sys.stdin);'
               + 'o=[x for x in d if ((x.get("info") or {}).get("props") or {})'
               + '.get("node.name","").startswith("bluez_output.' + macU + '")];'
               + 'i=(o[0].get("info") or {}) if o else {};'
               + 'L=((i.get("params") or {}).get("Latency") or []);'
               + 'ns=(L[0].get("minNs") if L else 0) or 0;'
               + 'print("REFLAT",int(ns/1000)) if ns else None';
        app.exec(": PW_REFLAT " + (forCalib ? "C" : "S") + " " + mac + "; "
                 + "pw-dump 2>/dev/null | python3 -c '" + py + "' 2>/dev/null; true # " + app.nextSeq());
    }

    // A beat after a rebuild/transport event, ask every Bluetooth member
    // for its current report — immediately after the event the transport
    // may not be up yet and the reading would simply be absent.
    Timer {
        id: refLatProbeTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (!_combineActive) return;
            var rs = _combineRealSinks();
            for (var i = 0; i < rs.length; i++) {
                var m = _btMacOfSink(rs[i]);
                if (m !== "") _refLatProbe(m, false);
            }
        }
    }

    // One loopback per hardware sink, each with a REAL buffer delay
    // (latency_msec) — deterministic, unlike latency compensation that
    // trusts what a Bluetooth box claims about itself. Every sink is held
    // back to the SLOWEST device's schedule: wired outputs wait the full
    // worst lag, a faster Bluetooth device waits the difference. Stereo is
    // pinned.
    function _combineLoopbackCmds(sinks) {
        // No anchoring here either, and the reason is the OPPOSITE of the
        // fold's: a rebuild sees only the members connected right now, and
        // anchoring that subset rewrites their entries against a floor the
        // absent member never agreed to — a Bluetooth speaker walking out
        // of range for one rebuild would come back to a map whose frame
        // moved under it. The map's floor drifts back to zero at the next
        // write that anchors with the full group present (calibration,
        // slider, verify); until then a non-zero floor costs nothing,
        // because only differences ever reach a speaker.
        // EVERY sink carries its measured lag now — Bluetooth from its MAC
        // calibration (or the slider), wired from its CALIB_XLAG (or the
        // assumed zero it always had). The slowest device sets the schedule
        // and everyone else waits the difference; a negative wired lag (the
        // sink runs ahead) simply earns it more delay.
        var maxLag = 0;
        var lags = {};
        for (var j = 0; j < sinks.length; j++) {
            lags[sinks[j]] = _lagForSink(sinks[j]);
            if (lags[sinks[j]] > maxLag) maxLag = lags[sinks[j]];
        }
        // Remember what is going out, because the map and the room stop
        // agreeing the moment a quiet fold writes one and leaves the other.
        var bl = {}, blChanged = false;
        for (var bk in _builtLags) bl[bk] = _builtLags[bk];
        for (var bj = 0; bj < sinks.length; bj++) {
            if (bl[sinks[bj]] !== undefined && bl[sinks[bj]] !== lags[sinks[bj]])
                blChanged = true;
            bl[sinks[bj]] = lags[sinks[bj]];
        }
        _builtLags = bl;
        // Accreted exactly like _builtLags above, never rebuilt from the
        // current sinks alone: a member absent for one rebuild keeps its
        // _builtLags entry, so it must keep the shift that entry was baked
        // with — wiping one side of the pair hands the fold a deployed
        // number whose shift it can no longer see, and the whole shift
        // walks into the map on the next fold after a leave-and-rejoin.
        var bsh = {};
        for (var bso in _builtShiftByMac) bsh[bso] = _builtShiftByMac[bso];
        for (var bsi = 0; bsi < sinks.length; bsi++) {
            var bsm = _btMacOfSink(sinks[bsi]);
            if (bsm !== "") bsh[bsm] = _refLatShiftByMac[bsm] || 0;
        }
        _builtShiftByMac = bsh;
        // THIS is the moment a pending correction actually reaches the room
        // — a fold, the slider, a calibration, whoever wrote the map. The
        // drift bookkeeping resets HERE and not where the map was written:
        // everything measured before this line describes the previous room,
        // and the first probe after a reload reads the Bluetooth re-roll,
        // not the drift. Resetting at fold time instead left the history
        // primed to re-confirm a correction that had not landed yet, and
        // one calibration mid-history had its fix folded right back out.
        if (blChanged) {
            _driftSkipNext = true;
            _driftHistory = [];
            _driftHistoryAt = [];
            _driftEstHistory = [];
            // The guard timer runs exactly while a probe is out. That probe
            // was launched at the room this rebuild just replaced.
            if (driftGuardTimer.running) _driftProbeStale = true;
        }
        var cmds = "";
        for (var i = 0; i < sinks.length; i++) {
            var s = sinks[i].replace(/'/g, "'\\''");
            var d = _loopbackFloorMs + (maxLag - lags[sinks[i]]);
            // The sink rides along in the echo so the handler can pair module
            // ids with sinks for the balance — /LB (\d+)/ readers are
            // unaffected. The balance itself is baked in right here, in the
            // same shell round, so every (re)build restores it atomically.
            // EXISTENCE GATE, learned the hard way: loading a loopback whose
            // sink is not registered yet (a Bluetooth speaker mid-connect)
            // does NOT fail — pactl attaches it to the DEFAULT sink, which is
            // now the combined sink itself: a silent feedback loop, and the
            // speaker plays nothing. Skip it, report LBMISS, and the retry
            // pass picks it up once the sink is really there.
            // The speaker's channel mode lives in the loopback's own map:
            // a single explicit position takes exactly that source channel,
            // mono is the equal downmix, stereo the plain 2ch pass.
            var chMode = channelOf(_trimKeyForSink(sinks[i]));
            var chSpec = chMode === "L" ? "channels=1 channel_map=front-left"
                       : chMode === "R" ? "channels=1 channel_map=front-right"
                       : chMode === "M" ? "channels=1 channel_map=mono"
                       : "channels=2";
            cmds += "if pactl list short sinks 2>/dev/null | cut -f2 | grep -Fxq '" + s + "'; then "
                 + "id=$(pactl load-module module-loopback source=" + _combineSinkName + ".monitor"
                 + " sink='" + s + "' latency_msec=" + d + " " + chSpec + ") && echo \"LB $id " + s + "\"";
            var pct = Math.round(trimOf(_trimKeyForSink(sinks[i])) * 100);
            // Semicolons, not &&: the trim group returns nonzero when the
            // sink-input has not registered yet (async), and an && chain
            // then SKIPPED the birth flush on exactly the trimmed Bluetooth
            // speaker that needed it.
            if (pct < 100) cmds += "; { " + _sinkInputVolCmd("$id", pct) + "true; }";
            // Flush at birth, Bluetooth only: a loopback attached to a sink
            // that is still settling (a speaker that just connected, a codec
            // switch recreating the node) starts with a backlog it can NEVER
            // drain — measured live at 2.3 seconds of permanent echo. The
            // beat of sleep lets the attach actually land first; flushing
            // in the same breath as load-module raced the stream's birth.
            if (sinks[i].indexOf("bluez_") === 0)
                cmds += "; [ -n \"$id\" ] && { sleep 1.2;"
                     + " pactl suspend-sink '" + s + "' 1;"
                     + " pactl suspend-sink '" + s + "' 0; }";
            cmds += "; else echo \"LBMISS " + s + "\"; fi; ";
        }
        return cmds;
    }

    // The levels a measurement parked and has not put back yet. Written the
    // moment they are read, deleted by the same shell after the restore —
    // so its EXISTENCE is the honest answer to "is the room still parked?",
    // true across a cancel, a guard expiry and a dead session alike.
    readonly property string _parkFile:
        "\"$XDG_RUNTIME_DIR/onair_park_" + app.instanceId + ".sh\""

    // Where a running measurement writes down the pid a cancel must kill.
    // XDG_RUNTIME_DIR only (0700, ours), per-instance: two widgets on one
    // desktop each own their own run and neither may stop the other's.
    readonly property string _calibPidFile:
        "\"$XDG_RUNTIME_DIR/onair_calib_" + app.instanceId + ".pid\""
    // The periodic probe writes its own name. It used to share the file
    // above, and then a calibration started while a probe was in flight had
    // its pid overwritten and, seconds later, deleted by the probe's own
    // cleanup — leaving Cancel with nothing to kill while the clicks kept
    // coming for the rest of the python's leash. Two runs, two files.
    readonly property string _driftPidFile:
        "\"$XDG_RUNTIME_DIR/onair_drift_" + app.instanceId + ".pid\""

    // The one way calibrate.py is launched. The python goes to the
    // BACKGROUND so its pid can be written down, and the shell then waits
    // for it exactly as if it had run in front — the restore lines that
    // follow are unchanged and still only reachable through this wait.
    // Why the bookkeeping: cancelling used to `pgrep -f 'python3
    // .*calibrate\.py'`, which matches the sh and the timeout wrappers too
    // (their command line CARRIES that text), so the cancel killed the very
    // shell holding the saved sink levels and left the room parked at 55%
    // with the loopbacks at full. Measured on this machine: killing the
    // timeout pid alone ends the python (wait → 143) and the shell runs its
    // restore to the end.
    // ONAIR_LEASH_PID is this shell's own pid: the script watches it and
    // ends itself when the session that asked for the measurement is gone.
    // Its old test (getppid()==1) could never fire — `timeout` sits between
    // the two, so the shell is what gets reparented, never the python.
    function _calibRunCmd(budgetSec, script, argvStr, pidFile) {
        var f = pidFile || _calibPidFile;
        return " ONAIR_LEASH_PID=$$ timeout " + budgetSec + " python3 '" + script + "'" + argvStr + " &"
             + " cp=$!;"
             + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then echo \"$cp\" > " + f + "; fi;"
             + " wait \"$cp\";"
             + " if [ -n \"$XDG_RUNTIME_DIR\" ]; then rm -f " + f + "; fi;";
    }

    // Whether the calibration has both of its reference speakers IN the
    // group — the button grays out instead of silently doing nothing when
    // the only Bluetooth (or only wired) speaker was ticked out.
    // The hand on the emergency brake: end a running calibration or verify
    // NOW — clicks stop mattering, every speaker unmutes, the parked stream
    // comes back. Same cancel the disable performs, without touching the
    // sync's on/off state; the generation bump makes the run's in-flight
    // shell ack stale, and the shell's own in-line restore still puts the
    // parked sink levels back when it finally exits.
    // The remembered microphone as a shell word, always quoted, always
    // safe: a device name is machine text but it still reaches a command
    // line, and '' means "you decide" to the script.
    // The inaudible sweep is a setting, and calibrate.py reads it from the
    // environment rather than argv so that all three commands (calibrate,
    // verify, drift) obey one switch without three argument parsers. Placed
    // AFTER the sentinel by every caller — the sync dispatcher matches on
    // the command's opening ": PW_x;" and anything in front of it orphans
    // the handler.
    // Every loopback gets at least this much, so the schedule has room to
    // hold the fast devices back rather than trying to rush the slow one.
    readonly property int _loopbackFloorMs: 60

    // Sinks that came back with an empty 18-19 kHz band. Kept for the
    // session only: a speaker replugged into a live jack, or a group the
    // user rebuilds, deserves a fresh hearing — _combineRebuildLoopbacks
    // clears this for exactly that reason.
    property var _ultraDeaf: ({})
    // The group the deaf list belongs to. Anything else about the build may
    // change without reopening the question.
    property string _ultraDeafSig: ""

    // Slide the group's stored lags so the smallest of them is zero.
    //
    // Nothing a speaker HEARS changes: _combineLoopbackCmds turns lags into
    // delays by subtracting each from the group's maximum, so the whole set
    // can move up or down together without shifting a single millisecond of
    // sound. What does change is that the numbers stay attached to
    // something. The verify's correction can only ADD — its residuals are
    // measured against the earliest arrival and are never negative — so
    // without an anchor the set walks upward forever: this room's slider
    // went 145, then 214, then 267 while the sound stayed exactly where it
    // was. Far enough up and the 2000 ms clamp in _lagForSink starts biting
    // the differences too, at which point the walk stops being cosmetic.
    //
    // A member with no entry counts as the zero it already reads as
    // everywhere else, which means a healthy frame (someone sitting at
    // zero) is left completely alone — this only moves a set that has
    // drifted off its anchor as a whole.
    //
    // Only the CURRENT group is touched. A lag stored for a speaker that is
    // not here was measured in its own group's frame and is not ours to
    // shift.
    function _anchorLags(map, sinks) {
        if (!sinks || sinks.length === 0) return map;
        var keys = [], lo = null;
        for (var i = 0; i < sinks.length; i++) {
            var k = _btMacOfSink(sinks[i]) || sinks[i];
            var v = parseInt(map[k], 10);
            if (!isFinite(v)) {
                // A member with no entry is NOT a member at zero. That is
                // what _lagForSink says: a Bluetooth sink with no entry
                // deploys the global offset, a wired one deploys nothing.
                // Reading the absence as zero made this function fabricate
                // an entry that wiped the offset the speaker was actually
                // playing with — bench with map {DAC:-60}, offset 250 and an
                // entry-less Bluetooth member: the pair went from 250 ms
                // apart to 0. It also planted the spurious zeros that made
                // the early-out below fire on nearly every run, which is why
                // the map has been free to inflate for so long.
                v = _btMacOfSink(sinks[i]) !== "" ? (cfg.syncOffsetMs || 0) : 0;
            }
            keys.push({ k: k, v: v });
            if (lo === null || v < lo) lo = v;
        }
        if (lo === null || lo === 0) return map;   // already anchored
        for (var j = 0; j < keys.length; j++)
            map[keys[j].k] = keys[j].v - lo;
        return map;
    }

    // The delay a member is ACTUALLY played with. This is NOT its stored
    // lag: the slowest device sets the schedule and gets the floor, and
    // everyone faster waits out the difference. Getting this wrong is easy
    // and silent — the drift probe first passed the stored lag, and on this
    // desk that turned a room 13 ms out (which is in tune) into 299 ms.
    // _combineRebuild builds the loopbacks from the same formula and a test
    // pins the two together.
    // What the loopbacks were LAST BUILT with, per sink. The map is where a
    // correction is written; this is what the room is actually hearing, and
    // between a quiet fold and the next rebuild the two differ on purpose.
    property var _builtLags: ({})

    // The transport shift each Bluetooth member was BUILT with, keyed by
    // MAC. A shift can be recorded while a reloop is mid-flight, and until
    // the next rebuild lands the loopbacks carry the old one — the fold's
    // frame conversion has to subtract what the room is actually playing
    // with, not what the ledger says now, or an undeployed 400 ms re-roll
    // reaches the map at full weight through the subtraction.
    property var _builtShiftByMac: ({})

    // What the map says this speaker SHOULD be played with. The slider and
    // the anchor reason in these terms, and for them the map is the truth.
    function _appliedDelayMs(sink, sinks) {
        var maxLag = 0;
        for (var j = 0; j < sinks.length; j++)
            maxLag = Math.max(maxLag, _lagForSink(sinks[j]));
        return _loopbackFloorMs + (maxLag - _lagForSink(sink));
    }

    // What this speaker is ACTUALLY being played with, which is what the
    // check has to add back. The two part company on purpose: a quiet fold
    // writes the map and leaves the loopbacks alone until a rebuild that
    // costs the listener nothing.
    //
    // Crediting the map instead is a feedback loop, and it ran: on
    // 2026-08-01 the map walked 207 -> 173 -> 150 while every loopback still
    // carried 207. Each fold's own step came back to the next check looking
    // like fresh drift in the same direction and earned another fold. The
    // room never moved; only the number did.
    function _deployedDelayMs(sink, sinks) {
        var maxLag = 0, known = _builtLags[sink] !== undefined;
        for (var j = 0; j < sinks.length && known; j++) {
            if (_builtLags[sinks[j]] === undefined) known = false;
            else maxLag = Math.max(maxLag, _builtLags[sinks[j]]);
        }
        // Nothing built yet — the map is the only thing there is to go on.
        return known ? _loopbackFloorMs + (maxLag - _builtLags[sink])
                     : _appliedDelayMs(sink, sinks);
    }

    // The lag this MAC's member is actually playing with, or -1 when
    // nothing is deployed for it. The fold and the popup's suggestion
    // reason from here for the same reason the probe credits
    // _deployedDelayMs: between a fold and the rebuild that lands it, the
    // map is a promise and the loopbacks are the room.
    function _deployedLagForMac(mac) {
        var s = _combineRealSinks();
        for (var i = 0; i < s.length; i++)
            if (_btMacOfSink(s[i]) === mac && _builtLags[s[i]] !== undefined)
                return _builtLags[s[i]];
        return -1;
    }

    function _ultraEnv() {
        return cfg.syncUltrasonic === false ? " export ONAIR_NO_ULTRA=1;" : "";
    }

    function _micArg() {
        var m = String(cfg.syncMicName || "");
        if (!/^[A-Za-z0-9._:+-]{1,200}$/.test(m)) return "''";
        return "'" + m + "'";
    }

    // Every road that calls a measurement off, in one place. Four of them
    // exist — the user's own button, the disable, the resurrect and the two
    // guard timers — and only the button used to end the PROCESS: the others
    // cleared the flags and left the python clicking and muting into a room
    // that was being torn down under it, while every busy-gate read idle.
    // rebuildToo: the disable is about to rebuild everything anyway, so it
    // does not want the held rebuild released a moment before the teardown.
    function _calibAbort(rebuildToo) {
        _calibrating = false;
        _verifyPending = false;
        _verifyCorrected = false;
        _verifyProposal = null;
        _verifyMutedSaid = ({});
        calibGuardTimer.stop();
        verifySettleTimer.stop();
        verifyGuardTimer.stop();
        _verifyUnmuteAll();
        _calibRestoreVolume();
        // The cancelled run's shell is still out there and its ack still
        // carries the CURRENT generation — without a bump it would pass the
        // staleness gate minutes later and act on a group that no longer
        // exists: a CALIB_OK arming the verify against nothing, or a 'no
        // click heard' launching an unasked-for 85% run over the music.
        _calibRunSeq++;
        if (rebuildToo && _rebuildHeld) { _rebuildHeld = false; _combineRebuildLoopbacks(); }
        else _rebuildHeld = false;
        // By pid, from the run's own file: OUR run, not every calibrate.py
        // this user happens to have, and not the shell that still owes the
        // room its volume restore. A missing or unreadable file is a no-op,
        // which is what makes this safe to call from every road.
        app.exec(": PW_CALIBKILL; f=" + _calibPidFile + ";"
                 + " if [ -n \"$XDG_RUNTIME_DIR\" ] && [ -r \"$f\" ]; then"
                 + " p=$(cat \"$f\" 2>/dev/null);"
                 + " case \"$p\" in ''|*[!0-9]*) ;; *) kill \"$p\" 2>/dev/null;; esac;"
                 + " fi; true # " + app.nextSeq());
    }

    // The drift probe writes its pid and, until now, nobody ever read it
    // back: there was no road at all that could stop a probe already
    // sweeping. Unticking the caretaker therefore left it playing for the
    // rest of its budget — up to 78 s of tones after the switch said stop.
    function _driftKill() {
        driftGuardTimer.stop();
        driftLastText = "";
        app.exec(": PW_DRIFTKILL; f=" + _driftPidFile + ";"
                 + " if [ -n \"$XDG_RUNTIME_DIR\" ] && [ -r \"$f\" ]; then"
                 + " p=$(cat \"$f\" 2>/dev/null);"
                 + " case \"$p\" in ''|*[!0-9]*) ;; *) kill \"$p\" 2>/dev/null;; esac;"
                 + " fi; true # " + app.nextSeq());
    }

    function calibrateCancel() {
        if (!_calibrating && !_verifyPending) return;
        _calibAbort(true);
    }

    function calibPairReady() {
        void _exclRev;
        var sinks = _combineRealSinks();
        var wired = false, bt = false;
        for (var i = 0; i < sinks.length; i++) {
            if (sinks[i].indexOf("bluez_") === 0) bt = true;
            else wired = true;
        }
        return wired && bt;
    }

    // ── Microphone auto-calibration ──────────────────────────────────────────
    // calibrate.py plays clicks through the wired reference and the Bluetooth
    // speaker and times, with the microphone, when each actually arrives —
    // the difference IS the lag, no ears needed. Volumes are raised for the
    // clicks (a too-quiet speaker measures as silence) and restored after.
    property bool _calibrating: false
    // Stream volume to put back after calibration (-1 = nothing to restore).
    property real _calibVolumeBefore: -1
    // Set only when the AUTOMATIC caretaker parks the stream (manual calibrate
    // shows its own UI): announces the silent window and lets a volume nudge
    // during it fold onto the pre-park level instead of the muted 0. Cleared
    // in _calibRestoreVolume and the gesture's own cancel.
    property bool _autoCareParked: false

    // Jack detection, refreshed at startup, on device changes and before a
    // calibration: sink name → true when its active port says "not
    // available" (an empty jack). An empty jack can never pass the check —
    // measuring it wastes half a minute and ends in an alarming partial
    // verdict about a "speaker" that does not exist.
    property var _portUnplugged: ({})
    property int _portRev: 0

    function refreshPortStates() {
        app.exec(": PW_PORTS; pactl --format=json list sinks 2>/dev/null; true");
    }

    function portUnplugged(sink) {
        void _portRev;
        return _portUnplugged[sink] === true;
    }

    // parkPct: the level every sink is parked at for the clicks. The 55%
    // default is polite for a quiet room; a noisy one (fans, a sensitive
    // studio mic — a floor of ~540 measured where the bench sat at ~40)
    // can bury the clicks in it, and the failure handler then retries once
    // at 85% before giving up.
    property int _calibParkPct: 55

    function calibrateSync(parkPct) {
        if (_calibrating || _verifyPending || !_combineActive) return;
        // By-ear mode: the microphone is off the table entirely. The button
        // is hidden in that mode, but a hidden button is a UI fact and this
        // is the contract — nothing here may reach a microphone.
        if (cfg.syncManualOnly === true) return;
        // A recording is running: this road plays audible clicks, parks the
        // master and hardware-mutes members for a minute. It does not spoil
        // the file — that comes off the stream, not the room — but silencing
        // someone's speakers mid-recording without a word is not on. The
        // periodic check has refused during a recording from the start; the
        // louder road that a person actually presses did not, which was the
        // wrong way round. Said out loud rather than silently ignored: this
        // one is a button press, and a button that does nothing is a bug.
        if (app.recording === true) {
            // One literal, not a concatenation: xgettext extracts only the
            // first piece of "a" + "b", so the msgid it writes never matches
            // the string i18n() is given at runtime and the translation is
            // silently skipped in every language.
            app.notify(i18n("Sync measurement"),
                       i18n("A recording is running. The measurement plays test tones and quiets the speakers, so it waits until the recording is done."),
                       "media-record");
            return;
        }
        // The caretaker's own probe may be out sweeping right now. It is not
        // covered by the guards above — those watch _calibrating and
        // _verifyPending, and a drift probe sets neither — so two processes
        // could measure the same room at once, each hearing the other's
        // tones, and the contaminated lag was the one that got stored. The
        // person pressing the button wins: stop the background probe first.
        _driftKill();
        // Nothing used to mark the start of a hand-started run in the log,
        // so a report of "it clicked" could not be told apart from hardware
        // waking up. Now it can — and it names the stimulus honestly. This
        // line used to say "audible clicks" on every run, and in the
        // 2026-07-28 forensics it read as proof the sweep never played,
        // when the words were just a leftover from before the sweep existed.
        console.log("[ARP] sync: measuring by hand ("
                    + (cfg.syncUltrasonic !== false ? "inaudible sweep" : "audible clicks")
                    + ", speakers parked)");
        // Jack state can be stale: plugging a speaker into a previously empty
        // port usually fires no device-list change, so the empty-jack filter
        // below would still skip a now-audible speaker. Refresh first — the
        // one-shot lag is harmless (a jack the user just plugged is not one
        // they will immediately calibrate against in the same instant).
        refreshPortStates();
        var sinks = _combineRealSinks();
        // Empty jacks step aside: they stay in the group (plugging in later
        // is welcome) but nobody clicks into a hole in the air.
        var skipped = [];
        sinks = sinks.filter(function(s) {
            if (!portUnplugged(s)) return true;
            skipped.push(outputDescription(s));
            return false;
        });
        var wired = "", bt = "";
        for (var i = 0; i < sinks.length; i++) {
            if (sinks[i].indexOf("bluez_") === 0) { if (bt === "") bt = sinks[i]; }
            else if (wired === "") wired = sinks[i];
        }
        if (wired === "" || bt === "") return;
        var park = parkPct || 55;
        _calibParkPct = park;
        _calibrating = true;
        _verifyCorrected = false;
        _verifyProposal = null;
        _verifyMutedSaid = ({});
        _verifySatOut = ({});
        // The natural moment to calibrate is WHILE listening — but program
        // audio through the live loopbacks either drowns the clicks (every
        // measurement fails) or a drum hit beats them in the peak search and
        // a plausible-but-wrong lag gets persisted for the device. Silence
        // the stream at its source for the measurement; the clicks are
        // played straight at the sinks and don't pass through it.
        // Captured only when nothing is held yet: the louder retry arrives
        // with the stream already muted by the first run, and re-capturing
        // here would remember "0" as the level to put back.
        if (_calibVolumeBefore < 0)
            _calibVolumeBefore = app.playerOutput.volume;
        app.playerOutput.volume = 0;
        var script = Qt.resolvedUrl("calibrate.py").toString().substring(7).replace(/'/g, "'\\''");
        // The timing pair goes first; EVERY other speaker in the group rides
        // along for the loudness measurement, all parked at the same 55% so
        // the click amplitudes compare speaker against speaker, nothing else.
        // Capped to what calibrate.py will measure (2 + MAX_EXTRA_SINKS) —
        // parking the volume of a sink nobody clicks would be a pointless
        // save/restore cycle.
        var calSinks = [wired, bt];
        for (var e = 0; e < sinks.length; e++)
            if (sinks[e] !== wired && sinks[e] !== bt) calSinks.push(sinks[e]);
        calSinks = calSinks.slice(0, 8);
        // The guard must outlast the WORST run, not the typical one: every
        // extra speaker adds two clicks, and a dying sink holds each click
        // for paplay's full 5 s timeout — a fixed 60 s fired mid-run with a
        // full group, unmuting the radio INTO the tail measurements and
        // persisting music-contaminated levels.
        // The run now measures the timing pair TWICE over: once with the
        // inaudible sweep, which is what the fine-tune number comes from,
        // and once with the clicks, which is the only stimulus a microphone
        // can read a loudness off. Seven sweep captures at 2.6 s each is
        // about 18 s on top of the clicks' own ~35 s, so the old 60 s base
        // would have killed a healthy four-speaker run partway through the
        // extras — the same shape of failure the 14 s verify guard used to
        // produce.
        calibGuardTimer.interval = 90000 + (calSinks.length - 2) * 15000;
        calibGuardTimer.restart();
        // A balance-trimmed loopback would mute the clicks on that speaker
        // and the measurement would read as silence — raise OUR sink-inputs
        // to full for the clicks and put the balance back right after.
        var pre = "", post = "";
        for (var ci = 0; ci < calSinks.length; ci++) {
            var mod = _combineModuleForKey(_trimKeyForSink(calSinks[ci]));
            var pct = Math.round(trimOf(_trimKeyForSink(calSinks[ci])) * 100);
            if (mod !== "" && pct < 100) {
                pre += _sinkInputVolCmd(mod, 100);
                post += _sinkInputVolCmd(mod, pct);
            }
        }
        var setup = "", restore = "", argv = "";
        for (var si = 0; si < calSinks.length; si++) {
            var esc = calSinks[si].replace(/'/g, "'\\''");
            setup += " s" + si + "='" + esc + "';"
                  + " v" + si + "=$(pactl get-sink-volume \"$s" + si + "\" | grep -o '[0-9]*%' | tr '\\n' ' ');"
                  // The restored volume rides along for the loudness math:
                  // the clicks are measured at the park level, but playback
                  // happens at THIS level — the handler folds it back in.
                  + " echo \"CALIBVOL $s" + si + " ${v" + si + ":-" + park + "%}\";"
                  + " pactl set-sink-volume \"$s" + si + "\" " + park + "%;";
            // Unquoted on purpose: $vN holds one %-value PER CHANNEL and
            // word-splitting hands pactl each as its own argument, so a
            // left/right balance survives the round-trip. An unreadable
            // volume falls back to the park the calibration itself used.
            restore += " pactl set-sink-volume \"$s" + si + "\" ${v" + si + ":-" + park + "%};";
            argv += " \"$s" + si + "\"";
            // The microphone the last calibration MEASURED as the best ear
            // in this machine, asked for again by name. Empty on the first
            // run (or after the device left), and calibrate.py then picks —
            // the desktop's default source is a routing preference, not a
            // judgement about which microphone hears the room.
            if (si === 1) argv += " " + _micArg();
        }
        // The timeout must beat the guard timer: only the SHELL knows the
        // saved sink levels ($vN) and the balance percentages to put back —
        // if a hung pw-record lived past the guard, the sinks would stay
        // parked at 55% and the loopbacks at full, and QML could not restore
        // either. Killing the python inside the guard window keeps the
        // restore lines on the path no matter how the measurement dies.
        var calBudget = Math.round(calibGuardTimer.interval / 1000) - 10;
        // Generation stamp: only the python is under `timeout`, so the setup
        // and restore pactl calls can hang on a drowsy Bluetooth sink past
        // the guard. If that shell finally exits DURING a second calibration,
        // its ack must be recognized as stale and dropped — otherwise it
        // stops the new guard, clears _calibrating mid-run and can unmute the
        // music into the fresh measurement.
        var calSeq = ++_calibRunSeq;
        // The in-shell restore covers every way the MEASUREMENT can die —
        // but not the shell's own death: a logout SIGTERMs the whole
        // cgroup, and the next session then plays every speaker at the
        // park. The saved levels are written to a runtime file the moment
        // they are read; the same shell deletes it after restoring, and
        // startup() replays whatever a dead session left behind.
        // XDG_RUNTIME_DIR only (0700, ours): the twin of this file is
        // replayed with sh at startup, so it must never live in a shared,
        // predictable /tmp path. No runtime dir → the save is skipped and
        // the calibration's own restore commands still put levels back.
        var parkFile = _parkFile;
        var parkSave = " [ -n \"$XDG_RUNTIME_DIR\" ] && : > " + parkFile + ";";
        for (var pf = 0; pf < calSinks.length; pf++)
            parkSave += " printf 'pactl set-sink-volume '\\''%s'\\'' %s\\n'"
                      + " \"$s" + pf + "\" \"${v" + pf + ":-" + park + "%}\" >> " + parkFile + ";";
        // The setting is a promise, not a preference — and it holds for the
        // button too. A listener who ticked "measure with a tone too high to
        // hear" and then pressed Calibrate was still getting the clicks,
        // because the inaudible road was only ever a first choice here. If
        // this room cannot carry the sweep, the honest answer is to say so
        // and let them decide, not to fall back behind their back.
        app.exec(": PW_CALIB " + calSeq + " " + _btMacOfSink(bt) + " P" + park + " ;"
            + _ultraEnv()
            + (cfg.syncUltrasonic !== false ? " export ONAIR_ULTRA_ONLY=1;" : "")
            + setup
            + parkSave
            + " " + pre
            + _calibRunCmd(calBudget, script, argv)
            + restore
            + " " + post
            + " rm -f " + parkFile + "; true # " + app.nextSeq());
        // Said AFTER the work is on its way (state before speech), because
        // it must be said: two rounds of clicks with a quiet check between
        // them read as "done" halfway through, and a calibration interrupted
        // at half-time is worse than none. The louder retry announces itself
        // from the failure handler instead — no second "started" toast.
        if (park === 55) {
            // Say what this run will actually play. With the inaudible
            // setting on there are no clicks at all, and promising "two
            // rounds of clicks" to someone who has just asked for silence
            // reads as the widget ignoring them.
            var calNote = cfg.syncUltrasonic !== false
                ? i18n("Measuring with a tone too high to hear — about two minutes in total. The music stays silent until the check finishes.")
                : i18n("Two rounds of clicks with a quiet check between them — about two minutes in total. The music stays silent until the check finishes.");
            if (skipped.length > 0)
                calNote += " " + i18n("Skipped (empty jack): %1.", skipped.join(", "));
            app.notify(i18n("Calibration started"), calNote, "audio-input-microphone");
        }
    }

    // Every load carries this generation: PipeWire happily loads a SECOND
    // null sink under the same name, so a stale in-flight load landing after
    // an enable→disable→enable would otherwise be adopted next to the live
    // set — every speaker gets two differently-delayed loopbacks (phasing)
    // and the first set leaks until the next session's sweep.
    property int _combineLoadSeq: 0
    // Generation for calibration runs — a stale ack from a superseded run
    // (its untimeout'd restore hung past the guard) is dropped by number.
    property int _calibRunSeq: 0
    // The user's real default sink, rescued from a superseded load's ack
    // when a fast re-enable's own probe already saw the combined sink. The
    // live generation's ack adopts it; see the PW_COMBINE handler.
    property string _combinePrevDefaultFallback: ""

    function combineOutputsEnable(fromUser) {
        if (!_combineAvailable || _combineWantActive) return;
        // Two pieces of hardware make a sync; how many of them PLAY is the
        // user's per-speaker choice (one alone is a valid evening).
        if (_combineAllSinks().length < 2) return;
        var sinks = _combineRealSinks();
        if (sinks.length === 0) {
            // The big switch says "play", but the remembered exclusions
            // leave nothing to play on — the explicit action of right now
            // wins over the leftovers of some earlier evening. Only the
            // speakers standing here return: an absent device (a headset
            // excluded for good) keeps its choice for when it comes back.
            // And only for the user's OWN click: the startup probe, the
            // resurrect knocks and the wake replay a remembered wish, and a
            // wish must not overrule per-speaker choices that were each an
            // explicit act — every speaker unticked and the wish left on
            // would otherwise come back playing on all of them.
            if (fromUser !== true) return;
            var m = {};
            for (var xk in _syncExcluded) m[xk] = _syncExcluded[xk];
            var all = _combineAllSinks();
            for (var xi = 0; xi < all.length; xi++)
                delete m[_trimKeyForSink(all[xi])];
            _syncExcluded = m;
            _exclRev++;
            cfg.syncExcluded = JSON.stringify(m);
            sinks = _combineRealSinks();
        }
        if (sinks.length === 0) return;
        _combineWantActive = true;
        // The wish outlives the session: a login used to silently drop the
        // whole group (the startup sweep tears it down and nothing rebuilt
        // it) — "all speakers" meant "until the next reboot".
        cfg.combineWanted = true;
        // Never remember a combined name as "the output before the sync":
        // a resurrect (the null sink died under a live group) arrives here
        // with the player still routed onto the dead sink, and persisting
        // that would hand the eventual disable a corpse to restore to.
        var prevOut = cfg.audioOutputDevice || "";
        if (prevOut.indexOf("onair_combined") !== -1) prevOut = _combinePrevOutput;
        _combinePrevOutput = prevOut;
        cfg.combinePrevOutput = _combinePrevOutput;
        _combineSinksSnapshot = _combineGroupSignature();
        // Sync switched on while a speaker is still connecting: its sink is
        // not in the snapshot yet, so the join watchdog walks it in.
        if (app._btConnectingMac !== "")
            _btJoinWatchArm(app._btConnectingMac, app._btPendingSinkName);
        // Human name for the sink — this is what the output picker (ours and
        // the system volume applet) shows instead of the raw node name.
        var desc = i18n("All local outputs (On Air)").replace(/"/g, "").replace(/'/g, "'\\''");
        // The combined output also becomes the system DEFAULT sink while the
        // sync is on: the volume keys and the panel applet act on the default
        // sink, and pointing them anywhere else meant "volume up" reached the
        // wired speakers but never the Bluetooth ones. The null sink's volume
        // provably scales its monitor, so one keypress now moves the whole
        // room. The previous default's level is copied over first — becoming
        // the default must not jump the loudness.
        // The same-name sweep comes FIRST, in the same shell: a fast
        // disable→enable races the disable's asynchronous teardown, and
        // PipeWire happily loads a second sink under the same name — the new
        // loopbacks then resolve ".monitor" against whichever twin the name
        // lands on, and the old teardown kills their source out from under
        // them. Unloading every module of OUR name before loading makes the
        // enable idempotent no matter what is still in flight.
        //
        // The group master starts POLITE at 20% — no blast through hardware
        // levels nobody audited. The ramp to the room's remembered level
        // runs from the ACK (generation-checked), not from this shell: a
        // superseded enable's shell must not be able to ramp the next
        // generation's freshly-parked sink by name. The default switch is
        // best-effort — `true` keeps the group's exit status from gating
        // the loopbacks, which are the actual feature. The braces around
        // the loopback block matter: a failed null sink must skip EVERY
        // loopback, or pactl attaches them to the default source — the
        // microphone, live to the room.
        app.exec(": PW_COMBINE " + (++_combineLoadSeq) + ";"
                        + " d=$(pactl get-default-sink); echo \"PREVDEF $d\";"
                        // The level the room is at RIGHT NOW, before the
                        // combined sink takes the default over. With nothing
                        // remembered the ramp used to assume 100% — and the
                        // combined sink IS the system output while the sync
                        // runs, so a first enable (or a fresh install) put
                        // the whole machine at full blast. At night that is
                        // the whole house. Read it here, where the answer is
                        // still the user's own setting.
                        + " pv=$(pactl get-sink-volume \"$d\" 2>/dev/null"
                        + " | grep -o '[0-9]*%' | head -1 | tr -d %);"
                        + " echo \"PREVVOL ${pv:-0}\";"
                        // Pin the null sink to the graph's clock rate: the
                        // common-mode-resample guarantee (any station rate
                        // resamples UPSTREAM of the split) must not depend
                        // on the machine's clock.allowed-rates config.
                        + " r=$(pw-metadata -n settings 2>/dev/null"
                        + " | awk -F\"'\" '/clock.rate/{print $4; exit}');"
                        + " for sw in $(pactl list short modules 2>/dev/null"
                        + " | awk '/" + _combineSinkName + "([^0-9]|$)/ {print $1}'); do"
                        + " pactl unload-module \"$sw\" 2>/dev/null; done;"
                        + " m=$(pactl load-module module-null-sink"
                        + " sink_name=" + _combineSinkName + " channels=2 ${r:+rate=$r}"
                        + " sink_properties='device.description=\"" + desc + "\"')"
                        + " && { echo \"NULL $m\";"
                        + " pactl set-sink-volume " + _combineSinkName + " 20% 2>/dev/null;"
                        + " pactl set-default-sink " + _combineSinkName + " 2>/dev/null; true; }"
                        + " && { " + _combineLoopbackCmds(sinks) + "true; }"
                        + " # " + app.nextSeq());
    }

    function _combineUnloadCmd() {
        var ids = _combineLoopbackIds.slice();
        if (_combineNullId !== "") ids.push(_combineNullId);
        var cmd = "";
        for (var i = 0; i < ids.length; i++)
            cmd += "pactl unload-module " + ids[i] + " 2>/dev/null; ";
        _combineLoopbackIds = [];
        _combineLoopbackSinkByModule = {};
        _combineNullId = "";
        return cmd;
    }

    function combineOutputsDisable(fromTeardown) {
        // The user's word beats a pending resurrect — an explicit off must
        // not be undone by the retry ticks a dead sink armed. A teardown
        // (logout, widget removal) is NOT the user's word: the wish
        // persists and the next session's probe rebuilds the room.
        _resurrectTries = 0;
        _combineSinkSeen = false;
        if (fromTeardown !== true) {
            cfg.combineWanted = false;
            // A real off while parked (or any manual off) retires the park
            // state — nothing may wake a sync the user switched off.
            _combineIdleParked = false;
            _combineWakeQueued = false;
        }
        if (!_combineWantActive) return;
        _combineWantActive = false;
        if (!_combineActive && _combineNullId === "") {
            // The load is still in flight — the PW_COMBINE handler sees the
            // intent withdrawn and unloads everything the moment it lands.
            return;
        }
        _combineActive = false;
        _combinePendingRoute = false;
        _combineLbRetries = 0;
        combineLbRetry.stop();
        // Whether a measurement holds the master right now — read BEFORE the
        // cancel below clears the flags. A verify parks the master at 100%
        // for the clicks; a disable landing inside that window must not
        // remember the PARK as "the level the user left the room at", or
        // the next morning's enable ramps to a full blast the user never
        // chose — the very regression the memory exists to prevent.
        var masterParked = _calibrating || _verifyPending || _combineRamping;
        // Generation boundary: an in-flight rebuild's ack is stale from here
        // on and deliberately keeps its hands off these flags — a leftover
        // busy would deadlock every rebuild of the next enable.
        _combineReloopBusy = false;
        _combineReloopPending = false;
        // A calibration or verify in flight is measuring a sink that is about
        // to be torn down: its clicks, its map corrections, its evictions and
        // its mutes would all land on a dead group, and a stranded
        // _verifyPending would hold every rebuild of the NEXT enable. Cancel
        // the whole measurement, restore the stream, drop the held rebuild.
        // The group is going away under the measurement — end the process
        // too, not just the flags.
        if (_calibrating || _verifyPending) _calibAbort(false);
        _btJoinWatchStop();
        // Route away FIRST — with the choice already off the combined sink,
        // its removal is not a "device vanished" event worth a notification.
        app.setAudioOutputDevice(_combinePrevOutput);
        _combinePrevOutput = "";
        cfg.combinePrevOutput = "";
        var unMods = _combineUnloadCmd();
        var un = "";
        if (unMods !== "" || _combinePrevDefault !== "") {
            // The default AND the master level are read BEFORE the unloads:
            // destroying the combined sink makes WirePlumber re-point the
            // default on its own, and the master — the level the volume keys
            // trimmed all evening — dies with the sink. It is echoed back and
            // remembered so the next enable's ramp ends where the user left
            // the room, not at a 100% they never chose.
            // The flags answer "is a measurement running RIGHT NOW", which
            // is not the same question. A cancelled or guard-expired run
            // clears them while its shell is still walking the restore, and
            // the read below then caught the 100% park and filed it as the
            // user's own level. The park file outlives the flags and is
            // deleted only once the levels are actually back — ask IT too.
            un = "d=$(pactl get-default-sink 2>/dev/null);"
               + (masterParked ? " " :
                  " if [ -z \"$XDG_RUNTIME_DIR\" ] || [ ! -e " + _parkFile + " ]; then"
                  + " cm=$(pactl get-sink-volume " + _combineSinkName
                  + " 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%');"
                  + " echo \"MASTER ${cm:-100}\"; fi;")
               + " " + unMods;
        }
        // Hand the system default back to whoever held it before the sync —
        // but only if it is still OURS to hand back: a default the user moved
        // elsewhere mid-session is their word, not a leftover to revert.
        if (_combinePrevDefault !== "") {
            // Two conditions, not one. "$d" was read before the unloads, so
            // it answers "was the sync holding the default when we started".
            // The second half asks whether our sink is gone FOR GOOD: a
            // disable followed quickly by an enable rebuilds it under the
            // same name, and this shell — still walking its tail — would
            // otherwise hand the default away from the live new group.
            un += "[ \"$d\" = \"" + _combineSinkName + "\" ]"
                  + " && ! pactl list short sinks 2>/dev/null | cut -f2"
                  + " | grep -Fxq '" + _combineSinkName + "'"
                  + " && pactl set-default-sink '"
                  + _combinePrevDefault.replace(/'/g, "'\\''") + "' 2>/dev/null; ";
            _combinePrevDefault = "";
        }
        // The persisted key is cleared by the DONE ack below, not here: this
        // exec is asynchronous, and a teardown that kills it before it runs
        // (disable is called from Component.onDestruction) must leave the key
        // for the next session's conditional startup restore.
        if (un !== "") app.exec(": PW_UNCOMBINE_DONE; " + un + "true # " + app.nextSeq());
        else cfg.combinePrevDefault = "";
    }

    // Swap the loopbacks under a live null sink: the player keeps feeding
    // onair_combined uninterrupted while the delays change (slider move,
    // Bluetooth sink came or went).
    // Serialized: a second rebuild while one is in flight would read the
    // id list as empty, skip the unloads, and leave every sink with two
    // live loopbacks — audible phasing, the exact artifact this feature
    // exists to prevent.
    property bool _combineReloopBusy: false
    property bool _combineReloopPending: false

    // A rebuild that lands mid-measurement unloads the very loopback a
    // click is riding and suspends the sink under it — the watchdog nudge,
    // an LBMISS retry or an outputs blink used to do exactly that during
    // the verify. Held rebuilds run the moment the measurement ends.
    property bool _rebuildHeld: false

    function _combineRebuildLoopbacks() {
        // Only a changed GROUP reopens the question of what each speaker can
        // carry. A rebuild also happens every time a delay moves — dragging
        // the fine-tune slider is one — and a speaker deaf to 18 kHz at
        // 145 ms is just as deaf at 200. Forgetting on every rebuild would
        // hand the user a fresh relay click for each nudge of the slider.
        var sigNow = _combineGroupSignature();
        if (sigNow !== _ultraDeafSig) {
            _ultraDeaf = ({});
            _ultraDeafSig = sigNow;
        }
        if (!_combineActive) return;
        if (_calibrating || _verifyPending) { _rebuildHeld = true; return; }
        if (_combineReloopBusy) { _combineReloopPending = true; return; }
        _combineReloopBusy = true;
        var sinks = _combineRealSinks();
        _combineSinksSnapshot = _combineGroupSignature();
        var un = "";
        for (var i = 0; i < _combineLoopbackIds.length; i++)
            un += "pactl unload-module " + _combineLoopbackIds[i] + " 2>/dev/null; ";
        _combineLoopbackIds = [];
        // The module→sink map dies with the modules: a slider moved during
        // the flight used to resolve against these very ids and volume a
        // corpse. Empty map = no live apply; the value is persisted and the
        // ack's reconcile pass brings the fresh modules to it.
        _combineLoopbackSinkByModule = {};
        // Re-assert the default while we're here: WirePlumber's
        // switch-on-connect policy hands the default to a freshly-connected
        // sink (the very Bluetooth speaker that just joined the group), and
        // the volume keys would silently start moving one device, not the room.
        // Conditionally, though — rebuilds run on every slider move, and an
        // unconditional grab kept overriding a default the user had pointed
        // elsewhere on purpose. Reclaim only when the current default is ours
        // already or a member of the group (the switch-on-connect steal);
        // anything outside the group is the user's word and stands.
        var reclaim = " d=$(pactl get-default-sink 2>/dev/null); ok=0;"
                    + " [ -z \"$d\" ] && ok=1; [ \"$d\" = \"" + _combineSinkName + "\" ] && ok=1;";
        for (var rc = 0; rc < sinks.length; rc++)
            reclaim += " [ \"$d\" = '" + sinks[rc].replace(/'/g, "'\\''") + "' ] && ok=1;";
        reclaim += " [ \"$ok\" = 1 ] && pactl set-default-sink " + _combineSinkName + " 2>/dev/null;";
        // The rebuild carries its enable-generation: a wedged rebuild whose
        // ack lands after a disable→re-enable would otherwise be adopted
        // into the NEW generation next to its own fresh build — every
        // speaker with two differently-delayed loopbacks, audible phasing.
        app.exec(": PW_RELOOP " + _combineLoadSeq + "; " + un + _combineLoopbackCmds(sinks)
                        + reclaim + " true"
                        + " # " + app.nextSeq());
        // Fresh loopbacks mean a fresh A2DP operating point — read every
        // Bluetooth member's reported latency once the dust settles. The
        // shift dead-zone keeps this from ping-ponging: a rebuild whose
        // report matches what it was built with arms nothing.
        refLatProbeTimer.restart();
    }

    // One number on screen, and it should be the number in force. The
    // fine-tune slider reads syncOffsetMs while every automatic correction
    // lands in the per-device map, so a speaker the caretaker had been
    // quietly retuning still showed whatever was set by hand once. With a
    // single Bluetooth speaker there is no doubt about which number the
    // slider stands for, so it follows the correction; with several there
    // is, and the "Tuned automatically" line lists them by name instead.
    // Writing it changes nothing about playback — _lagForSink prefers the
    // map for a speaker that has an entry, and setSyncOffset writes both
    // when the slider is dragged, so the two can never disagree in silence.
    // The floor _anchorLags would subtract, without writing anything: the
    // frame's free constant over the current group, absences read the same
    // way _lagForSink reads them.
    function _anchorFloor(map, sinks) {
        var lo = null;
        for (var i = 0; i < sinks.length; i++) {
            var k = _btMacOfSink(sinks[i]) || sinks[i];
            var v = parseInt(map[k], 10);
            if (!isFinite(v))
                v = _btMacOfSink(sinks[i]) !== "" ? (cfg.syncOffsetMs || 0) : 0;
            if (lo === null || v < lo) lo = v;
        }
        return lo === null ? 0 : lo;
    }

    function _mirrorTunedToSlider() {
        var s = _combineRealSinks();
        var bt = [];
        for (var i = 0; i < s.length; i++)
            if (_btMacOfSink(s[i]) !== "") bt.push(s[i]);
        if (bt.length !== 1) return;
        // The slider's number is the anchored-frame MAP difference — that
        // is what setSyncOffset writes after anchoring — so the mirror has
        // to speak exactly that frame. Neither the anchor floor NOR the
        // live transport shift belongs in it: the map is kept clean of the
        // shift and every read adds it back, so a mirror built on
        // _lagForSink re-applied the shift to the very number the slider
        // types into the map — a 137 ms map under a 150 ms shift mirrored
        // as 287, and one tick of the slider would have deployed the shift
        // twice. Read the raw entry instead, floor subtracted, shift never
        // added.
        var lag;
        try {
            var mm = JSON.parse(cfg.syncOffsetMap || "{}");
            lag = parseInt(mm[_btMacOfSink(bt[0])], 10);
            if (!isFinite(lag))
                lag = Math.max(0, Math.min(2000, cfg.syncOffsetMs || 0));
            lag -= _anchorFloor(mm, s);
        } catch (e) { return; }
        // The slider's own scale. A lag past its ceiling would show as a
        // pinned slider, which reads as a wrong number rather than a big one.
        if (lag < 0 || lag > 900) return;
        if (Math.round(lag) !== Math.round(cfg.syncOffsetMs || 0))
            cfg.syncOffsetMs = Math.round(lag);
    }

    function setSyncOffset(ms) {
        cfg.syncOffsetMs = Math.round(ms);
        // The slider speaks for the CONNECTED device(s) — remember the value
        // per MAC so each speaker keeps its own lag across sessions.
        try {
            var map = JSON.parse(cfg.syncOffsetMap || "{}");
            var sinks = _combineRealSinks();
            // Anchor BEFORE writing, or the number typed here is not the
            // number the room gets. The slider means "hold the Bluetooth
            // speaker back this much MORE than the wired one" — a
            // difference — but it only ever wrote the Bluetooth entry, so a
            // wired member carrying a lag of its own quietly subtracted
            // itself from every value the user chose. Measured on this
            // desk: 145 typed against a wired member sitting at 154 reached
            // the speakers as 17 ms, and no amount of dragging could fix it
            // from here. With the frame anchored first, the typed number is
            // the difference, which is what the slider has always claimed.
            _anchorLags(map, sinks);
            var touched = false;
            for (var i = 0; i < sinks.length; i++) {
                var mac = _btMacOfSink(sinks[i]);
                if (mac !== "") { map[mac] = Math.round(ms); touched = true; }
            }
            if (touched) cfg.syncOffsetMap = JSON.stringify(map);
        } catch (e) {}
        syncOffsetDebounce.restart();
    }

    Timer {
        id: syncOffsetDebounce
        interval: 300
        repeat: false
        onTriggered: _combineRebuildLoopbacks()
    }

    // Restore the stream volume muted for the calibration clicks. Skipped if
    // the user moved the slider themselves meanwhile — their word wins.
    function _calibRestoreVolume() {
        // Clear the park flag FIRST: the restore write below must not read
        // back through the volume observer as a fresh user gesture.
        _autoCareParked = false;
        if (_calibVolumeBefore >= 0 && app.playerOutput.volume === 0)
            app.playerOutput.volume = _calibVolumeBefore;
        _calibVolumeBefore = -1;
    }

    // A user volume gesture (compact wheel, slider, MPRIS) that lands while the
    // auto-care park holds the stream at 0. The caller read the muted 0 and
    // computed its new level from there, so a raw apply both persists ~5% as
    // the remembered volume AND, being non-zero, makes the terminal
    // _calibRestoreVolume skip its restore — losing the real level for the
    // session. Fold the gesture onto the pre-park level, drop the now unwanted
    // verify, and let setUserVolume persist the corrected absolute. Manual
    // calibration never sets _autoCareParked, so its semantics are untouched.
    // Off means off, the moment it is switched. The clicks are armed by a
    // settle timer and launched later, and nothing between those two points
    // read the setting again — so a listener who heard the announcement,
    // went to the settings page and unticked the caretaker still got the
    // full click round, twice over if the correction round followed. The
    // switch now reaches the machinery it governs: an armed run is dropped,
    // a running one is killed with the same road the manual cancel uses,
    // and the stream is handed back its level.
    Connections {
        target: cfg
        function onSyncAutoCareChanged() {
            if (cfg.syncAutoCare === true) return;
            // Only the caretaker's OWN run is dropped. A calibration the
            // user started by hand is their business and keeps going —
            // _autoCareParked is what tells the two apart, and it is set
            // before the arm, so a run announced but not yet clicking is
            // caught as well as one already underway.
            if (_autoCareParked) calibrateCancel();
            // A probe already sweeping is the caretaker's too, and it is
            // NOT covered by the line above: _autoCareParked is set when the
            // probe's result comes back, so during the probe itself it is
            // still false. Unticking used to leave it measuring — the switch
            // said stop and the room went on being swept.
            _driftKill();
            // The 6-minute listening stops with the switch through the
            // timer's own binding; the early first check has no such
            // binding and would still fire once.
            driftFirstCheck.stop();
            // The half-finished measurement SURVIVES the switch. It is an
            // observation about the room, not about the checkbox, and
            // throwing it away punished the one gesture a listener makes
            // when they want the widget to hurry up: toggling the switch
            // after a reading discarded it and started the pair over. Age
            // is what makes a remembered reading stale, and the history's
            // own timestamps are what enforce that.
            _driftHintShown = false;
        }
    }

    Connections {
        target: app.playerOutput
        // The check is DEFERRED past the write for two reasons: setUserVolume
        // stamps _pendingUserVolumePct AFTER the volume assignment that lands
        // us here, and re-entering it now would let its own stamp clobber our
        // corrected one on return.
        function onVolumeChanged() {
            if (!_autoCareParked || app.playerOutput.volume <= 0) return;
            Qt.callLater(_autoCareVolumeGesture);
        }
    }
    function _autoCareVolumeGesture() {
        if (!_autoCareParked) return;
        // Only setUserVolume stamps _pendingUserVolumePct (>= 0); a fade or a
        // stop's `volume = targetVolume()` writes the property directly and
        // leaves it -1 — those parked-window writes must not read as the
        // user's word, or a stop would fold targetVolume onto the level and
        // persist a blast.
        if (app._pendingUserVolumePct < 0) return;
        var v = app.playerOutput.volume;
        if (v <= 0) return;
        // Only a wheel/keyboard STEP was computed from the displayed 0 and
        // needs folding onto the pre-park level. An absolute gesture — the
        // popup slider, the unmute button's targetVolume, an MPRIS
        // SetVolume — already names its level; folding those doubled them
        // (unmute at pre-park 65% became min(1, 0.65+0.65) = full blast,
        // persisted).
        var target = app._pendingUserVolumeStep
                ? Math.max(0, Math.min(1, _calibVolumeBefore + v))
                : v;
        _cancelAutoCareVerify();
        app.setUserVolume(target);
    }
    // Tear down a pending/in-flight auto-care verify WITHOUT touching the
    // stream volume — the gesture handler owns the restore. Same shape as the
    // disable path's cancel, generation bump included so a verify already
    // launched has its late ack dropped by the seq gate.
    function _cancelAutoCareVerify() {
        _verifyPending = false;
        _verifyCorrected = false;
        _verifyProposal = null;
        _verifyMutedSaid = ({});
        verifySettleTimer.stop();
        verifyGuardTimer.stop();
        _verifyUnmuteAll();
        _autoCareParked = false;
        _calibVolumeBefore = -1;
        _calibRunSeq++;
        // A rebuild held back for the measurement's sake is still OWED: a
        // speaker the user unticked mid-verify keeps playing until some
        // unrelated rebuild happens by. Dropping the flag alone left that
        // debt unpaid — run it, exactly as the manual cancel does.
        if (_rebuildHeld) { _rebuildHeld = false; _combineRebuildLoopbacks(); }
    }

    Timer {
        id: calibGuardTimer
        // Interval is set per run by calibrateSync (it grows with the group's
        // size, sized to calibrate.py's worst case) — the guard only exists
        // so a lost result can't leave the stream muted forever.
        interval: 60000
        repeat: false
        onTriggered: {
            // Bump the generation FIRST: a setup/restore pactl can hang past
            // this guard (outside python's own timeout), and its very late
            // ack would otherwise still carry the current _calibRunSeq, pass
            // the PW_CALIB/PW_VERIFY gate, and act on a run already declared
            // lost — arming a verify that blasts the master at 100% over
            // live music, or launching an unasked 85% click run. Disable and
            // resurrect bump the seq for exactly this reason; the guard must
            // be a generation boundary too.
            _calibRunSeq++;
            _calibrating = false;
            _verifyPending = false;
            verifyGuardTimer.stop();
            verifySettleTimer.stop();
            _calibRestoreVolume();
            // Same as the failure branch: a rebuild held during the lost run
            // must not be stranded for the session.
            if (_rebuildHeld) { _rebuildHeld = false; _combineRebuildLoopbacks(); }
        }
    }

    // The verify pass (check-measure) in flight: a calibration succeeded,
    // the loopbacks were rebuilt with the new delays, and the room is being
    // listened back to.
    property bool _verifyPending: false

    function _verifyUnmuteAll() {
        var un = "";
        var vs = _combineRealSinks();
        // Union with the frozen verify set: a member unticked DURING the
        // measurement is gone from the live list, but the script may have
        // hardware-muted it for the isolation — skipping it here would
        // leave that sink silent everywhere, group or not, until the user
        // finds pavucontrol. Consumed ON USE: the frozen set belongs to
        // THIS measurement only — a stale union from last evening's verify
        // must not unmute a speaker the user has since silenced on purpose
        // (a clicks-phase cancel never hardware-muted anything at all).
        for (var m = 0; m < _verifyMembers.length; m++)
            if (vs.indexOf(_verifyMembers[m]) === -1) vs.push(_verifyMembers[m]);
        _verifyMembers = [];
        for (var i = 0; i < vs.length; i++) {
            // A member the script sat out is under the LISTENER's mute,
            // not ours. Unmuting it here would turn the speaker back on
            // in the middle of whatever the mute was for.
            if (_verifySatOut[vs[i]]) continue;
            un += "pactl set-sink-mute '" + vs[i].replace(/'/g, "'\\''") + "' 0; ";
        }
        if (un !== "")
            app.exec(": PW_UNMUTE; " + un + "true # " + app.nextSeq());
        // A rebuild held back during the measurement runs now.
        if (_rebuildHeld) {
            _rebuildHeld = false;
            _combineRebuildLoopbacks();
        }
    }
    // One correction round per calibration: the loop must converge, not
    // chase its own tail. Reset when a new calibration starts.
    property bool _verifyCorrected: false
    // The last few readings' per-speaker landings, newest last, each with the
    // moment it was taken. A measurement is about the room, so it outlives a
    // switch toggle — but not an afternoon: readings that agree an hour apart
    // are two different rooms agreeing by coincidence.
    property var _driftHistory: []
    property var _driftHistoryAt: []
    // What each reading said the spread WAS, by value — the passive road
    // reports an estimate with no landings, and the toast's median listens
    // to those readings too.
    property var _driftEstHistory: []
    readonly property int _driftHistoryMax: 5
    // Three is the fewest a median can be taken of without becoming a mean
    // with extra steps, and it is what makes the one flyer in twelve harmless.
    readonly property int _driftHistoryMin: 3
    // Readings age out of the median. Twenty minutes covers the mains
    // cadence (6 min) three times over, but on battery the probe runs every
    // twelve — three readings span 24+, and a fixed twenty starved both the
    // fold and the notification: the history could never hold three at
    // once. The window follows the cadence instead of assuming it.
    readonly property int _driftPendingMaxAgeMs:
        Math.max(20 * 60 * 1000, Math.round(2.5 * driftMonitorTimer.interval))
    // Below this a reading is the room's own noise, not an error. It has to
    // hold for EACH reading, not just their average.
    readonly property int _driftDeadbandMs: 5
    // Armed by the REBUILD that lands a new delay, not by the fold that
    // writes it — between those two moments nothing about the room has
    // changed and a probe is as good as any other. The reload re-rolls the
    // very Bluetooth buffering the next probe is about to measure (seen
    // live: the probe right after a reload read -17 where the one after
    // that read 0), so that one reading is spent, not stored: it describes
    // the correction, not the room.
    property bool _driftSkipNext: false

    // A rebuild that lands while a probe is still OUT makes that probe's
    // answer a letter from the previous room. Consuming the skip on it
    // spends the one free pass meant for the first post-rebuild reading —
    // the one that actually measures the Bluetooth re-roll — and that
    // reading then sits in a fresh history as a wrong-signed flyer with a
    // veto over the next fold. The flag marks the in-flight probe stale;
    // its ack is dropped whole, and the skip stays armed for the reading
    // the skip exists for.
    property bool _driftProbeStale: false

    // What the last check measured the fine-tune SHOULD be, or -1 when it
    // cannot say. The popup used to show only how far apart the room was,
    // which left the right number sitting in the journal behind a
    // subtraction nobody should have to do: the listener could see "31 ms
    // out" and still not know whether to type 141 or 203.
    function _driftSuggestion(ears) {
        if (!ears) return -1;
        var ref = -1, btKey = "", btEar = -1, seen = 0;
        for (var k in ears) {
            if (_btMacOfSink(k) === "") { ref = ears[k]; continue; }
            seen++; btKey = k; btEar = ears[k];
        }
        // One Bluetooth member is the room this can speak about plainly;
        // with two there is no single number to put on one slider.
        if (ref < 0 || seen !== 1) return -1;
        // The reading says how far off the DEPLOYED lag is, so that is the
        // base the advertised number stands on. Reading the map here
        // compounded a pending fold into the advice: seen live, the popup
        // said "measured 265" for a room whose right answer was 167, and a
        // listener typing that in would have done the walking by hand.
        var cur = _builtLags[btKey] !== undefined ? _builtLags[btKey]
                                                  : _lagForSink(btKey);
        // Both bases include the session's transport shift, but the number
        // advertised here gets TYPED INTO THE MAP, and every read of the map
        // adds the shift again. Advertise the map-frame value, or the
        // listener following the advice re-applies the shift by hand.
        cur -= (_refLatShiftByMac[_btMacOfSink(btKey)] || 0);
        // And the anchor floor, for the same reason: setSyncOffset anchors
        // the map before it writes, so the typed number lands in the
        // post-anchor frame. The mirror already speaks it — advertising the
        // pre-anchor absolute left the popup and the slider a floor apart
        // in one popup, and typing the advertised number moved the room by
        // exactly the floor.
        try {
            cur -= _anchorFloor(JSON.parse(cfg.syncOffsetMap || "{}"),
                                _combineRealSinks());
        } catch (e) {}
        return Math.max(0, Math.round(cur + (btEar - ref)));
    }

    // Where every member sat relative to the wired one, per reading. The
    // capture's own offset is common to a reading and drops out of the
    // difference, which is why this is the only quantity worth keeping.
    function _driftOffsetsFromHistory(hist) {
        var per = {};
        for (var i = 0; i < (hist || []).length; i++) {
            var ears = hist[i], ref = null;
            for (var rk in ears)
                if (_btMacOfSink(rk) === "") { ref = ears[rk]; break; }
            // No wired member in that reading means no still point in it.
            if (ref === null) continue;
            for (var k in ears) {
                var mac = _btMacOfSink(k);
                if (mac === "") continue;
                if (!per[mac]) per[mac] = [];
                per[mac].push(ears[k] - ref);
            }
        }
        return per;
    }

    // The step each member has earned, from the readings collected so far.
    // Pure arithmetic on numbers, so the tests can drive it without a room.
    //
    // A median, not a pair. Two consecutive readings within 15 ms of each
    // other was too thin a basis: measured on this desk over twenty checks
    // the scatter is sd 21 ms, so a pair lands inside the window barely half
    // the time — and on 2026-08-01 the room sat audibly out at 49, 36, 65 and
    // 61 ms while the widget printed the right answer in the popup and its
    // own rule forbade it from using it. The median of those four is 55, and
    // 55 is exactly the correction the room wanted.
    //
    // The direction rule survives, because that one is not noise-fighting but
    // arithmetic: a room that cannot agree which way it is out is not out, it
    // is unsettled, and nudging it walks it somewhere on its own. All but one
    // reading must point the same way.
    function _driftStepsFromOffsets(per) {
        var steps = {};
        for (var m in per) {
            var v = per[m];
            if (v.length < _driftHistoryMin) continue;
            var pos = 0, neg = 0;
            for (var j = 0; j < v.length; j++) {
                if (v[j] > 0) pos++;
                else if (v[j] < 0) neg++;
            }
            // With only three readings every one of them has to point the
            // same way: two against one is not a room that is out, it is a
            // room that cannot say, and "all but one" would have called
            // -40, +40, +40 a forty-millisecond correction. One dissenter is
            // allowed once there are four or more, which is where a single
            // flyer stops being half the evidence.
            if (Math.min(pos, neg) > (v.length >= 4 ? 1 : 0)) continue;
            var s = v.slice().sort(function(a, b) { return a - b; });
            var med = s.length % 2 ? s[(s.length - 1) / 2]
                                   : 0.5 * (s[s.length / 2 - 1] + s[s.length / 2]);
            if (Math.abs(med) < _driftDeadbandMs) continue;
            steps[m] = Math.round(med);
        }
        return steps;
    }

    // Correct the map from the readings collected so far — no muting, no
    // parked music, no clicks. Returns true when it acted.
    //
    // Where a speaker is heard is `arrival + the delay it is played with`,
    // and the calibration's own job is to make those equal. So the step is
    // simply how far a member sits from the wired reference: a Bluetooth
    // speaker heard LATE needs its stored lag to grow, because a bigger lag
    // buys it a smaller loopback delay. Measured against the room before
    // writing a line of this: ear(wired) - ear(bt) came out at +1.3 ms over
    // seven rounds with the fine-tune at 152, and 152 - 1.3 is exactly where
    // an independent sweep of the same room put the ideal.
    //
    // Only MAC-keyed members move, for the same reason the verify fold has
    // that rule: a Bluetooth path re-rolls its buffering per stream and a
    // wired one does not.
    function _driftFoldEars() {
        var steps = _driftStepsFromOffsets(_driftOffsetsFromHistory(_driftHistory));
        var foldedEars = _driftHistory.length
                       ? _driftHistory[_driftHistory.length - 1] : null;
        var moved = false, before = cfg.syncOffsetMap || "{}";
        try {
            var map = JSON.parse(before);
            var target = {};
            for (var mk in steps) {
                if (Math.abs(steps[mk]) < _driftDeadbandMs) continue;   // inside its own noise
                // The step was measured against what the loopbacks CARRY,
                // so it lands on that same base — never on the map, which
                // may hold an earlier fold still waiting for its rebuild.
                // Adding to the map compounded the wait: watched live on
                // 2026-08-02, a room 46 ms out walked the map 124 -> 170
                // -> 213 across two folds while every loopback still
                // carried 124, each fold re-adding the same unfixed error.
                // On the deployed base the same arithmetic is idempotent:
                // 124 + 46 is 170 however many times it is computed.
                var cur = _deployedLagForMac(mk);
                if (cur >= 0) {
                    // The deployed number carries the transport shift it was
                    // BUILT with on top of the map, and the map must stay
                    // clean of it: _lagForSink adds the shift back on every
                    // read, so a fold that writes the deployed value raw
                    // doubles the shift at the next rebuild. The verify fold
                    // learned this first (840 where 540 was intended). The
                    // as-built record, not the live ledger: a re-roll
                    // recorded mid-reloop is not in these loopbacks yet, and
                    // subtracting it here would push the whole undeployed
                    // move into the map.
                    cur -= (_builtShiftByMac[mk] || 0);
                } else {
                    cur = parseInt(map[mk], 10);
                }
                if (!isFinite(cur)) cur = Math.max(0, Math.min(2000, cfg.syncOffsetMs || 0));
                // Bounded, because this runs every few minutes: a correction
                // that cannot leap cannot run away either, and anything
                // larger is a room the microphone should look at properly.
                var step = Math.max(-60, Math.min(60, steps[mk]));
                target[mk] = cur + step;
                moved = true;
            }
            if (!moved) return false;
            // No anchoring here. The anchor slides the whole MAP frame, and
            // between a fold and its rebuild the deployed lags stay in the
            // old frame — a second fold reading its base from _builtLags
            // would then write an old-frame number next to re-anchored
            // entries and land the room out by the anchor delta, sign
            // flipped. A floor above zero waits for the next write that
            // anchors with the room present; it deploys the same sound.
            //
            // A floor BELOW zero does not. _lagForSink clamps a MAC entry
            // at zero on every read, so the part of a correction that dips
            // under the line simply never deploys: a Bluetooth link that
            // re-rolled FASTER earned map {wired:25, bt:-46}, the rebuild
            // played it as {25, 0}, and the fold rewrote the same -46
            // forever while the journal said the room was being corrected.
            // When any moved entry lands negative, the whole CURRENT group
            // is lifted together — every member rewritten from its own
            // deployed base, so a second fold recomputes the same numbers
            // instead of stacking lifts, and absent members' entries stay
            // untouched in their own frame.
            var lift = 0;
            for (var lk in target)
                if (-target[lk] > lift) lift = -target[lk];
            if (lift > 0) {
                var lg = _combineRealSinks();
                for (var li = 0; li < lg.length; li++) {
                    var lkey = _btMacOfSink(lg[li]) || lg[li];
                    if (target[lkey] !== undefined) continue;
                    var lcur;
                    if (_btMacOfSink(lg[li]) !== "") {
                        lcur = _deployedLagForMac(lkey);
                        if (lcur >= 0) lcur -= (_builtShiftByMac[lkey] || 0);
                        else lcur = parseInt(map[lkey], 10);
                        if (!isFinite(lcur))
                            lcur = Math.max(0, Math.min(2000, cfg.syncOffsetMs || 0));
                    } else {
                        lcur = _builtLags[lg[li]] !== undefined
                             ? _builtLags[lg[li]] : parseInt(map[lkey], 10);
                        if (!isFinite(lcur)) lcur = 0;
                    }
                    target[lkey] = lcur;
                }
            }
            for (var wk in target)
                map[wk] = Math.max(-100, Math.min(2000, target[wk] + lift));
            cfg.syncOffsetMap = JSON.stringify(map);
            _mirrorTunedToSlider();
        } catch (e) { return false; }
        // No probe is spent here: the room has not changed yet. The rebuild
        // that lands this correction arms the skip, in _combineLoopbackCmds.
        var foldedFrom = _driftHistory.length;
        // The readings describe the room BEFORE the correction. Keeping them
        // would let the room it used to be vote on the room it now is.
        _driftHistory = [];
        _driftHistoryAt = [];
        _driftEstHistory = [];
        console.log("[ARP] sync: quiet fold from the median of "
                    + foldedFrom + " checks — map "
                    + before + " -> " + cfg.syncOffsetMap
                    + " (applies at the next rebuild)");
        // The map is written; the LOOPBACKS are deliberately left alone.
        //
        // Swapping a loopback mid-stream is not the small gap it was assumed
        // to be: the listener described a startling clatter from the
        // speakers the first time a correction landed under real music. A
        // delay lives in the module's own parameter, so applying it means
        // tearing a live stream down and building another, and a Bluetooth
        // codec fed a discontinuity makes a noise nobody asked for.
        //
        // Nothing is lost by waiting. The map is what every rebuild reads,
        // and rebuilds happen on their own — the graph parks after fifteen
        // idle minutes and comes back on the next play, a speaker joins or
        // leaves, the slider moves. The correction lands then, in a moment
        // that costs the room nothing. Until the swap itself is proven
        // quiet, a measurement worth keeping is not worth startling anyone
        // for.
        // Honest about what it costs. A loopback carries its delay in the
        // module's own parameter, so a new delay means a new module — the
        // stream restarts and the speaker whose delay changed skips a
        // moment. That is a fraction of a second against the minute of
        // parked music the older road spent, but "no music interrupted"
        // was a promise this code does not keep, and the listener heard it.
        var dfSug = _driftSuggestion(foldedEars);
        driftLastText = dfSug >= 0
            ? i18n("Auto-check: measured %1 ms — takes effect the next time the music pauses", dfSug)
            : i18n("Auto-check: adjusted — takes effect the next time the music pauses");
        return true;
    }

    // Pass 1's proposed correction, waiting for pass 2 to agree. The fold
    // used to write the map off ONE reading; on 2026-07-29 a single pair of
    // captures that agreed on garbage (419 ms late through spawn jitter)
    // inverted a healthy room in one stroke. Now the reading that wants to
    // move the map has to happen twice.
    property var _verifyProposal: null
    // Members already named as sitting a verify out muted, so the two-pass
    // correction does not say the same thing once per pass.
    property var _verifyMutedSaid: ({})
    // Members the LAST verify ack reported sat out because the listener
    // had muted them. Their mute belongs to the listener: the cleanup's
    // blanket unmute must step around it, or the very run that promised
    // "skipped it" turns the speaker back on mid-phone-call — and pass two
    // would then measure a member pass one never saw, handing the vote a
    // fabricated zero to veto the correction with.
    property var _verifySatOut: ({})
    // Sinks the microphone actually heard during the LAST calibration's
    // click rounds — the partial verdict's evidence for telling a shy
    // speaker from an output with nothing audible behind it.
    property var _calibHeard: ({})
    // Unheard-through-both-rounds counts per sink: the self-eviction needs
    // TWO independent verdicts, so one noisy run cannot kick a healthy
    // speaker. Being heard in any later run wipes the sink's slate.
    property var _verifyPartialStrikes: ({})

    // Settle and guard are sized from the GROUP, not hard-coded: with five
    // members the measurement needs ~a minute, and the old fixed 35 s guard
    // fired mid-isolation on every single run — it unmuted the room in the
    // middle of the measurement, the script kept muting members for its
    // remaining passes (music cutting in and out, "the speaker is dead"),
    // and the real verdict arriving later was discarded as stale. That is
    // why no verify ever managed to record its result.
    // Busy phase for the UI: "" when idle, otherwise which round is on.
    readonly property string calibPhase: _calibrating ? "clicks"
                                         : (_verifyPending ? "verify" : "")

    // The exact member set this verify pass will measure, frozen when the
    // timers are armed. The guard budget is computed from it, and the launch
    // (fired ~8 s later) MUST use this same list — a Bluetooth sink
    // registering or a jack flipping in the settle window would otherwise
    // give the launch more members than the guard budgeted for, and the
    // script would outlive its own guard mid-measurement.
    property var _verifyMembers: []

    function _verifyArmTimers() {
        // The same member set the verify will actually measure — empty
        // jacks are skipped there, so they must not inflate the budget.
        _verifyMembers = _combineRealSinks().filter(function(s) { return !portUnplugged(s); });
        var vs = _verifyMembers;
        var n = Math.max(1, Math.min(8, vs.length));
        var bt = 0;
        for (var i = 0; i < vs.length; i++)
            if (vs[i].indexOf("bluez_") === 0) bt++;
        // Rebuild + Bluetooth re-acquire need real time before clicks ride
        // the fresh loopbacks; then warm-up plus up to three captures per
        // member; then generous headroom before anyone panics.
        verifySettleTimer.interval = 8000 + bt * 3000;
        verifyGuardTimer.interval = verifySettleTimer.interval
                                    + (10 + n * _verifySecondsPerMember) * 1000 + 12000;
        verifySettleTimer.restart();
        verifyGuardTimer.restart();
    }

    // Test seams — the timers themselves are private ids.
    // Whether a rebuild is queued — the debounce is private, and a test
    // cannot otherwise tell "noticed and queued" from "did nothing".
    function offsetDebounceRunning() { return syncOffsetDebounce.running; }

    function verifySettleInterval() { return verifySettleTimer.interval; }
    // Whether a click round is armed but not yet launched — the window the
    // off switch has to reach, and the one a test cannot see from outside.
    function verifySettleRunning() { return verifySettleTimer.running; }
    function verifyGuardInterval() { return verifyGuardTimer.interval; }

    Timer {
        id: verifySettleTimer
        // The rebuilt loopbacks need real time before the clicks ride them:
        // a fresh loopback's first second reported arrivals over a second
        // off while its buffer settled (measured live).
        interval: 6000
        repeat: false
        onTriggered: _verifyLaunch()
    }

    function _verifyLaunch() {
        if (!_verifyPending) return;
        // Each run's sat-out set belongs to that run's own ack. Carrying
        // the last one into a fresh launch let a guard timeout skip the
        // blanket unmute for a member THIS run had hardware-muted itself —
        // the exact half-silenced machine the blanket exists to prevent.
        // Until the new ack lands, nobody is exempt.
        _verifySatOut = ({});
        // Disabled between arm and launch: the group is gone — parking and
        // hardware-muting the sinks the user just routed back to would turn
        // a cancelled measurement into waves of silence over their music.
        if (!_combineActive) {
            _verifyPending = false;
            verifyGuardTimer.stop();
            _verifyUnmuteAll();
            _calibRestoreVolume();
            return;
        }
        // A recording started between the arm and the launch. This road can
        // fall back to audible clicks and it parks and mutes for a minute —
        // an automatic thing must never do that over a recording. Held, not
        // cancelled: the drift that armed it is still real, so the next
        // check re-arms once the recording is done.
        if (app.recording === true) {
            _verifyPending = false;
            verifyGuardTimer.stop();
            // The arm already pulled the player to 0 and told the listener
            // the music would pause for a minute. Holding here without
            // giving that back left the stream silent for the rest of the
            // session: the release rides on a verdict this road never
            // reaches. Only the volume is handed back — the script has not
            // run, so nothing in the room was hardware-muted by us, and
            // unmuting on the way out would undo a mute the listener set.
            _calibRestoreVolume();
            console.log("[ARP] sync: verify held — a recording is running");
            return;
        }
        var script = Qt.resolvedUrl("calibrate.py").toString().substring(7).replace(/'/g, "'\\''");
        // The EXACT member set the guard was budgeted for (frozen at arm
        // time) — recomputing it here could hand the launch a member the
        // guard never accounted for, and the script would then run past the
        // guard that is supposed to protect it.
        var sinks = _verifyMembers.slice();
        // The check clicks must not ride at whatever level the evening left
        // behind: a sink the connect capped polite (or the user turned down
        // for the night) drops the through-path click under the noise gate,
        // and a perfectly healthy speaker reads back as unheard. Park every
        // member at the level the calibration itself measured at (55%, or
        // its louder retry) and put the exact levels back — in the SAME
        // shell, so nothing that happens to QML can strand the room
        // re-leveled. The deployed path has two more knobs the direct
        // clicks never met, and both must sit at a KNOWN level too: the
        // combined master (its cubic curve at a polite 50% already eats
        // ~7/8 of the click — measured here as a healthy speaker reading
        // "unheard") goes to 100% = acoustic passthrough, and our loopback
        // sink-inputs (a calibration just balance-trimmed the loud ones
        // down) go to full, exactly like the calibration's own pre/post.
        var park = _calibParkPct || 55;
        var pre2 = "", post2 = "";
        for (var pi = 0; pi < sinks.length && pi < 8; pi++) {
            var vMod = _combineModuleForKey(_trimKeyForSink(sinks[pi]));
            var vPct = Math.round(trimOf(_trimKeyForSink(sinks[pi])) * 100);
            if (vMod !== "" && vPct < 100) {
                pre2 += _sinkInputVolCmd(vMod, 100);
                post2 += _sinkInputVolCmd(vMod, vPct);
            }
        }
        var setup = " cm=$(pactl get-sink-volume " + _combineSinkName
                  + " | grep -o '[0-9]*%' | head -1);"
                  + " pactl set-sink-volume " + _combineSinkName + " 100%;";
        var restore = " pactl set-sink-volume " + _combineSinkName + " ${cm:-100%};";
        var argv = "";
        for (var vi = 0; vi < sinks.length && vi < 8; vi++) {
            var esc = sinks[vi].replace(/'/g, "'\\''");
            setup += " w" + vi + "='" + esc + "';"
                  + " y" + vi + "=$(pactl get-sink-volume \"$w" + vi + "\" | grep -o '[0-9]*%' | tr '\\n' ' ');"
                  + " pactl set-sink-volume \"$w" + vi + "\" " + park + "%;";
            // Unquoted on purpose: $yN holds one %-value PER CHANNEL and
            // word-splitting hands pactl each as its own argument, so a
            // left/right balance survives the round-trip.
            restore += " pactl set-sink-volume \"$w" + vi + "\" ${y" + vi + ":-" + park + "%};";
            argv += " \"$w" + vi + "\"";
        }
        // Warm-up plus up to three captures per member — the same
        // arithmetic the guard was armed with.
        var vBudget = 10 + Math.min(8, sinks.length) * _verifySecondsPerMember;
        // Same logout insurance as the calibration's: parks, the master and
        // the isolation's hardware mutes all land in a runtime file that
        // only a completed restore deletes — startup() replays a dead
        // session's leftovers.
        // XDG_RUNTIME_DIR only, same reason as the calibration's park file.
        var vParkFile = _parkFile;
        var vParkSave = " [ -n \"$XDG_RUNTIME_DIR\" ] && : > " + vParkFile + ";"
                      + " printf 'pactl set-sink-volume '\\''%s'\\'' %s\\n' "
                      + _combineSinkName + " \"${cm:-100%}\" >> " + vParkFile + ";";
        for (var vf = 0; vf < sinks.length && vf < 8; vf++)
            vParkSave += " printf 'pactl set-sink-volume '\\''%s'\\'' %s\\n'"
                       + " \"$w" + vf + "\" \"${y" + vf + ":-" + park + "%}\" >> " + vParkFile + ";"
                       + " printf 'pactl set-sink-mute '\\''%s'\\'' 0\\n' \"$w" + vf + "\" >> " + vParkFile + ";";
        app.exec(": PW_VERIFY " + _calibRunSeq + ";" + _ultraEnv() + setup + vParkSave + " " + pre2
                 // The same promise the calibration makes two thousand lines
                 // up, and for the same reason: the setting reads "measure
                 // with a tone too high to hear", not "prefer to". This used
                 // to require _autoCareParked, which is set on exactly one
                 // road (the drift probe's), so every check that followed a
                 // manual Calibrate fell back to audible clicks with the box
                 // still ticked. That fallback is where the beeps the user
                 // reported were coming from, and it also fed the eviction
                 // below: a clicks-road VERIFY_PARTIAL against a heard-map
                 // that an inaudible calibration never filled.
                 + (cfg.syncUltrasonic !== false ? " export ONAIR_ULTRA_ONLY=1;" : "")
                 + _calibRunCmd(vBudget, script, " verify '" + _combineSinkName + "' " + _micArg() + argv)
                 + restore + " " + post2 + " rm -f " + vParkFile + "; true # " + app.nextSeq());
    }

    Timer {
        id: verifyGuardTimer
        // A lost verify must not leave the stream muted forever — nor any
        // SPEAKER: the verify isolates members by hardware mute, and a
        // measurement that died mid-member would otherwise leave the
        // machine's own audio half silenced. Belt and braces on top of the
        // script's own signal handling.
        interval: 35000
        repeat: false
        onTriggered: {
            // The guard must be a generation boundary too, exactly like
            // calibGuardTimer's: only the python sits under `timeout`, so
            // the shell's restore pactl can wedge on a drowsy Bluetooth
            // sink past this guard, and without the bump its eventual ack
            // would pass the seq gate — into a LATER verify that reused
            // the number — and fold stale residuals into the offset map.
            // This was the only cancel road of the six without the bump.
            _calibRunSeq++;
            _verifyPending = false;
            _calibRestoreVolume();
            _verifyUnmuteAll();
        }
    }

    // The rebind bounce below is momentarily audible — pick the least
    // surprising stop for it: the device the user was playing on before the
    // sync, then a wired sink still IN the group, then any wired sink, and a
    // Bluetooth device only when nothing else exists. A speaker ticked out
    // of the group usually means "not in this room" — never blip it first.
    function _combineBounceTarget(outs) {
        var prev = null, wiredIn = null, wired = null, any = null;
        for (var b = 0; b < outs.length; b++) {
            var oid = String(outs[b].id);
            if (oid.indexOf(_combineSinkName) !== -1) continue;
            if (any === null) any = outs[b];
            if (prev === null && _combinePrevOutput !== "" && oid === _combinePrevOutput)
                prev = outs[b];
            if (oid.indexOf("bluez_") !== 0) {
                if (wired === null) wired = outs[b];
                if (wiredIn === null && syncDeviceIncluded(_trimKeyForSink(oid)))
                    wiredIn = outs[b];
            }
        }
        return prev || wiredIn || wired || any;
    }

    function _combineTryRoute() {
        if (!_combinePendingRoute) return;
        var outs = app.mediaDevs.audioOutputs;
        for (var i = 0; i < outs.length; i++) {
            if (String(outs[i].id).indexOf(_combineSinkName) !== -1) {
                _combinePendingRoute = false;
                // Bounce through another device first while playing: a
                // re-enable recreates the combined sink under the SAME name,
                // and Qt treats the same-id assignment as a no-op — the live
                // stream stays bound to the DEAD node, silent while claiming
                // to play. Seen live: four orphaned streams on one session.
                if (app.isPlaying()) {
                    var bounce = _combineBounceTarget(outs);
                    if (bounce !== null) app.playerOutput.device = bounce;
                }
                app.setAudioOutputDevice(String(outs[i].id));
                return;
            }
        }
    }

    // A loopback skipped mid-build because its sink was still registering —
    // bounded retries; the outputs-changed rebuild covers anything later.
    property int _combineLbRetries: 0

    Timer {
        id: combineLbRetry
        interval: 1500
        repeat: false
        onTriggered: _combineRebuildLoopbacks()
    }

    // Which sinks the last build reported missing — a DIFFERENT miss set
    // means a new speaker is registering and deserves its own full retry
    // budget; the cap only ever exhausts against the same stuck sink(s).
    property string _combineLbMissLast: ""

    function _combineHandleMiss(out) {
        var misses = [];
        var missRe = /LBMISS (\S+)/g, missM;
        while ((missM = missRe.exec(out || "")) !== null) misses.push(missM[1]);
        if (misses.length === 0) {
            _combineLbRetries = 0;
            _combineLbMissLast = "";
            return;
        }
        var missKey = misses.sort().join("|");
        if (missKey !== _combineLbMissLast) {
            _combineLbMissLast = missKey;
            _combineLbRetries = 0;
        }
        // 8 × 1.5 s: a Bluetooth speaker's sink registers up to ~6 s after
        // the connect (measured on a JBL Xtreme 3) — the old 3-try window
        // closed before the sink existed and the speaker never joined.
        if (_combineActive && _combineLbRetries < 8) {
            _combineLbRetries++;
            combineLbRetry.restart();
        }
    }

    // ── Sync join watchdog ───────────────────────────────────────────────────
    // bluetoothctl saying "Connected: yes" does not mean audio: some speakers
    // (JBLs, notoriously) come up without their A2DP profile on the first
    // page, so no sink ever appears — the fix a human eventually finds is
    // "connect it again". This watchdog does exactly that, once, on its own:
    // after a connect that should JOIN the sync it checks every 2 s that the
    // speaker's sink and its loopback actually materialized, nudges a rebuild
    // if only the loopback is missing, and cycles the Bluetooth connection if
    // the sink itself never showed up. Bounded; gives up with a note.
    property string _btJoinWatchMac: ""
    property string _btJoinWatchName: ""
    property int _btJoinWatchTicks: 0
    property bool _btJoinKicked: false
    // The kick shell lives for up to ~21 s and its reconnect phase cannot be
    // recalled — if the user clicks Disconnect inside that window, their
    // choice would be silently reverted. Tracked so the kick's handler can
    // undo its own reconnect the moment it lands.
    property string _btKickMac: ""
    property bool _btKickAbort: false
    // The kick's own round-trip (up to ~21 s) plus the sink registration
    // after it (~6 s) together outrun the 15-tick give-up — the watch used
    // to declare "did not join" while the cure was still being applied.
    // Ticks hold while the kick is in flight and restart from zero when it
    // lands, so the reconnected speaker gets the full window again.
    property bool _btKickInFlight: false

    // A second speaker connecting while one is already being walked in
    // waits its turn here — the single slot used to be overwritten, which
    // silently orphaned the FIRST speaker's watch. {mac, name} entries.
    property var _btJoinWatchQueue: []

    // Bluetooth members this group has actually seen playing. A speaker whose
    // transport dies leaves the device list entirely: the signature it was
    // part of is gone with it, the missing-loopback check has no member to
    // find, and nothing is left that could notice. Remembering who was here
    // is what turns that silence into something the watchdog can act on.
    property var _btMembersSeen: ({})

    function _btWatchLostMembers() {
        var members = _combineRealSinks();
        for (var i = 0; i < members.length; i++) {
            var mac = _btMacOfSink(members[i]);
            if (mac !== "") _btMembersSeen[mac] = members[i];
        }
        var outs = app.mediaDevs ? app.mediaDevs.audioOutputs : [];
        for (var known in _btMembersSeen) {
            var here = false;
            for (var o = 0; o < outs.length; o++)
                if (_btMacOfSink(String(outs[o].id)) === known) { here = true; break; }
            if (here) continue;
            var lastName = _btMembersSeen[known];
            delete _btMembersSeen[known];
            // A speaker the listener has sat out is not lost, it is dismissed.
            if (!syncDeviceIncluded(String(known).toUpperCase())) continue;
            console.log("[ARP] sync: " + lastName + " left the group without being"
                        + " asked — walking it back in");
            _btJoinWatchArm(known, lastName);
        }
    }

    function _btJoinWatchArm(mac, name) {
        if (!(_combineWantActive || _combineActive) || !app._btValidMac(mac)) return;
        if (_btJoinWatchMac !== "" && _btJoinWatchMac !== mac) {
            for (var q = 0; q < _btJoinWatchQueue.length; q++)
                if (_btJoinWatchQueue[q].mac === mac) return;
            _btJoinWatchQueue = _btJoinWatchQueue.concat([{ mac: mac, name: name || "" }]);
            return;
        }
        _btJoinWatchMac = mac;
        _btJoinWatchName = name || "";
        _btJoinWatchTicks = 0;
        _btJoinKicked = false;
        btJoinWatch.restart();
    }

    function _btJoinWatchStop() {
        btJoinWatch.stop();
        _btJoinWatchMac = "";
        _btJoinWatchName = "";
        // A kick whose ack never lands must not paralyze every FUTURE
        // watch's tick hold — the stopped watch takes its flag with it.
        // (A kick that DOES land later clears it again, harmlessly.)
        _btKickInFlight = false;
        if (!(_combineWantActive || _combineActive)) {
            // Sync went off — nobody left to walk in.
            _btJoinWatchQueue = [];
            return;
        }
        // The freed slot goes to the next speaker waiting its turn — but a
        // queued speaker can go stale while it waits. The RUNNING watch
        // re-checks this on every tick and gives up when the user sits the
        // speaker out; a queued one used to be armed regardless, so a
        // speaker disconnected or unticked during the wait was paged, and
        // the kick dragged it back into a group it had been dismissed from.
        while (_btJoinWatchQueue.length > 0) {
            var nxt = _btJoinWatchQueue[0];
            _btJoinWatchQueue = _btJoinWatchQueue.slice(1);
            if (!syncDeviceIncluded(String(nxt.mac).toUpperCase())) continue;
            _btJoinWatchArm(nxt.mac, nxt.name);
            return;
        }
    }

    // The user disconnected or forgot this speaker by hand — every claim
    // the watchdog holds on it goes too: the queued turn, the active slot,
    // and the lost-members memory that would otherwise page it again the
    // moment its sink disappears. Dismissal used to clear only the active
    // slot, so a QUEUED speaker still got its profile bounce and a false
    // "did not join the sync" toast once the slot freed up.
    function _btJoinWatchDismiss(mac) {
        var want = String(mac).toUpperCase();
        if (_btMembersSeen[want] !== undefined) delete _btMembersSeen[want];
        var keep = [];
        for (var i = 0; i < _btJoinWatchQueue.length; i++)
            if (String(_btJoinWatchQueue[i].mac).toUpperCase() !== want)
                keep.push(_btJoinWatchQueue[i]);
        if (keep.length !== _btJoinWatchQueue.length) _btJoinWatchQueue = keep;
        if (_btJoinWatchMac !== "" && String(_btJoinWatchMac).toUpperCase() === want)
            _btJoinWatchStop();
    }

    Timer {
        id: btJoinWatch
        interval: 2000
        repeat: true
        onTriggered: _btJoinWatchTick()
    }

    function _btJoinWatchTick() {
        if (!(_combineActive || _combineWantActive) || _btJoinWatchMac === "") {
            _btJoinWatchStop();
            return;
        }
        // The connect/pair attempt itself is still in flight — its retry path
        // pages a sleeping speaker for up to ~36 s, and a kick's disconnect
        // here would sabotage the very attempt being guarded. Hold the count
        // until bluez has given its verdict (the handler re-arms on success
        // and stops the watch on failure). Same hold during our own kick.
        if (app._btConnectingMac !== "" || app._btPairingMac !== "" || _btKickInFlight) return;
        // The user sat this speaker out of the group mid-watch — there is
        // nothing to walk in anymore, and a kick would drag it back.
        if (!syncDeviceIncluded(_btJoinWatchMac.toUpperCase())) {
            _btJoinWatchStop();
            return;
        }
        _btJoinWatchTicks++;
        var token = _btJoinWatchMac.toLowerCase().replace(/:/g, "_");
        var outs = app.mediaDevs.audioOutputs;
        var sinkUp = false;
        for (var i = 0; i < outs.length; i++)
            if (String(outs[i].id).toLowerCase().indexOf(token) !== -1) { sinkUp = true; break; }
        if (sinkUp) {
            for (var mod in _combineLoopbackSinkByModule) {
                if (String(_combineLoopbackSinkByModule[mod]).toLowerCase().indexOf(token) !== -1) {
                    // In the group — but "sink up + loopback attached" can
                    // still be silence: a transport that came back under a
                    // LIVE loopback plays into a dead pipe (measured live —
                    // signal flowing, nothing in the air). One flush as the
                    // watchdog signs off clears it; harmless when healthy.
                    var okSink = String(_combineLoopbackSinkByModule[mod]).replace(/'/g, "'\\''");
                    app.exec(": PW_FLUSH; pactl suspend-sink '" + okSink + "' 1;"
                             + " pactl suspend-sink '" + okSink + "' 0; true # " + app.nextSeq());
                    _btJoinWatchStop();
                    // The flush just re-rolled the A2DP buffer — read the
                    // fresh report and recompensate if it moved.
                    refLatProbeTimer.restart();
                    return;
                }
            }
            // Sink is up but no loopback feeds it — the outputs-changed
            // signal was missed somehow; ask for a rebuild. Every OTHER tick,
            // and only when no rebuild or retry is already scheduled: each
            // rebuild swaps every loopback (a blink on all speakers), so the
            // nudge must never turn into a drumbeat.
            if (_btJoinWatchTicks % 2 === 1 && !_combineReloopBusy
                && !syncOffsetDebounce.running && !combineLbRetry.running)
                syncOffsetDebounce.restart();
        } else if (_btJoinWatchTicks >= 4 && !_btJoinKicked) {
            // ~8 s connected with no sink: the audio profile did not come
            // up. Bounce the card's A2DP PROFILE — that renegotiates the
            // transport without ever touching the link. The old full
            // disconnect/reconnect cycle is gone for cause: measured on a
            // JBL Flip 7, a software disconnect can DESTROY the pairing
            // outright (Paired: no, AuthenticationCanceled on re-pair) —
            // a missing speaker with an honest toast beats an unpaired one.
            _btJoinKicked = true;
            _btKickMac = _btJoinWatchMac;
            _btKickAbort = false;
            _btKickInFlight = true;
            // The bounce itself lives in main.qml — the solo kick walks the
            // same road, and two copies of one shell drift apart.
            app.exec(": BT_KICK " + _btJoinWatchMac + "; "
                + app.btProfileBounceShell(_btJoinWatchMac)
                + " # " + app.nextSeq());
        }
        if (_btJoinWatchTicks >= 15) {
            // ~30 s is past every observed good case — stop, and say why the
            // speaker is absent instead of leaving a silently missing device.
            var gaveUpName = _btJoinWatchName || _btJoinWatchMac;
            _btJoinWatchStop();
            app.notify(i18n("%1 did not join the sync", gaveUpName),
                       sinkUp
                       ? i18n("The speaker is connected but could not be pulled into the group — switch the sync off and on to rebuild it.")
                       : i18n("The speaker is connected but its audio output never appeared — switch the speaker off and on, then connect it again."),
                       "network-bluetooth");
        }
    }

    // Switch-on-connect steal watch. The RELOOP reclaim only takes the
    // default back from GROUP members — a device excluded from the sync
    // never triggers a rebuild when it reconnects (the group signature is
    // unchanged), so WirePlumber handing it the default would stand and the
    // volume keys would silently move a speaker that plays nothing. The
    // precise tell: a steal lands on a sink that APPEARED just now — a sink
    // the user cannot have picked by hand in the same instant. Only such
    // just-appeared sinks are ever taken back here; a default moved to any
    // pre-existing device remains the user's word.
    property var _outputIdsSnapshot: []
    property var _defaultStealSuspects: []

    function _combineDefaultStealWatch() {
        var outs = app.mediaDevs.audioOutputs;
        var ids = [];
        for (var i = 0; i < outs.length; i++) ids.push(String(outs[i].id));
        var prev = _outputIdsSnapshot;
        _outputIdsSnapshot = ids;
        if (!(_combineActive || _combineWantActive)) return;
        var suspects = _defaultStealSuspects.slice();
        for (var n = 0; n < ids.length; n++) {
            if (prev.indexOf(ids[n]) !== -1) continue;
            if (ids[n].indexOf(_combineSinkName) !== -1) continue; // our own sink
            if (suspects.indexOf(ids[n]) === -1) suspects.push(ids[n]);
        }
        if (suspects.length === 0) return;
        _defaultStealSuspects = suspects;
        // Delayed: WirePlumber applies its policy at about the same moment
        // the sink appears — checking instantly would race it and miss.
        defaultStealCheck.restart();
    }

    Timer {
        id: defaultStealCheck
        interval: 1200
        repeat: false
        onTriggered: {
            var suspects = _defaultStealSuspects;
            _defaultStealSuspects = [];
            if (!(_combineActive || _combineWantActive) || suspects.length === 0) return;
            var cmd = ": PW_STEALBACK; d=$(pactl get-default-sink 2>/dev/null); ";
            for (var i = 0; i < suspects.length; i++)
                cmd += "[ \"$d\" = '" + suspects[i].replace(/'/g, "'\\''") + "' ] && "
                     + "pactl set-default-sink " + _combineSinkName + " 2>/dev/null; ";
            app.exec(cmd + "true # " + app.nextSeq());
        }
    }
}
