// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The favicon gate, the backfill's directory-row picker and the monogram
// math — the pure pieces behind "every station gets a face".
import QtQuick
import QtTest

import "../../package/contents/ui/FaviconLogic.js" as FL

TestCase {
    name: "FaviconLogic"

    // ── webUrlOrEmpty: the one gate to Image.source and the shell ─────────

    function test_gate_passes_plain_web_urls() {
        compare(FL.webUrlOrEmpty("https://a.b/f.png"), "https://a.b/f.png")
        compare(FL.webUrlOrEmpty("http://a.b/f.ico"), "http://a.b/f.ico")
        compare(FL.webUrlOrEmpty("  https://a.b/x  "), "https://a.b/x")
        compare(FL.webUrlOrEmpty("HTTPS://A.B/x"), "HTTPS://A.B/x")
    }

    function test_gate_rejects_everything_else() {
        compare(FL.webUrlOrEmpty("file:///etc/passwd"), "")
        compare(FL.webUrlOrEmpty("data:image/png;base64,AAAA"), "")
        compare(FL.webUrlOrEmpty("javascript:alert(1)"), "")
        compare(FL.webUrlOrEmpty("sky.ee/favicon.ico"), "")   // scheme-less
        compare(FL.webUrlOrEmpty("null"), "")
        compare(FL.webUrlOrEmpty(" null "), "")
        compare(FL.webUrlOrEmpty(""), "")
        compare(FL.webUrlOrEmpty(undefined), "")
        compare(FL.webUrlOrEmpty(null), "")
        compare(FL.webUrlOrEmpty(42), "")
    }

    // ── pickFavicon: the backfill's exact-name donor rule ─────────────────

    function norm(s) {
        // stand-in for HealLogic.normName: lowercase, strip non-alnum
        return String(s).toLowerCase().replace(/[^a-z0-9]/g, "")
    }

    function test_pick_first_gated_favicon() {
        var rows = [
            { name: "A", favicon: "" },
            { name: "B", favicon: "file:///x" },
            { name: "C", favicon: "https://c.ee/l.png" },
            { name: "D", favicon: "https://d.ee/l.png" }
        ]
        compare(FL.pickFavicon(rows), "https://c.ee/l.png")
    }

    function test_pick_with_wantnorm_requires_exact_name_match() {
        var rows = [
            { name: "Sky Plus Latvia", favicon: "https://wrong.example/l.png" },
            { name: "Sky Plus", favicon: "https://sky.ee/l.png" }
        ]
        compare(FL.pickFavicon(rows, norm("Sky Plus"), norm), "https://sky.ee/l.png")
        // No exact match anywhere -> nothing, never the near-namesake.
        compare(FL.pickFavicon(rows, norm("Sky Plus Estonia"), norm), "")
    }

    function test_pick_handles_garbage() {
        compare(FL.pickFavicon([], null, null), "")
        compare(FL.pickFavicon(null, null, null), "")
        compare(FL.pickFavicon([null, {}, { name: "x" }], null, null), "")
        // wantNorm given but no normFn: fail closed.
        compare(FL.pickFavicon([{ name: "x", favicon: "https://a/l.png" }], "x", null), "")
    }

    // ── monogramText ──────────────────────────────────────────────────────

    function test_monogram_two_words() {
        compare(FL.monogramText("Raadio Elmar"), "RE")
        compare(FL.monogramText("Sky Plus"), "SP")
        compare(FL.monogramText("HITS RADIO ESTONIA"), "HR")
        compare(FL.monogramText("Võmba FM"), "VF")
    }

    function test_monogram_single_word() {
        compare(FL.monogramText("Elmar"), "EL")
        compare(FL.monogramText("R2"), "R2")
        compare(FL.monogramText("Õ"), "Õ")
    }

    function test_monogram_keeps_diacritics() {
        compare(FL.monogramText("Õhtune Ärikanal"), "ÕÄ")
    }

    function test_monogram_strips_leading_punctuation() {
        compare(FL.monogramText("«Radio» +Nova"), "RN")
        compare(FL.monogramText("...Beat FM"), "BF")
    }

    function test_monogram_garbage_is_empty() {
        compare(FL.monogramText(""), "")
        compare(FL.monogramText("   "), "")
        compare(FL.monogramText("«»..."), "")
        compare(FL.monogramText(undefined), "")
        compare(FL.monogramText(null), "")
    }

    // ── monogramHue ───────────────────────────────────────────────────────

    function test_hue_is_deterministic_and_case_blind() {
        compare(FL.monogramHue("Raadio Elmar"), FL.monogramHue("Raadio Elmar"))
        compare(FL.monogramHue("Sky Plus"), FL.monogramHue("sky plus"))
        compare(FL.monogramHue(" Sky Plus "), FL.monogramHue("Sky Plus"))
    }

    function test_hue_stays_in_the_safe_band() {
        var names = ["Raadio Elmar", "Sky Plus", "R2", "Võmba FM", "x", "",
                     "HITS RADIO ESTONIA", "Retro FM Estonia", "Raadio Kuku"]
        for (var i = 0; i < names.length; i++) {
            var h = FL.monogramHue(names[i])
            verify(h >= 90 && h <= 230, names[i] + " -> " + h)
        }
    }

    function test_hue_spreads_across_names() {
        // Not a strict requirement, but the three demo stations must not
        // all collapse onto one color — that would defeat the point.
        var a = FL.monogramHue("Raadio Elmar")
        var b = FL.monogramHue("Sky Plus")
        var c = FL.monogramHue("Raadio Kuku")
        verify(!(a === b && b === c))
    }
}
