/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Where a saved station was before a heal moved it.
//
// prev is the address a heal moved the row away from. The settings pages
// read it to keep a moved station in its place while they hold unsaved
// edits. Every row gets it, as a plain string: a ListModel turns an array of
// strings into [{},{}] on its round trip and locks a role's type to the
// first row (measured on Qt 6.12.0), so nothing richer survives the
// settings page.
.pragma library
.import "HealLogic.js" as HealLogic
.import "FaviconLogic.js" as FaviconLogic

var MAX_ADDR = 2048;
// A station file is whatever the listener picked in the file dialog. 500
// rows and 500 characters a field is far beyond any real station list.
var IMPORT_ROWS = 500;
var IMPORT_FIELD = 500;

// Contract: the address as a trimmed string when it is http(s) and at most
// MAX_ADDR long, else "". null, numbers and objects are answered, never
// thrown on.
function cleanAddr(u) {
    if (typeof u !== "string") return "";
    var t = u.trim();
    return t.length <= MAX_ADDR && /^https?:\/\/./i.test(t) ? t : "";
}

// Contract: a copy of the row with prev as a cleanAddr string, "" when it
// names the row's own hostname (HealLogic.addrKey). Anything that is not an
// object comes back as it went in.
function normalize(row) {
    if (row === null || typeof row !== "object") return row;
    var out = {};
    for (var k in row) out[k] = row[k];
    out.prev = cleanAddr(row.prev);
    if (HealLogic.addrKey(out.prev) === HealLogic.addrKey(row.hostname)) out.prev = "";
    return out;
}

// The row an Edit dialog was opened on, found again when it is accepted.
// The popup writes the list while the dialog is open, and the page follows:
// a heal can move the row (its old address goes to prev), a removal can
// shift the rows below it, and of two rows on one address only the name
// tells them apart, which the popup never writes.
// Contract: the index of the row with opened.name holding opened.hostname,
// or else holding it as prev, the index the dialog opened at first. Any
// address counts, a web one or not; -1 when no such row is left (another
// station on that address is not it) or the address is empty.
function editRowIndex(rows, openedAt, opened) {
    var o = opened || {};
    var key = HealLogic.addrKey(o.hostname);
    if (!Array.isArray(rows) || key === "") return -1;
    var holds = function(i, field, named) {
        var r = rows[i];
        if (r === null || typeof r !== "object" || (named && r.name !== o.name)) return false;
        return HealLogic.addrKey(r[field]) === key;
    };
    var tries = [["hostname", true], ["prev", true]];
    for (var t = 0; t < tries.length; t++) {
        if (openedAt >= 0 && openedAt < rows.length && holds(openedAt, tries[t][0], tries[t][1])) return openedAt;
        for (var i = 0; i < rows.length; i++)
            if (holds(i, tries[t][0], tries[t][1])) return i;
    }
    return -1;
}

// What an Edit dialog's OK makes of the row it was opened on. opened is the
// dialog's fields as it filled them, shown the same fields at OK, and clean
// the values at OK tidied the way the page saves them; each has name,
// hostname, favicon and active. A field the listener left alone keeps the
// row's current value, whatever the popup wrote meanwhile (a heal's move, a
// logo found); a changed one takes the clean value. A new address starts
// without history, and the uuid goes when the edit points the row at
// another station (HealLogic.editKeepsIdentity).
// Contract: a new object; live is not changed.
function editedRow(live, opened, shown, clean) {
    var src = live || {}, out = {}, k;
    for (k in src) out[k] = src[k];
    var fields = ["name", "hostname", "favicon", "active"];
    for (var i = 0; i < fields.length; i++) {
        k = fields[i];
        if (shown[k] !== opened[k]) out[k] = clean[k];
    }
    if (out.uuid && !HealLogic.editKeepsIdentity(src.name, src.hostname, out.name, out.hostname))
        out.uuid = "";
    if (HealLogic.addrKey(out.hostname) !== HealLogic.addrKey(src.hostname)) out.prev = "";
    return out;
}

// A parsed station file as the rows the list would save.
// Contract: null when parsed is not an array or no row in it is usable;
// else an array of at most IMPORT_ROWS new rows in the file's order. A row
// is usable when it is an object whose hostname is a string with something
// in it; anything else is skipped. Each row has name (the hostname when the
// file has none), hostname, favicon (a public web address or "") and
// active, plus country, uuid, codec, bitrate and prev when the file's row
// has them. Text is cut at IMPORT_FIELD characters, codec is lower case and
// at most 16, bitrate a whole number from 0 up, prev as normalize leaves
// it. Keys the list never wrote are left behind. Nothing is thrown.
function importedRows(parsed) {
    if (!Array.isArray(parsed)) return null;
    var out = [];
    for (var i = 0; i < parsed.length && out.length < IMPORT_ROWS; i++) {
        var src = parsed[i];
        if (src === null || typeof src !== "object" || Array.isArray(src)) continue;
        if (typeof src.hostname !== "string" || src.hostname.trim() === "") continue;
        // The address and the name stay as the file spells them: favorites
        // are kept by name, and an alarm finds its station by the address.
        var row = {
            "name": _importText(src.name),
            "hostname": src.hostname.substring(0, IMPORT_FIELD),
            "favicon": FaviconLogic.webUrlOrEmpty(_importText(src.favicon)),
            "active": src.active === undefined ? true
                      : src.active !== false && src.active !== "false" && src.active !== 0
        };
        if (row.name === "") row.name = row.hostname;
        if (src.country !== undefined) row.country = _importText(src.country);
        if (src.uuid !== undefined) row.uuid = _importText(src.uuid);
        // The codec is what sends an Ogg stream through the relay, and the
        // bitrate is all the footer has on a FLAC station. Both were left
        // behind here once, so an export and an import cost a station both.
        if (src.codec !== undefined) row.codec = _importText(src.codec).toLowerCase().substring(0, 16);
        if (src.bitrate !== undefined) row.bitrate = Math.max(0, parseInt(src.bitrate, 10) || 0);
        row.prev = src.prev;
        row = normalize(row);
        if (row.prev === "") delete row.prev;
        out.push(row);
    }
    return out.length > 0 ? out : null;
}

// How many rows of a file the import did not take: the ones that are no
// station, and whatever stood past IMPORT_ROWS.
// Contract: parsed is what importedRows was handed and rows what it gave
// back. 0 when either is no array, never below 0.
function importLeftOut(parsed, rows) {
    if (!Array.isArray(parsed) || !Array.isArray(rows)) return 0;
    return Math.max(0, parsed.length - rows.length);
}

// Text and numbers as text, cut at IMPORT_FIELD; anything else is "".
function _importText(v) {
    if (typeof v !== "string" && typeof v !== "number") return "";
    return String(v).substring(0, IMPORT_FIELD);
}
