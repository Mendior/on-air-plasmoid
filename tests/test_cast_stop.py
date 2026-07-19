# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Stop-failure visibility in cast.py. FAIL is reserved for a device that was
REACHED but refused to stop (it may well still be playing, and a silent DONE
would tell the UI otherwise). A device that is off/unreachable, or one that is
already idle and answers Stop with a SOAP fault, is demonstrably not playing —
that is a quiet DONE. Exit code stays 0 either way (the sentinel is the
protocol; a nonzero exit reads as a helper crash)."""
import urllib.error


def sentinel_lines(capsys):
    return capsys.readouterr().out.strip().splitlines()


def test_cmd_stop_connect_failure_stays_done(cast, monkeypatch, capsys):
    # Connect raised = the device is off/unreachable, so nothing plays on it —
    # the quiet DONE path, not a FAIL notify.
    def boom(*a, **kw):
        raise RuntimeError("no route to host")

    monkeypatch.setattr(cast, "_import", lambda: object())
    monkeypatch.setattr(cast, "_connect_host", boom)
    cast.cmd_stop("h", "8009", "u", "m")  # returning (not raising) = exit 0
    assert sentinel_lines(capsys) == [cast.DONE]


def test_cmd_stop_quit_failure_emits_fail(cast, monkeypatch, capsys):
    # Connected, but quit_app raised = the receiver was reached and likely
    # still plays — the failure must be visible.
    class FakeCast:
        def quit_app(self):
            raise RuntimeError("receiver busy")

        def disconnect(self, timeout=2):
            pass

    monkeypatch.setattr(cast, "_import", lambda: object())
    monkeypatch.setattr(cast, "_connect_host", lambda *a, **kw: FakeCast())
    cast.cmd_stop("h", "8009", "u", "m")
    out = sentinel_lines(capsys)
    assert len(out) == 1
    assert out[0].startswith(cast.FAIL)
    assert "receiver busy" in out[0]
    assert cast.DONE not in out[0]


def test_cmd_stop_success_still_emits_done(cast, monkeypatch, capsys):
    class FakeCast:
        def quit_app(self):
            pass

        def disconnect(self, timeout=2):
            pass

    monkeypatch.setattr(cast, "_import", lambda: object())
    monkeypatch.setattr(cast, "_connect_host", lambda *a, **kw: FakeCast())
    cast.cmd_stop("h", "8009", "u", "m")
    assert sentinel_lines(capsys) == [cast.DONE]


def test_cmd_dlna_stop_control_unreachable_emits_fail(cast, monkeypatch, capsys):
    # Descriptor answered but the control URL could not be reached — ambiguous,
    # the renderer may still be streaming, so FAIL.
    dev = {"name": "X", "model": "", "udn": "u",
           "avtransport": "http://192.0.2.1:8080/ctl", "rendering": None}
    monkeypatch.setattr(cast, "_describe_renderer", lambda loc: dev)

    def boom(*a, **kw):
        raise OSError("connection refused")

    monkeypatch.setattr(cast, "_soap", boom)
    cast.cmd_dlna_stop("http://192.0.2.1:8080/dd.xml")
    out = sentinel_lines(capsys)
    assert len(out) == 1
    assert out[0].startswith(cast.FAIL)
    assert "connection refused" in out[0]


def test_cmd_dlna_stop_idle_soap_fault_stays_done(cast, monkeypatch, capsys):
    # An already-idle renderer answers Stop with a SOAP fault (HTTP 500) —
    # nothing is playing, so DONE, not a misleading FAIL.
    dev = {"name": "X", "model": "", "udn": "u",
           "avtransport": "http://192.0.2.1:8080/ctl", "rendering": None}
    monkeypatch.setattr(cast, "_describe_renderer", lambda loc: dev)

    def fault(*a, **kw):
        raise urllib.error.HTTPError(
            "http://192.0.2.1:8080/ctl", 500, "Internal Server Error", {}, None)

    monkeypatch.setattr(cast, "_soap", fault)
    cast.cmd_dlna_stop("http://192.0.2.1:8080/dd.xml")
    assert sentinel_lines(capsys) == [cast.DONE]


def test_cmd_dlna_stop_gone_device_stays_done(cast, monkeypatch, capsys):
    # No descriptor = the device is off or unplugged — nothing is playing,
    # so the quiet DONE path is the right answer, not a FAIL notify.
    monkeypatch.setattr(cast, "_describe_renderer", lambda loc: None)
    cast.cmd_dlna_stop("http://192.0.2.1:8080/dd.xml")
    assert sentinel_lines(capsys) == [cast.DONE]
