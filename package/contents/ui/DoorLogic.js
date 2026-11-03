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

var MAX_ADDR = 2048;

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
