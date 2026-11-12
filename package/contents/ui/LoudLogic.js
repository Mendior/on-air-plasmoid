/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// How much quieter a saved station plays so that the next one is not a
// reach for the volume.
//
// Measured on 2026-11-11 over the twenty stations the widget ships with,
// sixty seconds each: the loudest stood at -7.8 LUFS and the quietest at
// -21.1, 13.3 dB apart, with the median at -12.3. A station louder than the
// target is turned down by the difference on this computer; a quieter one is
// left as it is, because turning up would clip and would raise the noise of
// a station that chose to be quiet.
//
// One reading is not a station. The same day one of the twenty read -14.8
// where the survey had it at -21.1, and an advert twice as loud in a
// reading's twenty seconds turns the programme behind it down by 6 dB too
// much. So up to five readings are kept for an address, taken on different
// days, and their median is what the station is turned down by. Pure
// functions; Loudness.qml listens and keeps the numbers.
.pragma library
.import "PodcastLogic.js" as PodcastLogic

// At -18 nineteen of the twenty are turned down and 3.1 dB of the 13.3 is
// left between them; -16 leaves 5.1 and reaches fourteen. The loudest loses
// 10.2 dB, which the listener has back with the system volume.
var TARGET_LUFS = -18;
// The most a station is turned down. The survey's largest cut was 10.2 dB;
// what a reading asks for beyond 15 is more likely a fault in the reading
// than a station, and must not make one inaudible.
var MAX_CUT_DB = 15;
// Seconds of the stream one reading listens to. Against the sixty-second
// figure twenty seconds were within 1.3 dB on every station; ten seconds
// missed one by 3.1 dB and five seconds one by 6.3 (speech, a quiet intro).
var LISTEN_S = 20;
// The helper's own wall clock, and the shell's above it. Twenty seconds of a
// stream arrive in less than twenty (a station sends a burst first: sixty
// seconds took 29 to 57), so this is reached only by one that stalls.
var HELPER_LIMIT_S = 40;
// A reading at or under this is no programme: dead air, or a stream that
// decoded to nothing. The quietest station measured was -21.1.
var SILENT_LUFS = -50;
// Nothing a decoder puts out is louder than this; what reads higher is not
// a loudness.
var LOUDEST_LUFS = 6;
// Readings kept for one address. Five is the fewest whose median two wrong
// ones cannot move, and each one is a connection to the station.
var KEEP = 5;
// A station's level moves with what it plays (one station's range was
// 11.5 LU), so once there are five the oldest is replaced when the newest
// is thirty days old.
var STALE_S = 30 * 86400;
// A station is connected to for a reading once a day at most, whether the
// last attempt gave a number or not: readings of one hour say the same
// thing five times, and one that told nothing is not worth a second
// connection the same day.
var RETRY_S = 86400;
// A listener's list is a few dozen stations and a large one a few hundred.
// An entry is its address and up to fifty characters, so a full map is in
// the order of the saved list itself.
var CAP = 512;
// A time is a whole second since 1970 and lies after 2001, or is 0 for
// "never". A smaller number is a clock that was not set, or not a time.
var EPOCH_S = 1000000000;
// How long a change of the cut under a listener takes: a reading that
// arrives, the option ticked or unticked, a device that joins or leaves.
// At two seconds ten decibels were an event, the radio was heard to drop.
// Over eight they are 1.25 dB a second, and the fifteen there can be at
// most under 2. Counted in dB, so that it is one pace all the way.
var EASE_MS = 8000;
// How long a station has sounded before it is listened to a second time.
// The start's own connections are over by then: the question what the
// stream is takes up to seven seconds (StreamKind.qml, where five
// connections inside one second were answered 429), and somebody zapping
// through the list is not followed from station to station.
var SETTLE_MS = 10000;

// How many dB a station that reads lufs is turned down.
// Contract: a number from -MAX_CUT_DB to 0; 0 for a station at or under the
// target and for anything that is not a finite number.
function cutDb(lufs) {
    if (!Number.isFinite(lufs)) return 0;
    return Math.max(-MAX_CUT_DB, Math.min(0, TARGET_LUFS - lufs));
}

