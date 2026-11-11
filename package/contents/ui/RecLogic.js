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

// How long after the end of its window a scheduled capture may still be
// running before the schedule tick stops it. A healthy one has left by
// then, also one that was slow to connect: it runs its own length and ends
// as late as it began, and 141 s to connect has been measured. A machine
// that slept through the window is hours late, not minutes.
var OVERRUN_GRACE_MS = 300000

// Whether a scheduled capture has outlived its window, by the wall clock.
// Nothing else that bounds a capture reads it. The shell's timeout is a
// relative one, ffmpeg's -t counts seconds of audio and the elapsed
// counter counts timer ticks, and all three stand still while the machine
// sleeps. A window that cannot be read (no end, no clock) stops nothing.
function captureOverran(nowMs, windowEndMs, graceMs) {
    var grace = graceMs === undefined ? OVERRUN_GRACE_MS : graceMs
    if (typeof nowMs !== "number" || typeof windowEndMs !== "number" || !(windowEndMs > 0))
        return false
    return nowMs - windowEndMs > grace
}

// Whether a finished capture with nothing on disk needs no word said. The
// listener asked for the stop, so nothing on disk is what was asked for;
// it used to read "Recording failed". The schedule tick's own stop, of a
// capture past its window, is nobody's wish: a programme that left nothing
// behind has to be heard of. Anything but a plain true or false counts as
// not known, and then the word is said.
function calledOff(stopAsked, overran, onDisk) {
    return stopAsked === true && overran === false && onDisk === false
}

// What the capture's own shell says the file holds, in whole seconds: the
// " secs=N" after the size, which it reads off the finished file with
// ffprobe. NaN when the shell could not say: no ffprobe on the machine, a
// container that does not know its own length (measured: a FLAC copied
// from a pipe answers N/A), or an answer of another shape.
function mediaSeconds(answer) {
    var text = (answer === null || answer === undefined) ? "" : String(answer)
    var m = /__REC_DONE__ rc=-?\d+ bytes=\d+ secs=(\d{1,9})(?=\s|$)/.exec(text)
    return m ? parseInt(m[1], 10) : NaN
}

function _counts(sec) {
    return typeof sec === "number" && isFinite(sec) && sec >= 0
}

// The seconds of audio a finished capture is taken to hold: what the file
// says when it could be asked, otherwise the time since it appeared.
function heardSeconds(mediaSec, clockSec) {
    return _counts(mediaSec) ? mediaSec : clockSec
}

// How far below its asked length a capture may end and still be whole: a
// tenth, and never less than the witness can be wrong by. The file's own
// length is exact for MP3, Opus and Matroska and an estimate for raw AAC
// (measured 295.4 s for 300.0). The clock since the file appeared runs
// behind the audio by what the server sent in its first burst: the bench
// counter read 0:53 over a 58.3 s file.
var SHORT_SHARE = 0.1
var MEDIA_SLACK_SEC = 10
var CLOCK_SLACK_SEC = 60

// Whether a capture whose time ran out holds far less than was asked for.
// The wall clock alone cannot tell: measured, a station that sent ten
// seconds and then held the socket silent kept a one-minute capture going
// for its whole six-minute cap, and the answer was rc=0 with ten seconds
// in the file. mediaSec is the file's own word and is believed first;
// clockSec, the time since the file appeared, only when the file has none
// (pass NaN for a file that was never seen). With neither, or with no
// asked length to compare with, nothing is called short.
function fallsShort(wantedSec, mediaSec, clockSec) {
    if (!_counts(wantedSec) || wantedSec === 0) return false
    if (_counts(mediaSec))
        return mediaSec < wantedSec - Math.max(MEDIA_SLACK_SEC, wantedSec * SHORT_SHARE)
    if (_counts(clockSec))
        return clockSec < wantedSec - Math.max(CLOCK_SLACK_SEC, wantedSec * SHORT_SHARE)
    return false
}

// HLS/playlist wrappers don't survive a plain "-c copy"; anything that
// is not an http(s) stream (local files, odd schemes) can't be recorded.
function canRecordUrl(url) {
    var s = (url || "").toString();
    if (!/^https?:\/\//i.test(s)) return false;
    var fmt = StreamLogic.streamFormat(s);
    return fmt !== "hls" && fmt !== "playlist";
}

// The minutes typed into the "Max length" box, read back from the box's own
// text. The box shows "180 min", and from a thousand up KDE writes the number
// grouped: "1,440 min" in English, "1 440 min" in Finnish (measured with
// KI18n). parseInt read both as 1. So every digit counts, whatever stands
// between them, and the unit after them is ignored. A text without a digit
// is `fallback`. Past six digits the rest is dropped; the box has its own
// ceiling to hold the answer to.
function typedMinutes(text, fallback) {
    var digits = (text === null || text === undefined) ? "" : String(text).replace(/\D/g, "");
    if (digits === "") return fallback;
    return parseInt(digits.substring(0, 6), 10);
}
