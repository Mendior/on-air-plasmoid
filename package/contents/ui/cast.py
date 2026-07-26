# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Cast bridge for On Air: Google Cast + DLNA/UPnP renderers.

Casting a radio stream is handled by SHORT-LIVED commands, not a long-running
daemon: once the stream URL is handed to the device it pulls the audio itself,
so the device keeps playing after this process exits. No orphaned background
process, no local audio decoding while casting, and near-zero host CPU — which
matters most on the low-powered machines this feature targets.

Two device families are supported:

* Google Cast (Chromecast, Nest, Android TVs) — needs the optional
  pychromecast package; its absence only hides Cast devices.
* DLNA/UPnP MediaRenderers (smart TVs, soundbars, AV receivers, network
  speakers, Sonos) — pure standard library (SSDP + SOAP), always available.

Discovery is slow (seconds), so it is done ONCE up front; the returned
address lets every later play/stop/volume command connect directly in
~0.1 s, which keeps volume changes and playback responsive.

Commands (argv[1]):
  probe                       -> "__CAST_OK__ cast=0|1" (dlna is always on)
  discover [seconds]          -> "DEV\\t<kind>\\t<id>\\t<name>\\t<host>\\t<port>\\t<model>\\t<location>"
  play   <host> <port> <uuid> <model> <url> <ctype> <title> <art>
  stop   <host> <port> <uuid> <model>
  volume <host> <port> <uuid> <model> <0.0..1.0>
  dlna-play   <location> <url> <ctype> <title> [art]
  dlna-stop   <location>
  dlna-volume <location> <0.0..1.0>
  get-volume      <host> <port> <uuid> <model>  -> "__CAST_VOL__ <0.0..1.0>"
  dlna-get-volume <location>                    -> "__CAST_VOL__ <0.0..1.0>"

