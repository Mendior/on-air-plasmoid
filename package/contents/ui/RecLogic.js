/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// The recorder's small judgments: what a station may be called on disk,
// how elapsed time reads on the button, and whether a URL can be recorded
// at all. The name sanitizer is the security-sensitive one — its output
// rides into a shell command and a file path.
.pragma library
.import "StreamLogic.js" as StreamLogic

function _pad2(n) { return ("0" + n).slice(-2); }

// Station names come from an external catalogue — make them file-name safe
// (and quote-free, so they are also shell-safe after the dir escaping).
function sanitizeStationName(name) {
    var s = (name || "").replace(/[\/\\:*?"<>|'\t\r\n]/g, "-").replace(/\s+/g, " ").trim();
    if (s.length > 60) s = s.substring(0, 60).trim();
    return s || "Radio";
}

function elapsedText(seconds) {
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    var s = seconds % 60;
    return (h > 0 ? h + ":" + _pad2(m) : m) + ":" + _pad2(s);
}

// HLS/playlist wrappers don't survive a plain "-c copy"; anything that
// is not an http(s) stream (local files, odd schemes) can't be recorded.
function canRecordUrl(url) {
    var s = (url || "").toString();
    if (!/^https?:\/\//i.test(s)) return false;
    var fmt = StreamLogic.streamFormat(s);
    return fmt !== "hls" && fmt !== "playlist";
}
