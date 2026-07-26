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
function buildFilteredRows(stations, favoriteNames, filterRaw, favOnly) {
    const filter = SearchLogic.fold(filterRaw)
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
            if (filter !== "" && SearchLogic.fold(fs.name).indexOf(filter) === -1)
                continue
            out.push(_row(fs, fi))
        }
        return out
    }
    for (var i = 0; i < stations.length; i++) {
        const s = stations[i]
        if (filter !== "" && SearchLogic.fold(s.name).indexOf(filter) === -1)
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
