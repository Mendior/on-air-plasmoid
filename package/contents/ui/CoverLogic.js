/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// How large the cover is drawn, on the Playing page and in the larger view.
// Sizes in, a factor out: the page and CoverTouch.qml place the pictures.
// A picture's own size is what its Image read, in pixels.
.pragma library

// How far past its own pixels the larger view enlarges a picture. Station
// logos of 32 and 64 pixels were looked at on 2026-11-12 at one to nine
// times their size: at twice they are soft and whole, at three times the
// edges smear, from four on a logo is fog. The larger view used to fill its
// room whatever the picture, which put a 32-pixel logo at 600.
// The pixels are the screen's. A size here is in the page's units, and on a
// scaled screen one such unit is more than one pixel: at 175% a cover of 300
// shown 600 wide covered 1050 pixels, three and a half times its own
// (measured on the panel the same day). ratio is how many of the screen's
// pixels one unit is; an Image tells a picture's size in the picture's own
// pixels whatever the screen (Qt 6.12, scale factors 1, 1.75 and 2).
var STRETCH = 2;

// How much larger than the cover on the page the larger view has to be to
// be offered: a quarter, by its side. Less than that is a click for a
// picture that looks the same.
var GAIN = 1.25;

// A size as a number above zero, 0 for anything else.
function _side(v) {
    return typeof v === "number" && isFinite(v) && v > 0 ? v : 0;
}

// The factor at which a picture of natW by natH covers a frame of w by h in
// its own shape: its smaller side fills the frame and the other hangs over,
// for the frame to cut. 0 while any of the four is no size, which is how it
// stands before the picture is read.
// Contract: coverScale(300, 300, 324, 324) = 1.08; coverScale(400, 200, 200,
//   200) = 1; coverScale(0, 0, 324, 324) = 0.
function coverScale(natW, natH, w, h) {
    natW = _side(natW); natH = _side(natH); w = _side(w); h = _side(h);
    if (!natW || !natH || !w || !h) return 0;
    return Math.max(w / natW, h / natH);
}

// The factor for the larger view: the whole picture in its own shape, as
// large as a room of roomW by roomH lets it be and at most STRETCH times its
// own pixels, counted in the screen's. 0 while any of the four is no size; a
// ratio that is none is a screen that is not scaled.
// Contract: largerScale(32, 32, 600, 600) = 2; largerScale(500, 500, 600,
//   600) = 1.2; largerScale(600, 300, 400, 400) = 2/3; largerScale(300, 300,
//   2000, 2000, 1.75) = 2/1.75, which draws it 343 wide.
function largerScale(natW, natH, roomW, roomH, ratio) {
    natW = _side(natW); natH = _side(natH); roomW = _side(roomW); roomH = _side(roomH);
    if (!natW || !natH || !roomW || !roomH) return 0;
    return Math.min(roomW / natW, roomH / natH, STRETCH / (_side(ratio) || 1));
}

// Whether the larger view has anything to add: it draws the picture at
// least GAIN times as large as the page already does in its frame of w by
// h. A view that would show the same picture hardly larger is not offered.
// Contract: largerAdds(32, 32, 126, 126, 600, 600) = false; largerAdds(300,
//   300, 324, 324, 440, 620) = true; largerAdds(300, 300, 310, 310, 600, 600,
//   1.75) = false; any size that is none = false.
function largerAdds(natW, natH, w, h, roomW, roomH, ratio) {
    var page = coverScale(natW, natH, w, h), view = largerScale(natW, natH, roomW, roomH, ratio);
    return page > 0 && view >= page * GAIN;
}

// A copy of a set of addresses with one more in it. The page keeps the
// addresses whose picture failed to load and replaces the set as a whole,
// because a binding does not see a key added in place.
function marked(set, key) {
    var out = {};
    for (var k in set) out[k] = true;
    out[key] = true;
    return out;
}

// The size a drawing of w by h is rendered at: its own shape, as large as
// fits a square of side. A drawing has no pixels of its own, and how it is
// read decides what comes back: by its name Qt fills the whole source size
// with it, square whatever its shape, and without the name Qt reads it at
// the few pixels it declares (measured in Qt 6.12 on a drawing of 200 by 80:
// 600 by 600 as "wide.svg", 200 by 80 as the same file without the
// extension). Asked for this box instead, it comes back in its shape and
// sharp, and never larger than the source size.
// A shape thinner than one pixel at that size gets no box: { 0, 0 }, and it
// is read like any picture, which bounds it too.
// Contract: box(200, 80, 600) = { 600, 240 }; box(80, 200, 600) = { 240,
//   600 }; box(100000, 10, 600) = { 0, 0 }; a size that is none = { 0, 0 }.
function box(w, h, side) {
    w = _side(w); h = _side(h); side = _side(side);
    var k = w && h && side ? side / Math.max(w, h) : 0;
    if (Math.min(w, h) * k < 1) return { "width": 0, "height": 0 };
    return { "width": Math.round(w * k), "height": Math.round(h * k) };
}

// The path of a local file's address, "" for any other address. A local
// file can be asked what it is; nothing else is.
function localPath(address) {
    var m = /^file:\/\/(\/.*)$/.exec(typeof address === "string" ? address : "");
    if (!m) return "";
    try {
        return decodeURIComponent(m[1]);
    } catch (e) {
        // A "%" that escapes nothing: the path is what is written.
        return m[1];
    }
}

// Whether an address on the network says by its name that it is a drawing:
// its path ends in .svg or .svgz. That name is also what makes Qt fill the
// source size with it.
function namedSvg(address) {
    return /^https?:\/\/[^?#]*\.svgz?(?:[?#]|$)/i.test(typeof address === "string" ? address : "");
}
