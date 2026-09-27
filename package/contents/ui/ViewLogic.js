/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Where a list view stands when the code, not the listener, changed what it
// holds. The view itself is passed in: the trap is in Qt's own layout timing,
// and a test that faked the view would fake exactly that away.
.pragma library

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
