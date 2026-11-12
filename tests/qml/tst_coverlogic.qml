// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// How large the cover is drawn on the Playing page and in the larger view.
// A station's logo of 32 pixels was shown there at 600, which is fog.
import QtQuick
import QtTest

import "../../package/contents/ui/CoverLogic.js" as CL

TestCase {
    name: "CoverLogic"

    // What the page's frame does to a picture: the smaller side fills it,
    // the other hangs over and is cut. A square cover is simply its size.
    function test_a_picture_covers_its_frame_in_its_own_shape() {
        compare(CL.coverScale(300, 300, 324, 324), 324 / 300)
        compare(CL.coverScale(32, 32, 126, 126), 126 / 32)
        compare(CL.coverScale(600, 600, 200, 200), 200 / 600)
        // Wide: the height fills the frame, the sides hang over.
        compare(CL.coverScale(400, 200, 200, 200), 1)
        // Tall: the width fills it.
        compare(CL.coverScale(200, 400, 200, 200), 1)
        // A frame that is not square is covered all the same.
        compare(CL.coverScale(100, 100, 300, 150), 3)
    }

    // The larger view shows the whole picture, as large as its room lets it
    // be, and never more than twice its own pixels.
    function test_the_larger_picture_is_whole_and_at_most_twice_its_pixels() {
        compare(CL.STRETCH, 2)
        // A 32-pixel logo in a room of 600: 64 pixels, not 600.
        compare(CL.largerScale(32, 32, 600, 600), 2)
        compare(CL.largerScale(300, 300, 600, 600), 2)
        compare(CL.largerScale(300, 300, 601, 601), 2)
        // The room is the limit for a picture with pixels to spare.
        compare(CL.largerScale(500, 500, 600, 600), 600 / 500)
        compare(CL.largerScale(600, 600, 404, 404), 404 / 600)
        // Whole: the side that fills the room first decides.
        compare(CL.largerScale(600, 300, 400, 400), 400 / 600)
        compare(CL.largerScale(300, 600, 400, 500), 500 / 600)
        compare(CL.largerScale(100, 50, 400, 400), 2)
    }

    // Offered only when the larger view draws the picture larger than the
    // page already does, by a whole pixel at least.
    function test_a_larger_view_that_adds_nothing_is_not_offered() {
        // The 32-pixel logo: 64 in the larger view, 126 on the smallest cover.
        verify(!CL.largerAdds(32, 32, 126, 126, 600, 600))
        verify(!CL.largerAdds(64, 64, 128, 128, 600, 600))
        verify(CL.largerAdds(64, 64, 100, 100, 600, 600))
        // A 120-pixel logo: 240 at most, so it depends on the cover's size.
        verify(CL.largerAdds(120, 120, 190, 190, 600, 600))
        verify(!CL.largerAdds(120, 120, 324, 324, 600, 600))
        // An iTunes cover of 300 and a Deezer one of 500 in an ordinary popup.
        verify(CL.largerAdds(300, 300, 324, 324, 440, 620))
        verify(CL.largerAdds(500, 500, 324, 324, 440, 620))
        // No more room than the cover has: nothing to add.
        verify(!CL.largerAdds(500, 500, 324, 324, 324, 324))
        verify(!CL.largerAdds(500, 500, 324, 324, 324.9, 324.9))
        verify(!CL.largerAdds(500, 500, 324, 324, 326, 326))
        // A wide logo the page crops to its middle is drawn larger there
        // than the whole of it would be here.
        verify(!CL.largerAdds(400, 200, 324, 324, 600, 600))
    }

    // Twice a picture's pixels means pixels of the screen. On a screen
    // scaled to 175% a cover of 300 was shown 600 wide in the page's units,
    // which is 1050 of the screen's: three and a half times its own.
    function test_the_limit_is_twice_the_pictures_pixels_on_the_screen() {
        fuzzyCompare(CL.largerScale(300, 300, 2000, 2000, 1.75) * 300, 342.857, 0.01)
        fuzzyCompare(CL.largerScale(500, 500, 2000, 2000, 1.75) * 500, 571.429, 0.01)
        fuzzyCompare(CL.largerScale(64, 64, 2000, 2000, 1.75) * 64, 73.143, 0.01)
        // A cover of 600 has pixels to spare there: the room is the limit.
        compare(CL.largerScale(600, 600, 600, 600, 1.75), 1)
        compare(CL.largerScale(300, 300, 2000, 2000, 2) * 300, 300)
        compare(CL.largerScale(300, 300, 2000, 2000, 1), 2)
        compare(CL.largerScale(300, 300, 2000, 2000, 0.5), 4)
        // A ratio that is none is a screen that is not scaled.
        var none = [0, -1, NaN, undefined, null, "2", Infinity, {}]
        for (var i = 0; i < none.length; i++)
            compare(CL.largerScale(300, 300, 2000, 2000, none[i]), 2, "ratio " + none[i])
        compare(CL.largerScale(300, 300, 2000, 2000), 2)
    }

    // A view that would be only a little larger than the cover is not worth
    // a click: it has to be a quarter larger at least.
    function test_a_view_only_a_little_larger_is_not_offered() {
        compare(CL.GAIN, 1.25)
        verify(CL.largerAdds(125, 125, 200, 200, 600, 600, 1))
        verify(!CL.largerAdds(124, 124, 200, 200, 600, 600, 1))
        verify(CL.largerAdds(600, 600, 200, 200, 250, 250, 1))
        verify(!CL.largerAdds(600, 600, 200, 200, 249, 249, 1))
        // The desk it was measured on: scaled to 175%, the cover 310 a side.
        verify(!CL.largerAdds(300, 300, 310, 310, 600, 600, 1.75))
        verify(CL.largerAdds(500, 500, 310, 310, 600, 600, 1.75))
        verify(CL.largerAdds(600, 600, 310, 310, 600, 600, 1.75))
        verify(!CL.largerAdds(64, 64, 126, 126, 600, 600, 1.75))
        // The same cover of 300 on a screen that is not scaled, in an ordinary popup.
        verify(CL.largerAdds(300, 300, 310, 310, 440, 620, 1))
        verify(CL.largerAdds(300, 300, 310, 310, 440, 620))
        verify(!CL.largerAdds(300, 300, 310, 310, 440, 620, 2))
    }

    function test_sizes_that_are_no_sizes_data() {
        return [
            { tag: "zero", v: 0 }, { tag: "negative", v: -5 }, { tag: "undefined", v: undefined },
            { tag: "null", v: null }, { tag: "NaN", v: NaN }, { tag: "infinite", v: Infinity },
            { tag: "text", v: "300" }, { tag: "an object", v: {} }
        ]
    }
    function test_sizes_that_are_no_sizes(data) {
        // Before the picture is read its size is 0 by 0: nothing is drawn
        // and nothing is offered.
        compare(CL.coverScale(data.v, 300, 324, 324), 0)
        compare(CL.coverScale(300, data.v, 324, 324), 0)
        compare(CL.coverScale(300, 300, data.v, 324), 0)
        compare(CL.coverScale(300, 300, 324, data.v), 0)
        compare(CL.largerScale(data.v, 300, 600, 600), 0)
        compare(CL.largerScale(300, data.v, 600, 600), 0)
        compare(CL.largerScale(300, 300, data.v, 600), 0)
        compare(CL.largerScale(300, 300, 600, data.v), 0)
        verify(!CL.largerAdds(data.v, 300, 324, 324, 600, 600))
        verify(!CL.largerAdds(300, 300, data.v, 324, 600, 600))
        verify(!CL.largerAdds(300, 300, 324, 324, data.v, 600))
    }

    function test_a_huge_picture_and_a_huge_room() {
        compare(CL.largerScale(1e6, 1e6, 600, 600), 600 / 1e6)
        compare(CL.largerScale(600, 600, 1e9, 1e9), 2)
        compare(CL.coverScale(1e6, 1, 324, 324), 324)
        verify(CL.largerAdds(600, 600, 324, 324, 1e9, 1e9))
    }

    // A drawing is rendered into the source size in its own shape.
    function test_a_drawing_gets_a_box_of_its_own_shape_inside_the_source_size() {
        var b = CL.box(200, 80, 600)
        compare(b.width, 600)
        compare(b.height, 240)
        b = CL.box(80, 200, 600)
        compare(b.width, 240)
        compare(b.height, 600)
        b = CL.box(48, 48, 600)
        compare(b.width, 600)
        compare(b.height, 600)
        b = CL.box(3000, 1000, 600)
        compare(b.width, 600)
        compare(b.height, 200)
        // Thinner than a pixel at that size: no box, and it is read like any picture.
        b = CL.box(100000, 10, 600)
        compare(b.width, 0)
        compare(b.height, 0)
        b = CL.box(10, 100000, 600)
        compare(b.width, 0)
        // 600 to 1 is the thinnest that still has a pixel.
        compare(CL.box(600, 1, 600).height, 1)
        compare(CL.box(601, 1, 600).height, 0)
        var none = [[0, 80, 600], [200, 0, 600], [200, 80, 0], [-1, 80, 600], [NaN, 80, 600], [undefined, 80, 600],
                    ["200", 80, 600], [Infinity, 80, 600]]
        for (var i = 0; i < none.length; i++) {
            b = CL.box(none[i][0], none[i][1], none[i][2])
            compare(b.width, 0, "box of " + none[i])
            compare(b.height, 0)
        }
    }

    function test_the_path_of_a_local_file_and_of_nothing_else() {
        compare(CL.localPath("file:///home/user/.cache/onair-favicons/12ab"), "/home/user/.cache/onair-favicons/12ab")
        compare(CL.localPath("file:///home/user/My%20Music/s%C3%BCda.svg"), "/home/user/My Music/süda.svg")
        compare(CL.localPath("https://example.org/logo.svg"), "")
        compare(CL.localPath("http://example.org/file:///etc/passwd"), "")
        compare(CL.localPath("data:image/png;base64,AAAA"), "")
        compare(CL.localPath("/home/user/logo.svg"), "")
        compare(CL.localPath(""), "")
        compare(CL.localPath(undefined), "")
        compare(CL.localPath(null), "")
        // A percent sign that escapes nothing leaves the path as it is written.
        compare(CL.localPath("file:///tmp/100%.svg"), "/tmp/100%.svg")
    }

    function test_an_address_that_names_a_drawing() {
        verify(CL.namedSvg("https://example.org/logo.svg"))
        verify(CL.namedSvg("http://example.org/a/b/LOGO.SVG"))
        verify(CL.namedSvg("https://example.org/logo.svgz"))
        verify(CL.namedSvg("https://example.org/logo.svg?v=3"))
        verify(CL.namedSvg("https://example.org/logo.svg#top"))
        verify(!CL.namedSvg("https://example.org/logo.png"))
        verify(!CL.namedSvg("https://example.org/logo.svg.png"))
        verify(!CL.namedSvg("https://example.org/logo?file=x.svg"))
        verify(!CL.namedSvg("https://example.org/svg"))
        // A local file is asked itself, whatever it is called.
        verify(!CL.namedSvg("file:///home/user/logo.svg"))
        verify(!CL.namedSvg(""))
        verify(!CL.namedSvg(undefined))
        verify(!CL.namedSvg(null))
    }

    // The page keeps the addresses whose picture failed to load, and puts a
    // new set in place of the old one for every address it adds.
    function test_an_address_is_added_to_a_copy_of_the_set() {
        var before = { "http://x/a.jpg": true }
        var after = CL.marked(before, "http://x/b.jpg")
        compare(Object.keys(after).sort(), ["http://x/a.jpg", "http://x/b.jpg"])
        verify(after["http://x/b.jpg"] === true)
        verify(after !== before)
        compare(Object.keys(before), ["http://x/a.jpg"])
        compare(Object.keys(CL.marked({}, "http://x/b.jpg")), ["http://x/b.jpg"])
        compare(Object.keys(CL.marked(before, "http://x/a.jpg")), ["http://x/a.jpg"])
        compare(Object.keys(CL.marked(undefined, "http://x/b.jpg")), ["http://x/b.jpg"])
        compare(Object.keys(CL.marked(null, "http://x/b.jpg")), ["http://x/b.jpg"])
        var many = {}
        for (var i = 0; i < 500; i++) many["http://x/" + i] = true
        compare(Object.keys(CL.marked(many, "http://x/new")).length, 501)
    }
}
