// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The picture on the Playing page, as the cover and as its larger view. A
// raster says its own size in pixels. A drawing has none: it keeps its shape
// and is rendered for the size it is shown at, never larger than the source
// size whatever its shape.
import QtQuick
import QtTest

import "../../package/contents/ui"

Item {
    id: root
    width: 700
    height: 700

    // A logo of 32 pixels and a sleeve of 300, as addresses that are no files.
    readonly property string logo32: "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR42mN4phFFU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULADvioEyy1N5PAAAA"
        + "AElFTkSuQmCC"
    readonly property string sleeve300: "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAASwAAAEsCAIAAAD2HxkiAAACe0lEQVR42u3TQQkAAAgEwYtjJvtjDjP48jMwCRY21QM8igRgQjAhYEIwIWBCMCFgQjAhYEIw"
        + "IWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFg"
        + "QjAhYEIwIWBCMCFgQjAhYEIwIZhQBTAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQ"
        + "MCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQTKgCmBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBM"
        + "CJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiY"
        + "EEwImBBMCJgQTAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRM"
        + "CCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgQTSgAmBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMC"
        + "JgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAjcLtRh/cw8Jo4cAAAAASUVORK5CYII="

    // The page's frame: square, and the picture covers it.
    CoverImage {
        id: page
        width: 200
        height: 200
    }
    // The larger view's use: whoever places it gives it the picture's shape.
    CoverImage {
        id: whole
        x: 220
        width: natural.width / 2
        height: natural.height / 2
    }

    TestCase {
        name: "CoverImage"
        when: windowShown

        function show(item, address) {
            item.source = "";
            item.source = address;
            tryCompare(item, "status", Image.Ready, 10000);
        }

        // A station's logo that is a drawing and not square was squeezed
        // into the square frame; one kept without its extension, as the
        // logo cache keeps them, came out at the few pixels it declares.
        function test_a_drawing_keeps_its_shape_and_is_rendered_for_the_frame_data() {
            return [
                { tag: "wide", file: "covers/wide.svg", shape: 2.5 },
                { tag: "tall", file: "covers/tall.svg", shape: 0.4 },
                { tag: "wide, kept without an extension", file: "covers/wide-drawing", shape: 2.5 }
            ];
        }
        function test_a_drawing_keeps_its_shape_and_is_rendered_for_the_frame(data) {
            show(page, Qt.resolvedUrl(data.file));
            var img = page._image;
            fuzzyCompare(img.width / img.height, data.shape, 0.02);
            // It covers the frame: its smaller side fills it, the rest hangs over and is cut.
            fuzzyCompare(Math.min(img.width, img.height), 200, 0.5);
            verify(page.clip);
            fuzzyCompare(img.x + img.width / 2, 100, 0.5);
            fuzzyCompare(img.y + img.height / 2, 100, 0.5);
            // Rendered into the source size in its own shape: neither the 200 by
            // 80 it declares nor a square.
            fuzzyCompare(page.natural.width / page.natural.height, data.shape, 0.02);
            compare(Math.max(page.natural.width, page.natural.height), 600);
            // In the larger view it is whole, in the same shape.
            show(whole, Qt.resolvedUrl(data.file));
            fuzzyCompare(whole._image.width / whole._image.height, data.shape, 0.02);
            fuzzyCompare(whole._image.width, whole.width, 0.01);
            fuzzyCompare(whole._image.height, whole.height, 0.01);
            compare(whole.natural, page.natural);
        }

        // A raster keeps telling its own size, which is what stops the
        // larger view at twice a small logo's pixels.
        function test_a_raster_says_its_own_size_and_covers_the_frame_data() {
            return [
                { tag: "a logo of 32", address: root.logo32, side: 32 },
                { tag: "a sleeve of 300", address: root.sleeve300, side: 300 }
            ];
        }
        function test_a_raster_says_its_own_size_and_covers_the_frame(data) {
            show(page, data.address);
            compare(page.natural, Qt.size(data.side, data.side));
            compare(page._image.width, 200);
            compare(page._image.height, 200);
            show(whole, data.address);
            compare(whole.natural, Qt.size(data.side, data.side));
        }

        // A drawing one hundred thousand wide and ten high. Whatever is made
        // of it, it is not read larger than the source size holds.
        function test_a_drawing_of_an_extreme_shape_is_not_read_large() {
            page.source = "";
            page.source = Qt.resolvedUrl("covers/thread.svg");
            tryVerify(function() { return page.status === Image.Ready || page.status === Image.Error; }, 10000);
            verify(page.natural.width * page.natural.height <= 600 * 600,
                   "read at " + page.natural.width + " by " + page.natural.height);
        }

        function test_no_picture_no_size() {
            page.source = "";
            compare(page.status, Image.Null);
            compare(page.natural, Qt.size(0, 0));
            show(page, root.logo32);
            page.source = "";
            compare(page.natural, Qt.size(0, 0));
        }

        // The next picture is of another kind: a drawing after a raster and back.
        function test_a_drawing_after_a_raster_and_a_raster_after_a_drawing() {
            show(page, root.logo32);
            show(page, Qt.resolvedUrl("covers/wide.svg"));
            fuzzyCompare(page._image.width / page._image.height, 2.5, 0.02);
            show(page, root.sleeve300);
            compare(page.natural, Qt.size(300, 300));
            compare(page._image.width, 200);
        }
    }
}
