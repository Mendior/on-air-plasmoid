/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// What the station list SHOWS and how a reorder lands — pure decisions,
// no view, under qmltestrunner. The popup's filtered model, the favorites
// ordering, the live-drag commit slot and the rebuild-or-patch judgement
// all live here, because every one of them has an off-by-one waiting in
// the dark: an insertion slot is not an index, a hidden favorite is not a
// visible row, and a rebuilt model is not the same model with new numbers.
.pragma library
.import "SearchLogic.js" as SearchLogic

// One display row, always the same five roles the delegates bind.
function _row(s, idx) {
    return {
        name: s.name || "",
        hostname: s.hostname || "",
        favicon: s.favicon || "",
        active: s.active !== false,
        originalIndex: idx
    }
}

// The rows the filtered model should show, given the stations, the
// favorites order and the current filter. favOnly follows favoriteNames'
// OWN order (the reorder controls work on exactly the order on screen),
// resolves each name against the stations (first index wins on duplicate
// names — favorites are name-keyed by design) and silently skips
// favorites whose station is not in the list (deactivated, not deleted).
// named are the stations of this list the directory's answer to the text
// held (SearchLogic.knownStation's third argument, and a row just starred).
// The web rows leave those out as already saved, so they are shown here
// whatever their names say: "Example FM", filed under Estonia and jazz, is a
// row under "estonia" and under "jazz". Without text every row shows anyway,
// and the favourites view still shows favourites alone.
function buildFilteredRows(stations, favoriteNames, filterRaw, favOnly, named) {
    const filter = SearchLogic.fold(filterRaw)
    // The indices of the named stations. Null-prototype like idxByName below.
    const found = Object.create(null)
    if (filter !== "" && Array.isArray(named))
        for (var h = 0; h < named.length; h++) {
            const at = SearchLogic.knownStationAt(stations, named[h])
            if (at !== -1) found[at] = true
        }
    const out = []
    if (favOnly) {
        // Null-prototype: a station named "constructor" must not read
        // Object.prototype as its index (same trap the search dodges).
        const idxByName = Object.create(null)
        for (var m = 0; m < stations.length; m++)
            if (idxByName[stations[m].name] === undefined)
                idxByName[stations[m].name] = m
        for (var f = 0; f < favoriteNames.length; f++) {
            const fi = idxByName[favoriteNames[f]]
            if (fi === undefined) continue
            const fs = stations[fi]
            if (filter !== "" && found[fi] !== true && SearchLogic.fold(fs.name).indexOf(filter) === -1)
                continue
            out.push(_row(fs, fi))
        }
        return out
    }
    for (var i = 0; i < stations.length; i++) {
        const s = stations[i]
        if (filter !== "" && found[i] !== true && SearchLogic.fold(s.name).indexOf(filter) === -1)
            continue
        out.push(_row(s, i))
    }
    return out
}

// Reconcile the live model with the rows it SHOULD show. If the station
// sequence (name+hostname, in order) already matches — a reorder the view
// performed live, a favicon that just backfilled — the changed roles are
// patched IN PLACE and true is returned: no delegate is recreated, hover
// survives, no entry cascade replays. A genuinely different sequence
// returns false and the caller rebuilds.
function syncModelToRows(model, rows) {
    if (model.count !== rows.length) return false
    for (var i = 0; i < rows.length; i++) {
        const m = model.get(i)
        if (m.name !== rows[i].name || m.hostname !== rows[i].hostname)
            return false
    }
    for (var j = 0; j < rows.length; j++) {
        const m = model.get(j), r = rows[j]
        if (m.favicon !== r.favicon) model.setProperty(j, "favicon", r.favicon)
        if (m.active !== r.active) model.setProperty(j, "active", r.active)
        if (m.originalIndex !== r.originalIndex)
            model.setProperty(j, "originalIndex", r.originalIndex)
    }
    return true
}

// The station list the way it is saved: one plain object per row with the
// row's roles and nothing else. ListModel.get() hands back the row's QObject
// wrapper, and JSON.stringify took its objectName along, so the settings
// pages wrote "objectName":"" into every station they saved (appletsrc on
// the bench, 2026-09-23).
function savedRows(model) {
    var out = []
    for (var i = 0; i < model.count; i++) {
        var row = JSON.parse(JSON.stringify(model.get(i)))
        delete row.objectName
        // Every model row carries prev so the first row sets the role's
        // shape (DoorLogic.normalize); an empty prev says nothing.
        if (row.prev === "") delete row.prev
        out.push(row)
    }
    return out
}

