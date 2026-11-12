// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// CastLogic: who was asked to play, who answered, and whether anything
// carries the stream.
import QtQuick
import QtTest

import "../../package/contents/ui/CastLogic.js" as CL

TestCase {
    name: "CastLogic"

    readonly property string script: ": CAST_PLAY; python3 '/usr/share/x/cast.py'"
    readonly property var targets: [
        { "uuid": "cc-1", "kind": "cast", "host": "192.168.1.20", "port": 8009 },
        { "uuid": "uuid:ruark-r5", "kind": "dlna", "location": "http://192.168.1.30:8080/desc.xml" },
        { "uuid": "uuid:odd", "kind": "dlna", "location": "http://192.168.1.31/it's here/desc.xml" }
    ]

    function chromecast(uuid, seq) {
        return script + " 'play' '192.168.1.20' '8009' '" + uuid + "' 'Chromecast' 'http://s.example/live' 'audio/mpeg' 'Name' '' '' # " + seq;
    }
    function dlna(location, seq) {
        return script + " 'dlna-play' '" + location.replace(/'/g, "'\\''") + "' 'http://s.example/live' 'audio/mpeg' 'Name' '' # " + seq;
    }

    function test_a_command_names_its_number() {
        compare(CL.seqOf(chromecast("cc-1", 41)), 41);
        compare(CL.seqOf(dlna("http://192.168.1.30:8080/desc.xml", 0)), 0);
        compare(CL.seqOf(script + " 'play' 'a' 'b' 'c'"), -1);
        compare(CL.seqOf(script + " # 12 '"), -1);
        compare(CL.seqOf(""), -1);
        compare(CL.seqOf(undefined), -1);
        compare(CL.seqOf(null), -1);
        compare(CL.seqOf(7), -1);
        compare(CL.seqOf("# 99999999"), 99999999);
    }

    function test_a_play_command_names_its_device() {
        compare(CL.who(chromecast("cc-1", 1), targets), "cc-1");
        // A renderer is named by its address in the command, and found by it.
        compare(CL.who(dlna("http://192.168.1.30:8080/desc.xml", 2), targets), "uuid:ruark-r5");
        // A quote in the address was escaped on the way out and comes back.
        compare(CL.who(dlna("http://192.168.1.31/it's here/desc.xml", 3), targets), "uuid:odd");
        // A Chromecast is named whether it is still selected or not: the
        // record decides what its answer is worth.
        compare(CL.who(chromecast("cc-gone", 4), targets), "cc-gone");
        // A renderer that is no longer selected has no name to give.
        compare(CL.who(dlna("http://192.168.1.99/desc.xml", 5), targets), "");
        compare(CL.who(dlna("http://192.168.1.30:8080/desc.xml", 5), []), "");
    }

    function test_what_is_no_play_command_names_nobody() {
        compare(CL.who(": CAST_STOP; python3 'x' 'stop' 'h' 'p' 'cc-1' 'm' # 3", targets), "");
        compare(CL.who(": CAST_VOL; python3 'x' 'volume' 'h' 'p' 'cc-1' 'm' '0.5' # 3", targets), "");
        // Whatever its arguments look like, only a play command is one.
        compare(CL.who(": CAST_VOL; python3 'x' 'play' 'h' '8009' 'cc-1' 'm' # 3", targets), "");
        compare(CL.who(" : CAST_PLAY; python3 'x' 'play' 'h' '8009' 'cc-1' 'm' # 3", targets), "");
        compare(CL.who("echo : CAST_PLAY; 'dlna-play' 'http://192.168.1.30:8080/desc.xml' # 3", targets), "");
        compare(CL.who("", targets), "");
        compare(CL.who(undefined, targets), "");
        compare(CL.who(null, null), "");
        compare(CL.who(7, targets), "");
        compare(CL.who(chromecast("cc-1", 1), undefined), "cc-1");
        compare(CL.who(dlna("http://192.168.1.30:8080/desc.xml", 2), "not a list"), "");
        compare(CL.who(dlna("http://192.168.1.30:8080/desc.xml", 2), [null, 7, {}]), "");
        // A command as long as a command may get.
        var longName = new Array(5000).join("n");
        compare(CL.who(script + " 'play' 'h' '8009' 'cc-1' 'm' 'http://s.example/" + longName + "' # 9", targets), "cc-1");
    }

    function test_a_device_that_was_asked_is_pending_until_it_answers() {
        var s = CL.fresh();
        verify(!CL.carried(s));
        var s1 = CL.tried(s, "cc-1", 10);
        compare(s1.pending["cc-1"], 10);
        verify(CL.carried(s1), "a device still being asked is not counted");
        // The record handed in is not changed.
        compare(Object.keys(s.pending).length, 0);
        // Asked again: the newer command is the one waited for, and a device
        // that played is being asked anew, so it is not on meanwhile.
        var on = CL.answered(s1, "cc-1", 10, true).session;
        verify(on.on["cc-1"] === true);
        var again = CL.tried(on, "cc-1", 12);
        compare(again.pending["cc-1"], 12);
        verify(again.on["cc-1"] !== true);
        // What is no device or no number changes nothing.
        compare(CL.tried(s1, "", 11), s1);
        compare(CL.tried(s1, null, 11), s1);
        compare(CL.tried(s1, "cc-2", -1), s1);
        compare(CL.tried(s1, "cc-2", NaN), s1);
        compare(CL.tried(s1, "cc-2", "11"), s1);
        compare(CL.tried(s1, "cc-2", undefined), s1);
    }

    function test_the_only_device_refusing_leaves_nothing_carrying_the_stream() {
        // The Ruark case: one device, asked, answers no.
        var s = CL.tried(CL.fresh(), "uuid:ruark-r5", 7);
        var a = CL.answered(s, "uuid:ruark-r5", 7, false);
        compare(a.stale, false);
        compare(a.carried, false);
        verify(!CL.carried(a.session));
        compare(Object.keys(a.session.pending).length, 0);
        compare(Object.keys(a.session.on).length, 0);
        // It says yes: it carries the stream.
        var b = CL.answered(s, "uuid:ruark-r5", 7, true);
        compare(b.stale, false);
        compare(b.carried, true);
        verify(b.session.on["uuid:ruark-r5"] === true);
        // An answer that is not exactly yes is a no.
        compare(CL.answered(s, "uuid:ruark-r5", 7, "true").carried, false);
        compare(CL.answered(s, "uuid:ruark-r5", 7, 1).carried, false);
        compare(CL.answered(s, "uuid:ruark-r5", 7, undefined).carried, false);
    }

    function test_one_of_two_refusing_leaves_the_other_playing() {
        var s = CL.tried(CL.tried(CL.fresh(), "cc-1", 20), "uuid:ruark-r5", 21);
        // The refusal first, while the other is still being asked.
        var a = CL.answered(s, "uuid:ruark-r5", 21, false);
        compare(a.carried, true);
        var b = CL.answered(a.session, "cc-1", 20, true);
        compare(b.carried, true);
        // The other way round.
        var c = CL.answered(s, "cc-1", 20, true);
        var d = CL.answered(c.session, "uuid:ruark-r5", 21, false);
        compare(d.carried, true);
        verify(d.session.on["cc-1"] === true);
        // Both refuse: nothing.
        var e = CL.answered(CL.answered(s, "cc-1", 20, false).session, "uuid:ruark-r5", 21, false);
        compare(e.carried, false);
    }

    function test_a_late_answer_of_an_older_attempt_changes_nothing() {
        // Asked (seq 30), asked again for another station (seq 31), the new
        // one plays; then the old refusal comes home.
        var s = CL.tried(CL.tried(CL.fresh(), "cc-1", 30), "cc-1", 31);
        var playing = CL.answered(s, "cc-1", 31, true).session;
        var late = CL.answered(playing, "cc-1", 30, false);
        compare(late.stale, true);
        compare(late.carried, true);
        compare(late.session, playing);
        // The old yes after the new no does not bring it back either.
        var refused = CL.answered(s, "cc-1", 31, false).session;
        var lateYes = CL.answered(refused, "cc-1", 30, true);
        compare(lateYes.stale, true);
        compare(lateYes.carried, false);
        // The older refusal comes home FIRST, while the newer attempt is
        // still being asked: it is the older one's, and the newer goes on.
        var early = CL.answered(s, "cc-1", 30, false);
        compare(early.stale, true);
        compare(early.carried, true);
        compare(early.session.pending["cc-1"], 31);
        compare(CL.answered(s, "cc-1", 30, true).session.on["cc-1"], undefined);
        // An answer for a device nobody asked, and one that was unticked.
        compare(CL.answered(playing, "cc-9", 31, false).stale, true);
        var gone = CL.left(s, "cc-1");
        compare(CL.answered(gone, "cc-1", 31, true).stale, true);
        compare(CL.answered(gone, "cc-1", 31, true).carried, false);
        // The same answer twice: the second finds nobody waiting.
        compare(CL.answered(playing, "cc-1", 31, true).stale, true);
    }

    function test_a_device_that_leaves_takes_its_part_with_it() {
        var s = CL.tried(CL.tried(CL.fresh(), "cc-1", 40), "uuid:ruark-r5", 41);
        var both = CL.answered(CL.answered(s, "cc-1", 40, true).session, "uuid:ruark-r5", 41, true).session;
        var one = CL.left(both, "cc-1");
        verify(CL.carried(one));
        verify(one.on["cc-1"] !== true);
        verify(!CL.carried(CL.left(one, "uuid:ruark-r5")));
        // A device still pending leaves: its answer will find nobody.
        var pend = CL.left(s, "uuid:ruark-r5");
        compare(pend.pending["uuid:ruark-r5"], undefined);
        compare(pend.pending["cc-1"], 40);
        // Leaving twice, and nobody leaving, change nothing.
        compare(CL.left(one, "cc-1"), one);
        compare(CL.left(both, ""), both);
        compare(CL.left(both, undefined), both);
        // The record handed in is not changed.
        verify(both.on["cc-1"] === true);
    }

    function test_the_picture_is_the_first_thing_known_that_a_device_can_fetch_data() {
        var ep = "https://pod.example/show.jpg", al = "https://covers.example/album.jpg", lo = "http://radio.example/logo.png";
        var side = "file:///home/me/Music/.covers/song.jpg";
        return [
            { tag: "an episode outranks the rest", a: [ep, al, lo], want: ep },
            { tag: "a cover outranks the logo", a: ["", al, lo], want: al },
            { tag: "the logo when nothing else is known", a: ["", "", lo], want: lo },
            { tag: "nothing known", a: ["", "", ""], want: "" },
            { tag: "nothing handed in", a: [], want: "" },
            // The road that sent no picture: the first candidate is one the
            // device cannot fetch, and the choice ended there.
            { tag: "a sidecar cover before a logo", a: ["", side, lo], want: lo },
            { tag: "a path for an episode", a: ["/var/lib/show.jpg", al, lo], want: al },
            { tag: "two unusable, then the logo", a: ["data:image/png;base64,AAAA", "ftp://x.example/a.jpg", lo], want: lo },
            { tag: "three unusable", a: [side, "covers/a.jpg", "image-missing"], want: "" },
            { tag: "the scheme in capitals", a: ["", "HTTPS://Covers.Example/A.JPG", lo], want: "HTTPS://Covers.Example/A.JPG" },
            { tag: "a scheme and nothing behind it", a: ["http:", "https://", lo], want: lo },
            { tag: "a scheme and a slash too many", a: ["https:///a.jpg", "", lo], want: lo },
            { tag: "no scheme, two slashes", a: ["//covers.example/a.jpg", "", lo], want: lo },
            { tag: "a longer scheme that starts alike", a: ["httpx://a.example/a.jpg", "https-ish", lo], want: lo },
            { tag: "a space in front", a: [" https://covers.example/a.jpg", "", lo], want: lo },
            { tag: "http inside, not in front", a: ["see http://covers.example/a.jpg", "", ""], want: "" },
            { tag: "things that are no text", a: [null, undefined, lo], want: lo },
            { tag: "more things that are no text", a: [7, { url: al }, [al]], want: "" },
            { tag: "true and a number", a: [true, 0, ""], want: "" }
        ];
    }
    function test_the_picture_is_the_first_thing_known_that_a_device_can_fetch(data) {
        compare(CL.picture(data.a[0], data.a[1], data.a[2]), data.want);
    }

    function test_a_picture_goes_out_as_it_was_given() {
        var odd = "https://covers.example/a b/%7Ealbum.jpg?size=600&x=\"1\"#top";
        compare(CL.picture("", odd, ""), odd);
        var big = "https://covers.example/" + new Array(100001).join("a") + ".jpg";
        compare(CL.picture("", "", big), big);
    }

    // ── what an answer says ──────────────────────────────────────────────

    function test_what_an_answer_says_data() {
        var fail = "__CAST_FAIL__ ";
        return [
            { tag: "the Ruark's refusal, as recorded", out: fail + "upnp=716 action=SetAVTransportURI http=500 Resource not found\n",
              kind: "refused", log: "SetAVTransportURI refused, UPnP 716" },
            { tag: "a refusal at Play", out: fail + "upnp=716 action=Play http=500 Resource not found\n",
              kind: "refused", log: "Play refused, UPnP 716" },
            { tag: "a type the device does not take", out: fail + "upnp=714 action=SetAVTransportURI http=500 Illegal MIME-type\n",
              kind: "refused", log: "SetAVTransportURI refused, UPnP 714" },
            { tag: "702", out: fail + "upnp=702 action=Play http=500\n", kind: "refused", log: "Play refused, UPnP 702" },
            { tag: "703", out: fail + "upnp=703 action=Play http=500\n", kind: "refused", log: "Play refused, UPnP 703" },
            { tag: "704", out: fail + "upnp=704 action=Play http=500\n", kind: "refused", log: "Play refused, UPnP 704" },
            { tag: "715", out: fail + "upnp=715 action=SetAVTransportURI http=500\n", kind: "refused", log: "SetAVTransportURI refused, UPnP 715" },
            // The neighbours of those codes are about the device, not the address.
            { tag: "701, a state the device is in", out: fail + "upnp=701 action=Play http=500 Transition not available\n",
              kind: "other", log: "Play failed, HTTP 500, UPnP 701" },
            { tag: "705, a locked transport", out: fail + "upnp=705 action=Play http=500 Transport is locked\n",
              kind: "other", log: "Play failed, HTTP 500, UPnP 705" },
            { tag: "713", out: fail + "upnp=713 action=Play http=500\n", kind: "other", log: "Play failed, HTTP 500, UPnP 713" },
            { tag: "717", out: fail + "upnp=717 action=Play http=500\n", kind: "other", log: "Play failed, HTTP 500, UPnP 717" },
            { tag: "718", out: fail + "upnp=718 action=SetAVTransportURI http=500\n", kind: "other", log: "SetAVTransportURI failed, HTTP 500, UPnP 718" },
            { tag: "402, the command's arguments", out: fail + "upnp=402 action=SetAVTransportURI http=500 Invalid Args\n",
              kind: "other", log: "SetAVTransportURI failed, HTTP 500, UPnP 402" },
            { tag: "501", out: fail + "upnp=501 action=Play http=500 Action Failed\n", kind: "other", log: "Play failed, HTTP 500, UPnP 501" },
            // 716 in answer to something that is no play says nothing about a stream.
            { tag: "716 to a Stop", out: fail + "upnp=716 action=Stop http=500\n", kind: "other", log: "Stop failed, HTTP 500, UPnP 716" },
            { tag: "716 to a level", out: fail + "upnp=716 action=SetVolume http=500\n", kind: "other", log: "SetVolume failed, HTTP 500, UPnP 716" },
            { tag: "716 and no action", out: fail + "upnp=716 http=500\n", kind: "other", log: "failed, HTTP 500, UPnP 716" },
            { tag: "a code that only looks like 716", out: fail + "upnp=0716 action=Play http=500\n", kind: "other", log: "Play failed, HTTP 500, UPnP 0716" },
            { tag: "7160", out: fail + "upnp=7160 action=Play http=500\n", kind: "other", log: "Play failed, HTTP 500, UPnP 7160" },
            { tag: "a status and no code", out: fail + "action=SetAVTransportURI http=404\n", kind: "other", log: "SetAVTransportURI failed, HTTP 404" },
            { tag: "a status, no code, words", out: fail + "action=Play http=500 Resource not found\n", kind: "other", log: "Play failed, HTTP 500" },
            // No answer at all.
            { tag: "a timeout", out: fail + "reach=timeout action=SetAVTransportURI\n", kind: "unreachable", log: "SetAVTransportURI got no answer, timeout" },
            { tag: "a refused connection", out: fail + "reach=refused action=connect\n", kind: "unreachable", log: "connect got no answer, refused" },
            { tag: "no description", out: fail + "reach=nodesc renderer description unavailable\n", kind: "unreachable", log: "no answer, nodesc" },
            { tag: "the helper's own time limit", out: fail + "reach=timeout helper timed out\n", kind: "unreachable", log: "no answer, timeout" },
            { tag: "a kind of silence nobody named yet", out: fail + "reach=asleep action=Play\n", kind: "unreachable", log: "Play got no answer, asleep" },
            // A Cast receiver's word on a load. No television has been watched refusing a stream
            // yet, so it is written down and nothing is built on it.
            { tag: "a receiver that could not load it", out: fail + "load=104 action=play the receiver could not load the stream\n",
              kind: "other", log: "play failed, load error 104" },
            { tag: "a failed load without a code", out: fail + "action=play the receiver could not load the stream\n", kind: "other", log: "play failed" },
            { tag: "a load code of five digits", out: fail + "load=12345 action=play\n", kind: "other", log: "play failed" },
            { tag: "a load code that is no number", out: fail + "load=x action=play\n", kind: "other", log: "play failed" },
            { tag: "a load code and nothing else", out: fail + "load=905\n", kind: "other", log: "failed, load error 905" },
            // A line of before the fields, and what is no line.
            { tag: "the old line", out: fail + "HTTP Error 500: <s:Envelope\n", kind: "other", log: "failed, no reason named" },
            { tag: "a Chromecast that did not take it", out: fail + "the device did not take the stream within 12s\n",
              kind: "other", log: "failed, no reason named" },
            { tag: "the sentinel alone", out: "__CAST_FAIL__\n", kind: "other", log: "failed, no reason named" },
            { tag: "the sentinel and a space", out: "__CAST_FAIL__ ", kind: "other", log: "failed, no reason named" },
            { tag: "nothing", out: "", kind: "other", log: "failed, no reason named" },
            { tag: "undefined", out: undefined, kind: "other", log: "failed, no reason named" },
            { tag: "null", out: null, kind: "other", log: "failed, no reason named" },
            { tag: "a number", out: 716, kind: "other", log: "failed, no reason named" },
            { tag: "an object", out: { "upnp": 716 }, kind: "other", log: "failed, no reason named" },
            // Fields are read in front of the words and nowhere else.
            { tag: "fields after words", out: fail + "sorry upnp=716 action=Play http=500\n", kind: "other", log: "failed, no reason named" },
            { tag: "words that hold a field", out: fail + "action=Play http=500 said upnp=716\n", kind: "other", log: "Play failed, HTTP 500" },
            { tag: "the sentinel inside a line", out: "x __CAST_FAIL__ upnp=716 action=Play http=500\n", kind: "other", log: "failed, no reason named" },
            { tag: "a field name in capitals", out: fail + "UPNP=716 action=Play http=500\n", kind: "other", log: "failed, no reason named" },
            { tag: "a field nobody knows", out: fail + "secret=1 upnp=716 action=Play http=500\n", kind: "other", log: "failed, no reason named" },
            { tag: "a code that is no number", out: fail + "upnp=abc action=Play http=500\n", kind: "other", log: "Play failed, HTTP 500" },
            { tag: "a code of nothing", out: fail + "upnp= action=Play http=500\n", kind: "other", log: "failed, no reason named" },
            { tag: "an action that is none", out: fail + "upnp=716 action=Play;rm http=500\n", kind: "other", log: "failed, UPnP 716" },
            { tag: "an address for an action", out: fail + "upnp=716 action=http://s.example/live http=500\n", kind: "other", log: "failed, UPnP 716" },
            { tag: "a status that is none", out: fail + "action=Play http=5xx\n", kind: "other", log: "Play failed" },
            { tag: "an action with marks in it", out: fail + "action=Set_AV-1.0 http=500\n", kind: "other", log: "failed, HTTP 500" },
            { tag: "a kind of silence in capitals", out: fail + "reach=TIMEOUT action=Play\n", kind: "other", log: "Play failed" },
            { tag: "a kind of silence with a dot", out: fail + "reach=time.out action=Play\n", kind: "other", log: "Play failed" },
            { tag: "a kind of silence with marks in it", out: fail + "reach=time/out action=Play\n", kind: "other", log: "failed, no reason named" },
            { tag: "tabs for spaces", out: "__CAST_FAIL__\tupnp=716\taction=Play\n", kind: "other", log: "failed, no reason named" },
            // The first failure line counts; what stands on other lines does not make it another.
            { tag: "two lines", out: fail + "reach=timeout action=Play\n" + fail + "upnp=716 action=Play http=500\n",
              kind: "unreachable", log: "Play got no answer, timeout" },
            { tag: "a line in front", out: "DEV\tx\n" + fail + "upnp=716 action=Play http=500\n", kind: "refused", log: "Play refused, UPnP 716" },
            { tag: "a carriage return at the end", out: fail + "upnp=716 action=Play http=500\r\n", kind: "refused", log: "Play refused, UPnP 716" },
            { tag: "a carriage return after the last field", out: fail + "upnp=716 action=Play\r\n", kind: "refused", log: "Play refused, UPnP 716" },
            { tag: "no line end", out: fail + "upnp=716 action=SetAVTransportURI http=500", kind: "refused", log: "SetAVTransportURI refused, UPnP 716" },
            { tag: "both a refusal and a silence", out: fail + "reach=timeout upnp=716 action=Play http=500\n",
              kind: "refused", log: "Play refused, UPnP 716" },
            // What was asked for and taken.
            { tag: "taken", out: "__CAST_OK__\n", kind: "ok", log: "" },
            { tag: "taken, said after a failure line", out: fail + "upnp=716 action=Play http=500\n__CAST_OK__\n", kind: "ok", log: "" },
            { tag: "the library is missing", out: "__NO_PYCHROMECAST__\n", kind: "nolib", log: "" },
            { tag: "taken wins over a missing library", out: "__NO_PYCHROMECAST__\n__CAST_OK__\n", kind: "ok", log: "" },
            { tag: "a missing library wins over a failure", out: fail + "reach=timeout\n__NO_PYCHROMECAST__\n", kind: "nolib", log: "" }
        ];
    }
    function test_what_an_answer_says(data) {
        var v = CL.verdict(data.out);
        compare(v.kind, data.kind);
        compare(v.log, data.log);
    }

    function test_the_address_is_never_in_what_is_written_down() {
        var address = "http://radio.example:9000/live/320b?token=LISTENER-TOKEN-7731";
        var lines = [
            "__CAST_FAIL__ upnp=716 action=SetAVTransportURI http=500 " + address + "\n",
            "__CAST_FAIL__ " + address + "\n",
            "__CAST_FAIL__ action=Play http=500 could not open " + address + "\n",
            "__CAST_FAIL__ reach=timeout action=Play " + address + "\n",
            "__CAST_FAIL__ upnp=716 action=" + address + " http=500\n",
            "__CAST_FAIL__ reach=" + address + "\n",
            "__CAST_FAIL__ upnp=" + address + "\n"
        ];
        for (var i = 0; i < lines.length; i++) {
            var log = CL.verdict(lines[i]).log;
            verify(log.indexOf("radio.example") === -1 && log.indexOf("TOKEN") === -1 && log.indexOf("320b") === -1, lines[i] + " -> " + log);
            verify(log.length < 60, log);
        }
    }

    function test_an_answer_of_any_length_is_read() {
        var words = new Array(200001).join("w ");
        compare(CL.verdict("__CAST_FAIL__ upnp=716 action=Play http=500 " + words).kind, "refused");
        var fields = new Array(20001).join("upnp=716 ");
        compare(CL.verdict("__CAST_FAIL__ " + fields + "action=Play http=500").kind, "refused");
        var lines = new Array(20001).join("noise\n");
        compare(CL.verdict(lines + "__CAST_FAIL__ reach=down action=connect\n" + lines).log, "connect got no answer, down");
    }

    // ── who is named ─────────────────────────────────────────────────────

    readonly property var tv: ({ "uuid": "cc-1", "name": "Living room TV" })
    readonly property var ruark: ({ "uuid": "uuid:ruark-r5", "name": "Ruark R5se" })
    readonly property var nest: ({ "uuid": "cc-2", "name": "Kitchen" })

    function names(session, list) {
        return CL.carriers(session, list).map(function (d) { return d.name; });
    }

    function test_only_the_devices_that_carry_the_stream_are_named() {
        var asked = CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "uuid:ruark-r5", 2);
        // Both are being asked: both are named until they answer.
        compare(names(asked, [tv, ruark]), ["Living room TV", "Ruark R5se"]);
        // The television plays and the Ruark refused: one name, not "2 devices".
        var one = CL.answered(CL.answered(asked, "cc-1", 1, true).session, "uuid:ruark-r5", 2, false).session;
        compare(names(one, [tv, ruark]), ["Living room TV"]);
        compare(names(one, [ruark, tv]), ["Living room TV"]);
        // The other way round, and both, in the order they are listed in.
        var other = CL.answered(CL.answered(asked, "cc-1", 1, false).session, "uuid:ruark-r5", 2, true).session;
        compare(names(other, [tv, ruark]), ["Ruark R5se"]);
        var both = CL.answered(CL.answered(asked, "cc-1", 1, true).session, "uuid:ruark-r5", 2, true).session;
        compare(names(both, [ruark, tv]), ["Ruark R5se", "Living room TV"]);
        // Everybody refused, and a device that is ticked while nothing plays.
        var none = CL.answered(CL.answered(asked, "cc-1", 1, false).session, "uuid:ruark-r5", 2, false).session;
        compare(names(none, [tv, ruark]), []);
        compare(names(CL.fresh(), [tv, ruark]), []);
        // The entry itself is handed back, not a copy of it.
        verify(CL.carriers(one, [tv, ruark])[0] === tv);
        // A device that left is not named, whatever it did before.
        compare(names(CL.left(both, "cc-1"), [tv, ruark]), ["Ruark R5se"]);
        // One that plays and is not among the selected has no entry to name.
        compare(names(both, [nest]), []);
    }

    function test_who_is_named_when_what_is_handed_in_is_odd() {
        var both = CL.answered(CL.answered(CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "cc-2", 2), "cc-1", 1, true).session, "cc-2", 2, true).session;
        compare(CL.carriers(both, undefined), []);
        compare(CL.carriers(both, null), []);
        compare(CL.carriers(both, "cc-1"), []);
        compare(CL.carriers(both, { "0": tv }), []);
        compare(CL.carriers(both, []), []);
        compare(names(both, [null, 7, "cc-1", {}, { "uuid": 7 }, { "uuid": "" }, [tv], tv]), ["Living room TV"]);
        compare(CL.carriers(undefined, [tv]), []);
        compare(CL.carriers({ "on": "cc-1" }, [tv]), []);
        // A uuid is text: a number that happens to spell one names nobody.
        var seven = CL.answered(CL.tried(CL.fresh(), "7", 1), "7", 1, true).session;
        compare(CL.carriers(seven, [{ "uuid": 7, "name": "a number" }]), []);
        compare(names(seven, [{ "uuid": "7", "name": "text" }]), ["text"]);
        compare(CL.carriers(CL.tried(CL.fresh(), "7", 1), [{ "uuid": 7, "name": "a number" }]), []);
        // The same device listed twice is named twice: the list is the caller's.
        compare(names(both, [tv, tv]).length, 2);
        var many = [], s = CL.fresh();
        for (var i = 0; i < 400; i++) { many.push({ "uuid": "d" + i, "name": "n" + i }); s = CL.tried(s, "d" + i, i); }
        compare(CL.carriers(s, many).length, 400);
        for (i = 0; i < 400; i++) s = CL.answered(s, "d" + i, i, i % 100 === 0).session;
        compare(names(s, many), ["n0", "n100", "n200", "n300"]);
    }

    // ── a device that refused keeps its mark ─────────────────────────────

    function test_a_device_that_refused_is_marked_until_it_is_asked_again_or_leaves() {
        var asked = CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "uuid:ruark-r5", 2);
        verify(!CL.refusedBy(asked, "uuid:ruark-r5"));
        var no = CL.answered(asked, "uuid:ruark-r5", 2, false, "refused").session;
        verify(CL.refusedBy(no, "uuid:ruark-r5"));
        verify(!CL.refusedBy(no, "cc-1"), "the device beside it is marked too");
        // The other one playing, or failing in another way, does not touch the mark.
        var both = CL.answered(no, "cc-1", 1, true, "ok").session;
        verify(CL.refusedBy(both, "uuid:ruark-r5") && !CL.refusedBy(both, "cc-1"));
        // The record handed in is not changed.
        verify(!CL.refusedBy(asked, "uuid:ruark-r5"));
        // Asked again: the mark is down while it is asked, and its next answer decides anew.
        var again = CL.tried(both, "uuid:ruark-r5", 3);
        verify(!CL.refusedBy(again, "uuid:ruark-r5"));
        verify(!CL.refusedBy(CL.answered(again, "uuid:ruark-r5", 3, true, "ok").session, "uuid:ruark-r5"));
        verify(CL.refusedBy(CL.answered(again, "uuid:ruark-r5", 3, false, "refused").session, "uuid:ruark-r5"));
        // Unticked: gone, and ticking it again starts clean.
        var gone = CL.left(both, "uuid:ruark-r5");
        verify(!CL.refusedBy(gone, "uuid:ruark-r5"));
        verify(!CL.refusedBy(CL.tried(gone, "uuid:ruark-r5", 4), "uuid:ruark-r5"));
        // Another device leaving does not take it down.
        verify(CL.refusedBy(CL.left(both, "cc-1"), "uuid:ruark-r5"));
    }

    function test_only_a_refusal_of_the_address_marks_a_device_data() {
        return [
            { tag: "refused", ok: false, kind: "refused", marked: true },
            { tag: "out of reach", ok: false, kind: "unreachable", marked: false },
            { tag: "another failure", ok: false, kind: "other", marked: false },
            { tag: "a missing library", ok: false, kind: "nolib", marked: false },
            { tag: "no kind given", ok: false, kind: undefined, marked: false },
            { tag: "a kind that is no text", ok: false, kind: true, marked: false },
            { tag: "a kind in capitals", ok: false, kind: "REFUSED", marked: false },
            { tag: "taken", ok: true, kind: "ok", marked: false },
            // The two cannot both be so: taken is what counts.
            { tag: "taken and called refused", ok: true, kind: "refused", marked: false }
        ];
    }
    function test_only_a_refusal_of_the_address_marks_a_device(data) {
        var a = CL.answered(CL.tried(CL.fresh(), "uuid:ruark-r5", 7), "uuid:ruark-r5", 7, data.ok, data.kind);
        compare(a.stale, false);
        compare(CL.refusedBy(a.session, "uuid:ruark-r5"), data.marked);
        compare(a.carried, data.ok);
    }

    function test_an_answer_that_is_nobodys_marks_nobody() {
        var s = CL.tried(CL.tried(CL.fresh(), "cc-1", 30), "cc-1", 31);
        // The older attempt's refusal comes home while the newer one is asked.
        var late = CL.answered(s, "cc-1", 30, false, "refused");
        compare(late.stale, true);
        verify(!CL.refusedBy(late.session, "cc-1"));
        // A device nobody asked, and one that left before its answer.
        verify(!CL.refusedBy(CL.answered(s, "cc-9", 31, false, "refused").session, "cc-9"));
        verify(!CL.refusedBy(CL.answered(CL.left(s, "cc-1"), "cc-1", 31, false, "refused").session, "cc-1"));
    }

    function test_the_end_of_a_cast_keeps_the_marks_and_nothing_else() {
        var s = CL.tried(CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "uuid:ruark-r5", 2), "cc-2", 3);
        s = CL.answered(s, "uuid:ruark-r5", 2, false, "refused").session;
        s = CL.answered(s, "cc-1", 1, true, "ok").session;
        var over = CL.ended(s);
        verify(!CL.carried(over));
        compare(Object.keys(over.on).length, 0);
        compare(Object.keys(over.pending).length, 0);
        verify(CL.refusedBy(over, "uuid:ruark-r5"));
        verify(!CL.refusedBy(over, "cc-1") && !CL.refusedBy(over, "cc-2"));
        // An answer still on its way after the end belongs to nobody, and marks nobody.
        var late = CL.answered(over, "cc-2", 3, false, "refused");
        compare(late.stale, true);
        verify(!CL.refusedBy(late.session, "cc-2"));
        // The record handed in is as it was.
        verify(CL.carried(s) && s.on["cc-1"] === true && s.pending["cc-2"] === 3);
        // Ended twice, and the end of nothing.
        compare(CL.ended(over), over);
        compare(CL.ended(CL.fresh()), CL.fresh());
        compare(CL.ended(undefined), CL.fresh());
        compare(CL.ended({ "refused": "uuid:ruark-r5" }), CL.fresh());
        // A new record knows of no refusal.
        verify(!CL.refusedBy(CL.fresh(), "uuid:ruark-r5"));
    }

    function test_a_mark_is_asked_about_by_a_uuid_of_text() {
        var no = CL.answered(CL.tried(CL.fresh(), "7", 1), "7", 1, false, "refused").session;
        verify(CL.refusedBy(no, "7"));
        verify(!CL.refusedBy(no, 7));
        verify(!CL.refusedBy(no, ""));
        verify(!CL.refusedBy(no, undefined));
        verify(!CL.refusedBy(no, null));
        verify(!CL.refusedBy(no, ["7"]));
        var bad = [undefined, null, 7, "x", [], { "refused": 7 }, { "refused": ["7"] }, { "refused": { "7": "yes" } }, { "refused": { "7": 1 } }];
        for (var i = 0; i < bad.length; i++) verify(!CL.refusedBy(bad[i], "7"), JSON.stringify(bad[i]));
        // A list is no set of marks, whatever stands in it.
        verify(!CL.refusedBy({ "refused": [true, true] }, "0"));
        verify(!CL.refusedBy({ "refused": [true, true] }, "1"));
        // Four hundred devices refuse, and each second one is asked again.
        var s = CL.fresh(), k;
        for (k = 0; k < 400; k++) s = CL.tried(s, "d" + k, k);
        for (k = 0; k < 400; k++) s = CL.answered(s, "d" + k, k, false, "refused").session;
        for (k = 0; k < 400; k += 2) s = CL.tried(s, "d" + k, 400 + k);
        var marked = 0;
        for (k = 0; k < 400; k++) if (CL.refusedBy(s, "d" + k)) marked++;
        compare(marked, 200);
        verify(CL.refusedBy(s, "d399") && !CL.refusedBy(s, "d398"));
    }

    // ── who is sent a level ──────────────────────────────────────────────

    function test_only_a_device_that_plays_is_sent_a_level() {
        var asked = CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "uuid:ruark-r5", 2);
        // Being asked is not playing: the device may yet refuse.
        verify(!CL.plays(asked, "cc-1"));
        verify(!CL.plays(asked, "uuid:ruark-r5"));
        // The television plays and the Ruark refused.
        var one = CL.answered(CL.answered(asked, "cc-1", 1, true, "ok").session, "uuid:ruark-r5", 2, false, "refused").session;
        verify(CL.plays(one, "cc-1"));
        verify(!CL.plays(one, "uuid:ruark-r5"));
        // A device out of reach, one that left, one nobody knows, and nobody.
        var out = CL.answered(asked, "uuid:ruark-r5", 2, false, "unreachable").session;
        verify(!CL.plays(out, "uuid:ruark-r5"));
        verify(!CL.plays(CL.left(one, "cc-1"), "cc-1"));
        verify(!CL.plays(one, "cc-9"));
        verify(!CL.plays(one, ""));
        verify(!CL.plays(one, undefined));
        verify(!CL.plays(one, null));
        verify(!CL.plays(one, 7));
        verify(!CL.plays(CL.fresh(), "cc-1"));
        verify(!CL.plays(undefined, "cc-1"));
        verify(!CL.plays({ "on": ["cc-1"] }, "0"));
        // Asked again for the next station: not until it has answered that one.
        var again = CL.tried(one, "cc-1", 3);
        verify(!CL.plays(again, "cc-1"));
        verify(CL.plays(CL.answered(again, "cc-1", 3, true, "ok").session, "cc-1"));
        // The cast is over: nobody plays.
        verify(!CL.plays(CL.ended(one), "cc-1"));
        // A uuid is text.
        var seven = CL.answered(CL.tried(CL.fresh(), "7", 1), "7", 1, true, "ok").session;
        verify(CL.plays(seven, "7") && !CL.plays(seven, 7));
    }

    function test_a_level_asked_for_while_a_device_is_asked_goes_out_with_its_answer() {
        var asked = CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "uuid:ruark-r5", 2);
        var tvOn = CL.answered(asked, "cc-1", 1, true, "ok");
        // Nothing was asked for meanwhile: nothing is owed.
        compare(tvOn.owed, -1);
        // A level is asked for while the Ruark is still being asked.
        var owing = CL.owing(tvOn.session, 30);
        // It takes the stream: the level is its to have, once.
        var took = CL.answered(owing, "uuid:ruark-r5", 2, true, "ok");
        compare(took.owed, 30);
        compare(CL.answered(CL.tried(took.session, "uuid:ruark-r5", 5), "uuid:ruark-r5", 5, true, "ok").owed, -1);
        // It refuses, or cannot be reached: nothing goes out, then or later.
        var no = CL.answered(owing, "uuid:ruark-r5", 2, false, "refused");
        compare(no.owed, -1);
        compare(CL.answered(CL.tried(no.session, "uuid:ruark-r5", 6), "uuid:ruark-r5", 6, true, "ok").owed, -1);
        compare(CL.answered(owing, "uuid:ruark-r5", 2, false, "unreachable").owed, -1);
        // The device that played when the level was asked for was sent it then, and is owed nothing.
        compare(CL.answered(CL.tried(owing, "cc-1", 7), "cc-1", 7, true, "ok").owed, -1);
        // The record handed in is not changed.
        compare(CL.answered(tvOn.session, "uuid:ruark-r5", 2, true, "ok").owed, -1);
    }

    function test_the_last_level_asked_for_is_the_one_owed() {
        var s = CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "cc-2", 2);
        s = CL.owing(CL.owing(CL.owing(s, 30), 0), 55);
        compare(CL.answered(s, "cc-1", 1, true, "ok").owed, 55);
        compare(CL.answered(s, "cc-2", 2, true, "ok").owed, 55);
        // A mute is a level like any other, and so is all the way up.
        compare(CL.answered(CL.owing(s, 0), "cc-1", 1, true, "ok").owed, 0);
        compare(CL.answered(CL.owing(s, 100), "cc-1", 1, true, "ok").owed, 100);
        // A device asked after the level was asked for is owed nothing: it was not waited for then.
        var later = CL.tried(CL.owing(CL.tried(CL.fresh(), "cc-1", 1), 30), "cc-2", 2);
        compare(CL.answered(later, "cc-2", 2, true, "ok").owed, -1);
        compare(CL.answered(later, "cc-1", 1, true, "ok").owed, 30);
        // Asked again before it answered: still owed, to the answer that counts.
        var again = CL.tried(CL.owing(CL.tried(CL.fresh(), "cc-1", 1), 30), "cc-1", 2);
        compare(CL.answered(again, "cc-1", 1, true, "ok").owed, -1);
        compare(CL.answered(again, "cc-1", 2, true, "ok").owed, 30);
    }

    function test_what_is_owed_goes_with_the_device_and_with_the_cast() {
        var s = CL.owing(CL.tried(CL.tried(CL.fresh(), "cc-1", 1), "cc-2", 2), 30);
        // Unticked, and ticked again later: it starts clean.
        var back = CL.tried(CL.left(s, "cc-1"), "cc-1", 3);
        compare(CL.answered(back, "cc-1", 3, true, "ok").owed, -1);
        compare(CL.answered(back, "cc-2", 2, true, "ok").owed, 30);
        // The cast ended, and the next one owes nothing from before.
        var next = CL.tried(CL.ended(s), "cc-1", 4);
        compare(CL.answered(next, "cc-1", 4, true, "ok").owed, -1);
        // An answer that is nobody's is owed nothing and uses nothing up.
        compare(CL.answered(s, "cc-1", 9, true, "ok").owed, -1);
        compare(CL.answered(CL.answered(s, "cc-1", 9, true, "ok").session, "cc-1", 1, true, "ok").owed, 30);
    }

    function test_a_level_that_is_none_is_owed_to_nobody_data() {
        return [
            { tag: "below nothing", pct: -1 }, { tag: "over the top", pct: 101 }, { tag: "no number", pct: NaN },
            { tag: "text", pct: "30" }, { tag: "undefined", pct: undefined }, { tag: "null", pct: null },
            { tag: "infinite", pct: Infinity }, { tag: "an object", pct: { "pct": 30 } }
        ];
    }
    function test_a_level_that_is_none_is_owed_to_nobody(data) {
        var s = CL.tried(CL.fresh(), "cc-1", 1);
        compare(CL.owing(s, data.pct), s);
        compare(CL.answered(CL.owing(s, data.pct), "cc-1", 1, true, "ok").owed, -1);
        // And it does not take away what was owed before.
        compare(CL.answered(CL.owing(CL.owing(s, 30), data.pct), "cc-1", 1, true, "ok").owed, 30);
    }

    function test_a_level_between_two_whole_ones_and_many_devices() {
        var s = CL.tried(CL.fresh(), "cc-1", 1);
        compare(CL.answered(CL.owing(s, 12.5), "cc-1", 1, true, "ok").owed, 12.5);
        // Nobody being asked: nothing to owe, and the record is as it was.
        var on = CL.answered(s, "cc-1", 1, true, "ok").session;
        compare(CL.owing(on, 30), on);
        compare(CL.owing(CL.fresh(), 30), CL.fresh());
        compare(CL.owing(undefined, 30), CL.fresh());
        compare(CL.answered({ "pending": { "cc-1": 1 }, "owed": { "cc-1": "30" } }, "cc-1", 1, true, "ok").owed, -1);
        compare(CL.answered({ "pending": { "cc-1": 1 }, "owed": { "cc-1": 300 } }, "cc-1", 1, true, "ok").owed, -1);
        compare(CL.answered({ "pending": { "cc-1": 1 }, "owed": [30] }, "cc-1", 1, true, "ok").owed, -1);
        // A list is no account of what is owed, whatever its places are called.
        compare(CL.answered({ "pending": { "0": 1 }, "owed": [30] }, "0", 1, true, "ok").owed, -1);
        var many = CL.fresh(), k;
        for (k = 0; k < 400; k++) many = CL.tried(many, "d" + k, k);
        many = CL.owing(many, 42);
        var told = 0;
        for (k = 0; k < 400; k++) {
            var a = CL.answered(many, "d" + k, k, k % 2 === 0, "ok");
            many = a.session;
            if (a.owed === 42) told++;
        }
        compare(told, 200);
    }

    function test_a_record_that_is_none_reads_as_empty() {
        var bad = [undefined, null, 7, "x", [], { "pending": 7 }, { "on": "yes" }, { "pending": null, "on": null }];
        for (var i = 0; i < bad.length; i++) {
            verify(!CL.carried(bad[i]), JSON.stringify(bad[i]));
            compare(CL.tried(bad[i], "cc-1", 1).pending["cc-1"], 1, JSON.stringify(bad[i]));
            compare(CL.answered(bad[i], "cc-1", 1, true).stale, true, JSON.stringify(bad[i]));
            compare(CL.left(bad[i], "cc-1"), CL.fresh(), JSON.stringify(bad[i]));
        }
        // Many devices.
        var s = CL.fresh();
        for (var k = 0; k < 400; k++) s = CL.tried(s, "d" + k, k);
        for (k = 0; k < 400; k++) s = CL.answered(s, "d" + k, k, k === 399).session;
        verify(CL.carried(s));
        compare(Object.keys(s.on), ["d399"]);
    }
}