Every command prints a sentinel the QML side matches on and always exits 0, so
a missing optional dependency is a clean "feature unavailable", never a crash.
"""
import glob
import hashlib
import http.client
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

NO_LIB = "__NO_PYCHROMECAST__"
OK = "__CAST_OK__"
FAIL = "__CAST_FAIL__"
DONE = "__CAST_DONE__"
VOL = "__CAST_VOL__"

# mDNS/SSDP discovery is bounded so the picker never spins forever on a
# network with no devices; direct connections use a shorter socket timeout.
DEFAULT_DISCOVERY_SECONDS = 6.0
CONNECT_TIMEOUT = 6.0

_out_lock = threading.Lock()


def _out(line):
    with _out_lock:
        print(line, flush=True)


def _dbg(context, exc):
    """Trace for failure branches that are handled by design.

    stderr ONLY: stdout is the sentinel channel the QML side parses, and one
    stray line there corrupts a command's result. Never raises — a trace must
    not introduce a failure mode of its own (stderr can be a closed pipe).
    """
    try:
        print("cast.py %s: %r" % (context, exc), file=sys.stderr)
    except Exception:
        pass


def _import():
    """Import pychromecast lazily so `probe` can report absence cleanly."""
    import pychromecast  # noqa: F401
    return pychromecast


# C0/C1 controls plus the Unicode bidi formatting marks (LRM/RLM, the
# LRE..RLO embeddings, LRI..PDI isolates): device names travel into the
# TAB-separated DEV protocol and the picker UI, and a hostile friendlyName
# could use these to split records or visually reorder/mask text.
_CLEAN_RE = re.compile(
    "[\\x00-\\x1f\\x7f-\\x9f\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069]")


def _clean(text):
    return " ".join(_CLEAN_RE.sub(" ", text or "").split())[:120]


def _udn_safe(text):
    """A device UDN reduced to the charset a real one uses. The value becomes
    the device key and, QML-side, part of a shell sentinel — stripping it here
    means a hostile renderer cannot smuggle shell metacharacters through it."""
    return "".join(c for c in (text or "") if c.isalnum() or c in ":._-")


# ── Google Cast ──────────────────────────────────────────────────────────────

def _stop_browser(browser):
    if browser is None:
        return
    try:
        browser.stop_discovery()
    except Exception as exc:
        _dbg("stop-browser", exc)


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
    except Exception as exc:
        _dbg("disconnect", exc)


def _discover_cast(seconds):
    found = {}
    try:
        pychromecast = _import()
    except Exception as exc:
        _dbg("discover(cast) import", exc)
        return
    browser = None
    try:
        casts, browser = pychromecast.get_chromecasts(timeout=seconds)
        for cast in casts:
            info = cast.cast_info
            uuid = str(info.uuid)
            found[uuid] = {
                "kind": "cast",
                "name": _clean(info.friendly_name) or "Cast device",
                "host": info.host or "",
                "port": info.port or 8009,
                "model": _clean(info.model_name),
                "location": "",
            }
            _disconnect(cast)
    except Exception as exc:
        _dbg("discover(cast)", exc)
    finally:
        _stop_browser(browser)
    # Fresh mDNS results are proven alive — print them NOW, before the cache
    # re-verification below. Printing everything only at the end meant one
    # offline cached device (its 6 s connect timeout) could push this thread
    # past cmd_discover's join budget and the daemonized kill dropped even
    # the devices that had already been found.
    for uuid, dev in found.items():
        _out("DEV\tcast\t%s\t%s\t%s\t%s\t%s\t" % (
            uuid, dev["name"], dev["host"], dev["port"], dev["model"]))

    # mDNS is lossy — a device found last time but missed this round gets one
    # direct connection attempt, which either proves it alive or it really is
    # gone. This keeps the picker stable instead of flickering per round.
    # Verified in PARALLEL: each offline device costs its own connect timeout,
    # and serially two dead entries already blow the whole discovery budget.
    def verify_cached(uuid, dev):
        cast = None
        try:
            cast = _connect_host(pychromecast, dev["host"], dev["port"],
                                 uuid, dev.get("model", ""))
            with _cache_write_lock:
                found[uuid] = dev
            _out("DEV\tcast\t%s\t%s\t%s\t%s\t%s\t" % (
                uuid, dev["name"], dev["host"], dev["port"], dev["model"]))
        except Exception as exc:
            # Expected for a cached device that is offline right now.
            _dbg("verify-cache %s" % uuid, exc)
        finally:
            _disconnect(cast)

    verifiers = []
    for uuid, dev in _cache_load().items():
        if uuid in found or dev.get("kind") != "cast" or not dev.get("host"):
            continue
        t = threading.Thread(target=verify_cached, args=(uuid, dev))
        t.daemon = True
        t.start()
        verifiers.append(t)
    for t in verifiers:
        t.join(CONNECT_TIMEOUT + 1.0)
    # Snapshot under the lock: a verifier that outlived its join timeout may
    # still be inserting while _cache_save iterates.
    with _cache_write_lock:
        snapshot = dict(found)
    _cache_save(snapshot)


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
        try:
            cast = _connect_host(pychromecast, host, port, uuid, model)
        except Exception as exc:
            # Unreachable/off device — nothing is playing on it, so a quiet
            # DONE is the truth. FAIL is reserved for a stop that REACHED the
            # device and then raised (that one likely left it playing).
            _dbg("stop connect (device offline)", exc)
            _out(DONE)
            return
        # quit_app stops playback and returns the device to its idle backdrop,
        # freeing it for other apps — cleaner than a lingering paused receiver.
        cast.quit_app()
        _out(DONE)
    except Exception as exc:
        # A stop that raised on a reached device very likely left it playing —
        # a silent DONE would tell the UI otherwise, so the failure is visible.
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))
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


# ── DLNA / UPnP MediaRenderer ────────────────────────────────────────────────
# Pure standard library. A renderer is driven with two SOAP services from its
# device description XML: AVTransport (SetAVTransportURI/Play/Stop) and
# RenderingControl (SetVolume). Like Cast, the renderer pulls the stream URL
# itself, so nothing keeps running on this machine.

SSDP_ADDR = ("239.255.255.250", 1900)
ST_RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1"
_DEVNS = "{urn:schemas-upnp-org:device-1-0}"
AVT_SERVICE = "urn:schemas-upnp-org:service:AVTransport:1"
RC_SERVICE = "urn:schemas-upnp-org:service:RenderingControl:1"

# Well-known descriptor locations, probed directly as a fallback for setups
# where a local firewall drops SSDP replies (multicast responses create no
# conntrack entry, so default-deny firewalls eat them). Ports/paths cover the
# common stacks: Frontier Silicon radios (8080), Samsung TVs (9197), Sonos
# (1400), LG (1441..) and the generic UPnP default (49152).
KNOWN_DESCRIPTOR_PATHS = (
    ":8080/dd.xml",
    ":9197/dmr",
    ":1400/xml/device_description.xml",
    ":49152/description.xml",
    ":1441/",
)


def _local_ipv4_addrs():
    """The IPv4 address of every up interface — Linux ioctl, no dependencies.

    The kernel routes an un-pinned multicast send out ONE interface (the
    default route); on a machine with, say, ethernet plus a hotspot the
    speakers on the other network never hear the M-SEARCH. Best effort:
    any failure just means the plain default-route send below stands alone.
    """
    addrs = []
    probe = None
    try:
        import fcntl
        import struct
        # One throwaway socket serves every ioctl — it only exists to have
        # a file descriptor for SIOCGIFADDR.
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for _idx, name in socket.if_nameindex():
            try:
                packed = fcntl.ioctl(probe.fileno(), 0x8915,  # SIOCGIFADDR
                                     struct.pack("256s", name.encode()[:15]))
                addrs.append(socket.inet_ntoa(packed[20:24]))
            except OSError:
                continue  # no IPv4 on this interface (down, or v6-only)
    except Exception as exc:
        _dbg("iface enum", exc)
    finally:
        if probe is not None:
            try:
                probe.close()
            except Exception:
                pass
    return [a for a in addrs if not a.startswith("127.")]


def _msearch(st, wait, target=None):
    """One M-SEARCH round; returns a set of LOCATION URLs.

    target=None sends to the multicast group; otherwise unicast to one host
    (unicast replies pass stateful firewalls because the request created a
    conntrack entry).
    """
    locations = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    except OSError as exc:
        _dbg("msearch socket", exc)
        return locations
    try:
        s.settimeout(wait)
        msg = "\r\n".join([
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            'MAN: "ssdp:discover"',
            "MX: %d" % max(1, int(wait)),
            "ST: " + st,
            "", "",
        ]).encode()
        dest = (target, 1900) if target else SSDP_ADDR
        ifaddrs = []
        if not target:
            s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
            ifaddrs = _local_ipv4_addrs()
        # Some renderers (Bose, notably) miss the first datagram after idling;
        # a third send costs nothing and makes single-round discovery reliable.
        # The group send goes out once per interface (IP_MULTICAST_IF), plus
        # one un-pinned send for whatever the kernel would have picked anyway.
        for _ in range(3):
            for addr in ifaddrs:
                try:
                    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                                 socket.inet_aton(addr))
                    s.sendto(msg, dest)
                except OSError:
                    pass  # interface went away mid-round — the others still go
            s.sendto(msg, dest)
            time.sleep(0.15)
        end = time.time() + wait
        while time.time() < end:
            try:
                data, _addr = s.recvfrom(65507)
            except socket.timeout:
                break
            for line in data.decode("utf-8", "replace").split("\r\n"):
                if line.lower().startswith("location:"):
                    locations.add(line.split(":", 1)[1].strip())
    except OSError as exc:
        # A send failure (unreachable network, buffer pressure) just means no
        # results from this round — but the socket must not leak with it.
        _dbg("msearch %s" % (target or "multicast"), exc)
    finally:
        s.close()
    return locations


class _HttpOnlyRedirects(urllib.request.HTTPRedirectHandler):
    # The stdlib handler follows redirects to http, https AND ftp — a
    # hostile LAN device answering 302 ftp://10.0.0.5:2121/ would turn the
    # description fetch into an FTP probe of the attacker's choosing. The
    # declared http(s)-only invariant holds at every hop, not just the first.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme.lower() not in ("http", "https"):
            raise urllib.error.HTTPError(newurl, code,
                                         "redirect to non-http scheme refused",
                                         headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_HTTP_OPENER = urllib.request.build_opener(_HttpOnlyRedirects)


def _http_get(url, timeout=3.0, max_bytes=512 * 1024):
    # http(s) only: LOCATION comes from an unauthenticated SSDP reply, and
    # urllib's default opener would happily serve file:// or ftp:// — a
    # hostile LAN host must not be able to point the description parser at
    # local files.
    scheme = urllib.parse.urlsplit(url).scheme.lower()
    if scheme not in ("http", "https"):
        raise ValueError("unsupported scheme %r" % scheme)
    req = urllib.request.Request(url, headers={"User-Agent": "OnAir"})
    with _HTTP_OPENER.open(req, timeout=timeout) as resp:
        # Capped read: the socket timeout bounds each recv, not the total —
        # an endless body would otherwise buffer wholesale into RAM. No
        # device description has business being half a megabyte.
        data = resp.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise ValueError("description larger than %d bytes" % max_bytes)
        return data


def _describe_renderer(location):
    """Fetch+parse a device description; None unless it is a MediaRenderer."""
    try:
        root = ET.fromstring(_http_get(location))
    except Exception as exc:
        # The direct-probe fallback hits many dead ports by design — most of
        # these lines are the expected mass, but they are exactly what shows
        # WHICH addresses were tried when a renderer fails to appear.
        _dbg("describe %s" % location, exc)
        return None
    # URLBase is deprecated but still used by older stacks (e.g. Frontier
    # Silicon); without it relative control URLs resolve against the location.
    base = (root.findtext(_DEVNS + "URLBase") or "").strip() or location
    loc_host = urllib.parse.urlsplit(location).hostname
    for dev in root.iter(_DEVNS + "device"):
        if (dev.findtext(_DEVNS + "deviceType") or "").startswith(
                "urn:schemas-upnp-org:device:MediaRenderer:"):
            services = {}
            for svc in dev.iter(_DEVNS + "service"):
                stype = (svc.findtext(_DEVNS + "serviceType") or "").strip()
                curl = (svc.findtext(_DEVNS + "controlURL") or "").strip()
                if stype and curl:
                    resolved = urllib.parse.urljoin(base, curl)
                    # Control URLs stay pinned to the descriptor's host: a
                    # hostile URLBase/absolute controlURL would otherwise
                    # redirect SOAP POSTs to a third host (LAN SSRF, incl.
                    # 127.0.0.1 on this machine). Ports may differ — Frontier
                    # Silicon legitimately moves the port, never the host.
                    if urllib.parse.urlsplit(resolved).hostname != loc_host:
                        _dbg("describe %s cross-host controlURL" % location,
                             resolved)
                        continue
                    services[stype] = resolved
            avt = next((u for t, u in services.items()
                        if t.startswith("urn:schemas-upnp-org:service:AVTransport:")), None)
            if not avt:
                return None
            rc = next((u for t, u in services.items()
                       if t.startswith("urn:schemas-upnp-org:service:RenderingControl:")), None)
            return {
                "name": _clean(dev.findtext(_DEVNS + "friendlyName")) or "DLNA device",
                "model": _clean(dev.findtext(_DEVNS + "modelName")),
                # Defense in depth: the udn becomes the device key and, on the
                # QML side, reaches a shell sentinel. Strip it to the same
                # allowlist a real UDN already obeys so a hostile renderer
                # cannot smuggle shell metacharacters through it. The QML
                # boundary rejects anything that slips past this too.
                "udn": _udn_safe(_clean(dev.findtext(_DEVNS + "UDN"))),
                "avtransport": avt,
                "rendering": rc,
            }
    return None


def _parse_avahi(out):
    """Parse `avahi-browse -atrp` output into {IPv4: extra descriptor paths}.

    Bose publishes its device GUID in the TXT record, and its descriptor
    lives at :8091/<GUID>.xml — probing that is deterministic where its UDP
    replies are not.
    """
    candidates = {}
    for line in out.split("\n"):
        parts = line.split(";")
        if len(parts) > 9 and parts[0] == "=" and parts[2] == "IPv4":
            ip = parts[7]
            if ip.count(".") != 3 or ip.startswith("127."):
                continue
            extra = candidates.setdefault(ip, set())
            for token in parts[9].split('" "'):
                token = token.strip('"')
                if token.startswith("GUID="):
                    extra.add(":8091/%s.xml" % token[5:])
    return candidates


def _mdns_candidates():
    """Map of IPv4 -> extra descriptor paths for mDNS-visible devices.

    Renderers whose SSDP replies a firewall drops (or which sleep through
    M-SEARCH datagrams, like Bose soundbars) almost always advertise some
    service over mDNS, so their IPs make good direct-probe candidates.
    avahi-browse is optional; without it this fallback just yields nothing.
    NB: resolving can outlast the timeout — on expiry the PARTIAL output is
    kept (killing the process used to throw everything away, which made
    whole discovery rounds come back empty).
    """
    out = ""
    try:
        proc = subprocess.Popen(
            ["avahi-browse", "-atrp"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            out, _ = proc.communicate(timeout=3.5)
        except subprocess.TimeoutExpired as exc:
            _dbg("avahi-browse timeout (partial output kept)", exc)
            proc.kill()
            out, _ = proc.communicate()
    except Exception as exc:
        # Typically FileNotFoundError: avahi-browse is an optional helper.
        _dbg("avahi-browse", exc)
    return _parse_avahi(out or "")


# Devices seen in earlier rounds. SSDP/mDNS are lossy UDP and devices doze
# through queries, so any single round finds a random subset — but a KNOWN
# device can be re-verified with one direct TCP request, which either
# succeeds or the device is really offline. This is what makes the picker
# stable from the second use on.
CACHE_PATH = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "onair-cast-devices.json")
CACHE_MAX_AGE_S = 30 * 24 * 3600
# The cast and dlna threads both merge into the cache at the end of a round;
# read-merge-write must not interleave or one side's devices get lost.
_cache_write_lock = threading.Lock()


def _cache_load():
    try:
        with open(CACHE_PATH) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}  # first run — nothing cached yet, not worth a trace
    except Exception as exc:
        _dbg("cache-load", exc)
        return {}


def _cache_save(devices):
    """Merge this round's devices into the cache, drop long-unseen ones."""
    with _cache_write_lock:
        now = time.time()
        cache = _cache_load()
        for uuid, dev in devices.items():
            entry = dict(dev)
            entry["last_seen"] = now
            cache[uuid] = entry
        cache = {u: d for u, d in cache.items()
                 if now - d.get("last_seen", 0) < CACHE_MAX_AGE_S}
        try:
            cache_dir = os.path.dirname(CACHE_PATH)
            os.makedirs(cache_dir, exist_ok=True)
            # mkstemp instead of a fixed ".tmp": unpredictable name (no
            # symlink games in a shared /tmp-style dir) and 0600 from birth.
            # os.replace keeps the swap atomic; last writer wins as before.
            fd, tmp = tempfile.mkstemp(dir=cache_dir, prefix=".onair-cast-")
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w") as fh:
                    json.dump(cache, fh)
                os.replace(tmp, CACHE_PATH)
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
            # A hard kill between mkstemp and os.replace orphans a uniquely
            # named temp forever (the old fixed ".tmp" self-overwrote). Sweep
            # aged siblings; the 1 h guard spares a concurrent in-flight temp.
            for p in glob.glob(os.path.join(cache_dir, ".onair-cast-*")):
                try:
                    if now - os.path.getmtime(p) > 3600:
                        os.unlink(p)
                except OSError:
                    pass
        except Exception as exc:
            _dbg("cache-save", exc)


