# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""What cast.py says when a device does not play what it was sent.

A Ruark R5se answered three station addresses with HTTP 500 and a SOAP fault
naming UPnP error 716, "Resource not found", and played a fourth (measured
2026-11-12). The helper kept the first 200 characters of the answer and the
code sits 270 in, so the widget could only say "could not cast", the same
words it has for a speaker that is switched off.

A renderer on loopback stands in for the device here and answers each SOAP
action as the test tells it to; the fault it sends is the one the Ruark sent,
byte for byte. The helper's own _soap talks to it over a real socket, because
the reading of the answer is what was wrong. No device on the network is
asked anything.
"""

import http.server
import socket
import threading
from types import SimpleNamespace

import pytest

# The body of every one of the six refusals recorded on 2026-11-12. It names
# no address and no device; the URLs in it are the SOAP and UPnP namespaces.
RUARK_716 = (
    '<s:Envelope\r\n xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault>'
    "<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>"
    '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>716</errorCode>'
    "<errorDescription>Resource not found</errorDescription></UPnPError></detail>"
    "</s:Fault></s:Body></s:Envelope>"
)

STREAM = "http://radio.example:9000/live/320b?token=LISTENER-TOKEN-7731"
# No part of the address may come out, in any spelling a device could echo.
SECRETS = ("radio.example", "LISTENER-TOKEN-7731", "320b", "token=")

DESCRIPTION = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Stand-in renderer</friendlyName>
    <modelName>Loopback</modelName>
    <UDN>uuid:stand-in</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>%(control)s/avt</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>%(control)s/rc</controlURL>
      </service>
    </serviceList>
  </device>
</root>"""


def fault(code, words):
    return RUARK_716.replace("716", code).replace("Resource not found", words)


class Renderer(http.server.ThreadingHTTPServer):
    """A renderer on loopback. answers maps an action to (status, body), to
    "hang" (take the request and say nothing) or to "drop" (hang up); an
    action it has no answer for is answered 200. asked keeps the actions in
    the order they came, sent the body of each."""

    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _Answering)
        self.answers = {}
        self.asked = []
        self.sent = []
        self.control = ""
        self.release = threading.Event()

    @property
    def location(self):
        return "http://127.0.0.1:%d/desc.xml" % self.server_address[1]


