/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The picture on the Playing page: the cover in its frame, and the same
// picture again in the larger view. Both are this component with the same
// address, and so ask for the picture the same way and share one decoded
// copy.
//
// A raster is read as it is, with no fitting mode. Asked to crop or fit, Qt
// enlarges a small picture to the source size while it reads it, and a
// 32-pixel logo then says it has 600; read as it is, it says its own size
// (natural), and the larger view can stop at twice that.
//
// A drawing has no pixels of its own. Read like a raster, an SVG named so
// came back 600 by 600 whatever its shape and was drawn squeezed, and one
// kept without its extension, as the logo cache keeps them, came back at
// the few pixels it declares and was drawn blurred. So a drawing is asked
// for its shape first and then rendered into a box of that shape inside
// the source size (CoverLogic.box). A local file is asked itself, whatever
// it is called (KSvg reads its size without painting anything). One on the
// network is known by its name only, and its shape is read off a copy of
// 16 pixels, which is a second request for that one file. A drawing on the
// network without the extension is not known for one: it is read like a
// raster, at the size it declares, in its own shape.
//
// Nothing here is read larger than the source size. The copy of 16 pixels
// is the one place a shape decides the size, and there Qt refuses a side
// over 65535 pixels (measured in Qt 6.12: 65520 by 16 is read, 65600 by 16
// is not): 4 MB at the very most. Cropped to the whole source size, the
// way covers used to be read, a drawing of 109 to 1 was read at 65400 by
// 600, which is 157 MB.

import QtQuick
import org.kde.ksvg as KSvg

import "CoverLogic.js" as CoverLogic

Item {
    id: cover

    // The picture covers this item in its own shape and is cut by it. An
    // item given the picture's shape, as the larger view's is, shows it whole.
    property url source
    readonly property alias status: img.status
    // The picture's size in pixels as it was read: a raster's own, at most
    // the source size; a drawing's box.
    readonly property size natural: Qt.size(img.implicitWidth, img.implicitHeight)
    // The tests' way to what is drawn.
    readonly property alias _image: img

    readonly property string _address: source.toString()
    // The shape of a drawing, 0 by 0 for a raster or while it is not known.
    readonly property size _shape: {
        if (file.imagePath !== "" && file.isValid()) return file.size;
        return sketch.status === Image.Ready ? Qt.size(sketch.implicitWidth, sketch.implicitHeight) : Qt.size(0, 0);
    }
    readonly property var _box: CoverLogic.box(_shape.width, _shape.height, 600)
    clip: true

    KSvg.Svg {
        id: file
        imagePath: CoverLogic.localPath(cover._address)
    }
    Image {
        id: sketch
        visible: false
        source: CoverLogic.namedSvg(cover._address) ? cover.source : ""
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(16, 16)
        asynchronous: true
    }
    Image {
        id: img
        readonly property real k: CoverLogic.coverScale(implicitWidth, implicitHeight, cover.width, cover.height)
        anchors.centerIn: parent
        width: implicitWidth * k
        height: implicitHeight * k
        // A drawing on the network waits until its shape is read.
        source: sketch.status === Image.Loading ? "" : cover.source
        // With a box of the drawing's own shape, cropping to it scales the
        // drawing to the box and cuts nothing.
        fillMode: cover._box.width > 0 ? Image.PreserveAspectCrop : Image.Stretch
        sourceSize: cover._box.width > 0 ? Qt.size(cover._box.width, cover._box.height) : Qt.size(600, 600)
        asynchronous: true
    }
}