def _discover_dlna(seconds):
    deadline = time.time() + seconds
    locations = set()
    lock = threading.Lock()

    def collect(st, wait, target=None):
        found = _msearch(st, wait, target)
        if not found and target and time.time() + wait < deadline:
            # Idle renderers (Bose soundbars, notably) regularly sleep through
            # a whole M-SEARCH round; one retry makes discovery dependable.
            found = _msearch(st, wait, target)
        with lock:
            locations.update(found)

    threads = [
        threading.Thread(target=collect, args=(ST_RENDERER, min(3.0, seconds))),
        threading.Thread(target=collect, args=("ssdp:all", min(3.0, seconds))),
    ]
    # Firewall fallback: unicast M-SEARCH + well-known descriptor probes
    # against every mDNS-visible device.
    candidates = _mdns_candidates()
    # Known devices from earlier rounds re-verify with one direct TCP
    # request each — immune to the UDP lottery.
    cached = _cache_load()
    for dev in cached.values():
        loc = dev.get("location", "")
        if dev.get("kind") == "dlna" and loc:
            with lock:
                locations.add(loc)
    for ip in candidates:
        threads.append(threading.Thread(
            target=collect, args=(ST_RENDERER, min(2.5, seconds), ip)))

    def probe_known(ip, extra_paths):
        for suffix in list(extra_paths) + list(KNOWN_DESCRIPTOR_PATHS):
            url = "http://" + ip + suffix
            try:
                if _describe_renderer(url):
                    with lock:
                        locations.add(url)
                    return
            except Exception as exc:
                _dbg("probe %s" % url, exc)

    for ip, extra_paths in candidates.items():
        threads.append(threading.Thread(target=probe_known, args=(ip, extra_paths)))

    for t in threads:
        t.daemon = True
        t.start()
    for t in threads:
        t.join(max(0.1, deadline - time.time()))

    # The join above is bounded, so a straggler thread may still be adding
    # locations — snapshot under the lock or iteration can die mid-loop.
    with lock:
        found_locations = sorted(locations)

    # Describe every location in PARALLEL and print each renderer the moment
    # it proves alive. The serial loop paid up to 3 s per dead cached URL —
    # entries that happened to sort first starved live renderers of the
    # remaining budget, and everything after the kill was silently dropped.
    fresh = {}
    fresh_lock = threading.Lock()

    def describe_loc(loc):
        dev = _describe_renderer(loc)
        if not dev:
            return
        entry = {
            "kind": "dlna",
            "name": dev["name"],
            "host": urllib.parse.urlsplit(loc).hostname or "",
            "port": 0,
            "model": dev["model"],
            "location": loc,
        }
        # A renderer without a UDN (bare-bones firmware) falls back to its
        # descriptor URL as identity — the empty string used to collide
        # every such device into one cache slot and one menu row.
        # No UDN: derive a stable key the QML allowlist accepts — the
        # descriptor URL itself contains '/' and was rejected wholesale,
        # so UDN-less renderers never appeared in the menu at all.
        key = dev["udn"] or ("loc-%s" % hashlib.sha1(loc.encode()).hexdigest()[:16])
        with fresh_lock:
            if key in fresh:
                return
            fresh[key] = entry
        _out("DEV\tdlna\t%s\t%s\t%s\t%s\t%s\t%s" % (
            key, dev["name"], entry["host"], 0, dev["model"], loc))

    describers = [threading.Thread(target=describe_loc, args=(loc,))
                  for loc in found_locations]
    for t in describers:
        t.daemon = True
        t.start()
    # The describe phase gets a floor of its own: the collectors above run
    # right up to the shared deadline, and handing the leftovers to this
    # join used to give it 0.1 s — every renderer the search DID find was
    # then dropped undescribed. One descriptor fetch is bounded at 3 s, so
    # 2.5 s covers the parallel batch without doubling the whole budget.
    describe_by = max(deadline, time.time() + 2.5)
    for t in describers:
        t.join(max(0.1, describe_by - time.time()))
    # Snapshot under the lock — a describer that outlived its join may still
    # be inserting while _cache_save iterates.
    with fresh_lock:
        snapshot = dict(fresh)
    _cache_save(snapshot)


