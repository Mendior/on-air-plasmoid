/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The sliding buffer: the last minutes of a station, kept as short segments
// in a folder, for as long as the station plays.
//
// ffmpeg cuts the stream into MPEG-TS segments of SEG_SEC seconds and deletes
// the oldest as it goes, so the folder stays one window long. The player is
// never given ffmpeg's own playlist (measured on Qt 6.12 with FFmpeg 9: it
// cannot be searched and starts sixteen seconds short of its end) but a list
// this widget writes for the moment it wants to open: the segment that holds
// the moment first, then every later one, and no end mark, so the list can
// grow under the player. A search is a new list and a new open.
//
// Every place in the buffer is counted in milliseconds from the writer's
// first segment: segment n holds [n * SEG_MS, (n + 1) * SEG_MS). ffmpeg cuts
// at the first frame at or after each multiple of SEG_SEC, so that is true
// to one frame (26 ms of MP3) however long the writer has run.
//
// Pure functions; TimeshiftEngine.qml keeps the state and tsslide.sh touches
// the folder.
.pragma library
.import "PodcastLogic.js" as PodcastLogic
.import "StreamLogic.js" as StreamLogic

// Whole seconds, because the list says so in whole seconds: FFmpeg reads
// "#EXTINF:" with atof(), and under a Finnish, Estonian or German locale
// "3.996" is 3 (a 120 s list read as 93 s on the bench and a far search
// landed in the wrong place).
var SEG_SEC = 2;
var SEG_MS = SEG_SEC * 1000;

// How near the list's end an open may land. The player's reader runs ahead
// of the sound by a little over four seconds (measured: with 4.5 s of list
// left a stop came back at once, with 4.0 s it did not), and a reader that
// has run out of list waits inside FFmpeg for more. A player stopped while
// its reader waits there takes the whole desktop shell with it until the
// list grows or ends: measured 2.0 s after an end mark was written, 4.0 s
// after the list was taken away, and for good with neither. So the sound
// stays LEAVE_GAP_MS short of the list's end at every moment, and an open
// leaves room for one segment still being cut and one late look at the
// folder on top of that.
var LEAVE_GAP_MS = 7000;
var OPEN_GAP_MS = 12000;

// ffmpeg removes the oldest segment each time it finishes a new one. A list
// whose first segment was gone by the time the player came for it stood
// silent for 4.1 s on the bench, so an open keeps two segments clear of the
// oldest one on disk.
var KEEP_MS = 2 * SEG_MS;

// How far past the listener the list is kept filled, and how much of that
// may be used up before the folder is asked for more. It need not reach the
// newest segment, only stay well ahead of the reader; and one question costs
// 8 ms of processor (measured), so a listener a minute behind is asked for
// once in ten seconds, not with every beat.
var AHEAD_MS = 30000;
var GROW_SLACK_MS = 10000;

// One press of a step button, and how long a writer has to have run before
// one is offered: an open needs OPEN_GAP_MS and KEEP_MS of finished segments
// and the one being cut, and ffmpeg hands over its first segments about four
// seconds after it starts (4.2 s measured).
var STEP_MS = 30000;
var STEP_READY_MS = OPEN_GAP_MS + KEEP_MS + SEG_MS + 4000;

// The clock's beat, and the longest gap between two beats that is taken at
// its word. A longer one is the machine waking up or its clock being set,
// and neither moved the sound.
var TICK_MS = 1000;
var TICK_SANE_MS = 3000;

// How much of the stream the writer looks at before it decides what to cut.
var HEAD_BYTES = 4096;

// A pause is a place the listener left, and the window slides on behind it.
// Left to slide for good, a paused radio went on fetching the station until
// somebody pressed Stop, and the place was pushed out after one window all
// the same. So the capture ends just before the parked place would leave
// what is kept: what was cut stays, Play comes back to the pause, and a
// forgotten pause costs the line one window. The margin is what the clock
// cannot see of the folder: the two segments an open keeps clear of the
// oldest one, the last one a stopped writer still closes, and a station's
// first burst, by which the segments run ahead of the clock (4 s on the
// bench station; 64 KiB of a 32 kbit/s stream are 16 s).
var PARK_END_MS = 30000;

// Contract: true when a park at parkMs is PARK_END_MS or less from leaving a
// folder that keeps keepMs behind a clock at runMs. False for a park below
// 0, a window no longer than the margin, and anything that is no number.
function parkEndsCapture(parkMs, runMs, keepMs) {
    if (!_num(parkMs) || !_num(runMs) || !_num(keepMs) || parkMs < 0 || keepMs <= PARK_END_MS) return false;
    return runMs - parkMs >= keepMs - PARK_END_MS;
}

