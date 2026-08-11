// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The exit-code classifier, tested by CALLING it — the whole point of pulling
// it into a library. classify() decides whether a finished command's code
// means anything, and label() names it for a journal line without ever
// leaking the station names, URLs and paths the command line carries.
import QtQuick
import QtTest

import "../../package/contents/ui/ExecClass.js" as EC

TestCase {
    name: "ExecClass"

    function test_only_127_and_124_carry_a_meaning() {
        compare(EC.classify(127), "missing")
        compare(EC.classify(124), "timeout")
    }

    function test_success_and_ordinary_failures_stay_silent() {
        // 0 is success; 1 is grep/pgrep's "no match", 2, 126, 130 (Ctrl-C)
        // are real but ambiguous — none of them names a missing tool, so the
        // caller must hear nothing and not cry wolf on a healthy machine.
        compare(EC.classify(0), "")
        compare(EC.classify(1), "")
        compare(EC.classify(2), "")
        compare(EC.classify(126), "")
        compare(EC.classify(130), "")
    }

    function test_a_missing_or_odd_code_never_throws() {
        // The 3-arg callers (every sync-engine test) pass no exit code, so
        // classify sees undefined; a stray string must not match 127 either.
        compare(EC.classify(undefined), "")
        compare(EC.classify(null), "")
        compare(EC.classify("127"), "")
    }

    function test_label_prefers_the_widgets_own_sentinel() {
        compare(EC.label(": PW_PROBE;"), "PW_PROBE")
        compare(EC.label(": BT_KICK AA:BB:CC:DD:EE:00;"), "BT_KICK")
        // The exec facade prepends the locale export; the sentinel still wins.
        compare(EC.label("export LC_ALL=C LANGUAGE=C; : PW_DRIFT;"), "PW_DRIFT")
    }

    function test_label_falls_back_to_the_first_bare_word() {
        compare(EC.label("pactl list sinks"), "pactl")
        compare(EC.label("export LC_ALL=C LANGUAGE=C; bluetoothctl info"), "bluetoothctl")
    }

    function test_label_never_returns_the_whole_line() {
        // A command carrying a URL or a station name must not put it in a log:
        // label takes the first token only, never an argument that follows.
        var withUrl = "curl -s 'https://radio.example/secret-token/stream'"
        compare(EC.label(withUrl), "curl")
        verify(EC.label(withUrl).indexOf("http") === -1)
        verify(EC.label(withUrl).indexOf("token") === -1)
    }

    function test_a_colon_inside_an_argument_is_not_the_label() {
        // The sentinel is honoured only at the START. An earlier version
        // matched the first ":UPPERCASE" anywhere, so a header value or a
        // URL fragment became the label — a leak into the journal and a key
        // that changed on every call. These are the exact shapes that broke.
        compare(EC.label("xdg-open 'https://en.wikipedia.org/wiki/Foo:BAR'"), "xdg-open")
        compare(EC.label("curl -H 'X-Auth: SECRETTOKEN' https://x"), "curl")
        compare(EC.label("export LC_ALL=C LANGUAGE=C; pactl set-sink-mute @X:Y 0"), "pactl")
    }

    function test_label_of_nothing_is_nothing() {
        compare(EC.label(""), "")
        compare(EC.label(undefined), "")
        compare(EC.label(null), "")
    }
}