def _soap(control_url, service_type, action, args_xml, timeout=5.0):
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        "<s:Body><u:%s xmlns:u=\"%s\">%s</u:%s></s:Body></s:Envelope>"
    ) % (action, service_type, args_xml, action)
    # http.client instead of urllib: urllib normalizes header names to
    # Capitalized-Form and sends "Soapaction:" — embedded UPnP stacks that
    # match the header name case-sensitively (against the HTTP spec, but
    # common in cheap renderer firmware) then reject every command.
    parts = urllib.parse.urlsplit(control_url)
    if parts.scheme == "https":
        conn = http.client.HTTPSConnection(parts.hostname, parts.port or 443,
                                           timeout=timeout)
    else:
        conn = http.client.HTTPConnection(parts.hostname, parts.port or 80,
                                          timeout=timeout)
    try:
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        payload = body.encode("utf-8")
        conn.putrequest("POST", path)
        conn.putheader("Content-Type", 'text/xml; charset="utf-8"')
        conn.putheader("SOAPACTION", '"%s#%s"' % (service_type, action))
        conn.putheader("User-Agent", "OnAir")
        conn.putheader("Content-Length", str(len(payload)))
        conn.endheaders()
        conn.send(payload)
        resp = conn.getresponse()
        # Same cap rationale as _http_get: a SOAP reply is a few KB, and a
        # dripping or endless body must not hold the helper's memory open.
        data = resp.read(512 * 1024).decode("utf-8", "replace")
        # Parity with urlopen: a SOAP fault (HTTP 500 etc.) must raise, the
        # callers' except blocks turn it into FAIL sentinels / fallbacks.
        # >= 300 because http.client does not follow redirects — a 3xx here
        # would otherwise pass as a silent bogus success.
        if resp.status >= 300:
            raise urllib.error.HTTPError(control_url, resp.status,
                                         data[:200], resp.headers, None)
        return data
    finally:
        conn.close()


