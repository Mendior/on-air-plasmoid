// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The bitrate upgrade is a list of reasons NOT to switch, and every one of
// them was paid for: a false "upgrade" plays the wrong mount, a codec
// switch breaks the recorder, a playlist wrapper kills the ICY titles.
import QtQuick
import QtTest

import "../../package/contents/ui/StreamLogic.js" as StreamLogic

TestCase {
    name: "StreamLogic"

    // A radio-browser row, shaped like the directory actually answers.
    function row(name, url, bitrate) {
        return { name: name, url: url, url_resolved: "", bitrate: bitrate }
    }

    function test_the_host_comes_out_clean() {
        compare(StreamLogic.hostOf("https://radio.example.com:8000/live"), "radio.example.com")
        compare(StreamLogic.hostOf("http://user:pw@radio.example.com/live"), "radio.example.com")
        compare(StreamLogic.hostOf("https://[::1]:8000/live"), "[::1]")
        compare(StreamLogic.hostOf("https://RADIO.Example.COM/x"), "radio.example.com")
        compare(StreamLogic.hostOf("not a url"), "")
    }

    function test_the_base_domain_knows_its_exceptions() {
        compare(StreamLogic.baseDomain("s5.radio.co"), "radio.co")
        compare(StreamLogic.baseDomain("stream.bbc.co.uk"), "bbc.co.uk")
        compare(StreamLogic.baseDomain("example.com"), "example.com")
        compare(StreamLogic.baseDomain("192.168.1.5"), "192.168.1.5")
        compare(StreamLogic.baseDomain("[::1]"), "[::1]")
        compare(StreamLogic.baseDomain(""), "")
    }

    function test_the_format_verdict_by_extension_and_by_guess() {
        compare(StreamLogic.streamFormat("http://x/a.m3u8"), "hls")
        compare(StreamLogic.streamFormat("http://x/a.pls"), "playlist")
        compare(StreamLogic.streamFormat("http://x/a.mp3?token=1"), "mp3")
        compare(StreamLogic.streamFormat("http://x/aacp-stream"), "aac")
        compare(StreamLogic.streamFormat("http://x/mp3-96"), "mp3")
        // strict refuses the substring guess — the recorder depends on it.
        compare(StreamLogic.streamFormat("http://x/mp3-96", true), "unknown")
        compare(StreamLogic.streamFormat("http://x/live", true), "unknown")
    }

    function test_a_real_upgrade_is_taken() {
        var orig = "http://s1.radio.ee/live.mp3"
        var picked = StreamLogic.pickBitrateUpgrade([
            row("Jazz FM", orig, 128),
            row("Jazz FM", "http://s2.radio.ee/hi.mp3", 320)
        ], "Jazz FM", orig)
        compare(picked, "http://s2.radio.ee/hi.mp3")
    }

    function test_no_baseline_means_no_switch() {
        var orig = "http://s1.radio.ee/live.mp3"
        // The playing URL is not in the answer at all.
        compare(StreamLogic.pickBitrateUpgrade([
            row("Jazz FM", "http://s2.radio.ee/hi.mp3", 320)
        ], "Jazz FM", orig), orig)
        // It is there, but the directory does not know its bitrate.
        compare(StreamLogic.pickBitrateUpgrade([
            row("Jazz FM", orig, 0),
            row("Jazz FM", "http://s2.radio.ee/hi.mp3", 96)
        ], "Jazz FM", orig), orig)
    }

    function test_the_refusals_hold() {
        var orig = "http://s1.radio.ee/live.mp3"
        var base = [row("Jazz FM", orig, 128)]
        // Another station's mount, even at the same host family.
        compare(StreamLogic.pickBitrateUpgrade(
            base.concat([row("Jazz FM Extra", "http://s2.radio.ee/x.mp3", 320)]),
            "Jazz FM", orig), orig)
        // A different base domain.
        compare(StreamLogic.pickBitrateUpgrade(
            base.concat([row("Jazz FM", "http://cdn.other.com/x.mp3", 320)]),
            "Jazz FM", orig), orig)
        // Playlist and HLS wrappers.
        compare(StreamLogic.pickBitrateUpgrade(
            base.concat([row("Jazz FM", "http://s2.radio.ee/x.m3u8", 320),
                         row("Jazz FM", "http://s2.radio.ee/x.pls", 320)]),
            "Jazz FM", orig), orig)
        // A silent codec switch.
        compare(StreamLogic.pickBitrateUpgrade(
            base.concat([row("Jazz FM", "http://s2.radio.ee/x.aac", 320)]),
            "Jazz FM", orig), orig)
        // Equal is not better, and absurd rates are directory noise.
        compare(StreamLogic.pickBitrateUpgrade(
            base.concat([row("Jazz FM", "http://s2.radio.ee/x.mp3", 128),
                         row("Jazz FM", "http://s3.radio.ee/x.mp3", 9999)]),
            "Jazz FM", orig), orig)
    }

    function test_bps_reports_are_read_as_kbps() {
        var orig = "http://s1.radio.ee/live.mp3"
        var picked = StreamLogic.pickBitrateUpgrade([
            row("Jazz FM", orig, 128000),
            row("Jazz FM", "http://s2.radio.ee/hi.mp3", 320000)
        ], "Jazz FM", orig)
        compare(picked, "http://s2.radio.ee/hi.mp3")
    }

    function test_the_orig_url_matches_loosely_but_honestly() {
        // Protocol and a trailing slash differ; it is still the same mount.
        var orig = "https://S1.radio.ee/live.mp3/"
        var r = row("Jazz FM", "http://s1.radio.ee/live.mp3", 128)
        var hi = row("Jazz FM", "http://s2.radio.ee/hi.mp3", 320)
        compare(StreamLogic.pickBitrateUpgrade([r, hi], "Jazz FM", orig),
                "http://s2.radio.ee/hi.mp3")
    }

    function test_url_resolved_outranks_url() {
        var orig = "http://s1.radio.ee/live.mp3"
        var picked = StreamLogic.pickBitrateUpgrade([
            row("Jazz FM", orig, 128),
            { name: "Jazz FM", url: "http://s2.radio.ee/wrapper.pls",
              url_resolved: "http://s2.radio.ee/hi.mp3", bitrate: 320 }
        ], "Jazz FM", orig)
        compare(picked, "http://s2.radio.ee/hi.mp3")
    }

    function test_station_names_compare_with_folded_spaces() {
        var orig = "http://s1.radio.ee/live.mp3"
        var picked = StreamLogic.pickBitrateUpgrade([
            row("Jazz  FM ", orig, 128),
            row(" Jazz FM", "http://s2.radio.ee/hi.mp3", 320)
        ], "Jazz FM", orig)
        compare(picked, "http://s2.radio.ee/hi.mp3")
    }

    function test_empty_answers_change_nothing() {
        var orig = "http://s1.radio.ee/live.mp3"
        compare(StreamLogic.pickBitrateUpgrade([], "Jazz FM", orig), orig)
        compare(StreamLogic.pickBitrateUpgrade([row("Jazz FM", "", 320)],
                                               "Jazz FM", orig), orig)
    }
}