// How many dB what plays is turned down.
//   f.on        the option
//   f.subject   the saved address what plays belongs to, "" when it is no
//               saved station's stream (subject())
//   f.alarmPct  the wake-up alarm's own level in percent, below zero while
//               none stands; an alarm has to be heard
//   f.casting   a device carries the stream now
//   f.local     this computer plays along with the devices. A device takes
//               the stream itself and nobody turns it down, so with this
//               computer cut beside it the balance between the two would
//               move with every station
//   f.lufs      the number that serves for the subject (lufsAt), null when
//               there is none
// Contract: cutDb(f.lufs), from -MAX_CUT_DB to 0; exactly 0 unless on is
// true, subject is text that is not empty, alarmPct is a number below zero
// and either casting or local is exactly false. Never throws.
function cut(f) {
    if (!f || f.on !== true || typeof f.subject !== "string" || f.subject === "") return 0;
    if (typeof f.alarmPct !== "number" || !(f.alarmPct < 0)) return 0;
    if (f.casting !== false && f.local !== false) return 0;
    return cutDb(f.lufs);
}

// The factor the listener's level is multiplied by for a cut of db.
// Contract: 10^(db/20), from 0.178 to 1; a cut beyond MAX_CUT_DB counts as
// that, and 1 for a db above 0 and for anything that is not a number.
function factor(db) {
    if (typeof db !== "number" || !(db < 0)) return 1;
    return Math.pow(10, Math.max(-MAX_CUT_DB, db) / 20);
}

// The saved address the stream on the player belongs to.
//   f.station  the address of the row the last station start was made for
//   f.source   the address the player holds
//   f.preview  the audition's address, "" when none is on
//   f.episode  an episode is on or being started
//   f.buffer   the path of the pause buffer, "" while there is none
//   f.saved    the saved list, as its JSON text or as rows
// Contract: f.station when it is a web address a saved row holds and the
// player is on a web address or on the pause buffer; "" for an audition, an
// episode, a file of the listener's, the wake-up tone, an empty player and
// for facts that cannot be read. Never throws.
function subject(f) {
    if (!f || f.preview !== "" || f.episode !== false || typeof f.source !== "string") return "";
    if (f.source.indexOf("file://") === 0) {
        if (typeof f.buffer !== "string" || f.buffer === "" || f.source !== "file://" + f.buffer) return "";
    } else if (!_web(f.source)) {
        return "";
    }
    return (_web(f.station) && isSaved(f.saved, f.station)) ? f.station : "";
}

// May the station that plays be listened to now?
//   f.on, f.subject      as for cut()
//   f.playing    the player plays
//   f.wanted     the standing order is up: Stop takes it down at once and
//                the player plays on for the length of the fade, and a
//                station that was just stopped is not connected to again
//   f.paused     the listener is parked in the pause buffer
//   f.healing    the stream comes from an address the heal is trying, not
//                from the saved one
//   f.alarmPct   as for cut(): a morning is not the moment for one more
//                connection to the station that has to wake somebody
//   f.recording  a recording runs, which is a connection of its own
//   f.at         the address the player is on, the relay's tap already
//                translated to its station
// Contract: true only when on, playing and wanted are exactly true, paused,
// healing and recording exactly false, alarmPct a number below zero, subject text that
// is not empty and at a web address of at most 2048 characters.
function asks(f) {
    if (!f || f.on !== true || f.playing !== true || f.wanted !== true) return false;
    if (f.paused !== false || f.healing !== false || f.recording !== false) return false;
    if (typeof f.alarmPct !== "number" || !(f.alarmPct < 0)) return false;
    return typeof f.subject === "string" && f.subject !== "" && _web(f.at);
}

// Contract: true when a row of the saved list (JSON text or rows) holds
// exactly this address.
function isSaved(saved, url) {
    if (typeof url !== "string" || url === "") return false;
    return _rows(saved).some(function(r) { return !!r && r.hostname === url; });
}

// The helper's answer.
// Contract: the number stdout holds, when it is one number with at most
// one decimal and nothing else, above SILENT_LUFS and at most
// LOUDEST_LUFS; null for everything else. One decimal is what the helper
// prints and what is kept, so what this gives is what withAnswer writes.
function answerOf(stdout) {
    var word = typeof stdout === "string" ? stdout.trim() : "";
    if (!/^-?\d{1,3}(\.\d)?$/.test(word)) return null;
    var lufs = parseFloat(word);
    return _reading(lufs) ? lufs : null;
}