// The engine's clock is the writer's stream: it starts with the stream's
// first bytes and counts while the writer lives. So a writer may not outlive
// its stream. One that asked the station again after a stall went on cutting
// with a hole in its segments and a clock that had run through it: measured
// with a station silent for 40 s, a pause made three minutes later came back
// 21 s past its word, under a pill that read 0:44 for 0:30. The writer ends
// with its stream instead, and the station's next buffer is a new folder
// with a new clock.
// Whether that one may slide again is told by how long this one ran. A
// writer that worked for a minute was ended by the station or the line; one
// that ended sooner could not cut this station, and trying again with every
// start would be a gap with every pause.
var TRIED_MS = 60000;

// Contract: true when a cutting writer that ended after ranMs gives its
// station to the single file for the session: under TRIED_MS, and for a time
// that is no number.
function endedYoung(ranMs) {
    return !_num(ranMs) || ranMs < TRIED_MS;
}

// Where in the buffer a pause from the broadcast parks.
//   runMs  how long the writer has run: its clock, and the newest place
//   posMs  where the player is, counted on the writer's clock: the clock
//          at the moment the player joined the broadcast, and the player's
//          own position since
// The player and the writer join the station within a hundredth of a second
// and are sent the same first bytes, so the player's position is a place in
// the buffer. The writer's clock is not what the listener hears: the player
// took 3.2 s to make its first sound on the bench station, and a park made
// at the clock came back 4.2 s past the word it was pressed on. The sound is
// about a second behind the position (0.8 s measured), hence PARK_LAG_MS.
// A position more than PARK_TRUST_MS behind the clock is not believed: no
// start takes that long, and a position counted from the wrong moment once
// parked a listener 118 s before the word they paused on.
// Contract: posMs - PARK_LAG_MS, held to 0..runMs, when posMs is a number
// above 0, no more than two seconds past runMs and no more than
// PARK_TRUST_MS before it. Otherwise the guess the single file always made,
// PARK_GUESS_MS before the clock, not below 0. And 0 when runMs is no number.
var PARK_LAG_MS = 1000;
var PARK_GUESS_MS = 3000;
var PARK_TRUST_MS = 15000;

function parkAt(runMs, posMs) {
    if (!_num(runMs) || runMs < 0) return 0;
    if (_num(posMs) && posMs > 0 && posMs <= runMs + 2000 && posMs >= runMs - PARK_TRUST_MS)
        return Math.max(0, Math.min(runMs, posMs - PARK_LAG_MS));
    return Math.max(0, runMs - PARK_GUESS_MS);
}

// Contract: the number of the segment that holds place ms; 0 for a place
// before the start and for anything that is no number.
function segOf(ms) {
    return (_num(ms) && ms > 0) ? Math.floor(ms / SEG_MS) : 0;
}

// Contract: how many segments a window of windowMin minutes is, for ffmpeg's
// -hls_list_size. The window is held to 1..240 minutes, 60 for no number.
function listSize(windowMin) {
    var min = _num(windowMin) ? Math.max(1, Math.min(240, windowMin)) : 60;
    return Math.ceil(Math.floor(min) * 60 / SEG_SEC);
}

// What one beat of the clock adds to a running time.
// Contract: nowMs - lastMs when that is from 0 to TICK_SANE_MS; TICK_MS when
// it is longer or negative; 0 when either is no number or lastMs is not above
// 0 (the first beat has nothing to measure from).
function beat(lastMs, nowMs) {
    if (!_num(lastMs) || !_num(nowMs) || !(lastMs > 0)) return 0;
    var gone = nowMs - lastMs;
    return (gone >= 0 && gone <= TICK_SANE_MS) ? gone : TICK_MS;
}

// May an address go to the sliding writer at all? It looks at the stream's
// first bytes itself, so the address only has to not rule MP3 and AAC out:
// an ending that names another codec does, and so does a kind already
// learnt (KindLogic: "flac", "ogg" and "ogg-flac" are none of the two).
// Contract: true or false; false for anything that is no web address.
function mayCut(url, known) {
    if (typeof url !== "string" || !/^https?:\/\/./i.test(url)) return false;
    var whole = StreamLogic.streamFormat(url), ending = StreamLogic.streamFormat(url, true);
    if (whole === "hls" || whole === "playlist") return false;
    if (ending === "ogg" || ending === "opus" || ending === "flac") return false;
    return known !== "flac" && known !== "ogg" && known !== "ogg-flac";
}

