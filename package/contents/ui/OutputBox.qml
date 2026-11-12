/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick
import QtQuick.Controls as QQC2

import "OutputLogic.js" as OutputLogic

// The local output picker: the system's default and every output the sound
// server lists. It shows the output the config names and reports the row the
// listener picks; it never picks one by itself.
QQC2.ComboBox {
    id: outputBox

    // outs: the sound server's outputs, as MediaDevices lists them.
    // wanted: the configured output's id, "" for the system's default.
    // firstRow: what the default's row reads.
    property var outs: []
    property string wanted: ""
    property string firstRow: ""
    readonly property int row: OutputLogic.rowFor(outs, wanted)
    signal chosen(string id)

    model: OutputLogic.rowNames(firstRow, outs)
    // A ComboBox puts itself on its first row every time its model is
    // replaced, and a binding on currentIndex that ran before that is not
    // run again. The list here is replaced whenever an output comes or goes.
    // Measured with the group of all outputs switched on: list changed, key
    // written, row 1 found, model replaced, row 0, and "System default
    // output" stood over a list that had the group's row in it for as long
    // as nothing else changed. So the row is bound here, after every
    // replacement, the first one at the box's birth included; modelChanged
    // comes after the reset.
    onModelChanged: currentIndex = Qt.binding(function() { return row })
    onActivated: (index) => chosen(OutputLogic.idAt(outs, index))
}
