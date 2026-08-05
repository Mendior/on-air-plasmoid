/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The arithmetic of pausing live radio. A background ffmpeg keeps copying
// the stream into a growing local file; the player either drinks from the
// live stream or from a position inside that file. Everything here is the
// judgment layer for that: how far behind live a position is, where a seek
// may land, how much disk a buffer is allowed to eat. Pure functions —
// they exist before the engine does, so the engine can be built against
// tested ground instead of the other way around.
.pragma library
.import "StreamLogic.js" as StreamLogic
.import "PodcastLogic.js" as PodcastLogic

// Same rule as recording, because a timeshift buffer IS a recording:
// plain http(s) streams only — playlist wrappers and HLS don't survive
// a "-c copy", and local files have nothing to shift.
function canTimeshift(url) {
    var s = (url || "").toString();
    if (!/^https?:\/\//i.test(s)) return false;
    var fmt = StreamLogic.streamFormat(s);
    return fmt !== "hls" && fmt !== "playlist";
}

// The buffer always copies, never re-encodes — it runs in the background
// for as long as the radio plays, so its CPU cost has to stay near zero.
// Judged strictly on the extension: a fuzzy "probably mp3" written into a
// .mp3 shell breaks the moment the codec is anything else; unknown codecs
// go into mka, which holds anything.
function bufferExtension(url) {
    var extMap = { "mp3": "mp3", "aac": "aac", "ogg": "ogg", "opus": "opus", "flac": "flac" };
    return extMap[StreamLogic.streamFormat(url, true)] || "mka";
}

// How far behind the live edge a playback position is. Wall time since the
// capture began is all the buffer can possibly hold; the player's position
// inside the file is how much of it has been spent.
function behindLiveMs(captureStartMs, nowMs, playPosMs) {
    var behind = (nowMs - captureStartMs) - playPosMs;
    return behind > 0 ? behind : 0;
}

// "Live" is a band, not a point — a file reader always trails the writer
// by a moment, and a chip that flickers between live and behind on every
// position event would be worse than none.
function isAtLiveEdge(behindMs, thresholdMs) {
    return behindMs <= thresholdMs;
}

// Where a seek may actually land: never before the buffer's start, never
// into the file's unfinished tail. The writer is mid-frame at the very
// end — a player sent there stalls or spits decoder errors, so the last
// edgeGuardMs stays out of reach.
function clampSeekMs(targetPosMs, capturedMs, edgeGuardMs) {
    var ceiling = capturedMs - edgeGuardMs;
    if (ceiling < 0) ceiling = 0;
    if (targetPosMs < 0) return 0;
    if (targetPosMs > ceiling) return ceiling;
    return targetPosMs;
}

// The compressed-stream estimate the recorder's disk pre-flight measured:
// ≈2 MiB per minute. The buffer refuses to be configured larger than the
// free space would survive, with headroom so it is never the thing that
// fills the disk to the brim.
function maxBufferMinutes(freeBytes, headroomBytes) {
    var usable = freeBytes - headroomBytes;
    if (usable <= 0) return 0;
    return Math.floor(usable / (2 * 1024 * 1024));
}

// What the pause button means while a buffer runs: remember where the
// listener stopped drinking, let the file keep growing, come back to the
// exact same sentence. The return is the file position to resume at —
// clamped like any other seek, because a pause can outlive the buffer
// cap and the start of the file may have been trimmed away by then.
function resumePositionMs(pausedAtPosMs, capturedMs, edgeGuardMs) {
    return clampSeekMs(pausedAtPosMs, capturedMs, edgeGuardMs);
}

// The writer, mirrored from the recorder's proven pipeline: curl owns the
// network (VLC agent, retries, --http0.9 for ICY servers, a 30 s stall
// give-up) and pipes into ffmpeg, which only repackages. The address
// never rides the argv — it waits in a 0600 config file the command
// cleans up on every exit road. Differences from a recording, both
// deliberate: always "-c copy" (a background buffer must cost no CPU)
// and "-flush_packets 1" (measured 2026-08-03: without it the file showed
// 0 bytes six seconds into a capture — the readable edge would trail the
// wall clock by ~16 s and the seek guard would have to eat the gap).
function buildBufferCommands(o) {
    var q = PodcastLogic.shQuote;
    var cfgLine = 'url = "' + String(o.url).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + '"';
    // mkdir lives HERE, not only in the run command — the config write is
    // the first thing to touch the directory, and without it the very
    // first arm on a machine failed before the writer ever existed. The
    // find sweep clears leftovers of crashed sessions; it keeps anything
    // younger than a day because a FRESH pid file may belong to the
    // previous arm's still-live writer, whose stop command needs it.
    var writeUrl = ": TS_URL; umask 077; mkdir -p " + q(o.dirPath) + " 2>/dev/null; "
        + "find " + q(o.dirPath) + " -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null; "
        + "printf '%s' " + q(cfgLine)
        + " > " + q(o.cfgPath)
        + " && echo __TS_URL_OK__ || echo __TS_URL_FAIL__; true # " + o.seq;
    var windowSec = Math.max(60, Math.floor(o.windowSec));
    var wallSec = windowSec + Math.max(300, Math.ceil(windowSec * 0.10));
    var run = ": TS_RUN; cln() { rm -f " + q(o.cfgPath) + "; }; "
        + "if ! command -v ffmpeg >/dev/null 2>&1; then cln; echo __TS_NO_TOOL__; exit 0; fi; "
        + "if ! command -v curl >/dev/null 2>&1; then cln; echo __TS_NO_TOOL__; exit 0; fi; "
        + "mkdir -p " + q(o.dirPath) + " || { cln; echo __TS_FAIL__; exit 0; }; "
        + "avail=$(df -Pk " + q(o.dirPath) + " 2>/dev/null | awk 'NR==2{print $4}'); "
        + "if [ -n \"$avail\" ] && [ \"$avail\" -lt " + Math.floor(o.needKiB)
        + " ] 2>/dev/null; then cln; echo __TS_NOSPACE__; exit 0; fi; "
        + "timeout --signal=INT --kill-after=30 " + wallSec
        + " curl -sS -L --http0.9 -K " + q(o.cfgPath)
        + " -A 'VLC/3.0.20 LibVLC/3.0.20'"
        + " --retry 20 --retry-delay 2 --speed-limit 1 --speed-time 30"
        + " | ffmpeg -hide_banner -nostdin -loglevel error -i pipe:0"
        + " -c copy -flush_packets 1 -t " + windowSec
        + " -y " + q(o.outPath)
        + " & pid=$!; echo $pid > " + q(o.pidPath) + "; "
        + "wait $pid; rc=$?; rm -f " + q(o.pidPath) + " " + q(o.cfgPath) + "; "
        + "bytes=$(stat -c %s " + q(o.outPath) + " 2>/dev/null || echo 0); "
        + "echo \"__TS_EXIT__ rc=$rc bytes=$bytes\"; true # " + o.seq;
    return { writeUrl: writeUrl, run: run };
}

// The loopback tap for streams the backend cannot drink from the socket:
// live Ogg-family wedges the ffmpeg backend within the first frames, but
// the SAME bytes served clean over loopback HTTP play indefinitely
// (measured 2026-08-05: direct socket froze at 278 ms; through the tap
// Lapfox ran eight minutes without a stall, duration pinned at 0 so the
// player treats it as the live stream it is). The tap is a raw-byte
// python server on purpose — an ffmpeg remuxer in this seat died at
// every Ogg chain boundary a reconnecting upstream wrote, a few seconds
// of silence apiece. The port check answers when the player may actually
// connect; a player sent to a refused port never retries (measured).
function buildServeCommands(o) {
    var q = PodcastLogic.shQuote;
    var run = ": TS_SRV; "
        + "if ! command -v python3 >/dev/null 2>&1; then echo __TS_SRV_DOWN__; exit 0; fi; "
        + "python3 " + q(o.scriptPath) + " " + q(o.bufPath) + " " + o.port
        + " >/dev/null 2>&1 & echo $! > " + q(o.srvPidPath) + "; "
        + "i=0; while [ $i -lt 40 ]; do "
        + "if ss -ltnH 2>/dev/null | grep -q ':" + o.port + " '; then echo __TS_SRV_UP__; exit 0; fi; "
        + "if ! command -v ss >/dev/null 2>&1; then sleep 1; echo __TS_SRV_UP__; exit 0; fi; "
        + "i=$((i+1)); sleep 0.25; done; "
        // The port never opened (taken, python crashed): a stuck tap would
        // hold its seat forever — reap it and let the player stand pat.
        + "kill \"$(cat " + q(o.srvPidPath) + " 2>/dev/null)\" 2>/dev/null; "
        + "rm -f " + q(o.srvPidPath) + "; "
        + "echo __TS_SRV_DOWN__; true # " + o.seq;
    return { run: run };
}

// SIGINT lands on ffmpeg (the pid file holds the pipeline's last member),
// which finalizes the container; curl leaves with the broken pipe. The
// buffer file goes too — a stopped shift has nothing to come back to —
// and so does the url config: a disarm can land in the window between
// the config write and the writer launch, where no cln exists yet to
// take the address off the disk. A relay arm's tap pid rides along; the
// buffer deletion doubles as its failsafe — the tap notices the file
// vanish and leaves on its own even when the pid file never got written.
function buildStopCommand(pidPath, outPath, cfgPath, seq, srvPidPath) {
    var q = PodcastLogic.shQuote;
    var srv = "";
    if (srvPidPath) {
        srv = "kill \"$(cat " + q(srvPidPath) + " 2>/dev/null)\" 2>/dev/null; "
            + "rm -f " + q(srvPidPath) + "; ";
    }
    return ": TS_STOP; " + srv + "[ -f " + q(pidPath) + " ] && kill -INT \"$(cat "
        + q(pidPath) + ")\" 2>/dev/null; sleep 1; rm -f " + q(outPath)
        + " " + q(pidPath) + " " + q(cfgPath) + "; true # " + seq;
}
