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

    function test_the_hint_typed_back_lands_in_the_default_folder() {
        // Somebody who copies the hint into the field must get the folder
        // they would have had by leaving it empty.
        var dflt = PathLogic.defaultDir("file:///home/egon/Musiikki", "/run/user/1000/Music")
        compare(PathLogic.absoluteDir(PathLogic.shownDir(dflt, home), home), dflt)
    }
}
