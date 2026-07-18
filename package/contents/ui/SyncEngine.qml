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

    // Everything the engine started at startup() — availability probe, the
    // crash sweep, restore-key consumption, the steal-watch seed and the
    // persisted per-device maps.
    function startup() {
        _loadDeviceTrims();
        _loadDeviceChannels();
        _loadSyncExcluded();
        app.exec(": PW_PROBE; command -v pactl >/dev/null 2>&1 && echo __PACTL_YES__; true");
        // A session that died mid-measurement left its park levels (and the
        // verify's hardware mutes) behind — the restore file it never got
        // to delete puts the room back the way the user had it.
        // XDG_RUNTIME_DIR only — never a world-writable /tmp fallback: this
        // file is REPLAYED with sh at startup, so a predictable shared path
        // would let another local user pre-plant commands (or a symlink to
        // redirect the park writes). /run/user/<uid> is 0700 and ours; with
        // no runtime dir the park recovery is simply skipped.
        app.exec(": PW_PARKREST; d=\"$XDG_RUNTIME_DIR\"; f=\"$d/onair_park_" + app.instanceId + ".sh\";"
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
        // A hardware sink came or went while the combined output is live —
        // rebuild the loopbacks for the CURRENT set. Snapshot-compared, or
        // the null sink's own appearance would trigger a rebuild and double
        // every loopback.
        if (_combineActive
            && _combineGroupSignature() !== _combineSinksSnapshot)
            syncOffsetDebounce.restart();
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
        if (_calibrating || _verifyPending) {
            _calibrating = false;
            _verifyPending = false;
            _verifyCorrected = false;
            _rebuildHeld = false;
            calibGuardTimer.stop();
            verifySettleTimer.stop();
            verifyGuardTimer.stop();
            _verifyUnmuteAll();
            _calibRestoreVolume();
            _calibRunSeq++;
        }
        _resurrectTries = 6;
        combineOutputsEnable();
    }

    // Every engine-owned shell round-trip lands here from main.qml's exec
    // handler; true = the command was ours and is fully handled.
    function handleExec(cmd, stdout, stderr) {
        if (cmd.indexOf(": PW_UNCOMBINE;") === 0 || cmd.indexOf(": PW_COMBINE_CLEAN;") === 0
            || cmd.indexOf(": PW_TRIM;") === 0 || cmd.indexOf(": PW_STEALBACK;") === 0
            || cmd.indexOf(": PW_RAMP;") === 0 || cmd.indexOf(": PW_PARKREST;") === 0) {
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
            var nullM = pwOut.match(/NULL (\d+)/);
            // What was the default before this load switched it? ANY
            // combined name — this instance's, another's, a superseded
            // enable's from a fast toggle, a pre-2026.14 leftover — means
            // there is nothing real to restore: persisting it would point
            // the default at a dead node on the next disable.
            var prevDefM = pwOut.match(/PREVDEF (\S+)/);
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
            var rampTo = Math.max(10, Math.min(100, cfg.combineMasterPct || 100));
            var rampCmd = "";
            var rampSteps = [35, 50, 65, 80, 90, 100].filter(function(rs) { return rs < rampTo; });
            rampSteps.push(rampTo);
            for (var rp = 0; rp < rampSteps.length; rp++)
                rampCmd += "pactl set-sink-volume " + _combineSinkName + " "
                         + rampSteps[rp] + "% 2>/dev/null; sleep 0.12; ";
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
            var mM = (stdout || "").match(/MASTER (\d+)/);
            if (mM) cfg.combineMasterPct = Math.max(10, Math.min(100, parseInt(mM[1], 10)));
            if (!_combineActive && !_combineWantActive)
                cfg.combinePrevDefault = "";
            // The park's unload has fully landed — a wake that arrived
            // mid-tail can now take the clean road.
            _combineParkTail = false;
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
            var okM = (stdout || "").match(/CALIB_OK (\d+)/);
            var macM = cmd.match(/^: PW_CALIB \d+ ([0-9A-F:]{17}) /);
            // The park level this very run measured at — the sentinel
            // carries it so a louder retry's levels fold with the right
            // reference (pre-park commands default to the historic 55).
            var parkM = cmd.match(/ P(\d+) ;/);
            var calPark = parkM ? Math.max(1, parseInt(parkM[1], 10)) : 55;
            if (okM) {
                // Same ceiling as calibrate.py's own sanity window — a
                // 600 ms television is a real measurement, not an error,
                // and clamping it to 500 would report a made-up number.
                var calMs = Math.max(0, Math.min(900, parseInt(okM[1], 10)));
                cfg.syncOffsetMs = calMs;
                try {
                    var calMap = JSON.parse(cfg.syncOffsetMap || "{}");
                    if (macM) calMap[macM[1]] = calMs;
                    // Wired/extra sinks measured in the same run: CALIB_XLAG
                    // is each one's real lag against the wired reference — a
                    // USB DAC or an HDMI TV stops being assumed zero. Same
                    // map, keyed by sink name (names cannot collide with
                    // MACs); negative = faster than the reference.
                    var xRe = /^CALIB_XLAG (\S+) (-?\d+)/gm, xM;
                    while ((xM = xRe.exec(stdout || "")) !== null)
                        calMap[xM[1]] = Math.max(-100, Math.min(900, parseInt(xM[2], 10)));
                    cfg.syncOffsetMap = JSON.stringify(calMap);
                } catch (e) {}
                // Snapshot the transport's reported latency as the
                // reference this fresh number was measured under — the
                // silent recompensation shifts against it from now on.
                if (macM) _refLatProbe(macM[1], true);
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
                if (lvls.length >= 2) {
                    var refAmp = lvls[0].amp;
                    for (var li = 1; li < lvls.length; li++)
                        if (lvls[li].amp < refAmp) refAmp = lvls[li].amp;
                    for (var lj = 0; lj < lvls.length; lj++) {
                        var trimKey = _trimKeyForSink(lvls[lj].sink);
                        var newTrim = Math.pow(refAmp / lvls[lj].amp, 1 / 3);
                        // The measurement wins — that is what the button
                        // promises — but replacing a balance somebody set
                        // by hand must never happen without a word.
                        if (_deviceTrims[trimKey] !== undefined
                            && Math.abs(trimOf(trimKey)
                                        - Math.max(0.05, Math.min(1, newTrim))) > 0.05)
                            trimsReplaced = true;
                        setDeviceTrim(trimKey, newTrim);
                    }
                    leveled = true;
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
                var micM = (stdout || "").match(/^CALIB_MIC (.+)/m);
                if (micM)
                    calText += " " + i18n("Measured with %1 — the default microphone stayed silent.", micM[1].trim());
                app.notify(i18n("Speakers calibrated"), calText, "audio-input-microphone");
            } else {
                // Every microphone in the room delivered exact zeros — a
                // hardware mute (the touch button on the mic itself) that no
                // software flag reports. Louder clicks cannot fix a deaf
                // ear, so this failure never escalates the park.
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
                // so no music blasts between the rounds.
                if (calPark < 85 && _combineActive
                    && (stdout || "").indexOf("no click heard") !== -1) {
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
                        app.notify(i18n("Calibration"),
                                   i18n("The clicks were too quiet for this room — trying once more, louder."),
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
            var vM = (stdout || "").match(/VERIFY_OK (\d+)/);
            cfg.syncVerifiedMs = vM ? parseInt(vM[1], 10) : -1;
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
                var lagRe = /VERIFY_LAG (\S+) (\d+)/g, lagM;
                var residuals = {};
                while ((lagM = lagRe.exec(stdout || "")) !== null)
                    residuals[lagM[1]] = parseInt(lagM[2], 10);
                _verifyCorrected = true;
                var vText, vIcon;
                if (vSpreadNow <= 900) {
                    // Write the corrected map BEFORE unmuting: _verifyUnmuteAll
                    // releases any rebuild held during the measurement, and a
                    // rebuild that fires here must carry the NEW delays — or
                    // pass 2 measures the old ones and reports "still N apart".
                    try {
                        var vMap = JSON.parse(cfg.syncOffsetMap || "{}");
                        for (var vs in residuals) {
                            if (residuals[vs] === 0) continue;
                            var vKey = _btMacOfSink(vs) || vs;
                            var vOld = parseInt(vMap[vKey], 10);
                            if (!isFinite(vOld)) vOld = 0;
                            var vStep = Math.max(-600, Math.min(600, residuals[vs]));
                            vMap[vKey] = Math.max(-100, Math.min(2000, vOld + vStep));
                        }
                        cfg.syncOffsetMap = JSON.stringify(vMap);
                    } catch (e) {}
                    vText = i18n("The speakers were %1 ms apart — adjusted from the measurement, checking once more.", vSpreadNow);
                    vIcon = "audio-input-microphone";
                } else {
                    // Bounce the Bluetooth members: suspend/resume flushes a
                    // wedged buffer where more delay never could.
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
            if ((stdout || "").indexOf("VERIFY_FAIL room not quiet") !== -1) {
                app.notify(i18n("Sync check"),
                           i18n("The room was not quiet enough to verify — pause other audio and calibrate once more."),
                           "dialog-warning");
                return true;
            }
            // The mic went hardware-mute between the rounds (its own touch
            // button — no software flag reports it): the calibration stands,
            // the check just could not listen.
            if ((stdout || "").indexOf("VERIFY_FAIL microphone silent") !== -1) {
                app.notify(i18n("Sync check"),
                           i18n("Every microphone delivered pure silence. A mic's own mute button is invisible to the system — check the light on the microphone itself, or set a working microphone as the default."),
                           "dialog-warning");
                return true;
            }
            // A speaker the presence phase could not hear: the room is NOT
            // confirmed, and saying so honestly beats a soothing verdict
            // computed from the survivors — the calibration itself stands.
            var pM = (stdout || "").match(/VERIFY_PARTIAL (\S+)/);
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
        if (cmd.indexOf(": PW_REFLAT ") === 0) {
            var rlM = cmd.match(/^: PW_REFLAT ([CS]) ([0-9A-F:]{17})/);
            if (!rlM) return true;
            var rlUs = (stdout || "").match(/REFLAT (\d+)/);
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
            var m1 = {};
            for (var k1 in _refLatShiftByMac) m1[k1] = _refLatShiftByMac[k1];
            m1[rlM[2]] = shift;
            _refLatShiftByMac = m1;
            console.log("[ARP] sync: " + rlM[2] + " transport latency moved "
                        + shift + " ms vs calibration — recompensating");
            if (_combineActive && !_combineReloopBusy && !syncOffsetDebounce.running)
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
        combineOutputsDisable(true);
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
    // A large reading waiting for its confirming twin (mac → ms).
    property var _refLatPending: ({})

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

    // Read one Bluetooth sink's PipeWire-reported latency. forCalib stores
    // it as the calibration-time REFERENCE; otherwise the ack compares the
    // reading against the reference and arms a corrective rebuild when the
    // transport has genuinely moved. Silent — no clicks, no interruption.
    function _refLatProbe(mac, forCalib) {
        if (!app._btValidMac(mac)) return;
        var macU = mac.replace(/:/g, "_");
        app.exec(": PW_REFLAT " + (forCalib ? "C" : "S") + " " + mac + "; "
                 + "pactl list sinks | awk '/^Sink #/{f=0} "
                 + "/Name: bluez_output." + macU + "/{f=1} "
                 + "f && /Latency:/{print \"REFLAT \" $2; exit}'; true # " + app.nextSeq());
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
        var cmds = "";
        for (var i = 0; i < sinks.length; i++) {
            var s = sinks[i].replace(/'/g, "'\\''");
            var d = 60 + (maxLag - lags[sinks[i]]);
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

    // Whether the calibration has both of its reference speakers IN the
    // group — the button grays out instead of silently doing nothing when
    // the only Bluetooth (or only wired) speaker was ticked out.
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
        calibGuardTimer.interval = 60000 + (calSinks.length - 2) * 15000;
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
            if (si === 1) argv += " ''"; // the mic placeholder sits between
                                         // the timing pair and the extras
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
        var parkFile = "\"$XDG_RUNTIME_DIR/onair_park_" + app.instanceId + ".sh\"";
        var parkSave = " [ -n \"$XDG_RUNTIME_DIR\" ] && : > " + parkFile + ";";
        for (var pf = 0; pf < calSinks.length; pf++)
            parkSave += " printf 'pactl set-sink-volume '\\''%s'\\'' %s\\n'"
                      + " \"$s" + pf + "\" \"${v" + pf + ":-" + park + "%}\" >> " + parkFile + ";";
        app.exec(": PW_CALIB " + calSeq + " " + _btMacOfSink(bt) + " P" + park + " ;"
            + setup
            + parkSave
            + " " + pre
            + " timeout " + calBudget + " python3 '" + script + "'" + argv + ";"
            + restore
            + " " + post
            + " rm -f " + parkFile + "; true # " + app.nextSeq());
        // Said AFTER the work is on its way (state before speech), because
        // it must be said: two rounds of clicks with a quiet check between
        // them read as "done" halfway through, and a calibration interrupted
        // at half-time is worse than none. The louder retry announces itself
        // from the failure handler instead — no second "started" toast.
        if (park === 55) {
            var calNote = i18n("Two rounds of clicks with a quiet check between them — about two minutes in total. The music stays silent until the check finishes.");
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

    function combineOutputsEnable() {
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
                        + " for sw in $(pactl list short modules 2>/dev/null"
                        + " | awk '/" + _combineSinkName + "([^0-9]|$)/ {print $1}'); do"
                        + " pactl unload-module \"$sw\" 2>/dev/null; done;"
                        + " m=$(pactl load-module module-null-sink"
                        + " sink_name=" + _combineSinkName + " channels=2"
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
        var masterParked = _calibrating || _verifyPending;
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
        if (_calibrating || _verifyPending) {
            _calibrating = false;
            _verifyPending = false;
            _verifyCorrected = false;
            _rebuildHeld = false;
            calibGuardTimer.stop();
            verifySettleTimer.stop();
            verifyGuardTimer.stop();
            _verifyUnmuteAll();
            _calibRestoreVolume();
            // The cancelled run's shell is still out there and its ack still
            // carries the CURRENT generation — without a bump it would pass
            // the staleness gate minutes later and act on a group that no
            // longer exists: a CALIB_OK arming the verify against nothing,
            // or a 'no click heard' launching an unasked-for 85% run over
            // whatever the user is listening to by then.
            _calibRunSeq++;
        }
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
            un = "d=$(pactl get-default-sink 2>/dev/null);"
               + (masterParked ? " " :
                  " cm=$(pactl get-sink-volume " + _combineSinkName
                  + " 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%');"
                  + " echo \"MASTER ${cm:-100}\";")
               + " " + unMods;
        }
        // Hand the system default back to whoever held it before the sync —
        // but only if it is still OURS to hand back: a default the user moved
        // elsewhere mid-session is their word, not a leftover to revert.
        if (_combinePrevDefault !== "") {
            un += "[ \"$d\" = \"" + _combineSinkName + "\" ] && pactl set-default-sink '"
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

    function setSyncOffset(ms) {
        cfg.syncOffsetMs = Math.round(ms);
        // The slider speaks for the CONNECTED device(s) — remember the value
        // per MAC so each speaker keeps its own lag across sessions.
        try {
            var map = JSON.parse(cfg.syncOffsetMap || "{}");
            var sinks = _combineRealSinks();
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
        if (_calibVolumeBefore >= 0 && app.playerOutput.volume === 0)
            app.playerOutput.volume = _calibVolumeBefore;
        _calibVolumeBefore = -1;
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
        for (var i = 0; i < vs.length; i++)
            un += "pactl set-sink-mute '" + vs[i].replace(/'/g, "'\\''") + "' 0; ";
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
                                    + (10 + n * 14) * 1000 + 12000;
        verifySettleTimer.restart();
        verifyGuardTimer.restart();
    }

    // Test seams — the timers themselves are private ids.
    function verifySettleInterval() { return verifySettleTimer.interval; }
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
        var vBudget = 10 + Math.min(8, sinks.length) * 14;
        // Same logout insurance as the calibration's: parks, the master and
        // the isolation's hardware mutes all land in a runtime file that
        // only a completed restore deletes — startup() replays a dead
        // session's leftovers.
        // XDG_RUNTIME_DIR only, same reason as the calibration's park file.
        var vParkFile = "\"$XDG_RUNTIME_DIR/onair_park_" + app.instanceId + ".sh\"";
        var vParkSave = " [ -n \"$XDG_RUNTIME_DIR\" ] && : > " + vParkFile + ";"
                      + " printf 'pactl set-sink-volume '\\''%s'\\'' %s\\n' "
                      + _combineSinkName + " \"${cm:-100%}\" >> " + vParkFile + ";";
        for (var vf = 0; vf < sinks.length && vf < 8; vf++)
            vParkSave += " printf 'pactl set-sink-volume '\\''%s'\\'' %s\\n'"
                       + " \"$w" + vf + "\" \"${y" + vf + ":-" + park + "%}\" >> " + vParkFile + ";"
                       + " printf 'pactl set-sink-mute '\\''%s'\\'' 0\\n' \"$w" + vf + "\" >> " + vParkFile + ";";
        app.exec(": PW_VERIFY " + _calibRunSeq + ";" + setup + vParkSave + " " + pre2
                 + " timeout " + vBudget + " python3 '" + script + "' verify '"
                 + _combineSinkName + "' ''" + argv + ";"
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
        // The freed slot goes to the next speaker waiting its turn.
        if (_btJoinWatchQueue.length > 0) {
            var nxt = _btJoinWatchQueue[0];
            _btJoinWatchQueue = _btJoinWatchQueue.slice(1);
            _btJoinWatchArm(nxt.mac, nxt.name);
        }
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
            var kickMacU = _btJoinWatchMac.replace(/:/g, "_");
            app.exec(": BT_KICK " + _btJoinWatchMac
                + "; c=bluez_card." + kickMacU
                // Remember the profile that was active — if BOTH standard
                // A2DP names fail after the off, restoring it is the last
                // resort that keeps the card from being left dead on "off".
                + "; p=$(timeout 3 pactl list cards | awk '/Name: bluez_card." + kickMacU + "/{f=1}"
                + " f && /Active Profile:/{print $3; exit}')"
                + "; timeout 5 pactl set-card-profile \"$c\" off >/dev/null 2>&1; sleep 1;"
                + " timeout 5 pactl set-card-profile \"$c\" a2dp-sink >/dev/null 2>&1"
                + " || timeout 5 pactl set-card-profile \"$c\" a2dp_sink >/dev/null 2>&1"
                + " || { [ -n \"$p\" ] && timeout 5 pactl set-card-profile \"$c\" \"$p\" >/dev/null 2>&1; }; true"
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
