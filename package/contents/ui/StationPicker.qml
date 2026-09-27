/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// A station combo over the widget's shared station list.
// Contract: whatever the list does — it is cleared and refilled on every
// starred station, reorder and fetched logo — the box never sits empty while
// the list has rows, and a station the listener picked stays picked for as
// long as it is still in the list.
import QtQuick
import QtQuick.Controls as QQC2

QQC2.ComboBox {
    id: picker
    textRole: "name"

    // What the listener chose by hand. The index is no memory: a combo
    // answers a cleared model with -1 and never picks again on its own.
    property string _picked: ""
    onActivated: _picked = currentText
    onCountChanged: {
        var i = _picked !== "" ? find(_picked) : -1
        if (i >= 0) currentIndex = i
        else if (count > 0 && (currentIndex < 0 || _picked !== "")) currentIndex = 0
    }
}
