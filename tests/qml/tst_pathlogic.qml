// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The download directory as people actually type it: with a tilde, with
// $HOME, with a trailing slash, and relative — which used to download fine
// and list nothing.
import QtQuick
import QtTest

import "../../package/contents/ui/PathLogic.js" as PathLogic

TestCase {
    name: "PathLogic"

    readonly property string home: "/home/egon"

    function test_absolute_paths_pass_through() {
        compare(PathLogic.absoluteDir("/data/radio", home), "/data/radio")
        compare(PathLogic.absoluteDir("  /data/radio  ", home), "/data/radio")
        compare(PathLogic.absoluteDir("/data/radio/", home), "/data/radio")
        compare(PathLogic.absoluteDir("/", home), "/")
    }

    function test_tilde_expands() {
        compare(PathLogic.absoluteDir("~", home), "/home/egon")
        compare(PathLogic.absoluteDir("~/Music/OnAir", home), "/home/egon/Music/OnAir")
    }

    function test_home_variable_expands() {
        compare(PathLogic.absoluteDir("$HOME", home), "/home/egon")
        compare(PathLogic.absoluteDir("$HOME/Music", home), "/home/egon/Music")
    }

    function test_a_relative_path_is_anchored_at_home() {
        // The bug this file exists for: the shell resolved this against its
        // working directory and downloaded happily, while "file://Music/OnAir"
        // made Qt read "Music" as a host and list an empty folder.
        compare(PathLogic.absoluteDir("Music/OnAir", home), "/home/egon/Music/OnAir")
        compare(PathLogic.absoluteDir("Music/OnAir/", home), "/home/egon/Music/OnAir")
    }

    function test_nothing_typed_means_nothing() {
        compare(PathLogic.absoluteDir("", home), "")
        compare(PathLogic.absoluteDir("   ", home), "")
        compare(PathLogic.absoluteDir(undefined, home), "")
    }

    function test_without_a_home_nothing_is_invented() {
        // A path that cannot be anchored must come back empty so the caller
        // falls through to its own default. Returning "/Music" instead would
        // point the downloads at the root of the filesystem.
        compare(PathLogic.absoluteDir("~/Music", ""), "")
        compare(PathLogic.absoluteDir("Music", ""), "")
        compare(PathLogic.absoluteDir("$HOME/Music", ""), "")
        compare(PathLogic.absoluteDir("/data/radio", ""), "/data/radio")
    }

    function test_a_trailing_slash_on_home_does_not_double_up() {
        compare(PathLogic.absoluteDir("~/Music", "/home/egon/"), "/home/egon/Music")
        compare(PathLogic.absoluteDir("Music", "/home/egon/"), "/home/egon/Music")
    }

    function test_only_a_file_url_is_a_local_path() {
        compare(PathLogic.localPath("file:///home/egon/Musiikki"), "/home/egon/Musiikki")
        // StandardPaths hands the name back decoded (measured with a
        // "Музыка и песни" music folder), so nothing is unescaped here.
        compare(PathLogic.localPath("file:///home/egon/Музыка и песни"), "/home/egon/Музыка и песни")
        compare(PathLogic.localPath("file://"), "")
        compare(PathLogic.localPath(""), "")
        compare(PathLogic.localPath(undefined), "")
        compare(PathLogic.localPath("https://example.org/x"), "")
    }

    function test_the_default_folder_lives_in_the_desktops_music_folder() {
        // The folder is not called Music on every desktop: a Finnish one
        // names it Musiikki, and that is where the downloads have always gone.
        compare(PathLogic.defaultDir("file:///home/egon/Musiikki", "/run/user/1000/Music"),
                "/home/egon/Musiikki/OnAir")
        compare(PathLogic.defaultDir("file:///home/egon/Music", "/run/user/1000/Music"),
                "/home/egon/Music/OnAir")
        // No music folder at all: the caller's own base, never the root.
        compare(PathLogic.defaultDir("", "/run/user/1000/Music"), "/run/user/1000/Music/OnAir")
        compare(PathLogic.defaultDir(undefined, "/run/user/1000/Music"), "/run/user/1000/Music/OnAir")
    }

    function test_the_hint_spells_home_as_a_tilde() {
        compare(PathLogic.shownDir("/home/egon/Musiikki/OnAir", home), "~/Musiikki/OnAir")
        compare(PathLogic.shownDir("/home/egon", home), "~")
        compare(PathLogic.shownDir("/home/egon/Music/OnAir", "/home/egon/"), "~/Music/OnAir")
        // Only a whole directory name is home: /home/egonx is somebody else.
        compare(PathLogic.shownDir("/home/egonx/Music/OnAir", home), "/home/egonx/Music/OnAir")
        compare(PathLogic.shownDir("/data/radio/OnAir", home), "/data/radio/OnAir")
        compare(PathLogic.shownDir("/home/egon/Music/OnAir", ""), "/home/egon/Music/OnAir")
    }

    // ── a path as the URL the folder model gives for it ───────────────────
    // The right-hand sides are what FolderListModel's fileUrl read for a
    // file of that name on Qt 6.12; tests/test_file_url_spelling.py asks a
    // real one again on every run.

    property url asThePlayerHoldsIt

    readonly property var spelled: [
        ["/m/Podcasts/Episode 12 [3f1c9a7e].mp3", "file:///m/Podcasts/Episode 12 %5B3f1c9a7e%5D.mp3"],
        ["/m/100% pure #42 [aaaaaaaa].mp3", "file:///m/100%25 pure %2342 %5Baaaaaaaa%5D.mp3"],
        ["/m/what? [bbbbbbbb].mp3", "file:///m/what%3F %5Bbbbbbbbb%5D.mp3"],
        ["/m/a+b & c=d; e@f, g! (h) ~i $j *k l:m 'n.mp3", "file:///m/a+b & c=d; e@f, g! (h) ~i $j *k l:m 'n.mp3"],
        ["/m/curly {x} ^caret.mp3", "file:///m/curly %7Bx%7D %5Ecaret.mp3"],
        ["/m/back\\slash pipe| quote\" lt< gt> tick`.mp3",
         "file:///m/back%5Cslash pipe%7C quote%22 lt%3C gt%3E tick%60.mp3"],
        // A percent sign that already looks like an escape is still a percent sign.
        ["/m/percent %41 %zz %5B.mp3", "file:///m/percent %2541 %25zz %255B.mp3"],
        ["/m/Äö ж 語 🎧 é.mp3", "file:///m/Äö ж 語 🎧 é.mp3"],
        ["/m/zero\u200Bwidth nb\u00A0sp bom\uFEFF c1\u0092.mp3",
         "file:///m/zero\u200Bwidth nb\u00A0sp bom\uFEFF c1\u0092.mp3"],
        ["/m/tab\there line\nfeed us\u001F del\u007F.mp3", "file:///m/tab%09here line%0Afeed us%1F del%7F.mp3"],
        ["/my [music] 100%/Podcasts/a.mp3", "file:///my %5Bmusic%5D 100%25/Podcasts/a.mp3"],
        ["/", "file:///"]
    ]

    function test_a_path_is_spelled_as_the_folder_model_spells_it() {
        for (var i = 0; i < spelled.length; i++)
            compare(PathLogic.fileUrl(spelled[i][0]), spelled[i][1])
    }

    function test_the_player_reads_the_url_back_unchanged() {
        // MediaPlayer.source is a url property. What it hands back is what
        // "is this one playing" gets compared with.
        for (var i = 0; i < spelled.length; i++) {
            asThePlayerHoldsIt = PathLogic.fileUrl(spelled[i][0])
            compare(asThePlayerHoldsIt.toString(), spelled[i][1])
        }
    }

    function test_no_path_is_no_url() {
        compare(PathLogic.fileUrl(""), "")
        compare(PathLogic.fileUrl(null), "")
        compare(PathLogic.fileUrl(undefined), "")
        // "file://" + a relative path names a host, so there is no such URL.
        compare(PathLogic.fileUrl("Music/OnAir/a.mp3"), "")
        compare(PathLogic.fileUrl("~/Music/a.mp3"), "")
    }

    function test_a_path_of_any_length_and_any_text_gets_its_url() {
        var many = ""
        var want = ""
        for (var i = 0; i < 5000; i++) { many += "[x]"; want += "%5Bx%5D" }
        compare(PathLogic.fileUrl("/m/" + many), "file:///m/" + want)
        // Half a surrogate pair is broken text, not a reason to throw.
        compare(PathLogic.fileUrl("/m/a\uD83Cb.mp3"), "file:///m/a\uD83Cb.mp3")
    }

    function test_the_hint_typed_back_lands_in_the_default_folder() {
        // Somebody who copies the hint into the field must get the folder
        // they would have had by leaving it empty.
        var dflt = PathLogic.defaultDir("file:///home/egon/Musiikki", "/run/user/1000/Music")
        compare(PathLogic.absoluteDir(PathLogic.shownDir(dflt, home), home), dflt)
    }
}