# DLNA.ORG_PN profile tokens. Several renderers (Frontier Silicon based
# radios like Ruark/Roberts, notably) reject a bare "http-get:*:type:*"
# protocolInfo with UPnP error 716 but accept the same stream with the
# profile named; others ignore the token. Types without a universal profile
# fall back to the wildcard fourth field.
_DLNA_PN = {
    "audio/mpeg": "DLNA.ORG_PN=MP3",
    "audio/aac": "DLNA.ORG_PN=AAC_ADTS",
}


def _didl_metadata(title, ctype, url, art=""):
    """Raw (unescaped) DIDL-Lite for one radio stream.

    Both tested renderer families require the stream URL REPEATED inside
    <res> (SetAVTransportURI with metadata whose res is empty fails with
    error 716 "Resource not found") — CurrentURI alone is not enough.

    The optional artwork is emitted as <upnp:albumArtURI> only when it is an
    http(s) URL the renderer can actually fetch (a file:// sidecar could not
    reach the TV, and would only risk confusing a strict renderer).
    """
    proto = "http-get:*:%s:%s" % (ctype or "audio/mpeg",
                                  _DLNA_PN.get(ctype or "audio/mpeg", "*"))
    art_el = ""
    if art and art.startswith(("http://", "https://")):
        art_el = "<upnp:albumArtURI>%s</upnp:albumArtURI>" % escape(art)
    return (
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="onair-radio" parentID="-1" restricted="1">'
        "<dc:title>%s</dc:title>"
        "<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>"
        "%s"
        '<res protocolInfo="%s">%s</res>'
        "</item></DIDL-Lite>"
    ) % (escape(title or "On Air"), art_el, escape(proto), escape(url or ""))


