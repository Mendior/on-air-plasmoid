/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What a stream is, and what a start does about it.
//
// A start takes the road it always took: the relay at once for an address
// ending in .ogg, .opus or .flac and for an audition whose label names the
// family, the plain start for the rest. That guess is wrong in two places.
// Measured on 2026-11-11: an Ogg FLAC station at a bare address, saved with
// its label, started plain and stood silent for the rescue's six seconds
// (6.3 s and 11.7 s to sound on two stations, 0.3 s as an audition); and
// the stations filed as FLAC sent plain FLAC, which needs no relay (2.5 s
// to sound and its ICY titles straight off the socket, 5.5 s and no titles
// as an audition through the relay). So streamkind.py is asked what the
// stream is, beside the start, and the answer may correct the road in
// those two places only. Vorbis and Opus keep the road they had: through
// the relay a Vorbis station shows its titles (1.8 s to sound), played
// plainly it starts in 0.1 s and has none. Pure functions; StreamKind.qml
// asks.
.pragma library
.import "TimeshiftLogic.js" as TimeshiftLogic
.import "StreamLogic.js" as StreamLogic
.import "PodcastLogic.js" as PodcastLogic

var KINDS = ["ogg-flac", "ogg", "flac", "other"];
// A listener's list is a few dozen stations; the oldest answer goes first.
var CAP = 64;

// Contract: true when label is text holding ogg, flac, opus or vorbis in
// any case. Anything that is not text is false.
function labelHints(label) {
    return typeof label === "string" && /ogg|flac|opus|vorbis/i.test(label);
}

// The road a start took before anybody asked what the stream is: the relay
// at once for an address ending in .ogg, .opus or .flac (the ending as
// StreamLogic.streamFormat reads it, cut at the first ?) and for an audition
// whose own label names the family. A saved row's label never counted.
// Contract: "relay" or "plain"; an address that is no text is read as the
// text it makes, which ends in nothing.
function roadBefore(url, brought) {
    var ending = StreamLogic.streamFormat(url, true);
    return (ending === "ogg" || ending === "opus" || ending === "flac" || labelHints(brought)) ? "relay" : "plain";
}

// Is there a reason to ask what this stream is? A .flac ending, which plain
// FLAC and Ogg FLAC both wear; an .oga ending, which is Ogg by its name and
// was never relayed on it, so FLAC inside it froze until the rescue; and a
// label naming the family on any other ending the relay does not already
// take. Never an .ogg or .opus ending: those are on the relay as
// roadBefore reads them, and no answer takes an Ogg stream off it. And
// never an address the relay could not carry.
// Contract: true or false; never throws.
function hinted(url, label) {
    if (!TimeshiftLogic.canTimeshift(url)) return false;
    var ending = StreamLogic.streamFormat(url, true);
    if (ending === "ogg" || ending === "opus") return false;
    return ending === "flac" || /\.oga$/i.test(String(url).split("?")[0]) || labelHints(label);
}

// The label that goes with one address: what the caller holds for it (an
// audition's directory row) when that says anything, else the codec of the
// saved row that holds exactly this address.
// Contract: text, trimmed, lower case, at most 16 characters; "" when there
// is none. saved is the list as its JSON text or as rows. Never throws.
function labelFor(brought, saved, url) {
    if (typeof brought === "string" && brought.trim() !== "") return _label(brought);
    var rows = _rows(saved), i;
    if (typeof url !== "string" || url === "") return "";
    for (i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].hostname === url && typeof rows[i].codec === "string" && rows[i].codec.trim() !== "")
            return _label(rows[i].codec);
    }
    return "";
}

// Contract: true when a row of the saved list (JSON text or rows) holds
// exactly this address; false for no list, no address and no such row.
function isSaved(saved, url) {
    if (typeof url !== "string" || url === "") return false;
    return _rows(saved).some(function(r) { return !!r && r.hostname === url; });
}

// The helper's answer.
// Contract: stdout, trimmed, when it is exactly one of KINDS; "" for
// anything else, a second word and another spelling included.
function answerOf(stdout) {
    var word = typeof stdout === "string" ? stdout.trim() : "";
    return KINDS.indexOf(word) !== -1 ? word : "";
}

// The remembered kinds are a JSON object, address -> kind, oldest first.
// Whatever is not that reads as empty: text that is no JSON, a list, an
// address that is no web address or longer than 2048, a kind outside KINDS.
// Contract: the kind kept for exactly this address, "" when there is none.
function kindAt(text, url) {
    var kept = _entries(text), i;
    for (i = 0; i < kept.length; i++)
        if (kept[i][0] === url) return kept[i][1];
    return "";
}

// Contract: the map as JSON text with this address as its newest entry and
// at most cap entries (CAP when cap is no whole number above 0), the oldest
// dropped. An address or a kind that would not be read back is not written,
// and the map comes back as it was, tidied.
function mapWith(text, url, kind, cap) {
    var kept = _entries(text), top = (cap > 0 && Math.floor(cap) === cap) ? cap : CAP;
    if (_web(url) && KINDS.indexOf(kind) !== -1) {
        kept = kept.filter(function(e) { return e[0] !== url; });
        kept.push([url, kind]);
    }
    return _text(kept.slice(Math.max(0, kept.length - top)));
}

