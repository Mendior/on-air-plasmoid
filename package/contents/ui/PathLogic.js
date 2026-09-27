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

// A file:// URL from StandardPaths as a plain path, "" for anything else.
function localPath(url) {
    var s = String(url || "")
    return s.indexOf("file://") === 0 && s.length > 7 ? s.substring(7) : ""
}

// The folder downloads go to when the field is left empty.
// musicUrl: StandardPaths' MusicLocation as a string; fallback: the base to
// use when there is none. Returns an absolute path ending in /OnAir.
// The settings page used to promise ~/Music/OnAir in grey while the files
// went to the desktop's own music folder, and that is Musik, Musiikki or
// Muusika on a desktop set up in another language. Both now ask this.
function defaultDir(musicUrl, fallback) {
    var base = localPath(musicUrl)
    return (base !== "" ? base : String(fallback || "")) + "/OnAir"
}

// A path as the settings hint shows it: home spelled "~".
function shownDir(path, home) {
    var p = String(path || "")
    var h = String(home || "").replace(/\/+$/, "")
    if (h === "") return p
    if (p === h) return "~"
    return p.indexOf(h + "/") === 0 ? "~" + p.substring(h.length) : p
}