def _dlna_set_uri_and_play(avt, url, didl, cdata):
    """One SetAVTransportURI+Play round with the metadata packed either as
    CDATA or XML-escaped."""
    meta = "<![CDATA[%s]]>" % didl if cdata else escape(didl)
    _soap(avt, AVT_SERVICE, "SetAVTransportURI",
          "<InstanceID>0</InstanceID><CurrentURI>%s</CurrentURI>"
          "<CurrentURIMetaData>%s</CurrentURIMetaData>" % (escape(url), meta))
    _soap(avt, AVT_SERVICE, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")


def cmd_dlna_play(location, url, ctype, title, art=""):
    try:
        dev = _describe_renderer(location)
        if not dev:
            _out("%s renderer description unavailable" % FAIL)
            return
        avt = dev["avtransport"]
        # A renderer that is already playing something may reject a new URI;
        # Stop first and ignore the result (stopped/idle devices error here).
        try:
            _soap(avt, AVT_SERVICE, "Stop", "<InstanceID>0</InstanceID>", timeout=3.0)
        except Exception as exc:
            _dbg("dlna-play pre-stop (expected on idle devices)", exc)
        didl = _didl_metadata(title, ctype, url, art)
        # CDATA first: Frontier Silicon renderers (Ruark, Roberts…) silently
        # DISCARD an escaped-metadata URI and then fail Play with 705
        # "Transport is locked" — CDATA is the only packing they play from.
        # Renderers that dislike CDATA get the spec-compliant escaped form
        # on the retry.
        try:
            _dlna_set_uri_and_play(avt, url, didl, cdata=True)
        except Exception as exc:
            _dbg("dlna-play cdata form, retrying escaped", exc)
            _dlna_set_uri_and_play(avt, url, didl, cdata=False)
        _out(OK)
    except Exception as exc:
        # Leave the renderer idle rather than stuck in a half-open session
        # (Frontier Silicon radios switch source on the incoming URI and
        # would otherwise sit in an empty "Music player" screen).
        try:
            _soap(dev["avtransport"], AVT_SERVICE, "Stop",
                  "<InstanceID>0</InstanceID>", timeout=3.0)
        except Exception as exc2:
            _dbg("dlna-play cleanup-stop", exc2)
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))


