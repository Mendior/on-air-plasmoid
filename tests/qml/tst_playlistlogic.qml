// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The playlist-unwrap decisions. Every case here is a real-world shape
// that produced a visible "Error: Could not open file" at some point:
// relative Icecast mounts, HLS media served under a .m3u name, playlists
// pointing at playlists, bodies with nothing usable in them.
import QtQuick
import QtTest

import "../../package/contents/ui/PlaylistLogic.js" as PL

TestCase {
    name: "PlaylistLogic"

    // ── classify: the happy paths ─────────────────────────────────────────

    function test_pls_absolute_entry() {
        var got = PL.classify("[playlist]\nFile1=http://ice.example.com/nova.mp3\nTitle1=Nova\n",
                              "http://radio.example.com/nova.pls");
        compare(got.kind, "entry");
        compare(got.url, "http://ice.example.com/nova.mp3");
    }

    function test_m3u_first_noncomment_line() {
        var got = PL.classify("#EXTM3U\n#EXTINF:-1,Nova\nhttps://ice.example.com/nova\n",
                              "http://radio.example.com/nova.m3u");
        compare(got.kind, "entry");
        compare(got.url, "https://ice.example.com/nova");
    }

    // ── classify: the shapes that used to end in a visible error ─────────

    function test_relative_entry_resolves_against_the_wrapper_directory() {
        // Icecast playlist generators often only know their own mounts.
        var got = PL.classify("[playlist]\nFile1=nova.aac\n",
                              "http://host.example.com/dir/list.pls?sid=1");
        compare(got.kind, "entry");
        compare(got.url, "http://host.example.com/dir/nova.aac");
    }

    function test_root_relative_entry_gets_the_wrapper_host() {
        var got = PL.classify("/mounts/nova\n", "https://host.example.com/x/list.m3u");
        compare(got.kind, "entry");
        compare(got.url, "https://host.example.com/mounts/nova");
    }

    function test_protocol_relative_entry_inherits_the_scheme() {
        var got = PL.classify("//cdn.example.com/nova\n", "https://host.example.com/list.m3u");
        compare(got.kind, "entry");
        compare(got.url, "https://cdn.example.com/nova");
    }

    function test_bare_host_wrapper_still_yields_a_directory() {
        var got = PL.classify("stream.mp3\n", "http://host.example.com");
        compare(got.kind, "entry");
        compare(got.url, "http://host.example.com/stream.mp3");
    }

    function test_hls_media_in_m3u_clothing_is_handed_over_whole() {
        // Unwrapping HLS media would play the first SEGMENT — a few seconds
        // of audio looping forever. The backend speaks HLS; give it the
        // playlist itself.
        var body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\nseg0001.ts\n";
        var got = PL.classify(body, "http://host.example.com/live.m3u");
        compare(got.kind, "hls");
        compare(got.url, "http://host.example.com/live.m3u");
    }

    function test_empty_body_is_honest_none() {
        var got = PL.classify("", "http://host.example.com/dead.pls");
        compare(got.kind, "none");
        compare(got.url, "http://host.example.com/dead.pls");
    }

    function test_comment_only_body_is_none() {
        var got = PL.classify("#EXTM3U\n#EXTINF:-1,ghost\n", "http://h.example.com/l.m3u");
        compare(got.kind, "none");
    }

    function test_unresolvable_entry_is_none_not_garbage() {
        // A wrapper fetched from a non-http base cannot anchor a relative
        // entry — better the original url than a mangled one.
        var got = PL.classify("stream.mp3\n", "not-a-url");
        compare(got.kind, "none");
    }

    // ── isWrapper: what earns one more unwrap hop ─────────────────────────

    function test_wrapper_suffixes() {
        verify(PL.isWrapper("http://h/x.pls"));
        verify(PL.isWrapper("http://h/x.m3u"));
        verify(PL.isWrapper("http://h/x.PLS?sid=1"));
        verify(!PL.isWrapper("http://h/x.m3u8"));      // HLS is a real format
        verify(!PL.isWrapper("http://h/x.mp3"));
        verify(!PL.isWrapper(""));
    }

    function test_pls_pointing_at_m3u_is_detected_for_the_second_hop() {
        var got = PL.classify("[playlist]\nFile1=http://h.example.com/inner.m3u\n",
                              "http://h.example.com/outer.pls");
        compare(got.kind, "entry");
        verify(PL.isWrapper(got.url));
    }
}
