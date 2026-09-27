// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
//
// Whether a colour can be read where it is written. On Breeze Light the
// playing station's name was a bright green on a pale green row, 1.23:1
// where body text wants 4.5:1. The ruler below is the WCAG one; the
// expected values come from that requirement and from "a dark scheme keeps
// both greens exactly", never from what the code happens to answer.
import QtQuick
import QtTest

import "../../package/contents/ui/ColorLogic.js" as CL

TestCase {
    name: "ColorLogic"

    readonly property var lightSurfaces: ["#ffffff", "#fcfcfc", "#eff0f1", "#dee0e2"]
    readonly property var darkSurfaces: ["#141618", "#1b1e20", "#202326", "#232629",
                                         "#292c30", "#2a2e32", "#31363b"]
    // Ten accents round the wheel, the kind a system accent can be.
    readonly property var wheel: ["#3daee9", "#e93a9a", "#e93d58", "#e9643a", "#e8cb2d",
                                  "#3dd425", "#00d3b8", "#b875dc", "#926ee4", "#686b6f"]
    property color qmlEmerald: "#6FCF97"
    property color qmlLightWindow: "#eff0f1"
    property color qmlDarkWindow: "#202326"

    function test_the_ruler_is_the_wcag_one() {
        compare(CL.contrast("#000000", "#ffffff"), 21)
        compare(CL.contrast("#6FCF97", "#6FCF97"), 1)
        // The well-known pair either side of AA.
        verify(CL.contrast("#767676", "#ffffff") >= 4.5)
        verify(CL.contrast("#777777", "#ffffff") < 4.5)
        compare(CL.contrast("#ffffff", "#767676"), CL.contrast("#767676", "#ffffff"))
    }

    function test_the_raw_greens_cannot_be_read_on_breeze_light() {
        fuzzyCompare(CL.contrast("#3BEE96", "#eff0f1"), 1.33, 0.01)
        fuzzyCompare(CL.worstContrast("#3BEE96", "#eff0f1", "#6FCF97"), 1.23, 0.01)
        fuzzyCompare(CL.contrast("#6FCF97", "#eff0f1"), 1.67, 0.01)
    }

    function test_a_dark_scheme_keeps_both_greens_exactly() {
        for (var i = 0; i < darkSurfaces.length; i++) {
            compare(CL.readable("#6FCF97", darkSurfaces[i], "#6FCF97"), "#6FCF97", darkSurfaces[i])
            compare(CL.readable("#3BEE96", darkSurfaces[i], "#6FCF97"), "#3BEE96", darkSurfaces[i])
        }
    }

    function test_a_light_scheme_gets_a_green_it_can_read() {
        var greens = ["#6FCF97", "#3BEE96"]
        for (var i = 0; i < lightSurfaces.length; i++)
            for (var g = 0; g < greens.length; g++) {
                var s = lightSurfaces[i]
                var out = CL.readable(greens[g], s, "#6FCF97")
                verify(CL.contrast(out, s) >= 4.5, greens[g] + " on " + s)
                verify(CL.worstContrast(out, s, "#6FCF97") >= 4.5, greens[g] + " on the wash over " + s)
                // The brand stays green...
                var c = CL.channels(out)
                verify(c.g > c.r && c.g > c.b, out)
                // ...lands with half a point to spare, because a popup is
                // translucent and the real surface is never quite the nominal
                // one, and stops there.
                verify(CL.worstContrast(out, s, "#6FCF97") >= 5.0, out + " has no margin")
                verify(CL.worstContrast(out, s, "#6FCF97") < 5.5, out + " went further than it had to")
            }
    }

    function test_the_playing_rows_wash_is_the_surface_that_decides() {
        compare(CL.washed("#eff0f1", "#6FCF97", 0.15), "#dcebe3")
        var bareOnly = CL.readable("#6FCF97", "#eff0f1")
        var forTheRow = CL.readable("#6FCF97", "#eff0f1", "#6FCF97")
        verify(CL.contrast(bareOnly, "#eff0f1") >= 4.5)
        // The tinted row is the harder surface: a shade chosen for the bare
        // popup reads worse on it than the shade chosen with the wash in mind.
        verify(CL.worstContrast(bareOnly, "#eff0f1", "#6FCF97") < CL.worstContrast(forTheRow, "#eff0f1", "#6FCF97"))
        verify(CL.worstContrast(forTheRow, "#eff0f1", "#6FCF97") >= 5.0)
    }

    function test_any_accent_reads_on_both_breezes() {
        var surfaces = ["#eff0f1", "#202326"]
        for (var i = 0; i < wheel.length; i++)
            for (var s = 0; s < surfaces.length; s++) {
                var a = wheel[i]
                verify(CL.worstContrast(CL.readable(a, surfaces[s], a), surfaces[s], a) >= 4.5,
                       a + " on " + surfaces[s])
            }
        // The system accent on a light scheme is where the fixed darkening
        // used to leave the most room; the measured one keeps a margin too.
        verify(CL.worstContrast(CL.readable("#3daee9", "#eff0f1", "#3daee9"), "#eff0f1", "#3daee9") >= 5.0)
        // Breeze's own blue already reads on Breeze Dark and is left alone.
        compare(CL.readable("#3daee9", "#202326", "#3daee9"), "#3daee9")
    }

    function test_a_surface_in_the_middle_gets_the_better_pole() {
        var out = CL.readable("#6FCF97", "#777777", "#6FCF97")
        verify(CL.worstContrast(out, "#777777", "#6FCF97") > CL.worstContrast("#6FCF97", "#777777", "#6FCF97"))
        verify(CL.luminance(out) < CL.luminance("#777777"))
    }

    function test_plain_mode_colours_pass_through() {
        compare(CL.readable("#232629", "#eff0f1", "#232629"), "#232629")
        compare(CL.readable("#fcfcfc", "#202326", "#fcfcfc"), "#fcfcfc")
    }

    function test_garbage_never_breaks_the_binding() {
        compare(CL.readable("teal", "#eff0f1", "#6FCF97"), "teal")
        compare(CL.readable("#6FCF97", undefined, "#6FCF97"), "#6FCF97")
        compare(CL.contrast("x", "#ffffff"), 0)
        compare(CL.luminance(null), -1)
        compare(CL.hex({ r: 2, g: -1, b: 0.5 }), "#ff0080")
        // A wash nobody can read is no wash.
        compare(CL.readable("#6FCF97", "#eff0f1", "nonsense"), CL.readable("#6FCF97", "#eff0f1"))
    }

    // Breeze's own negative text colour, the one LIVE is written in, on
    // both Breezes: measured on the bench before the change, 3.03:1 on light
    // and 2.83:1 on dark (T3 saw 2.83:1 on light over a darker cover).
    readonly property var negatives: ["#da4453", "#e93d58", "#ed1515", "#f67400"]

    function test_live_can_be_read_on_its_own_pill_on_both_breezes() {
        var surfaces = lightSurfaces.concat(darkSurfaces)
        for (var n = 0; n < negatives.length; n++) {
            for (var i = 0; i < surfaces.length; i++) {
                var fg = negatives[n], bg = surfaces[i]
                var pill = CL.pillSurface(fg, bg)
                verify(pill !== "", fg + " on " + bg + ": no surface")
                var text = CL.pillText(fg, bg)
                verify(CL.contrast(text, pill) >= 4.5,
                       fg + " on " + bg + ": " + text + " on " + pill + " = "
                       + CL.contrast(text, pill).toFixed(2))
            }
        }
    }

    function test_the_pill_is_its_colour_washed_over_the_popup() {
        // The wash the pill always had; only the text and the opacity move.
        compare(CL.pillSurface("#da4453", "#eff0f1"), CL.washed("#eff0f1", "#da4453", 0.16))
        compare(CL.pillSurface("#da4453", "#202326"), CL.washed("#202326", "#da4453", 0.16))
        // Measured on the bench, where the pill was still see-through: the
        // light one came out #ECD4D7, the model says one step off.
        verify(CL.contrast(CL.pillSurface("#da4453", "#eff0f1"), "#ecd4d7") < 1.02)
    }

    function test_live_stays_red_and_moves_only_as_far_as_it_must() {
        var light = CL.pillText("#da4453", "#eff0f1")
        var dark = CL.pillText("#da4453", "#202326")
        // Darker on light, lighter on dark, and still a red: the red channel
        // leads the other two by a wide margin.
        verify(CL.luminance(light) < CL.luminance("#da4453"))
        verify(CL.luminance(dark) > CL.luminance("#da4453"))
        var pl = CL.channels(light), pd = CL.channels(dark)
        verify(pl.r > pl.g + 0.25 && pl.r > pl.b + 0.2, light)
        verify(pd.r > pd.g + 0.15 && pd.r > pd.b + 0.1, dark)
        // No further than the line and its headroom: not black, not white.
        verify(CL.contrast(light, CL.pillSurface("#da4453", "#eff0f1")) < 6.5)
        verify(CL.contrast(dark, CL.pillSurface("#da4453", "#202326")) < 6.5)
    }

    function test_a_negative_that_already_reads_is_left_alone() {
        // A scheme whose red already reads on its pill keeps that exact red.
        compare(CL.pillText("#7a0000", "#ffffff"), "#7a0000")
        // Garbage in, the colour back, never a broken binding.
        compare(CL.pillText("red", "#eff0f1"), "red")
        compare(CL.pillSurface("#da4453", undefined), "")
    }

    function test_a_qml_colour_is_read_like_its_hex() {
        compare(CL.hex(qmlLightWindow), "#eff0f1")
        fuzzyCompare(CL.contrast(qmlEmerald, qmlLightWindow), CL.contrast("#6FCF97", "#eff0f1"), 0.001)
        compare(CL.readable(qmlEmerald, qmlLightWindow, qmlEmerald),
                CL.readable("#6FCF97", "#eff0f1", "#6FCF97"))
        verify(Qt.colorEqual(CL.readable(qmlEmerald, qmlDarkWindow, qmlEmerald), qmlEmerald))
    }
}