def cmd_dlna_stop(location):
    # No descriptor = the device is off or gone, so nothing is playing — DONE.
    dev = _describe_renderer(location)
    if not dev:
        _out(DONE)
        return
    try:
        _soap(dev["avtransport"], AVT_SERVICE, "Stop", "<InstanceID>0</InstanceID>")
    except urllib.error.HTTPError as exc:
        # A SOAP fault is the documented answer of an already-idle renderer to
        # Stop — the same class cmd_dlna_play deliberately swallows. Nothing is
        # playing, so DONE, not a misleading FAIL.
        _dbg("dlna-stop fault (idle renderer)", exc)
    except Exception as exc:
        # Descriptor answered but the control URL did not — the renderer may
        # still be streaming, so surface the failure rather than a quiet DONE.
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))
        return
    _out(DONE)


def cmd_dlna_volume(location, level):
    try:
        vol = int(round(max(0.0, min(1.0, float(level))) * 100))
        dev = _describe_renderer(location)
        if not dev or not dev["rendering"]:
            _out("%s no RenderingControl" % FAIL)
            return
        _soap(dev["rendering"], RC_SERVICE, "SetVolume",
              "<InstanceID>0</InstanceID><Channel>Master</Channel>"
              "<DesiredVolume>%d</DesiredVolume>" % vol)
        _out(OK)
    except Exception as exc:
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))