// Where an open lands.
//   wantMs  the place wished for
//   first, last  the oldest and the newest finished segment in the folder
// Contract: { ok, startMs, firstSeg, seekMs, clamped }.
//   ok        false when the folder holds too little to open anything:
//             fewer than OPEN_GAP_MS plus KEEP_MS of segments, or numbers
//             that are none. Everything else is then 0 and "".
//   startMs   the place the sound starts at: wantMs, held between KEEP_MS
//             past the oldest segment's start and OPEN_GAP_MS short of the
//             newest one's end
//   firstSeg  the segment holding startMs, the list's first
//   seekMs    startMs inside that segment
//   clamped   "old" when wantMs lay before what is kept, "edge" when it lay
//             too near the end, "" otherwise
function openPlan(wantMs, first, last) {
    var no = { ok: false, startMs: 0, firstSeg: 0, seekMs: 0, clamped: "" };
    if (!_num(wantMs) || !_count(first) || !_count(last) || last < first) return no;
    var oldest = first * SEG_MS + KEEP_MS, newest = (last + 1) * SEG_MS - OPEN_GAP_MS;
    if (newest < oldest) return no;
    var start = Math.min(newest, Math.max(oldest, wantMs)), seg = segOf(start);
    return { ok: true, startMs: start, firstSeg: seg, seekMs: start - seg * SEG_MS,
             clamped: wantMs < oldest ? "old" : (wantMs > newest ? "edge" : "") };
}

// What a step does.
//   fromMs   the place the listener is at (heard or parked)
//   deltaMs  the step, negative for back
//   edgeMs   the end of the newest finished segment
// Contract: "live" for a step forward that would land less than OPEN_GAP_MS
// short of edgeMs, or with numbers that are none; "open" otherwise. A step
// back is never "live".
function stepWhat(fromMs, deltaMs, edgeMs) {
    if (!_num(fromMs) || !_num(deltaMs) || !_num(edgeMs)) return "live";
    return (deltaMs > 0 && fromMs + deltaMs > edgeMs - OPEN_GAP_MS) ? "live" : "open";
}

// Contract: the list for segments first..upto as text: the header, the
// first segment's number as the media sequence, the EVENT type, and for each
// segment "#EXTINF:<SEG_SEC>," and "seg-<n>.ts" on a line each. No end
// mark. "" when first or upto is no whole number from 0 up or upto < first.
function listText(first, upto) {
    var lines = entriesText(first, upto);
    if (lines === "") return "";
    return "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:" + SEG_SEC + "\n#EXT-X-MEDIA-SEQUENCE:" + first
           + "\n#EXT-X-PLAYLIST-TYPE:EVENT\n" + lines;
}

// Contract: the lines that add segments from..upto to a list, two a
// segment as in listText; "" for the same numbers listText refuses.
function entriesText(from, upto) {
    if (!_count(from) || !_count(upto) || upto < from) return "";
    var out = [], n;
    for (n = from; n <= upto; n++) out.push("#EXTINF:" + SEG_SEC + ",\nseg-" + n + ".ts\n");
    return out.join("");
}

// Which segments a list is asked to grow by.
//   listLast  the last segment the list names
//   placeMs   where the listener is
// Contract: { from, upto } so that the list reaches AHEAD_MS past placeMs;
// null while it reaches AHEAD_MS less GROW_SLACK_MS past it, and when a
// number is none. At most 32 at once.
function growBy(listLast, placeMs) {
    if (!_num(listLast) || Math.floor(listLast) !== listLast || listLast < -1 || !_num(placeMs)) return null;
    var want = segOf(placeMs + AHEAD_MS - 1);
    if (placeMs + AHEAD_MS - GROW_SLACK_MS <= (listLast + 1) * SEG_MS) return null;
    return { from: listLast + 1, upto: Math.min(want, listLast + 32) };
}

// Must the player be taken off its list? listEndMs is the end of the last
// segment the list names.
// Contract: true when less than LEAVE_GAP_MS of list lies ahead of placeMs,
// and when either is no number.
function mustLeave(listEndMs, placeMs) {
    if (!_num(listEndMs) || !_num(placeMs)) return true;
    return listEndMs - placeMs < LEAVE_GAP_MS;
}