// The number a list of readings stands for.
// Contract: their median; of an even count the quieter of the two in the
// middle. A reading that is too loud turns a station down too far, and
// nothing on the screen says why; one that is too quiet leaves it where it
// would have played without the option. null when readings is no list or
// holds no reading; what is no reading in it is not counted, and the list
// is left as it was.
function median(readings) {
    var heard = Array.isArray(readings) ? readings.filter(function(r) { return _reading(r); }) : [];
    if (heard.length === 0) return null;
    heard.sort(function(a, b) { return a - b; });
    return heard[Math.floor((heard.length - 1) / 2)];
}

// The readings are a JSON object, address -> [at, tried, lufs, ...], the
// address written last standing last. at is the second the newest reading
// was taken, 0 while there is none; tried the second of a later attempt that
// gave no number, 0 when the last attempt gave one; then the readings, one
// to KEEP of them, oldest first. Whatever is not that reads as empty.
//
// Contract: the readings kept for exactly this address, oldest first; []
// when there are none.
function readingsAt(text, url) {
    var own = _find(_entries(text), url);
    return own === null ? [] : own[3].slice();
}

// Contract: the number that serves for this address, the median of its
// readings; null when there is none. A row that moved keeps where it was as
// prev (the heal writes it), and until the new address has a reading of its
// own the old one's serve.
function lufsAt(text, saved, url) {
    var all = _entries(text), own = _find(all, url), rows, i, was;
    if (own !== null && own[3].length > 0) return median(own[3]);
    rows = _rows(saved);
    for (i = 0; i < rows.length; i++) {
        if (!rows[i] || rows[i].hostname !== url || typeof rows[i].prev !== "string") continue;
        was = _find(all, rows[i].prev);
        if (was !== null && was[3].length > 0) return median(was[3]);
    }
    return null;
}

// Is a reading to be taken of this address now?
// Contract: true for an address nothing is kept of. Otherwise false until
// RETRY_S have passed since the last attempt, with a number or without;
// from then on true while fewer than KEEP readings are kept, and with KEEP
// of them once the newest is older than STALE_S. A stamp more than a day
// ahead of nowS was written by a clock that was wrong and counts as old.
// False for what is no web address and for a nowS that is no time.
function due(text, url, nowS) {
    if (!_web(url) || !_clock(nowS)) return false;
    var e = _find(_entries(text), url), last;
    if (e === null) return true;
    last = Math.max(e[1], e[2]);
    if (last - nowS > RETRY_S) return true;
    if (nowS - last < RETRY_S) return false;
    return e[3].length < KEEP || nowS - e[1] > STALE_S;
}

// Contract: the map as JSON text with this address as its newest entry,
// this reading as the newest of its readings and the oldest dropped where
// that makes more than KEEP; at most cap entries (CAP when cap is no whole
// number above 0), the entry written longest ago dropped. A reading
// answerOf would not give, an address that is no web address and a nowS
// that is no time write nothing, and the map comes back as it was, tidied.
function withAnswer(text, url, lufs, nowS, cap) {
    var all = _entries(text), heard = typeof lufs === "number" ? Math.round(lufs * 10) / 10 : null, had;
    if (!_web(url) || !_reading(heard) || !_clock(nowS)) return _text(all);
    had = _find(all, url);
    return _newest(all, [url, Math.floor(nowS), 0, (had === null ? [] : had[3]).concat([heard]).slice(-KEEP)], cap);
}

// An attempt that gave no number.
// Contract: the map as JSON text with this address as its newest entry: the
// readings it had, if any, with tried set to nowS. Bounded and guarded as
// withAnswer.
function withMiss(text, url, nowS, cap) {
    var all = _entries(text), had;
    if (!_web(url) || !_clock(nowS)) return _text(all);
    had = _find(all, url);
    return _newest(all, [url, had === null ? 0 : had[1], Math.floor(nowS), had === null ? [] : had[3]], cap);
}

// Contract: the map as JSON text with only the addresses a saved row holds
// now, or held before it moved.
function kept(text, saved) {
    var held = {}, rows = _rows(saved), i;
    for (i = 0; i < rows.length; i++) {
        if (!rows[i]) continue;
        if (typeof rows[i].hostname === "string") held[rows[i].hostname] = true;
        if (typeof rows[i].prev === "string") held[rows[i].prev] = true;
    }
    return _text(_entries(text).filter(function(e) { return held[e[0]] === true; }));
}

