/*
 *  SPDX-FileCopyrightText: 2026 Egon Greenberg
 *
 *  SPDX-License-Identifier: LGPL-2.0-or-later
 */
import QtQuick

import "HealLogic.js" as HealLogic
import "HostGuard.js" as HostGuard

// The network half of finding a mount that moved to another server of its
// own CDN. What may be asked and what counts as an answer is HealLogic's
// (kinPlan, kinGuess, kinAccepts); this sends the questions, one at a time.
//
// Every question is a GET cut off at the response headers: a stream has no
// end to wait for, and the status, the type and the address Qt ended on are
// all the hunt needs. Nothing is played. No address is asked that is not on
// a public host, and an answer whose last hop Qt does not name is no answer.
QtObject {
    id: hunt

    // Has _armXhrTimeout(xhr, ms) and _clearXhrTimeout(timer), as main.qml's
    // root does. QML's own xhr.timeout does nothing.
    required property var app
    // Tests hand in a stand-in request here; null sends real ones.
    property var makeRequest: null

    // Measured 2026-11-10 against the CDN this was written for: 36 to 137 ms
    // an answer, a 404 no slower. Three seconds is a host that is not there.
    readonly property int probeTimeoutMs: 3000

    // A newer find(), or cancel(), leaves an older hunt answering nobody.
    property int _gen: 0

    function cancel() { hunt._gen++; }

    function _request() {
        return hunt.makeRequest ? hunt.makeRequest() : new XMLHttpRequest();
    }

    // One question: onDone(status, contentType, landedUrl), a turn later.
    // 0, "" and "" when the address is not public or nobody answered in
    // time. -1, "" and "" when somebody answered and Qt does not name a
    // public host as the place: that is no answer to build on, and it is
    // not silence either.
    function probe(url, onDone) {
        var xhr = null, guard = null, settled = false, status = 0, ctype = "";
        var finish = function(st, ct, landed) {
            if (settled) return;
            settled = true;
            if (guard !== null) app._clearXhrTimeout(guard);
            Qt.callLater(function() { onDone(st, ct, landed); });
        };
        var host = HostGuard.hostOf(url);
        if (host === "" || HostGuard.isPrivateHost(host)) {
            finish(0, "", "");
            return;
        }
        try {
            xhr = _request();
            xhr.open("GET", url);
            xhr.setRequestHeader("User-Agent", "OnAir/2026.44");
        } catch (e) {
            finish(0, "", "");
            return;
        }
        xhr.onreadystatechange = function() {
            var landed = "";
            if (settled) return;
            if (xhr.readyState === xhr.HEADERS_RECEIVED) {
                status = xhr.status;
                try { ctype = xhr.getResponseHeader("Content-Type") || ""; } catch (e) { ctype = ""; }
                // Not from in here: an abort inside this handler re-enters
                // the dying reply and takes the shell down (Qt 6.11). A
                // turn later it cuts the endless body just as well.
                Qt.callLater(function() { try { xhr.abort(); } catch (e) {} });
            } else if (xhr.readyState === xhr.DONE) {
                // The address was judged before the request, but Qt follows
                // redirects by itself, and responseURL is only filled from
                // here on (measured on 6.12: empty at the headers).
                if (status === 0 || !HostGuard.answerKnownPublic(xhr)) {
                    finish(status === 0 ? 0 : -1, "", "");
                    return;
                }
                try { landed = String(xhr.responseURL || ""); } catch (e) { landed = ""; }
                finish(status, ctype, landed);
            }
        };
        guard = app._armXhrTimeout(xhr, hunt.probeTimeoutMs);
        try {
            xhr.send();
        } catch (e) {
            finish(0, "", "");
        }
    }

    // The second look at an address a move is about to replace:
    // onDone("keep" | "move" | "again"), HealLogic.proofVerdict's word.
    // What is counted is looks in a row that nobody answered, kept on the
    // move itself so the count ends with it. Every look used to count: busy,
    // then rate-limited, then one timeout made three, and the station moved
    // on a single unanswered look.
    function proof(move, onDone) {
        hunt.probe(move.oldUrl, function(status, ctype) {
            move.silent = status === 0 ? (move.silent || 0) + 1 : 0;
            onDone(HealLogic.proofVerdict(status, ctype, move.silent));
        });
    }

    // Where the saved mount lives today: onDone(address), "" for nowhere.
    // The address is always on the saved station's own domain: the server
    // that answered for the mount, or a door of that domain that lands on
    // it. A door on some other domain is asked only where it lands, never
    // saved: the directory is publicly writable, and whoever owns such a
    // door can point it elsewhere tomorrow.
    function find(savedUrl, leads, onDone) {
        var my = ++hunt._gen;
        var plan = HealLogic.kinPlan(savedUrl, leads);
        var guesses = plan.guesses.slice(), doors = plan.doors.slice();
        var asked = ({});
        var step = function() {
            if (my !== hunt._gen) return;
            // kinPlan bounds the hunt: six guesses, three doors, and a door
            // can add one guess, so twelve questions at the very most. It
            // hands over each address once; the only way to meet one twice
            // is a door landing on a server already asked, and that is
            // turned away where it would join the queue.
            var guess = guesses.length > 0;
            var url = guess ? guesses.shift() : doors.length > 0 ? doors.shift() : "";
            if (url === "") {
                onDone("");
                return;
            }
            asked[url] = true;
            hunt.probe(url, function(status, ctype, landed) {
                var next = "";
                if (my !== hunt._gen) return;
                if (guess) {
                    if (HealLogic.kinAccepts(savedUrl, url, status, ctype, landed)) {
                        onDone(url);
                        return;
                    }
                } else if (HealLogic.aliveAnswer(status, ctype)) {
                    // A stranger's door that lands under the station's own
                    // roof has named a relative that is alive right now.
                    next = HealLogic.kinGuess(savedUrl, landed);
                    if (next !== "" && asked[next] !== true) guesses.unshift(next);
                }
                step();
            });
        };
        // A turn later: the callers arrive from inside a directory request's
        // own handler, and a request started in there takes the shell down
        // the same way an abort does.
        Qt.callLater(step);
    }

    // The kin rung, both passes. o holds: saved, the dead address; name and
    // cc, the listener's name for the station and its country when known;
    // own, the listener's saved rows; rows, the directory rows the rungs
    // above fetched; wide, whether the ladder would otherwise end empty;
    // ask(path, onRows), the caller's one directory request.
    // First the relatives already in hand. Only if they lead nowhere, and
    // only where nothing else is left to play, one wider question to the
    // directory for the family's doors. onDone(address), "" for nowhere.
    function search(o, onDone) {
        hunt.find(o.saved, HealLogic.kinLeads(o.saved, o.own, o.rows), function(found) {
            // A row added by hand carries no country; its own domain may.
            var cc = (o.cc || "") !== "" ? o.cc : HealLogic.tldCountry(o.saved);
            var path = found === "" && o.wide === true ? HealLogic.kinSearchPath(o.name, cc) : "";
            var my = hunt._gen;
            if (path === "") {
                onDone(found);
                return;
            }
            o.ask(path, function(rows) {
                if (my !== hunt._gen) return;
                hunt.find(o.saved, HealLogic.kinLeads(o.saved, [], rows), onDone);
            });
        });
    }
}