// Contract: the map as JSON text without this address.
function mapWithout(text, url) {
    return _text(_entries(text).filter(function(e) { return e[0] !== url; }));
}

// Contract: the map as JSON text with only the addresses the saved list
// (JSON text or rows) still holds.
function mapKept(text, saved) {
    var rows = _rows(saved);
    return _text(_entries(text).filter(function(e) {
        return rows.some(function(r) { return !!r && r.hostname === e[0]; });
    }));
}

// What a start does about the stream at url. known is the kind remembered
// for it ("" when none), brought the audition's own label, label what
// labelFor answers.
// Contract: { relay, ask, pull }.
//   relay  through the relay at once, in an Ogg shell
//   ask    ask the helper beside the start
//   pull   the start is on the relay on a guess, and an answer of "flac" or
//          "other" may take it back to the plain start
// Known Ogg FLAC relays and known plain FLAC or "other" starts plainly,
// whatever the address or the label says. Known "ogg" and an address
// nothing is known of take the road they took before (roadBefore). A known
// address is never asked about, nor is one without a hint. All false for
// an address the relay cannot carry.
function plan(url, known, brought, label) {
    if (!TimeshiftLogic.canTimeshift(url)) return { relay: false, ask: false, pull: false };
    if (known === "ogg-flac") return { relay: true, ask: false, pull: false };
    if (known === "flac" || known === "other") return { relay: false, ask: false, pull: false };
    var before = roadBefore(url, brought) === "relay";
    var ask = known !== "ogg" && hinted(url, label);
    return { relay: before, ask: ask, pull: before && ask };
}

// Contract: the number a command ends in after "# ", -1 when there is none.
function seqOf(cmd) {
    var m = /# (\d+)\s*$/.exec(typeof cmd === "string" ? cmd : "");
    return m ? parseInt(m[1], 10) : -1;
}

// The two commands of one question. o: url, urlPath, scriptPath, seq.
// Contract: { write, run }. write puts the address into urlPath, readable
// by its owner only, and answers __SK_URL_OK__ or __SK_URL_FAIL__; run hands
// the helper urlPath and never holds the address. Both end in "# seq".
function buildAsk(o) {
    var q = PodcastLogic.shQuote, a = o || {};
    if (!_web(a.url) || typeof a.urlPath !== "string" || a.urlPath === ""
        || typeof a.scriptPath !== "string" || a.scriptPath === "" || !(a.seq >= 0))
        return { write: "", run: "" };
    // printf is the shell's own, so the address is on a command line only
    // for the instant this write takes; the helper's line holds the path.
    return {
        write: ": SK_URL; umask 077; printf '%s' " + q(a.url) + " > " + q(a.urlPath)
               + " && echo __SK_URL_OK__ || echo __SK_URL_FAIL__; true # " + a.seq,
        // The helper ends itself after four seconds and removes the file;
        // timeout and rm are for a python that never got that far.
        run: ": SK_RUN; timeout 6 python3 " + q(a.scriptPath) + " " + q(a.urlPath)
             + " 2>/dev/null; rm -f " + q(a.urlPath) + "; true # " + a.seq
    };
}

// The command that removes the address file of a question nobody waits
// for any more (StreamKind.handleExec).
// Contract: ": SK_RM; rm -f <path, quoted>; true # seq"; "" when urlPath is
// no text or empty, or seq is not a number from 0 up.
function buildSweep(urlPath, seq) {
    if (typeof urlPath !== "string" || urlPath === "" || typeof seq !== "number" || !(seq >= 0)) return "";
    return ": SK_RM; rm -f " + PodcastLogic.shQuote(urlPath) + "; true # " + seq;
}

function _web(u) {
    return typeof u === "string" && u.length <= 2048 && /^https?:\/\/./i.test(u);
}

function _label(text) {
    return text.trim().toLowerCase().substring(0, 16);
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

// The map's readable entries as [address, kind] pairs, oldest first.
function _entries(text) {
    var obj, out = [], keys, i;
    if (typeof text !== "string") return out;
    try { obj = JSON.parse(text); } catch (e) { return out; }
    // A list, a number and a word have no key that is an address, so only
    // null needs turning away before its keys are asked for.
    if (obj === null) return out;
    keys = Object.keys(obj);
    for (i = 0; i < keys.length; i++)
        if (_web(keys[i]) && KINDS.indexOf(obj[keys[i]]) !== -1) out.push([keys[i], obj[keys[i]]]);
    return out;
}

function _text(entries) {
    var obj = {}, i;
    for (i = 0; i < entries.length; i++) obj[entries[i][0]] = entries[i][1];
    return JSON.stringify(obj);
}
