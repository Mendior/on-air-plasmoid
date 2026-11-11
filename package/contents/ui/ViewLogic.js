/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Where a list view stands when the code, not the listener, changed what it
// holds. The view itself is passed in: the trap is in Qt's own layout timing,
// and a test that faked the view would fake exactly that away.
.pragma library

// Open-and-type on the station page: which character a key press adds to the
// search field. "" means the press is not text for the field, and the caller
// then leaves the field, the focus and the event alone.
//
// rowShown: the search row is on screen (Appearance, "Search field").
// chord: Ctrl or Alt is held (Ctrl+Up reorders, Ctrl+Return stars).
// text: the key event's text.
//
// With the row switched off there is nothing to type into. A letter used to
// filter the list from a field nobody could see and left the focus in it, so
// the next Space typed a space where it should have stopped the radio.
// Space stays with the list, where it is play and stop. Control characters
// are keys and not text, DEL among them: xkb hands the Delete key 0x7f as its
// text, that sorts above space, and one press blanked the list into a %7F
// search.
function typedChar(rowShown, chord, text) {
    if (rowShown !== true || chord) return "";
    if (typeof text !== "string" || text.length !== 1) return "";
    var cc = text.charCodeAt(0);
    return (cc <= 0x20 || cc === 0x7f) ? "" : text;
}

// The popup's pages by number: 0 Stations, 1 Playing, 2 My Music, 3 Podcasts,
// 4 Timers. Appearance can switch each one's tab off; `shown` holds one flag
// per page in that order, and only a plain true is a page with a tab.

// Where to stand when the listener arrives at page `from`: there if it has a
// tab, else on the nearest page that has one, looking first the way they were
// going (dir < 0 is back, anything else forward) and then the other way.
// The walk used to look forward first whatever the direction: with Playing
// switched off, a step back from My Music landed on My Music again.
// A `from` outside the pages counts from the nearer end. 0 when no page is
// shown at all, which is the page main.qml keeps standing in that case.
function nextVisibleView(from, dir, shown) {
    var n = shown ? (shown.length | 0) : 0;
    if (n <= 0) return 0;
    var at = Math.floor(Number(from));
    if (!(at >= 0)) at = 0;
    if (at > n - 1) at = n - 1;
    if (shown[at] === true) return at;
    var step = dir < 0 ? -1 : 1;
    for (var turn = 0; turn < 2; turn++, step = -step)
        for (var i = at + step; i >= 0 && i < n; i += step)
            if (shown[i] === true) return i;
    return 0;
}

// The page Escape goes home to: the first one that has a tab. Escape went to
// page 0 whatever was shown, so with Stations switched off the guard walked
// it on to Playing every time and the key never reached the popup: four
// presses, four times Playing, popup still open.
function firstVisibleView(shown) {
    return nextVisibleView(0, 1, shown);
}

// What an empty station list says:
//   "favorites"    the favourites view of a listener who has starred nothing
//   "unreachable"  the station directory did not answer
//   "nomatch"      a search found nothing
//   "none"         there are no stations
//
// The favourites view said "No favorite stations yet, tap the star on a
// station" whenever it was empty: also to a listener with favourites whose
// search had found none of them, and when the directory could not be reached.
// It says so now only when nothing is typed and nothing is starred. Anything
// typed is a search, a space included, as the list's own filter has it.
function emptyList(favoritesOnly, favoriteCount, searchFilter, directoryFailed) {
    var typed = (searchFilter === null || searchFilter === undefined) ? "" : String(searchFilter);
    if (favoritesOnly === true && typed === "" && !(Number(favoriteCount) > 0)) return "favorites";
    if (directoryFailed === true) return "unreachable";
    return typed !== "" ? "nomatch" : "none";
}

// A search chip's text as a button has to be given it. A button reads "&"
// as the mark of its keyboard shortcut, so the history chip for "r&b" read
// "rb". A doubled "&" is shown as one. An "&" with a space after it is left
// alone: the Plasma button doubles that one itself, and doubled twice it
// shows twice, "drum & bass" as "drum && bass" (both measured on
// PlasmaComponents3.ToolButton). The click and the accessible name keep the
// text as it was typed. Nothing readable is an empty label.
function chipLabel(text) {
    if (text === null || text === undefined) return "";
    return String(text).replace(/&(?! )/g, "&&");
}

// Contract: revealFooter(view) scrolls a ListView so its footer is in sight,
//   all of it when it fits, its top at the view's top when it does not.
//   A view without a visible footer is left alone. Returns whether there
//   was a footer to show.
function revealFooter(view) {
    var f = view ? view.footerItem : null;
    if (!f || !f.visible || typeof view.positionViewAtEnd !== "function") return false;
    // The rows went into the model a moment ago, but a Column places them once
    // a frame. Without this the footer is still its old height here, and a
    // thirty-row answer left its heading under the fold (tst_viewlogic).
    if (typeof f.forceLayout === "function") f.forceLayout();
    // The view's own end knows where the last rows really are, where a
    // footer y read before them is only an estimate.
    view.positionViewAtEnd();
    if (f.height > view.height) view.contentY = f.y;
    return true;
}

// Whether the popup's footer says the network is gone, in its red.
// The footer read "Check internet connection…" over a downloaded episode
// and over a My Music file that were playing fine from disk.
// Contract: offlineWord(connected, local, active) is true when connected is
//   false, unless a local file is playing: local says the player's source
//   is a file, active that sound is coming out. A file that is loaded but
//   silent hides nothing, since the next pick may be a station. Only a
//   plain false is offline and only a plain true is a file playing, so a
//   value that is not there yet reads as a station with the network up.
function offlineWord(connected, local, active) {
    return connected === false && !(local === true && active === true);
}
