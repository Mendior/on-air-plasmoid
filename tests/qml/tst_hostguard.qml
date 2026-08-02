// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The private-network gate. Catalogue rows are publicly writable and reach
// background GETs, so this file decides whether plasmashell may touch a
// host at all — the most security-critical library in the tree, and the
// one that used to live without its own tests.
import QtQuick
import QtTest

import "../../package/contents/ui/HostGuard.js" as HG

TestCase {
    name: "HostGuard"

    function test_host_of_reads_the_authority() {
        compare(HG.hostOf("https://Example.COM/path"), "example.com")
        compare(HG.hostOf("http://example.com:8080/x"), "example.com")
        compare(HG.hostOf("https://[2001:db8::1]:443/x"), "[2001:db8::1]")
        // Userinfo is stripped up to the LAST "@" — an earlier "@" must
        // not hide the real host behind it.
        compare(HG.hostOf("http://a@b@10.0.0.5/x"), "10.0.0.5")
        compare(HG.hostOf("http://user:pw@127.0.0.1/x"), "127.0.0.1")
        // Nothing to contact reads as "" and every caller treats that as unsafe.
        compare(HG.hostOf("not a url"), "")
        compare(HG.hostOf("/relative/path"), "")
        compare(HG.hostOf(""), "")
        compare(HG.hostOf(null), "")
    }

    function test_v4_of_speaks_every_inet_aton_dialect() {
        compare(HG.v4Of("127.0.0.1"), 2130706433)
        compare(HG.v4Of("2130706433"), 2130706433)   // one part swallows all
        compare(HG.v4Of("127.1"), 2130706433)        // last part fills the tail
        compare(HG.v4Of("0177.0.0.1"), 2130706433)   // octal
        compare(HG.v4Of("0x7f.0.0.1"), 2130706433)   // hex
        compare(HG.v4Of("0x7f000001"), 2130706433)
        // Not an address in any dialect.
        compare(HG.v4Of("example.com"), -1)
        compare(HG.v4Of("1.2.3.4.5"), -1)
        compare(HG.v4Of("256.0.0.1"), -1)
        compare(HG.v4Of("127.0.0.999"), -1)
        compare(HG.v4Of("09.0.0.1"), -1)             // 9 is no octal digit
        compare(HG.v4Of(""), -1)
    }

    function test_private_v4_in_every_spelling() {
        var privates = ["127.0.0.1", "127.1", "2130706433", "0177.0.0.1",
                        "0x7f.0.0.1", "10.0.0.5", "10.255.255.254",
                        "172.16.0.1", "172.31.255.254", "192.168.1.1",
                        "169.254.169.254", "0.0.0.0", "0",
                        "100.64.0.1", "100.127.255.255"]
        for (var i = 0; i < privates.length; i++)
            verify(HG.isPrivateHost(privates[i]), privates[i] + " must be private")
    }

    function test_public_v4_stays_reachable() {
        var publics = ["1.1.1.1", "8.8.8.8", "172.15.0.1", "172.32.0.1",
                       "192.169.1.1", "100.63.255.255", "100.128.0.1",
                       "126.255.255.255", "128.0.0.1"]
        for (var i = 0; i < publics.length; i++)
            verify(!HG.isPrivateHost(publics[i]), publics[i] + " must stay reachable")
    }

    function test_names_that_mean_this_machine() {
        verify(HG.isPrivateHost("localhost"))
        verify(HG.isPrivateHost("LocalHost"))
        verify(HG.isPrivateHost("localhost."))     // DNS root dot
        verify(HG.isPrivateHost("db.localhost"))
        verify(HG.isPrivateHost(""))               // nothing to contact
        // A plain DNS name passes: QML has no resolver, and the file says so.
        verify(!HG.isPrivateHost("example.com"))
        verify(!HG.isPrivateHost("stream.radio.fm"))
    }

    function test_ipv6_embeddings_and_zero_runs() {
        verify(HG.isPrivateHost("[::1]"))
        verify(HG.isPrivateHost("[::]"))
        verify(HG.isPrivateHost("[::ffff:127.0.0.1]"))   // v4-mapped loopback
        verify(HG.isPrivateHost("[::ffff:10.0.0.5]"))
        verify(HG.isPrivateHost("[::127.0.0.1]"))        // v4-compatible
        verify(HG.isPrivateHost("[0:0:0:0:0:0:0:1]"))    // spelled out
        verify(HG.isPrivateHost("[fe80::1]"))            // link-local
        verify(HG.isPrivateHost("[fe80::1%eth0]"))       // zone index
        verify(HG.isPrivateHost("[fc00::1]"))            // unique-local
        verify(HG.isPrivateHost("[fd12:3456::1]"))
        // Public v6 is reachable; v4-mapped public too.
        verify(!HG.isPrivateHost("[2001:db8::1]"))
        verify(!HG.isPrivateHost("[::ffff:8.8.8.8]"))
        // Malformed literals are refused, not guessed at.
        verify(HG.isPrivateHost("[::1::2]"))
        verify(HG.isPrivateHost("[gggg::1]"))
        verify(HG.isPrivateHost("[]"))
    }

    function test_spellings_qt_would_decode_are_refused() {
        // QUrl percent-decodes and IDN-normalizes the host before dialing,
        // so a literal parser must refuse anything it cannot read as-is —
        // "%31%32%37.0.0.1" reached loopback past an earlier gate.
        verify(HG.isPrivateHost("%31%32%37.0.0.1"))
        verify(HG.isPrivateHost("127.0.0.1%00"))
        verify(HG.isPrivateHost("ｌｏｃａｌｈｏｓｔ"))   // fullwidth
        verify(HG.isPrivateHost("exam­ple.com"))    // soft hyphen
    }

    function test_the_gate_as_the_callers_use_it() {
        // hostOf + isPrivateHost is the pair every caller runs; a URL with
        // no host must never read as safe.
        var deny = ["http://127.0.0.1:8080/x.m3u", "http://192.168.1.1/",
                    "http://[::1]:9000/", "http://a@b@10.0.0.5/",
                    "http://%31%32%37.0.0.1/", "not a url", ""]
        for (var i = 0; i < deny.length; i++) {
            var h = HG.hostOf(deny[i])
            verify(h === "" || HG.isPrivateHost(h), deny[i] + " must be refused")
        }
        var allow = ["https://stream.example.com/live", "http://8.8.8.8/x"]
        for (var j = 0; j < allow.length; j++) {
            var h2 = HG.hostOf(allow[j])
            verify(h2 !== "" && !HG.isPrivateHost(h2), allow[j] + " must pass")
        }
    }

    function test_answer_origin_is_judged_not_just_the_request() {
        // Qt follows redirects inside the network layer — measured on
        // 6.11.1, http://github.com/ arrives as status 200 with
        // responseURL https://github.com/ and no Location header. So the
        // answer's own origin has to be judged, or a public catalogue row
        // can answer 302 into the listener's LAN.
        verify(HG.answerFromPublicHost({ responseURL: "https://cdn.example.com/x.png" }))
        verify(!HG.answerFromPublicHost({ responseURL: "http://192.168.1.1/x.png" }))
        verify(!HG.answerFromPublicHost({ responseURL: "http://127.0.0.1:8080/" }))
        verify(!HG.answerFromPublicHost({ responseURL: "http://[::1]/" }))
        // Not reported (older/other builds): keep the previous behaviour
        // rather than refusing every answer.
        verify(HG.answerFromPublicHost({ responseURL: "" }))
        verify(HG.answerFromPublicHost({}))
        verify(HG.answerFromPublicHost(null))
    }
}