class _Answering(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert isinstance(self.server, Renderer)
        self._answer(200, DESCRIPTION % {"control": self.server.control})

    def do_POST(self):
        assert isinstance(self.server, Renderer)
        action = (self.headers.get("SOAPACTION") or "").strip('"').rpartition("#")[2]
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8")
        self.server.asked.append(action)
        self.server.sent.append(body)
        answer = self.server.answers.get(action, (200, "<ok/>"))
        if answer == "hang":
            self.server.release.wait(20)
        elif answer == "drop":
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
        else:
            self._answer(*answer)

    def _answer(self, status, body):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", 'text/xml; charset="utf-8"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


@pytest.fixture
def renderer():
    server = Renderer()
    # The default beat is half a second, and shutdown() waits one out.
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
    thread.start()
    yield server
    server.release.set()
    server.shutdown()
    server.server_close()
    thread.join(5)


@pytest.fixture
def quick(cast, monkeypatch):
    """The helper's own _soap with a wait of 0.3 s, whatever the caller asks
    for: a device that says nothing is waited for 5 s otherwise."""
    real = cast._soap
    monkeypatch.setattr(cast, "_soap", lambda *a, **kw: real(*a, **{**kw, "timeout": 0.3}))


def closed_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def play(cast, capsys, location):
    cast.cmd_dlna_play(location, STREAM, "audio/mpeg", "Station")
    said = capsys.readouterr()
    return said.out.strip().splitlines(), said.err


def test_a_renderer_that_takes_the_address_plays(cast, capsys, renderer):
    out, _err = play(cast, capsys, renderer.location)
    assert out == [cast.OK]
    assert renderer.asked == ["Stop", "SetAVTransportURI", "Play"]
    # The stand-in is talked to as a device is: the address goes out, once
    # as the URI and once inside the metadata, CDATA first.
    assert renderer.sent[1].count("radio.example:9000/live/320b?token=LISTENER-TOKEN-7731") == 2
    assert "<![CDATA[<DIDL-Lite" in renderer.sent[1]


def test_a_refused_address_is_named_by_the_code_the_device_gave(cast, capsys, renderer):
    renderer.answers["SetAVTransportURI"] = (500, RUARK_716)
    out, _err = play(cast, capsys, renderer.location)
    assert out == ["%s upnp=716 action=SetAVTransportURI http=500 Resource not found" % cast.FAIL]
    # Both packings were tried, Play was never sent, and the device is left idle.
    assert renderer.asked == ["Stop", "SetAVTransportURI", "SetAVTransportURI", "Stop"]


def test_the_recorded_fault_keeps_its_code_past_the_old_cut():
    assert RUARK_716.index("<errorCode>") == 270, "the fixture is not the answer that was recorded"
    assert "errorCode" not in RUARK_716[:200]


def test_a_refusal_at_play_names_play(cast, capsys, renderer):
    renderer.answers["Play"] = (500, fault("705", "Transport is locked"))
    out, _err = play(cast, capsys, renderer.location)
    assert out == ["%s upnp=705 action=Play http=500 Transport is locked" % cast.FAIL]
    assert renderer.asked == ["Stop", "SetAVTransportURI", "Play", "SetAVTransportURI", "Play", "Stop"]


@pytest.mark.parametrize("status, body", [
    (404, "<html><body><h1>404 Not Found</h1></body></html>"),
    (500, "Internal Server Error"),
    (500, ""),
    (500, '{"error": 716}'),
    # A SOAP fault that is no UPnP error names no code.
    (500, "<s:Envelope><s:Body><s:Fault><faultcode>s:Server</faultcode>"
          "<faultstring>Internal</faultstring></s:Fault></s:Body></s:Envelope>"),
    (301, ""),
    (503, RUARK_716.replace("<errorCode>716</errorCode>", "<errorCode>seven</errorCode>")),
])
def test_an_answer_that_names_no_upnp_error_gives_the_status_alone(cast, capsys, renderer, status, body):
    renderer.answers["SetAVTransportURI"] = (status, body)
    out, _err = play(cast, capsys, renderer.location)
    assert len(out) == 1
    assert out[0].startswith("%s action=SetAVTransportURI http=%d" % (cast.FAIL, status)), out
    assert "upnp=" not in out[0] and "reach=" not in out[0]


def test_a_device_that_takes_the_command_and_says_nothing_timed_out(cast, capsys, renderer, quick):
    renderer.answers["SetAVTransportURI"] = "hang"
    out, _err = play(cast, capsys, renderer.location)
    assert out == ["%s reach=timeout action=SetAVTransportURI" % cast.FAIL]


def test_a_device_that_hangs_up_dropped_the_command(cast, capsys, renderer):
    renderer.answers["SetAVTransportURI"] = "drop"
    out, _err = play(cast, capsys, renderer.location)
    assert out == ["%s reach=dropped action=SetAVTransportURI" % cast.FAIL]


def test_a_control_address_nobody_listens_on_refused(cast, capsys, renderer):
    # The description answers; the control address in it is a port nothing
    # is bound to. Another port of the same host is a renderer's right.
    renderer.control = "http://127.0.0.1:%d" % closed_port()
    out, _err = play(cast, capsys, renderer.location)
    assert out == ["%s reach=refused action=SetAVTransportURI" % cast.FAIL]


def test_a_device_with_no_description_is_not_there(cast, capsys):
    out, _err = play(cast, capsys, "http://127.0.0.1:%d/desc.xml" % closed_port())
    assert out == ["%s reach=nodesc renderer description unavailable" % cast.FAIL]


ECHOES = [
    ("the recorded fault", (500, RUARK_716)),
    ("the address after the words", (500, fault("716", "Resource not found: " + STREAM))),
    ("the address for words", (500, fault("716", STREAM))),
    ("the address with its marks escaped", (500, fault("716", STREAM.replace(":", "&#58;").replace("?", "&#63;")))),
    ("the address in the fault string", (500, RUARK_716.replace("UPnPError</faultstring>", STREAM + "</faultstring>"))),
    ("a page that quotes the address", (404, "<html><body>Cannot open %s</body></html>" % STREAM)),
    ("the address and nothing else", (500, STREAM)),
    ("the address in front of the code", (500, STREAM + RUARK_716)),
    ("no answer", "hang"),
    ("a dropped connection", "drop"),
]


@pytest.mark.parametrize("answer", [a for _tag, a in ECHOES], ids=[tag for tag, _a in ECHOES])
def test_the_address_is_in_nothing_the_helper_says(cast, capsys, renderer, quick, answer):
    renderer.answers["SetAVTransportURI"] = answer
    out, err = play(cast, capsys, renderer.location)
    assert len(out) == 1 and out[0].startswith(cast.FAIL), out
    for secret in SECRETS:
        assert secret not in out[0], "the answer carries %r: %s" % (secret, out[0])
        assert secret not in err, "the trace carries %r: %s" % (secret, err)
    # The whole body is not passed on either, whatever it holds.
    assert "Envelope" not in out[0] and "<" not in out[0]
    assert len(out[0]) < 120


def test_the_address_is_not_said_where_nothing_answers_either(cast, capsys, renderer):
    renderer.control = "http://127.0.0.1:%d" % closed_port()
    for location in (renderer.location, "http://127.0.0.1:%d/desc.xml" % closed_port()):
        out, err = play(cast, capsys, location)
        for secret in SECRETS:
            assert secret not in out[0] and secret not in err


def test_an_error_of_the_helpers_own_that_quotes_the_address_loses_it(cast, capsys, renderer, monkeypatch):
    def breaks(title, ctype, url, art=""):
        raise ValueError("cannot pack %s into the metadata" % url)

    monkeypatch.setattr(cast, "_didl_metadata", breaks)
    out, err = play(cast, capsys, renderer.location)
    assert out == ["%s cannot pack  into the metadata" % cast.FAIL]
    for secret in SECRETS:
        assert secret not in err


@pytest.mark.parametrize("body, named", [
    (RUARK_716, ("716", "Resource not found")),
    (fault("714", "Illegal MIME-type"), ("714", "Illegal MIME-type")),
    (fault("715", "Content &apos;BUSY&apos;"), ("715", "Content 'BUSY'")),
    # A prefix on the two elements, and attributes: seen from other stacks.
    ('<u:UPnPError xmlns:u="urn:schemas-upnp-org:control-1-0"><u:errorCode>701</u:errorCode>'
     "<u:errorDescription>Transition not available</u:errorDescription></u:UPnPError>",
     ("701", "Transition not available")),
    ('<errorCode xml:space="preserve"> 402\r\n</errorCode><errorDescription/>', ("402", "")),
    # The code alone, and the words alone.
    ("<errorCode>501</errorCode>", ("501", "")),
    ("<errorDescription>Action Failed</errorDescription>", ("", "Action Failed")),
    # Two of them: the first is the fault's own.
    ("<errorCode>716</errorCode><errorCode>402</errorCode>", ("716", "")),
    # The longest code there is room for, and one digit more.
    ("<errorCode>999999</errorCode>", ("999999", "")),
    ("<errorCode>1000000</errorCode>", ("", "")),
    # What is no code.
    ("<errorCode></errorCode>", ("", "")),
    ("<errorCode>-716</errorCode>", ("", "")),
    ("<errorCode>7 16</errorCode>", ("", "")),
    ("<errorCode>716", ("", "")),
    ("<errorCodes>716</errorCodes>", ("", "")),
    ("errorCode 716", ("", "")),
    ("", ("", "")),
    ("\x00\xff\ufffd<<<>>>", ("", "")),
    ("x" * 300000 + RUARK_716 + "y" * 300000, ("716", "Resource not found")),
    ("<" * 200000 + "errorCode>716</errorCode>", ("716", "")),
])
def test_what_a_fault_names(cast, body, named):
    assert cast._upnp_error(body) == named


def test_an_answer_built_to_be_slow_is_read_in_no_time(cast):
    """Half a megabyte of an element that never closes, which is all the
    helper reads of an answer. With the attributes unbounded each opening
    was followed to the end of the body: 88 kB took 2 s and the time grew
    with the square (measured), so a device could hold the helper for about
    a minute with one answer."""
    import time
    for hostile in ("<errorCode " * 47000, "<errorDescription " * 29000, "<" + "a" * 500000, "<a:" * 170000):
        began = time.perf_counter()
        assert cast._upnp_error(hostile) == ("", "")
        assert time.perf_counter() - began < 3.0, "%r... took %.1f s" % (hostile[:20], time.perf_counter() - began)


@pytest.mark.parametrize("words, plain", [
    ("Resource not found", "Resource not found"),
    ("  Resource\r\n\tnot   found  ", "Resource not found"),
    ("Illegal MIME-type", "Illegal MIME-type"),
    ("Content &apos;BUSY&apos;", "Content 'BUSY'"),
    ("Not found (716), sorry", "Not found (716), sorry"),
    # Whatever could be an address, or the start of one, ends the words.
    ("Resource not found: " + STREAM, "Resource not found"),
    ("Not found. See the manual", "Not found"),
    (STREAM, "http"),
    ("radio.example/live", "radio"),
    ("user@radio.example", "user"),
    ("a=b&c=d", "a"),
    ("<b>bold</b>", ""),
    ("&lt;script&gt;", ""),
    ("/live/320b", ""),
    ("\u202eevil", "evil"),
    ("Ресурс не найден", ""),
    ("", ""),
    ("   ", ""),
    ("x" * 5000, "x" * 60),
    ("word " * 40, ("word " * 12).strip()),
])
def test_a_devices_words_are_cut_down_to_plain_ones(cast, words, plain):
    assert cast._plain(words) == plain


@pytest.mark.parametrize("exc, word", [
    (TimeoutError("timed out"), "timeout"),
    (socket.timeout("timed out"), "timeout"),
    (ConnectionRefusedError(111, "Connection refused"), "refused"),
    (ConnectionResetError(104, "Connection reset by peer"), "dropped"),
    (BrokenPipeError(32, "Broken pipe"), "dropped"),
    (OSError(113, "No route to host"), "down"),
    (OSError(101, "Network is unreachable"), "down"),
    (socket.gaierror(-2, "Name or service not known"), "down"),
])
def test_how_a_connection_failed_is_one_word(cast, exc, word):
    assert cast._reach(exc) == word


def test_a_hang_up_in_the_middle_of_an_answer_is_dropped_too(cast):
    import http.client
    assert cast._reach(http.client.RemoteDisconnected("Remote end closed connection")) == "dropped"
    assert cast._reach(http.client.BadStatusLine("upnp=716 action=Play")) == "dropped"
    assert cast._reach(http.client.IncompleteRead(b"half")) == "dropped"


def test_an_error_that_is_neither_keeps_the_line_it_always_had(cast):
    assert cast._fail(RuntimeError("receiver busy")) == "%s receiver busy" % cast.FAIL
    assert cast._fail(RuntimeError("two\nlines")) == "%s two lines" % cast.FAIL
    # One line whatever the words hold: the widget reads the answer by lines.
    assert cast._fail(RuntimeError("two\r\nlines\rand a third")) == "%s two  lines and a third" % cast.FAIL
    assert cast._fail(RuntimeError("")) == "%s " % cast.FAIL
    long = cast._fail(RuntimeError("x" * 5000))
    assert long == "%s %s" % (cast.FAIL, "x" * 200)
    # The address is taken out where the command had one, and only then.
    assert cast._fail(ValueError("no " + STREAM + " here"), STREAM) == "%s no  here" % cast.FAIL
    assert cast._fail(ValueError("no " + STREAM + " here")) == "%s no %s here" % (cast.FAIL, STREAM)
    assert cast._fail(ValueError("nothing to hide"), "") == "%s nothing to hide" % cast.FAIL


def test_a_fault_and_a_silence_are_spelled_out_whoever_raised_them(cast):
    from email.message import Message
    refused = cast.SoapFault("http://192.0.2.1:8080/avt", 500, Message(), "SetAVTransportURI", RUARK_716)
    assert (refused.code, refused.action, refused.upnp, refused.words) == (500, "SetAVTransportURI", "716", "Resource not found")
    assert cast._fail(refused) == "%s upnp=716 action=SetAVTransportURI http=500 Resource not found" % cast.FAIL
    bare = cast.SoapFault("http://192.0.2.1:8080/avt", 404, Message(), "Play", "<html>" + STREAM + "</html>")
    assert (bare.upnp, bare.words) == ("", "")
    assert cast._fail(bare) == "%s action=Play http=404" % cast.FAIL
    # Neither its words nor its trace give the body away.
    for secret in SECRETS:
        assert secret not in str(bare) and secret not in repr(bare)
    assert "192.0.2.1" not in cast._fail(refused), "the device's own address has no place in the line either"
    assert cast._fail(cast.Unreached("Play", "timeout")) == "%s reach=timeout action=Play" % cast.FAIL


# ── the other commands read the same answers ─────────────────────────────────

def lines(capsys):
    return capsys.readouterr().out.strip().splitlines()


def test_a_level_the_device_refuses_names_its_code(cast, capsys, renderer):
    renderer.answers["SetVolume"] = (500, fault("402", "Invalid Args"))
    cast.cmd_dlna_volume(renderer.location, "0.5")
    assert lines(capsys) == ["%s upnp=402 action=SetVolume http=500 Invalid Args" % cast.FAIL]
    assert "<DesiredVolume>50</DesiredVolume>" in renderer.sent[0]


def test_a_level_is_set_and_read_as_before(cast, capsys, renderer):
    cast.cmd_dlna_volume(renderer.location, "0.16")
    assert lines(capsys) == [cast.OK]
    renderer.answers["GetVolume"] = (200, "<u:GetVolumeResponse><CurrentVolume>16</CurrentVolume></u:GetVolumeResponse>")
    cast.cmd_dlna_get_volume(renderer.location)
    assert lines(capsys) == ["%s 0.160" % cast.VOL]
    renderer.answers["GetVolume"] = (500, fault("501", "Action Failed"))
    cast.cmd_dlna_get_volume(renderer.location)
    assert lines(capsys) == ["%s upnp=501 action=GetVolume http=500 Action Failed" % cast.FAIL]


def test_a_stop_reads_the_status_as_before(cast, capsys, renderer):
    # A fault is an idle renderer's answer to Stop: nothing plays, DONE.
    renderer.answers["Stop"] = (500, fault("701", "Transition not available"))
    cast.cmd_dlna_stop(renderer.location)
    assert lines(capsys) == [cast.DONE]
    # Any other status is not the renderer speaking about Stop.
    renderer.answers["Stop"] = (404, "<html>" + STREAM + "</html>")
    cast.cmd_dlna_stop(renderer.location)
    assert lines(capsys) == ["%s action=Stop http=404" % cast.FAIL]
    renderer.answers["Stop"] = (200, "<ok/>")
    cast.cmd_dlna_stop(renderer.location)
    assert lines(capsys) == [cast.DONE]


def test_a_stop_nobody_heard_says_how(cast, capsys, renderer):
    renderer.control = "http://127.0.0.1:%d" % closed_port()
    cast.cmd_dlna_stop(renderer.location)
    assert lines(capsys) == ["%s reach=refused action=Stop" % cast.FAIL]
    # No description at all: the device is off, nothing plays.
    cast.cmd_dlna_stop("http://127.0.0.1:%d/desc.xml" % closed_port())
    assert lines(capsys) == [cast.DONE]


def test_an_answer_longer_than_the_helper_reads_names_no_code(cast, capsys, renderer):
    """The helper reads half a megabyte of an answer and no more. A fault
    behind that much of anything is not seen, and the status still is."""
    renderer.answers["SetAVTransportURI"] = (500, "x" * (512 * 1024) + RUARK_716)
    out, _err = play(cast, capsys, renderer.location)
    assert out == ["%s action=SetAVTransportURI http=500" % cast.FAIL]
    renderer.answers["SetAVTransportURI"] = (500, "x" * (256 * 1024) + RUARK_716)
    out, _err = play(cast, capsys, renderer.location)
    assert out == ["%s upnp=716 action=SetAVTransportURI http=500 Resource not found" % cast.FAIL]


# ── a Chromecast that is not there, and the helper's own time limit ───────────

class RequestTimeout(Exception):
    """Named as the Cast library names what wait() raises on a device that
    is off; the helper knows it by that name, the library being optional."""


@pytest.mark.parametrize("exc, line", [
    (RequestTimeout("Execution of wait timed out after 6.0 s."), "reach=timeout action=connect"),
    (TimeoutError("timed out"), "reach=timeout action=connect"),
    (ConnectionRefusedError(111, "Connection refused"), "reach=refused action=connect"),
    (OSError(113, "No route to host"), "reach=down action=connect"),
    (RuntimeError("anything else the library says"), "reach=down action=connect"),
])
def test_a_chromecast_that_cannot_be_connected_to_is_not_there(cast, capsys, monkeypatch, exc, line):
    def no_device(*a):
        raise exc

    monkeypatch.setattr(cast, "_import", lambda: object())
    monkeypatch.setattr(cast, "_connect_host", no_device)
    cast.cmd_play("192.0.2.9", 8009, "2f0a6ee2-5a55-4ad1-9a0b-3e5b3e5f6f10", "TV", STREAM, "audio/mpeg", "Station", "")
    said = capsys.readouterr()
    assert said.out.strip().splitlines() == ["%s %s" % (cast.FAIL, line)]
    for secret in SECRETS:
        assert secret not in said.out and secret not in said.err


def test_a_chromecast_error_that_quotes_the_address_loses_it(cast, capsys, monkeypatch):
    def refuses(url, **kw):
        raise RuntimeError("the receiver would not load %s" % url)

    monkeypatch.setattr(cast, "_import", lambda: object())
    monkeypatch.setattr(cast, "_connect_host", lambda *a: SimpleNamespace(media_controller=SimpleNamespace(play_media=refuses)))
    monkeypatch.setattr(cast, "_disconnect", lambda c: None)
    cast.cmd_play("192.0.2.9", 8009, "u", "TV", STREAM, "audio/mpeg", "Station", "")
    said = capsys.readouterr()
    assert said.out.splitlines() == ["%s the receiver would not load " % cast.FAIL]
    for secret in SECRETS:
        assert secret not in said.err


def test_a_chromecast_address_that_is_none_is_not_called_unreachable(cast, capsys, monkeypatch):
    # The real _connect_host: a uuid that is no uuid never reaches the network.
    def reached(*a, **kw):
        raise AssertionError("the library was asked to connect")

    monkeypatch.setattr(cast, "_import", lambda: SimpleNamespace(get_chromecast_from_host=reached))
    cast.cmd_play("192.0.2.9", 8009, "not-a-uuid", "TV", STREAM, "audio/mpeg", "Station", "")
    out = capsys.readouterr().out.strip().splitlines()
    assert len(out) == 1 and out[0].startswith(cast.FAIL + " ")
    assert "reach=" not in out[0] and "UUID" in out[0]


def test_the_helpers_own_time_limit_is_a_timeout(cast):
    import subprocess
    import sys
    script = (
        "import importlib.util, signal, sys, time\n"
        "spec = importlib.util.spec_from_file_location('cast_under_alarm', sys.argv[1])\n"
        "cast = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(cast)\n"
        "signal.signal(signal.SIGALRM, cast._alarm_bail)\n"
        "signal.setitimer(signal.ITIMER_REAL, 0.05)\n"
        "time.sleep(10)\n"
    )
    done = subprocess.run([sys.executable, "-c", script, cast.__file__], capture_output=True, text=True, timeout=30)
    assert done.stdout == "%s reach=timeout helper timed out\n" % cast.FAIL
    assert done.returncode == 1