// The two commands of one reading. o: url, urlPath, scriptPath, seq.
// Contract: { write, run }, both "" unless url is a web address, the paths
// are text that is not empty and seq a number from 0 up. write puts the
// address into urlPath, readable by its owner only, and answers
// __LD_URL_OK__ or __LD_URL_FAIL__; run hands the helper urlPath and
// LISTEN_S and never holds the address. Both end in "# seq".
function buildAsk(o) {
    var q = PodcastLogic.shQuote, a = o || {};
    if (!_web(a.url) || typeof a.urlPath !== "string" || a.urlPath === ""
        || typeof a.scriptPath !== "string" || a.scriptPath === "" || typeof a.seq !== "number" || !(a.seq >= 0))
        return { write: "", run: "" };
    // printf is the shell's own, so the address is on a command line only
    // for the instant this write takes; the helper's line holds the path.
    return {
        write: ": LD_URL; umask 077; printf '%s' " + q(a.url) + " > " + q(a.urlPath)
               + " && echo __LD_URL_OK__ || echo __LD_URL_FAIL__; true # " + a.seq,
        // The helper ends itself and removes the file; timeout and rm are
        // for a python that never got that far. -B: the helper imports its
        // neighbour, and no bytecode is left in the widget's own folder.
        run: ": LD_RUN; timeout " + (HELPER_LIMIT_S + 5) + " python3 -B " + q(a.scriptPath) + " " + q(a.urlPath) + " " + LISTEN_S
             + " 2>/dev/null; rm -f " + q(a.urlPath) + "; true # " + a.seq
    };
}

// Ends a reading: the helper stops as soon as its file is gone, and a file
// no helper came for goes too.
// Contract: ": LD_END; rm -f <path, quoted>; true # seq"; "" when urlPath is
// no text or empty, or seq is not a number from 0 up.
function buildEnd(urlPath, seq) {
    if (typeof urlPath !== "string" || urlPath === "" || typeof seq !== "number" || !(seq >= 0)) return "";
    return ": LD_END; rm -f " + PodcastLogic.shQuote(urlPath) + "; true # " + seq;
}

function _web(u) {
    return typeof u === "string" && u.length <= 2048 && /^https?:\/\/./i.test(u);
}

function _clock(nowS) {
    return Number.isFinite(nowS) && nowS >= EPOCH_S;
}

function _reading(lufs) {
    return typeof lufs === "number" && lufs > SILENT_LUFS && lufs <= LOUDEST_LUFS;
}

function _stamp(n) {
    return Number.isFinite(n) && (n === 0 || n >= EPOCH_S) && Math.floor(n) === n;
}

// The saved list as rows: its JSON text parsed, an array as it is, [] for
// anything else.
function _rows(saved) {
    var rows = saved;
    if (typeof saved === "string") {
        try { rows = JSON.parse(saved); } catch (e) { return []; }
    }
    return Array.isArray(rows) ? rows : [];
}

// The map's readable entries as [address, at, tried, readings], the one
// written longest ago first. Readings have the second the newest was taken;
// no readings have the second somebody tried; an entry with neither says
// nothing.
function _entries(text) {
    var obj, out = [], keys, i, v, heard;
    if (typeof text !== "string") return out;
    try { obj = JSON.parse(text); } catch (e) { return out; }
    if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return out;
    keys = Object.keys(obj);
    for (i = 0; i < keys.length; i++) {
        v = obj[keys[i]];
        if (!_web(keys[i]) || !Array.isArray(v) || v.length < 2 || v.length > 2 + KEEP || !_stamp(v[0]) || !_stamp(v[1])) continue;
        heard = v.slice(2);
        if (!heard.every(function(r) { return _reading(r); })) continue;
        if (heard.length === 0 ? (v[0] === 0 && v[1] > 0) : v[0] > 0) out.push([keys[i], v[0], v[1], heard]);
    }
    return out;
}

function _find(entries, url) {
    var i;
    for (i = 0; i < entries.length; i++)
        if (entries[i][0] === url) return entries[i];
    return null;
}

function _newest(entries, entry, cap) {
    var top = (cap > 0 && Math.floor(cap) === cap) ? cap : CAP;
    var rest = entries.filter(function(e) { return e[0] !== entry[0]; });
    rest.push(entry);
    return _text(rest.slice(Math.max(0, rest.length - top)));
}

function _text(entries) {
    var obj = {}, i;
    for (i = 0; i < entries.length; i++) obj[entries[i][0]] = [entries[i][1], entries[i][2]].concat(entries[i][3]);
    return JSON.stringify(obj);
}
