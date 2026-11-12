/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
// Whose answer a rebuild's answer is.
//
// One shell at a time swaps the loopbacks under a live group, and its answer
// used to be recognised by the enable it was started under and nothing else.
// Two rebuilds of the same enable carry the same number there. That matters
// once: when the first hangs past its thirty seconds, the lock is cleared
// and the next goes out while the first shell is still alive. Driven with
// stand-in commands, the late answer was adopted beside the newer one
// (module ids 201,202,301,302 for two speakers, the map knowing only the
// last pair), and in the other order it released the lock the newer rebuild
// was still holding.
//
// So every rebuild and every settle swap takes a job number of its own, and
// only the newest job's answer is the room's. What a superseded shell loaded
// before it answered is taken down again by whoever reads that answer.
.pragma library

// What a rebuild's command carries right after its tag: the enable it was
// started under, then its own number.
function stamp(gen, job) {
    return gen + " " + job;
}

// Whether `cmd` is the answer of the rebuild or swap the engine is waiting
// for. Compared as text, so a number too long for a double cannot pass for
// its neighbour, and an answer that lost either number is nobody's.
function owns(cmd, gen, job) {
    var m = /^: PW_(?:RELOOP|LBSWAP) (\d+) (\d+);/.exec(String(cmd));
    return m !== null && m[1] === String(gen) && m[2] === String(job);
}

// The shell that takes loopback modules down, quiet about the ones already
// gone. Takes ids, or the swap's records that carry one as `.id`. Anything
// that is not a plain number is left out: this text goes to sh.
function unload(mods) {
    var sh = "";
    for (var i = 0; mods && i < mods.length; i++) {
        var one = mods[i];
        var id = String(one !== null && typeof one === "object" ? one.id : one);
        if (/^\d+$/.test(id)) sh += "pactl unload-module " + id + " 2>/dev/null; ";
    }
    return sh;
}