// The popup wrote the station list (ext) while a settings page holds
// unsaved edits (cur) made against the list it loaded (base). Rows this
// page never touched follow the popup; a row edited here keeps what was
// changed here and takes the rest from the popup, field by field; a row
// added here stays, and one removed here stays removed, whatever the popup
// did to it meanwhile; rows the popup added come along once.
// The popup never writes a row's name or uuid: it moves a row (a heal
// writes hostname and prev), fills a logo, turns a row on, reorders, adds
// and removes. So a row of the page's list is found in the popup's by its
// name and uuid, and only among rows sharing those by the same address, by
// the address it moved from, and by order. Measured on the page on
// 2026-11-02 and 2026-11-03: keyed on the address, a move landed at the
// bottom or twice, a removed row came back, a rename kept the station on
// the address the heal had left and the popup then lost its favorite, an
// older heal's prev took another row's place, a heal onto an address
// another saved row held dropped a station, and of two rows on one address
// the wrong one took the change.
// Contract: { rows, changed }; norm(row) is the page's comparable form.
function mergeExternal(base, cur, ext, norm) {
    var extOf = _pairBaseExt(base, ext), atAddr = {}, i, k
    for (i = 0; i < base.length; i++) {
        k = base[i].hostname
        if (atAddr[k] === undefined) atAddr[k] = []
        atAddr[k].push(i)
    }
    var baseOf = _pairCurBase(base, cur, atAddr)
    var rows = [], changed = false
    for (i = 0; i < cur.length; i++) {
        var c = cur[i], bi = baseOf[i]
        if (bi === -1) { rows.push(c); continue }
        var b = base[bi], x = extOf[bi]
        if (norm(c) !== norm(b)) {
            if (x === undefined) { rows.push(c); continue }
            var both = _fieldMerge(b, c, x)
            rows.push(both)
            if (norm(both) !== norm(c)) changed = true
            continue
        }
        if (x === undefined) { changed = true; continue }
        if (norm(x) !== norm(b)) { rows.push(x); changed = true } else rows.push(c)
    }
    var paired = extOf.filter(function(x) { return x !== undefined })
    for (i = 0; i < ext.length; i++) {
        var e = ext[i]
        if (paired.indexOf(e) !== -1) continue
        var twice = rows.some(function(r) { return r.hostname === e.hostname && r.name === e.name })
        if (twice) continue
        rows.push(e)
        changed = true
    }
    return { rows: rows, changed: changed }
}

function _key(r) {
    return String(r.name === undefined ? "" : r.name) + "\u0001" + String(r.uuid === undefined ? "" : r.uuid)
}

// For every base row its row in the popup's list, or undefined where the
// popup removed it.
function _pairBaseExt(base, ext) {
    var pool = {}, taken = [], out = [], j
    for (j = 0; j < ext.length; j++) {
        var kj = _key(ext[j])
        if (pool[kj] === undefined) pool[kj] = []
        pool[kj].push(j)
    }
    var pass = function(fits) {
        for (var i = 0; i < base.length; i++) {
            if (out[i] !== undefined) continue
            var cands = pool[_key(base[i])] || []
            for (var c = 0; c < cands.length; c++) {
                if (taken[cands[c]] || !fits(base[i], ext[cands[c]])) continue
                taken[cands[c]] = true
                out[i] = ext[cands[c]]
                break
            }
        }
    }
    // A row the popup did not move keeps its address and its prev; a moved one
    // carries a new prev, the address it left.
    pass(function(b, x) { return x.hostname === b.hostname && _blank(x.prev) === _blank(b.prev) })
    pass(function(b, x) { return !!x.prev && x.prev === b.hostname })
    pass(function() { return true })
    return out
}

// For every page row the base row it came from, -1 for one added here or
// moved to an address of the page's choosing. Rows at one address pair up
// with the rows the page loaded there: first every row with its own name and
// uuid, then the rest in order, so a row renamed or moved here never takes
// the place of one that kept both.
function _pairCurBase(base, cur, atAddr) {
    var out = [], used = [], i, j, idx
    for (i = 0; i < cur.length; i++) {
        out[i] = -1
        idx = atAddr[cur[i].hostname] || []
        for (j = 0; j < idx.length; j++) {
            if (used[idx[j]] || _key(base[idx[j]]) !== _key(cur[i])) continue
            used[idx[j]] = true
            out[i] = idx[j]
            break
        }
    }
    for (i = 0; i < cur.length; i++) {
        if (out[i] !== -1) continue
        idx = atAddr[cur[i].hostname] || []
        for (j = 0; j < idx.length; j++) {
            if (used[idx[j]] || _keyHeldElsewhere(base[idx[j]], cur, out)) continue
            used[idx[j]] = true
            out[i] = idx[j]
            break
        }
    }
    return out
}

// Whether some page row still carries this base row's name and uuid and has
// no base row yet: then it is that row's, not a stranger's to take.
function _keyHeldElsewhere(b, cur, out) {
    for (var i = 0; i < cur.length; i++)
        if (out[i] === -1 && _key(cur[i]) === _key(b)) return true
    return false
}

function _blank(v) {
    return v === undefined || v === null ? "" : v
}

// A row changed on both sides: what this page changed wins, field by field,
// and every other field follows the popup.
function _fieldMerge(b, c, x) {
    var keys = {}, out = {}, k
    for (k in b) keys[k] = true
    for (k in c) keys[k] = true
    for (k in x) keys[k] = true
    for (k in keys) {
        var v = _blank(c[k]) === _blank(b[k]) ? x[k] : c[k]
        if (v !== undefined) out[k] = v
    }
    return out
}

// The insertion slot a finished live drag commits. The engine's contract
// (moveStationTo/moveFavoriteTo) speaks insert-before slots against the
// PRE-drag order with the row still in place; the view speaks final
// indices with the row already moved. Downward the removal shift eats
// one position, so the slot is final+1; upward they coincide.
function commitSlot(fromVisible, finalVisible) {
    return finalVisible > fromVisible ? finalVisible + 1 : finalVisible
}

// Where a live drag should move the row, given what the view found under
// the pointer. indexAt() answers -1 above the first row, below the last
// row and inside the spacing gap between rows — only the real misses may
// clamp to the ends; a gap keeps the current position, or every gap
// crossing would jitter the row to an edge.
function dragTarget(indexAtResult, pointerY, contentHeight, rowHeight, currentIndex, count) {
    if (indexAtResult >= 0 && indexAtResult < count) return indexAtResult
    if (pointerY < rowHeight / 2) return 0
    if (pointerY > contentHeight - rowHeight / 2) return count - 1
    return currentIndex
}
