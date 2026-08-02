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
}