// How far behind the broadcast a place is, for the pill. liveMs is the
// place a listener on the broadcast is at now: the writer's clock less the
// lag a park from live found between the two (parkAt). So a park reads 0:00
// the moment it is made and a second more with each beat, and a listener
// inside the buffer, whose place moves with the same beats, reads a number
// that stands still.
// Contract: liveMs - placeMs, never below 0; 0 when either is no number or
// placeMs is below 0 (no place).
function behindMs(liveMs, placeMs) {
    if (!_num(liveMs) || !_num(placeMs) || placeMs < 0) return 0;
    return liveMs > placeMs ? liveMs - placeMs : 0;
}

// "m:ss" for the pill.
// Contract: whole seconds, rounded; "0:00" for anything below half a second
// or no number; minutes are not wrapped into hours.
function clockText(ms) {
    var s = (_num(ms) && ms > 0) ? Math.round(ms / 1000) : 0, m = Math.floor(s / 60);
    s = s % 60;
    return m + ":" + (s < 10 ? "0" + s : s);
}

// The folder's answer (tsslide.sh have).
// Contract: { first, last } from "__TS_HAVE__ first=<n> last=<m>"; null when
// the line is missing, a number is, or last < first.
function parseHave(stdout) {
    var m = /(?:^|\n)__TS_HAVE__ first=(\d+) last=(\d+)(?:\n|$)/.exec(typeof stdout === "string" ? stdout : "");
    if (!m) return null;
    var first = parseInt(m[1], 10), last = parseInt(m[2], 10);
    return last < first ? null : { first: first, last: last };
}

// The answer to a list written or grown (tsslide.sh write / grow).
// Contract: { last, newest } from "__TS_LIST__ last=<n> newest=<m>": the last
// segment the list now names and the newest finished one in the folder
// (-1 when the helper could not say). null for anything else.
function parseList(stdout) {
    var m = /(?:^|\n)__TS_LIST__ last=(\d+)(?: newest=(-1|\d+))?(?:\n|$)/.exec(typeof stdout === "string" ? stdout : "");
    return m ? { last: parseInt(m[1], 10), newest: m[2] === undefined ? -1 : parseInt(m[2], 10) } : null;
}

// What the writer decided to cut (the wait's answer).
// Contract: "mp3" or "aac" from "__TS_KIND__ slide <codec>", "file" from
// "__TS_KIND__ file", "" for anything else, a second word included.
function parseKind(stdout) {
    var m = /(?:^|\n)__TS_KIND__ (slide (?:mp3|aac)|file)(?:\n|$)/.exec(typeof stdout === "string" ? stdout : "");
    return m ? (m[1] === "file" ? "file" : m[1].substring(6)) : "";
}

