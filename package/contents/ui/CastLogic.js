/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Which devices carry the stream.
//
// A device that is ticked has been ASKED to play. Whether it plays is its
// answer, and the answer can be no: measured on 2026-11-11 a Ruark R5se
// refused both a FLAC and an MP3 station (UPnP 716, "Resource not found"),
// and the widget went on saying "Casting to Ruark R5se" over a silent room
// for more than four minutes, because "casting" was raised when the play
// command went out and nothing ever took it down. Here is the record of who
// was asked, who answered and how, so that "casting" can mean "a device
// plays, or is still being asked". Pure functions; main.qml keeps the record.
.pragma library

// Contract: an empty record, { pending: {}, on: {}, refused: {}, owed: {} }.
// pending holds the number of the play command each device is still to
// answer, on the devices that answered they play, refused those whose last
// answer turned the address down, owed the level (0..100) asked for while a
// device was still pending.
function fresh() {
    return { "pending": {}, "on": {}, "refused": {}, "owed": {} };
}

// Contract: the number a command ends in after "# ", -1 when there is none.
function seqOf(cmd) {
    var m = /# (\d+)$/.exec(typeof cmd === "string" ? cmd : "");
    return m ? parseInt(m[1], 10) : -1;
}

// The device a play command was for.
// cmd: the command as it went out. targets: the selected devices, each
// { uuid, location } (location for a DLNA renderer).
// Contract: the device's uuid; "" for a command that is no play, one that
// names a device no longer selected, and anything that cannot be read.
function who(cmd, targets) {
    var line = typeof cmd === "string" ? cmd : "";
    if (line.indexOf(": CAST_PLAY;") !== 0) return "";
    // A Chromecast's play carries host, port and then its uuid.
    var cc = /'play' '[^']*' '[^']*' '([^']*)'/.exec(line);
    if (cc) return cc[1];
    // A renderer's carries its address, quoted for the shell: '\'' is one '.
    var dl = /'dlna-play' '((?:'\\''|[^'])*)'/.exec(line);
    if (!dl || !Array.isArray(targets)) return "";
    var location = dl[1].replace(/'\\''/g, "'");
    for (var i = 0; i < targets.length; i++) {
        var t = targets[i];
        if (t !== null && typeof t === "object" && t.location === location && typeof t.uuid === "string") return t.uuid;
    }
    return "";
}

// A device was sent the play command numbered seq.
// Contract: the record with that device pending under seq, no longer on and
// no longer marked as having refused; the record as it was for a uuid that
// is no text or empty, or a seq that is no number from 0 up. A level it is
// owed stays owed. The record handed in is not changed.
function tried(session, uuid, seq) {
    var s = _copy(session);
    if (typeof uuid !== "string" || uuid === "" || typeof seq !== "number" || !(seq >= 0)) return s;
    s.pending[uuid] = seq;
    delete s.on[uuid];
    delete s.refused[uuid];
    return s;
}

// A play command's answer came home.
// Contract: { session, stale, carried, owed }. stale is true, and the record
// unchanged, when the device is not pending under exactly this seq: the
// answer belongs to an attempt that was replaced or ended, and it must
// neither cancel what plays now nor be reported. Otherwise the device is
// no longer pending and is on when ok is exactly true. carried says whether
// any device is on or still pending afterwards. kind is what the answer
// said (verdict): a device that is not on and whose kind is "refused" is
// marked as having refused. owed is the level the device is to be sent now,
// one asked for while it was pending (owing), and -1 when there is none or
// the device is not on; either way it is owed nothing afterwards.
function answered(session, uuid, seq, ok, kind) {
    var s = _copy(session);
    if (typeof uuid !== "string" || uuid === "" || s.pending[uuid] !== seq)
        return { "session": s, "stale": true, "carried": carried(s), "owed": -1 };
    var owed = ok === true && s.owed[uuid] !== undefined ? s.owed[uuid] : -1;
    delete s.pending[uuid];
    delete s.owed[uuid];
    if (ok === true) s.on[uuid] = true;
    else if (kind === "refused") s.refused[uuid] = true;
    return { "session": s, "stale": false, "carried": carried(s), "owed": owed };
}

// A device was unticked or stopped.
// Contract: the record without it.
function left(session, uuid) {
    var s = _copy(session);
    if (typeof uuid !== "string" || uuid === "") return s;
    delete s.pending[uuid];
    delete s.on[uuid];
    delete s.refused[uuid];
    delete s.owed[uuid];
    return s;
}

// The cast is over: the stream is on nobody and nobody is being asked.
// Contract: an empty record that still knows which devices refused. Their
// rows in the output menu say so until each is asked again or unticked,
// and the last device refusing is what ends a cast.
function ended(session) {
    var out = fresh();
    out.refused = _copy(session).refused;
    return out;
}

// Contract: true when the device answered its last play command by turning
// the address down (answered with kind "refused") and has neither been
// asked again nor left since.
function refusedBy(session, uuid) {
    return typeof uuid === "string" && _copy(session).refused[uuid] === true;
}

// May the device be sent a level? Only one that answered it plays. A device
// that is ticked may be playing something of its own: a Ruark that had
// refused the stream stood beside a television that played, and its own
// level went from 10 to 6 with every move of the widget's slider
// (2026-11-12).
// Contract: true when the device is on; false for one that is pending,
// refused, unknown, or named by something that is no text.
function plays(session, uuid) {
    return typeof uuid === "string" && _copy(session).on[uuid] === true;
}

// A level was asked for, and the devices that play have been sent it.
// pct: the level, 0..100.
// Contract: the record with pct owed to every device still pending, in
// place of what it was owed before; the record as it was for a pct that is
// no number from 0 to 100. A device that is asked is not sent a level, for
// it may refuse; one that then takes the stream is handed what it is owed
// by answered(), so that an alarm's level or a mute asked for in between is
// not lost on it.
function owing(session, pct) {
    var s = _copy(session);
    if (typeof pct !== "number" || !(pct >= 0 && pct <= 100)) return s;
    for (var k in s.pending) s.owed[k] = pct;
    return s;
}

// Contract: true when any device is on or still pending.
function carried(session) {
    var s = _copy(session);
    return Object.keys(s.pending).length > 0 || Object.keys(s.on).length > 0;
}

// The devices the stream is on or on its way to, to be named where the
// widget says what it casts to. A device that refused stays ticked, and
// with a television playing beside it the footer read "Casting to 2
// devices" (2026-11-12).
// targets: the selected devices, each { uuid, name, ... }.
// Contract: the entries of targets whose uuid is on or pending, in the order
// of targets; [] for targets that are no list. An entry that is no object
// or has no uuid of text is passed over.
function carriers(session, targets) {
    var s = _copy(session), out = [];
    if (!Array.isArray(targets)) return out;
    for (var i = 0; i < targets.length; i++) {
        var t = targets[i];
        if (t === null || typeof t !== "object" || typeof t.uuid !== "string") continue;
        if (s.on[t.uuid] === true || s.pending[t.uuid] !== undefined) out.push(t);
    }
    return out;
}

// What a play command's answer says. cast.py names what it knows in fields
// after its sentinel, "upnp=716 action=SetAVTransportURI http=500 Resource
// not found" or "reach=timeout action=Play", and a line of before has none.
// stdout: what the helper printed.
// Contract: { kind, log }.
//   kind "ok": the device took the stream. "nolib": the Cast library is
//   missing. "refused": the device answered and turned this address down,
//   which is a UPnP error about the resource (702, 703, 704, 714, 715, 716)
//   in answer to SetAVTransportURI or Play. "unreachable": it gave no answer
//   (the reach field). "other": anything else, a failure line without
//   fields and no line at all among them.
//   log: for the last three, what to write down about it. It is built from
//   the fields alone and never holds the helper's words, which may be
//   anything; "" for ok and nolib.
// The Ruark that was measured (2026-11-12) refused three addresses with 716
// and played a fourth, so 716 is no word on the device, only on the address.
// A code like 701 or 705 is about the device's state, 4xx and 5xx about the
// command: those stay "other", and so does a fault that names no code. A
// Cast receiver's own word on a failed load (the load field) is written
// down and stays "other" too: no television has been watched refusing a
// stream yet, and what it means by its codes is not known from a device.
function verdict(stdout) {
    var out = typeof stdout === "string" ? stdout : "";
    if (out.indexOf("__CAST_OK__") !== -1) return { "kind": "ok", "log": "" };
    if (out.indexOf("__NO_PYCHROMECAST__") !== -1) return { "kind": "nolib", "log": "" };
    var f = _fields(out);
    if (_REFUSALS[f.upnp] === true && (f.action === "SetAVTransportURI" || f.action === "Play"))
        return { "kind": "refused", "log": f.action + " refused, UPnP " + f.upnp };
    if (f.reach !== "")
        return { "kind": "unreachable", "log": (f.action !== "" ? f.action + " got no answer, " : "no answer, ") + f.reach };
    var said = [f.action !== "" ? f.action + " failed" : "failed"];
    if (f.http !== "") said.push("HTTP " + f.http);
    if (f.upnp !== "") said.push("UPnP " + f.upnp);
    if (f.load !== "") said.push("load error " + f.load);
    if (said.length === 1 && f.action === "") said.push("no reason named");
    return { "kind": "other", "log": said.join(", ") };
}

// AVTransport's errors that are about the resource a device was sent: no
// contents, read error, format not supported, illegal MIME-type, content
// busy, resource not found.
var _REFUSALS = { "702": true, "703": true, "704": true, "714": true, "715": true, "716": true };

// What a field may hold. Anything else under that name is not the helper's.
var _FIELD = { "upnp": /^\d{1,6}$/, "http": /^\d{3}$/, "action": /^[A-Za-z]{1,40}$/, "reach": /^[a-z]{1,20}$/, "load": /^\d{1,4}$/ };

// The fields of the first failure line: each "" when the line does not give
// it. Fields stand between the sentinel and the words, one space apart; the
// first thing that is no field of a known name starts the words, and nothing
// after it is read.
function _fields(out) {
    var f = { "upnp": "", "http": "", "action": "", "reach": "", "load": "" };
    var line = /(?:^|\n)__CAST_FAIL__ ([^\r\n]*)/.exec(out);
    if (!line) return f;
    var rest = line[1], at = 0;
    while (at < rest.length) {
        var end = rest.indexOf(" ", at);
        var token = rest.substring(at, end === -1 ? rest.length : end);
        var eq = token.indexOf("=");
        var name = eq > 0 ? token.substring(0, eq) : "";
        if (!_FIELD.hasOwnProperty(name) || !/^[A-Za-z0-9_.-]+$/.test(token.substring(eq + 1))) break;
        if (_FIELD[name].test(token.substring(eq + 1))) f[name] = token.substring(eq + 1);
        if (end === -1) break;
        at = end + 1;
    }
    return f;
}

// The picture a device is sent along with a stream.
// episodeArt: the show cover of the episode that is the source, "" while a
// station plays. albumArt: the cover found for the track on air. logo: the
// station's own logo. The caller hands in only what belongs to the stream
// it is sending and leaves the rest empty.
// Contract: the first of the three, in that order, that is an http(s)
// address, exactly as it was given; "" when none is. A receiver fetches the
// picture itself, so a file:// sidecar or a path means nothing to it, and
// such a candidate is passed over for the next one. It used to end the
// choice: a local cover in front of a station's logo sent no picture at all.
function picture(episodeArt, albumArt, logo) {
    var known = [episodeArt, albumArt, logo];
    for (var i = 0; i < known.length; i++)
        if (typeof known[i] === "string" && /^https?:\/\/[^\s\/]/i.test(known[i])) return known[i];
    return "";
}

// The record as a new object of the same content; whatever is no record,
// or holds something that is none, reads as empty there.
function _copy(session) {
    var out = fresh(), k;
    if (session === null || typeof session !== "object") return out;
    var p = session.pending, o = session.on, r = session.refused, w = session.owed;
    if (p !== null && typeof p === "object" && !Array.isArray(p))
        for (k in p) if (typeof p[k] === "number" && p[k] >= 0) out.pending[k] = p[k];
    if (o !== null && typeof o === "object" && !Array.isArray(o))
        for (k in o) if (o[k] === true) out.on[k] = true;
    if (r !== null && typeof r === "object" && !Array.isArray(r))
        for (k in r) if (r[k] === true) out.refused[k] = true;
    if (w !== null && typeof w === "object" && !Array.isArray(w))
        for (k in w) if (typeof w[k] === "number" && w[k] >= 0 && w[k] <= 100) out.owed[k] = w[k];
    return out;
}
