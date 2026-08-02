/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Turning what someone typed into a settings field into a path both roads
// agree on. There are two of them and they disagree by default: the shell
// resolves a relative path against the working directory and quietly
// succeeds, while Qt reads "file://" + a relative path as a HOST plus a path
// (measured: "Music/OnAir" becomes host "music", path "/OnAir"). So the
// downloads land somewhere real and the library page that lists them stays
// empty, with nothing on screen to explain why.
.pragma library

// An absolute directory, or "" when there is nothing usable to anchor to.
// home is the expanded home directory, "" if even that could not be resolved.
function absoluteDir(conf, home) {
    var s = String(conf || "").trim()
    var h = String(home || "").replace(/\/+$/, "")
    if (s === "") return ""

    // The settings placeholder suggests "~/Music/...", so the tilde is the
    // form people actually type. Without expansion the download lands in a
    // directory literally named "~".
    if (s === "~") return h
    if (s.indexOf("~/") === 0) return h === "" ? "" : h + s.substring(1)

    // $HOME reads as a path to a person and as a variable to nobody here —
    // these strings never reach a shell unquoted, so it would stay literal.
    if (s === "$HOME") return h
    if (s.indexOf("$HOME/") === 0) return h === "" ? "" : h + s.substring(5)

    if (s.charAt(0) === "/") return s.replace(/\/+$/, "") || "/"

    // Still relative. Anchor it where the shell would have: plasmashell runs
    // from the home directory, so this keeps the two roads pointing at the
    // same place instead of only one of them working.
    return h === "" ? "" : h + "/" + s.replace(/\/+$/, "")
}