// The writer. o: cfgPath, dirPath, slidePath (the segments' folder), outPath
// (the single file, should the stream be neither MP3 nor AAC), pidPath,
// headPath, kindPath, probePath (streamkind.py), guardPath, windowMin,
// needKiB, seq.
// Contract: the command, or "" when a path is missing or seq is no number.
function buildWriter(o) {
    var q = PodcastLogic.shQuote, a = o || {}, i;
    var need = ["cfgPath", "dirPath", "outPath", "pidPath", "headPath", "kindPath", "probePath"];
    for (i = 0; i < need.length; i++) if (!_path(a[need[i]])) return "";
    if (!_folder(a.slidePath) || !_count(a.seq)) return "";
    var min = _num(a.windowMin) ? Math.max(1, Math.min(240, Math.floor(a.windowMin))) : 60;
    var windowSec = min * 60, wallSec = windowSec + Math.max(300, Math.ceil(windowSec * 0.10));
    var ff = "ffmpeg -hide_banner -nostdin -loglevel error -i pipe:0 -c copy";
    return ": TS_RUN; cln() { rm -f " + q(a.cfgPath) + " " + q(a.headPath) + " " + q(a.kindPath) + "; }; "
        + "if ! command -v ffmpeg >/dev/null 2>&1; then cln; echo __TS_NO_TOOL__; exit 0; fi; "
        + "if ! command -v curl >/dev/null 2>&1; then cln; echo __TS_NO_TOOL__; exit 0; fi; "
        + "mkdir -p " + q(a.dirPath) + " || { cln; echo __TS_FAIL__; exit 0; }; "
        + "avail=$(df -Pk " + q(a.dirPath) + " 2>/dev/null | awk 'NR==2{print $4}'); "
        + "if [ -n \"$avail\" ] && [ \"$avail\" -lt " + Math.floor(_num(a.needKiB) ? a.needKiB : 0)
        + " ] 2>/dev/null; then cln; echo __TS_NOSPACE__; exit 0; fi; "
        // curl runs with no wall-clock cap here: a sliding buffer has no
        // end. The single file keeps the cap it always had, on the cat
        // that feeds it. No --retry: a stream that stood still for half a
        // minute ends the writer, which is not to ask the station again
        // (TRIED_MS). -N, because a stop travels up this pipe a block
        // at a time: ffmpeg, cat and curl each learn of it with the next
        // one, and curl fills 4 KiB before it hands a block on. On a
        // 2 kB/s station the three were gone 3, 5 and 7 s after the stop.
        + "curl -sS -N -L --http0.9 -K " + q(a.cfgPath) + " -A 'VLC/3.0.20 LibVLC/3.0.20'"
        + " --speed-limit 1 --speed-time 30 | { exec 3<&0; "
        // The stream's own first bytes say what it is, on the connection
        // the writer makes anyway. ffmpeg is given them again in front of
        // the rest, so a container's header is not lost with them.
        + "head -c " + HEAD_BYTES + " <&3 > " + q(a.headPath) + " 2>/dev/null; "
        + "k=$(timeout 5 python3 " + q(a.probePath) + " --codec " + q(a.headPath) + " 2>/dev/null); "
        // A stop that came while the stream was being looked at found no
        // writer to signal, and it takes the address file first: without
        // that file this arm is over, and nothing is started for nobody.
        + "[ -e " + q(a.cfgPath) + " ] || exit 0; "
        + "case \"$k\" in mp3|aac) mkdir -p " + q(a.slidePath) + " 2>/dev/null || k= ;; *) k= ;; esac; "
        + "if [ -n \"$k\" ]; then echo \"slide $k\" > " + q(a.kindPath) + "; "
        + "{ cat " + q(a.headPath) + "; cat <&3; } | " + ff
        + " -f hls -hls_time " + SEG_SEC + " -hls_list_size " + listSize(min)
        + " -hls_segment_type mpegts -hls_flags delete_segments+temp_file"
        + " -hls_segment_filename " + q(a.slidePath + "/seg-%d.ts") + " -y " + q(a.slidePath + "/live.m3u8") + " 3<&- & "
        + "else echo file > " + q(a.kindPath) + "; "
        + "{ cat " + q(a.headPath) + "; timeout --signal=INT --kill-after=30 " + wallSec + " cat <&3; } | " + ff
        + " -flush_packets 1 -t " + windowSec + " -y " + q(a.outPath) + " 3<&- & fi; "
        // The three numbers the single file's writer leaves, for the same
        // guard and the same sweep: the writer, this shell and its host.
        // And the address file is looked for once more: a stop that came
        // between the look above and this line signalled nobody either.
        + "fp=$!; echo \"$fp $$ $PPID\" > " + q(a.pidPath) + "; "
        + "[ -e " + q(a.cfgPath) + " ] || kill -INT \"$fp\" 2>/dev/null; "
        // Its input is named, because here it would otherwise be the pipe
        // from curl, and a pipe someone still holds open never tells curl
        // that the writer has gone.
        + (_path(a.guardPath) ? "bash " + q(a.guardPath) + " watch \"$$\" \"$PPID\" \"$fp\" </dev/null >/dev/null 2>&1 3<&- & " : "")
        + "wait $fp; } & pid=$!; wait $pid; rc=$?; rm -f " + q(a.pidPath) + " " + q(a.cfgPath) + " " + q(a.headPath)
        + " " + q(a.kindPath) + "; bytes=$(stat -c %s " + q(a.outPath) + " 2>/dev/null || echo 0); "
        + "echo \"__TS_EXIT__ rc=$rc bytes=$bytes\"; true # " + a.seq;
}

// Waits for the writer's decision. o: kindPath, seq.
// Contract: the command; it answers "__TS_KIND__ slide mp3", "... slide aac",
// "... file", or "... none" when twenty seconds brought no decision. "" when
// kindPath is missing or seq is no number.
function buildKindWait(o) {
    var q = PodcastLogic.shQuote, a = o || {};
    if (!_path(a.kindPath) || !_count(a.seq)) return "";
    // The decision comes with the stream's first 4 KiB, which is a quarter
    // of a second of a 128 kbit/s station.
    return ": TS_KIND; i=0; while [ $i -lt 80 ]; do if [ -s " + q(a.kindPath) + " ]; then "
        + "echo \"__TS_KIND__ $(cat " + q(a.kindPath) + ")\"; exit 0; fi; i=$((i+1)); sleep 0.25; done; "
        + "echo \"__TS_KIND__ none\"; true # " + a.seq;
}

