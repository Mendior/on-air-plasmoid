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
        // A hardware sink came or went while the combined output is live —
        // rebuild the loopbacks for the CURRENT set. Snapshot-compared, or
        // the null sink's own appearance would trigger a rebuild and double
        // every loopback.
        if (_combineActive
            && _combineGroupSignature() !== _combineSinksSnapshot)
            syncOffsetDebounce.restart();
    }

    // Every engine-owned shell round-trip lands here from main.qml's exec
    // handler; true = the command was ours and is fully handled.
    function handleExec(cmd, stdout, stderr) {
        if (cmd.indexOf(": PW_UNCOMBINE;") === 0 || cmd.indexOf(": PW_COMBINE_CLEAN;") === 0
            || cmd.indexOf(": PW_TRIM;") === 0 || cmd.indexOf(": PW_STEALBACK;") === 0) {
            return true; // fire-and-forget
        }
        // Combined local output: pactl availability probe
        if (cmd.indexOf(": PW_PROBE;") === 0) {
            _combineAvailable = (stdout || "").indexOf("__PACTL_YES__") !== -1;
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
                _combineWantActive = false;
                _combinePrevOutput = "";
                // The persisted copy too — a stale key here used to make
                // the startup restore fire on every later login.
                cfg.combinePrevOutput = "";
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
            _combinePrevDefault = prevDef;
            cfg.combinePrevDefault = prevDef;
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
        // round-trip owns the key again and must keep it.
        if (cmd.indexOf(": PW_UNCOMBINE_DONE;") === 0) {
            if (!_combineActive && !_combineWantActive)
                cfg.combinePrevDefault = "";
            return true;
        }
        // Microphone calibration finished — apply and remember the lag.
        if (cmd.indexOf(": PW_CALIB") === 0) {
            _calibrating = false;
            calibGuardTimer.stop();
            var okM = (stdout || "").match(/CALIB_OK (\d+)/);
            var macM = cmd.match(/^: PW_CALIB ([0-9A-F:]{17}) /);
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
                    var xRe = /CALIB_XLAG (\S+) (-?\d+)/g, xM;
                    while ((xM = xRe.exec(stdout || "")) !== null)
                        calMap[xM[1]] = Math.max(-100, Math.min(900, parseInt(xM[2], 10)));
                    cfg.syncOffsetMap = JSON.stringify(calMap);
                } catch (e) {}
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
                var cvRe = /CALIBVOL (\S+) (\d+)%/g, cvM;
                while ((cvM = cvRe.exec(stdout || "")) !== null)
                    volBySink[cvM[1]] = Math.max(1, parseInt(cvM[2], 10));
                var lvls = [], lvlRe = /CALIB_LVL (\S+) (\d+)/g, lvlM;
                while ((lvlM = lvlRe.exec(stdout || "")) !== null) {
                    var lvlAmp = parseInt(lvlM[2], 10);
                    if (lvlAmp <= 0) continue;
                    // The clicks compared the speakers at an equal 55% —
                    // pure sensitivity. Playback runs at each sink's own
                    // restored level, so that level is folded back in
                    // (software volumes are cubic) or the trims would
                    // equalize a room the user never actually hears.
                    var calVol = volBySink[lvlM[1]] !== undefined ? volBySink[lvlM[1]] : 55;
                    lvls.push({ sink: lvlM[1],
                                amp: lvlAmp * Math.pow(calVol / 55, 3) });
                }
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
                // and the verify pass that restores it.
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
                var clRe = /CALIB_CLIP (\S+)/g, clM;
                while ((clM = clRe.exec(stdout || "")) !== null) clipped.push(clM[1]);
                if (clipped.length > 0)
                    calText += " " + i18n("The microphone clipped on %1 — that balance was left unchanged; lower the speaker's volume and calibrate again.", clipped.join(", "));
                app.notify(i18n("Speakers calibrated"), calText, "audio-input-microphone");
            } else {
                _calibRestoreVolume();
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
        if (cmd.indexOf(": PW_VERIFY;") === 0) {
            verifyGuardTimer.stop();
            if (!_verifyPending) return true;
            _verifyPending = false;
            // The isolation mutes members; the script unmutes in its own
            // finally-blocks, but a pactl that timed out on a drowsy
            // Bluetooth link was swallowed silently — belt and braces on
            // EVERY verdict, idempotent when everything already sings.
            _verifyUnmuteAll();
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
                // Re-armed before the toast, same rule as the calibration
                // ack: the second pass must not depend on the messenger.
                _combineRebuildLoopbacks();
                _verifyPending = true;
                _verifyArmTimers();
                app.notify(i18n("Sync check"), vText, vIcon);
                return true;
            }
            _calibRestoreVolume();
            // Other audio (a browser video, another player) reads as extra
            // arrivals and would make the verdict a dice roll — the script
            // discards polluted recordings and says why.
            if ((stdout || "").indexOf("VERIFY_FAIL room not quiet") !== -1) {
                app.notify(i18n("Sync check"),
                           i18n("The room was not quiet enough to verify — pause other audio and calibrate once more."),
                           "dialog-warning");
                return true;
            }
            // A speaker the presence phase could not hear: the room is NOT
            // confirmed, and saying so honestly beats a soothing verdict
            // computed from the survivors — the calibration itself stands.
            var pM = (stdout || "").match(/VERIFY_PARTIAL (\S+)/);
            if (pM) {
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
        if (cmd.indexOf(": BT_KICK;") === 0) {
            _btKickInFlight = false;
            if (_btKickAbort && app._btValidMac(_btKickMac))
                // Uniquified: an identical disconnect for the same MAC may
                // already be in flight from the user's own click, and the
                // exec dedup would silently swallow this one.
                app.exec(": BT_DISCONNECT; timeout 12 bluetoothctl disconnect "
                                + _btKickMac + "; true # " + app.nextSeq());
            else if (_btJoinWatchMac !== "" && _btJoinWatchMac === _btKickMac)
                _btJoinWatchTicks = 0; // fresh window for the reconnect
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
    function _lagForSink(sinkId) {
        var mac = _btMacOfSink(sinkId);
        try {
            var map = JSON.parse(cfg.syncOffsetMap || "{}");
            if (mac !== "") {
                if (map[mac] !== undefined)
                    return Math.max(0, Math.min(2000, parseInt(map[mac], 10) || 0));
            } else if (map[sinkId] !== undefined) {
                var w = parseInt(map[sinkId], 10);
                // The verify loop's corrections may push past the direct
                // calibration's own 900 ms sanity window — a through-path
                // lag includes loopback buffering the direct click never saw.
                if (isFinite(w)) return Math.max(-100, Math.min(2000, w));
            }
        } catch (e) {}
        return mac !== "" ? Math.max(0, Math.min(900, cfg.syncOffsetMs || 0)) : 0;
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

    function calibrateSync() {
        if (_calibrating || _verifyPending || !_combineActive) return;
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
        _calibrating = true;
        _verifyCorrected = false;
        // The natural moment to calibrate is WHILE listening — but program
        // audio through the live loopbacks either drowns the clicks (every
        // measurement fails) or a drum hit beats them in the peak search and
        // a plausible-but-wrong lag gets persisted for the device. Silence
        // the stream at its source for the measurement; the clicks are
        // played straight at the sinks and don't pass through it.
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
                  // the clicks are measured at the parked 55%, but playback
                  // happens at THIS level — the handler folds it back in.
                  + " echo \"CALIBVOL $s" + si + " ${v" + si + ":-55%}\";"
                  + " pactl set-sink-volume \"$s" + si + "\" 55%;";
            // Unquoted on purpose: $vN holds one %-value PER CHANNEL and
            // word-splitting hands pactl each as its own argument, so a
            // left/right balance survives the round-trip. An unreadable
            // volume falls back to the 55% the calibration itself used.
            restore += " pactl set-sink-volume \"$s" + si + "\" ${v" + si + ":-55%};";
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
        app.exec(": PW_CALIB " + _btMacOfSink(bt) + " ;"
            + setup
            + " " + pre
            + " timeout " + calBudget + " python3 '" + script + "'" + argv + ";"
            + restore
            + " " + post
            + " true # " + app.nextSeq());
        // Said AFTER the work is on its way (state before speech), because
        // it must be said: two rounds of clicks with a quiet check between
        // them read as "done" halfway through, and a calibration interrupted
        // at half-time is worse than none.
        var calNote = i18n("Two rounds of clicks with a quiet check between them — about two minutes in total. The music stays silent until the check finishes.");
        if (skipped.length > 0)
            calNote += " " + i18n("Skipped (empty jack): %1.", skipped.join(", "));
        app.notify(i18n("Calibration started"), calNote, "audio-input-microphone");
    }

    // Every load carries this generation: PipeWire happily loads a SECOND
    // null sink under the same name, so a stale in-flight load landing after
    // an enable→disable→enable would otherwise be adopted next to the live
    // set — every speaker gets two differently-delayed loopbacks (phasing)
    // and the first set leaks until the next session's sweep.
    property int _combineLoadSeq: 0

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
        _combinePrevOutput = cfg.audioOutputDevice || "";
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
        app.exec(": PW_COMBINE " + (++_combineLoadSeq) + ";"
                        + " d=$(pactl get-default-sink); echo \"PREVDEF $d\";"
                        + " m=$(pactl load-module module-null-sink"
                        + " sink_name=" + _combineSinkName + " channels=2"
                        + " sink_properties='device.description=\"" + desc + "\"')"
                        // Master starts at 100% = acoustic passthrough: every
                        // hardware sink keeps its own level, so enabling never
                        // jumps the loudness (copying one device's level here
                        // would double-apply it to that device). The default
                        // switch is best-effort — `true` keeps the group's
                        // exit status from gating the loopbacks, which are
                        // the actual feature.
                        + " && { echo \"NULL $m\";"
                        + " pactl set-sink-volume " + _combineSinkName + " 100% 2>/dev/null;"
                        + " pactl set-default-sink " + _combineSinkName + " 2>/dev/null; true; }"
                        + " && " + _combineLoopbackCmds(sinks) + "true"
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

    function combineOutputsDisable() {
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
        // Generation boundary: an in-flight rebuild's ack is stale from here
        // on and deliberately keeps its hands off these flags — a leftover
        // busy would deadlock every rebuild of the next enable.
        _combineReloopBusy = false;
        _combineReloopPending = false;
        _btJoinWatchStop();
        // Route away FIRST — with the choice already off the combined sink,
        // its removal is not a "device vanished" event worth a notification.
        app.setAudioOutputDevice(_combinePrevOutput);
        _combinePrevOutput = "";
        cfg.combinePrevOutput = "";
        var unMods = _combineUnloadCmd();
        var un = "";
        if (unMods !== "" || _combinePrevDefault !== "") {
            // The default is read BEFORE the unloads: destroying the combined
            // sink makes WirePlumber re-point the default on its own, and a
            // check made after that could no longer tell our sink was holding it.
            un = "d=$(pactl get-default-sink 2>/dev/null); " + unMods;
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
            _calibrating = false;
            _calibRestoreVolume();
        }
    }

    // The verify pass (check-measure) in flight: a calibration succeeded,
    // the loopbacks were rebuilt with the new delays, and the room is being
    // listened back to.
    property bool _verifyPending: false

    function _verifyUnmuteAll() {
        var un = "";
        var vs = _combineRealSinks();
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

    function _verifyArmTimers() {
        // The same member set the verify will actually measure — empty
        // jacks are skipped there, so they must not inflate the budget.
        var vs = _combineRealSinks().filter(function(s) { return !portUnplugged(s); });
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
        onTriggered: {
            if (!_verifyPending) return;
            var script = Qt.resolvedUrl("calibrate.py").toString().substring(7).replace(/'/g, "'\\''");
            // The group members ride along for the presence phase: the
            // verify must be able to say WHICH speaker it could not hear,
            // and the combined pass alone cannot (in-sync arrivals fuse).
            // Empty jacks are not members — an unpluggable partial verdict
            // about a hole in the air taught nobody anything.
            var sinks = _combineRealSinks().filter(function(s) { return !portUnplugged(s); });
            var argv = "";
            for (var vi = 0; vi < sinks.length && vi < 8; vi++)
                argv += " '" + sinks[vi].replace(/'/g, "'\\''") + "'";
            // Warm-up plus up to three captures per member — the same
            // arithmetic the guard was armed with.
            var vBudget = 10 + Math.min(8, sinks.length) * 14;
            app.exec(": PW_VERIFY; timeout " + vBudget + " python3 '" + script + "' verify '"
                     + _combineSinkName + "' ''" + argv + "; true # " + app.nextSeq());
        }
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
            // ~8 s connected with no sink: the audio profile did not come up.
            // Cycle the connection once — re-paging renegotiates A2DP.
            _btJoinKicked = true;
            _btKickMac = _btJoinWatchMac;
            _btKickAbort = false;
            _btKickInFlight = true;
            app.exec(": BT_KICK; timeout 5 bluetoothctl disconnect " + _btJoinWatchMac
                + " >/dev/null 2>&1; sleep 1;"
                // Wake the speaker's radio with an inquiry before re-paging —
                // the page itself is what sleeping speakers ignore.
                + " timeout 7 bluetoothctl --timeout 5 scan on >/dev/null 2>&1;"
                + " timeout 15 bluetoothctl connect " + _btJoinWatchMac + " >/dev/null 2>&1; true"
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
