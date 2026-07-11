# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Google Cast bridge for On Air.

Casting a radio stream is handled by SHORT-LIVED commands, not a long-running
daemon: once the stream URL is handed to the Cast device it pulls the audio
itself, so the device keeps playing after this process exits. No orphaned
background process, no local audio decoding while casting, and near-zero host
CPU — which matters most on the low-powered machines this feature targets.

Discovery (mDNS) is slow (~5 s), so it is done ONCE up front; the returned
host+port let every later play/stop/volume command connect directly in ~0.1 s,
which keeps volume changes and playback responsive.

Commands (argv[1]):
  probe                                   -> "__CAST_OK__" if pychromecast imports
  discover [seconds]                      -> "DEV\\t<uuid>\\t<name>\\t<host>\\t<port>\\t<model>" per device
  play   <host> <port> <uuid> <model> <url> <ctype> <title> <art>
  stop   <host> <port> <uuid> <model>
  volume <host> <port> <uuid> <model> <0.0..1.0>

Every command prints a sentinel the QML side matches on and always exits 0, so
a missing optional dependency is a clean "feature unavailable", never a crash.
"""
import sys

NO_LIB = "__NO_PYCHROMECAST__"
OK = "__CAST_OK__"
FAIL = "__CAST_FAIL__"
DONE = "__CAST_DONE__"

# mDNS discovery is bounded so the picker never spins forever on a network
# with no devices; direct connections use a shorter socket timeout.
DEFAULT_DISCOVERY_SECONDS = 6.0
CONNECT_TIMEOUT = 6.0


def _out(line):
    print(line, flush=True)


def _import():
    """Import pychromecast lazily so `probe` can report absence cleanly."""
    import pychromecast  # noqa: F401
    return pychromecast


def _clean(text):
    return (text or "").replace("\t", " ").replace("\n", " ")


def _stop_browser(browser):
    if browser is None:
        return
    try:
        browser.stop_discovery()
    except Exception:
        pass


def _connect_host(pychromecast, host, port, uuid, model):
    """Connect straight to a known host — no mDNS, ~0.1 s on a live device."""
    import uuid as uuidmod
    cast = pychromecast.get_chromecast_from_host(
        (host, int(port), uuidmod.UUID(uuid), model or None, None),
        timeout=CONNECT_TIMEOUT,
    )
    cast.wait(timeout=CONNECT_TIMEOUT)
    return cast


def _disconnect(cast):
    if cast is None:
        return
    try:
        cast.disconnect(timeout=2)
    except Exception:
        pass


def cmd_probe():
    try:
        _import()
    except Exception:
        _out(NO_LIB)
        return
    _out(OK)


def cmd_discover(seconds):
    try:
        pychromecast = _import()
    except Exception:
        _out(NO_LIB)
        return
    browser = None
    try:
        casts, browser = pychromecast.get_chromecasts(timeout=seconds)
        for cast in casts:
            info = cast.cast_info
            _out("DEV\t%s\t%s\t%s\t%s\t%s" % (
                info.uuid,
                _clean(info.friendly_name) or "Cast device",
                info.host or "",
                info.port or 8009,
                _clean(info.model_name),
            ))
            _disconnect(cast)
    except Exception as exc:
        print("cast.py discover: %r" % (exc,), file=sys.stderr)
    finally:
        _stop_browser(browser)
        _out(DONE)


def cmd_play(host, port, uuid, model, url, ctype, title, art):
    try:
        pychromecast = _import()
    except Exception:
        _out(NO_LIB)
        return
    cast = None
    try:
        cast = _connect_host(pychromecast, host, port, uuid, model)
        mc = cast.media_controller
        # stream_type LIVE tells the receiver there is no seekable duration —
        # correct for radio and it hides a bogus scrubber on the device.
        mc.play_media(
            url,
            content_type=ctype or "audio/mpeg",
            title=title or None,
            thumb=art or None,
            stream_type="LIVE",
        )
        mc.block_until_active(timeout=CONNECT_TIMEOUT)
        _out(OK)
    except Exception as exc:
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))
    finally:
        # Disconnect WITHOUT stopping the receiver: the device keeps streaming.
        _disconnect(cast)


def cmd_stop(host, port, uuid, model):
    try:
        pychromecast = _import()
    except Exception:
        _out(NO_LIB)
        return
    cast = None
    try:
        cast = _connect_host(pychromecast, host, port, uuid, model)
        # quit_app stops playback and returns the device to its idle backdrop,
        # freeing it for other apps — cleaner than a lingering paused receiver.
        cast.quit_app()
        _out(DONE)
    except Exception as exc:
        print("cast.py stop: %r" % (exc,), file=sys.stderr)
        _out(DONE)
    finally:
        _disconnect(cast)


def cmd_volume(host, port, uuid, model, level):
    try:
        pychromecast = _import()
    except Exception:
        _out(NO_LIB)
        return
    cast = None
    try:
        vol = max(0.0, min(1.0, float(level)))
        cast = _connect_host(pychromecast, host, port, uuid, model)
        cast.set_volume(vol)
        _out(OK)
    except Exception as exc:
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))
    finally:
        _disconnect(cast)


def main():
    if len(sys.argv) < 2:
        _out("%s usage: cast.py <command>" % FAIL)
        return
    command = sys.argv[1]
    args = sys.argv[2:]
    if command == "probe":
        cmd_probe()
    elif command == "discover":
        seconds = DEFAULT_DISCOVERY_SECONDS
        if args:
            try:
                seconds = max(1.0, min(15.0, float(args[0])))
            except ValueError:
                pass
        cmd_discover(seconds)
    elif command == "play" and len(args) >= 6:
        host, port, uuid, model, url, ctype = args[0:6]
        title = args[6] if len(args) > 6 else ""
        art = args[7] if len(args) > 7 else ""
        cmd_play(host, port, uuid, model, url, ctype, title, art)
    elif command == "stop" and len(args) >= 4:
        cmd_stop(args[0], args[1], args[2], args[3])
    elif command == "volume" and len(args) >= 5:
        cmd_volume(args[0], args[1], args[2], args[3], args[4])
    else:
        _out("%s bad arguments" % FAIL)


if __name__ == "__main__":
    main()