// The three folder commands. o: scriptPath, slidePath, seq and
//   have:   nothing more
//   write:  listName, text (listText), upto
//   grow:   listName, text (entriesText), from, upto
// Contract: the command, "" when a part is missing.
function buildHave(o) {
    var q = PodcastLogic.shQuote, a = o || {};
    if (!_path(a.scriptPath) || !_folder(a.slidePath) || !_count(a.seq)) return "";
    return ": TS_HAVE; bash " + q(a.scriptPath) + " have " + q(a.slidePath) + " 2>/dev/null; true # " + a.seq;
}

function buildWrite(o) {
    var q = PodcastLogic.shQuote, a = o || {};
    if (!_path(a.scriptPath) || !_folder(a.slidePath) || !_count(a.seq) || !_listName(a.listName)
        || typeof a.text !== "string" || a.text === "" || !_count(a.upto)) return "";
    return ": TS_LIST; printf '%s' " + q(a.text) + " | bash " + q(a.scriptPath) + " write " + q(a.slidePath) + " "
        + q(a.listName) + " " + a.upto + " 2>/dev/null; true # " + a.seq;
}

function buildGrow(o) {
    var q = PodcastLogic.shQuote, a = o || {};
    if (!_path(a.scriptPath) || !_folder(a.slidePath) || !_count(a.seq) || !_listName(a.listName)
        || typeof a.text !== "string" || a.text === "" || !_count(a.from) || !_count(a.upto) || a.upto < a.from) return "";
    return ": TS_GROW; printf '%s' " + q(a.text) + " | bash " + q(a.scriptPath) + " grow " + q(a.slidePath) + " "
        + q(a.listName) + " " + a.from + " " + a.upto + " 2>/dev/null; true # " + a.seq;
}

// The stop. o: pidPath, slidePath, cfgPath, headPath, kindPath, outPath, seq.
// The lists go first: a player whose reader waits on one is let go by its
// going, and the second the writer is given to close would hold it longer.
// The address file goes next, before the writer is signalled: a writer that
// is still looking at the stream has written no pid down yet, and the
// missing file is what tells it not to start (buildWriter).
// Contract: the command; "" unless slidePath is a folder of this widget's
// own naming (…/buffer-<n>.hls), which is what keeps a mistaken path from
// being removed with everything under it.
function buildStop(o) {
    var q = PodcastLogic.shQuote, a = o || {}, need = ["pidPath", "cfgPath", "headPath", "kindPath", "outPath"], i;
    for (i = 0; i < need.length; i++) if (!_path(a[need[i]])) return "";
    if (!_folder(a.slidePath) || !_count(a.seq)) return "";
    return ": TS_STOP; rm -f " + q(a.slidePath) + "/play-*.m3u8 2>/dev/null; rm -f " + q(a.cfgPath) + "; "
        + "[ -f " + q(a.pidPath) + " ] && read -r p _ < " + q(a.pidPath) + " && kill -INT \"$p\" 2>/dev/null; sleep 1; "
        + "rm -rf " + q(a.slidePath) + "; rm -f " + q(a.outPath) + " " + q(a.pidPath) + " "
        + q(a.headPath) + " " + q(a.kindPath) + "; true # " + a.seq;
}

// Ends the capture and leaves what was cut. o: pidPath, seq.
// The writer is signalled as a stop signals it and nothing is removed; its
// own command reports the end and tidies its small files.
// Contract: the command; "" when pidPath is missing or seq is no number.
function buildEnd(o) {
    var q = PodcastLogic.shQuote, a = o || {};
    if (!_path(a.pidPath) || !_count(a.seq)) return "";
    return ": TS_END; [ -f " + q(a.pidPath) + " ] && read -r p _ < " + q(a.pidPath) + " && kill -INT \"$p\" 2>/dev/null; true # " + a.seq;
}

function _num(x) {
    return typeof x === "number" && isFinite(x);
}

// A whole number from 0 up: a segment's number, a command's.
function _count(x) {
    return _num(x) && x >= 0 && Math.floor(x) === x;
}

function _path(x) {
    return typeof x === "string" && x !== "";
}

// The segments' folder as this widget names it and nothing else: it is
// removed with everything in it.
function _folder(x) {
    return typeof x === "string" && /^\/.*\/buffer-[0-9]+\.hls$/.test(x);
}

function _listName(x) {
    return typeof x === "string" && /^play-[0-9]+\.m3u8$/.test(x);
}