# Volume READS back the device's current level so the group-volume balance
# can adopt it: a device joining the group keeps the loudness it already has
# (its level/master ratio becomes its balance) instead of jumping to the
# master level on the first slider move.

def cmd_get_volume(host, port, uuid, model):
    try:
        pychromecast = _import()
    except Exception:
        _out(NO_LIB)
        return
    cast = None
    try:
        cast = _connect_host(pychromecast, host, port, uuid, model)
        # wait() in _connect_host has already pulled a status; volume_level
        # is 0.0–1.0 and covers speaker groups too (the group's own level).
        _out("%s %.3f" % (VOL, max(0.0, min(1.0, float(cast.status.volume_level)))))
    except Exception as exc:
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))
    finally:
        _disconnect(cast)


def cmd_dlna_get_volume(location):
    try:
        dev = _describe_renderer(location)
        if not dev or not dev["rendering"]:
            _out("%s no RenderingControl" % FAIL)
            return
        data = _soap(dev["rendering"], RC_SERVICE, "GetVolume",
                     "<InstanceID>0</InstanceID><Channel>Master</Channel>")
        m = re.search(r"<CurrentVolume>\s*(\d+)", data)
        if not m:
            _out("%s no CurrentVolume in reply" % FAIL)
            return
        _out("%s %.3f" % (VOL, max(0.0, min(1.0, int(m.group(1)) / 100.0))))
    except Exception as exc:
        _out("%s %s" % (FAIL, str(exc).replace("\n", " ")[:200]))


# ── entry points ─────────────────────────────────────────────────────────────

def cmd_probe():
    try:
        _import()
        has_cast = 1
    except Exception:
        has_cast = 0
    # DLNA needs nothing beyond the standard library, so the bridge is always
    # usable — the flag only tells the UI whether Cast devices can appear.
    _out("%s cast=%d" % (OK, has_cast))


def cmd_discover(seconds):
    threads = [
        threading.Thread(target=_discover_cast, args=(seconds,)),
        threading.Thread(target=_discover_dlna, args=(seconds,)),
    ]
    for t in threads:
        t.daemon = True
        t.start()
    for t in threads:
        t.join(seconds + 4.0)
    _out(DONE)


def _alarm_bail(signum, frame):
    # No _out here: it takes _out_lock, and the interrupted main thread may
    # be holding it — the one mechanism meant to end a wedged helper must
    # not be able to wedge with it. Raw write, hard exit.
    try:
        os.write(1, ("%s helper timed out\n" % FAIL).encode())
    except OSError:
        pass
    os._exit(1)


def main():
    if len(sys.argv) < 2:
        _out("%s usage: cast.py <command>" % FAIL)
        return
    # Total-duration backstop (reader.py's own rationale): socket timeouts
    # bound each recv, not the conversation — a renderer dripping one byte
    # per second held the helper and its command open forever. Ninety
    # seconds outlives the longest legitimate discovery round.
    if hasattr(signal, "SIGALRM"):
        signal.signal(signal.SIGALRM, _alarm_bail)
        signal.alarm(90)
    command = sys.argv[1]
    args = sys.argv[2:]
    if command == "probe":
        cmd_probe()
    elif command == "discover":
        seconds = DEFAULT_DISCOVERY_SECONDS
        if args:
            try:
                seconds = max(1.0, min(15.0, float(args[0])))
            except ValueError as exc:
                _dbg("discover seconds arg", exc)
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
    elif command == "dlna-play" and len(args) >= 3:
        cmd_dlna_play(args[0], args[1], args[2],
                      args[3] if len(args) > 3 else "",
                      args[4] if len(args) > 4 else "")
    elif command == "dlna-stop" and len(args) >= 1:
        cmd_dlna_stop(args[0])
    elif command == "dlna-volume" and len(args) >= 2:
        cmd_dlna_volume(args[0], args[1])
    elif command == "get-volume" and len(args) >= 4:
        cmd_get_volume(args[0], args[1], args[2], args[3])
    elif command == "dlna-get-volume" and len(args) >= 1:
        cmd_dlna_get_volume(args[0])
    else:
        _out("%s bad arguments" % FAIL)


if __name__ == "__main__":
    main()
