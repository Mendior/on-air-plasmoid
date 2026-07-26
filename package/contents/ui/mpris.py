#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""MPRIS2 DBus bridge for the On Air plasmoid.

The plasmoid spawns this script as a background daemon.
Communication is bidirectional via files:
  * State file (plasmoid -> daemon): JSON describing playback state.
  * Command file (daemon -> plasmoid): newline-separated commands
    (Play, Pause, PlayPause, Stop, Next, Previous).

Each command line includes a unique sequence number so the plasmoid
can poll and only react to new commands.
"""
import json
import os
import re
import signal
import sys
import threading
from pathlib import Path

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

# The public MPRIS name: what `playerctl -l` and media controls list.
# Renamed from the inherited "advancedradio" to match the published id —
# scripts that matched the old substring need the new one.
BUS_NAME = "org.mpris.MediaPlayer2.onair"
# The command file must not grow unbounded — QML reads the whole file on every event.
CMD_FILE_MAX_BYTES = 8192
OBJ_PATH = "/org/mpris/MediaPlayer2"
ROOT_IF = "org.mpris.MediaPlayer2"
PLAYER_IF = "org.mpris.MediaPlayer2.Player"
PROP_IF = "org.freedesktop.DBus.Properties"


class MPRISBridge(dbus.service.Object):
    def __init__(self, bus_name, state_file: Path, cmd_file: Path):
        super().__init__(bus_name, OBJ_PATH)
        self.state_file = state_file
        self.cmd_file = cmd_file
        self.cmd_seq = 0
        self._last_mtime_ns = -1
        self._lock = threading.Lock()
        self._state = {
            "status": "Stopped",
            "station": "",
            "artist": "",
            "title": "",
            "art": "",
            "volume": 0.75,
            "canGoNext": False,
            "canGoPrevious": False,
            "canPlay": False,
            "canPause": False,
        }
        self._track_seq = 0
        self._tracker_path = f"{OBJ_PATH}/Track/0"

    def update_from_state_file(self):
        # mtime gate: this runs every 300 ms for the whole session — reading
        # and JSON-parsing an unchanged file that often is pointless work.
        try:
            mtime_ns = self.state_file.stat().st_mtime_ns
        except OSError:
            return
        if mtime_ns == self._last_mtime_ns:
            return
        try:
            new_state = json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            # A read that raced the writer mid-truncate: do NOT consume the
            # mtime — the finished write can land within the same clock tick,
            # and committing here would make the poll skip it forever.
            return
        self._last_mtime_ns = mtime_ns

        changed_player = {}
        with self._lock:
            for key, value in new_state.items():
                if self._state.get(key) != value:
                    self._state[key] = value
                    changed_player[key] = value
            if "title" in changed_player or "artist" in changed_player:
                # A new track gets a new mpris:trackid — clients that diff
                # Metadata by trackid would otherwise treat the whole session
                # as one long track. Digits only, so the path stays valid.
                self._track_seq += 1
                self._tracker_path = f"{OBJ_PATH}/Track/{self._track_seq}"

        if not changed_player:
            return

        prop_changes = dbus.Dictionary({}, signature="sv")
        if "status" in changed_player:
            prop_changes["PlaybackStatus"] = dbus.String(self._state["status"], variant_level=1)
        if any(k in changed_player for k in ("station", "artist", "title", "art")):
            prop_changes["Metadata"] = dbus.Dictionary(self._build_metadata(), signature="sv", variant_level=1)
        if "volume" in changed_player:
            prop_changes["Volume"] = dbus.Double(float(self._state["volume"]), variant_level=1)
        if any(k in changed_player for k in ("canGoNext", "canGoPrevious", "canPlay", "canPause")):
            prop_changes["CanGoNext"] = dbus.Boolean(bool(self._state["canGoNext"]), variant_level=1)
            prop_changes["CanGoPrevious"] = dbus.Boolean(bool(self._state["canGoPrevious"]), variant_level=1)
            prop_changes["CanPlay"] = dbus.Boolean(bool(self._state["canPlay"]), variant_level=1)
            prop_changes["CanPause"] = dbus.Boolean(bool(self._state["canPause"]), variant_level=1)

        if prop_changes:
            self.PropertiesChanged(PLAYER_IF, prop_changes, dbus.Array([], signature="s"))

    def _build_metadata(self):
        meta = dbus.Dictionary({}, signature="sv")
        meta["mpris:trackid"] = dbus.ObjectPath(self._tracker_path, variant_level=1)
        title = self._state.get("title") or self._state.get("station") or " "
        meta["xesam:title"] = dbus.String(title, variant_level=1)
        album = self._state.get("station") or " "
        meta["xesam:album"] = dbus.String(album, variant_level=1)
        artist = self._state.get("artist") or ""
        if artist:
            meta["xesam:artist"] = dbus.Array([artist], signature="s", variant_level=1)
        art = self._state.get("art") or ""
        if art:
            meta["mpris:artUrl"] = dbus.String(art, variant_level=1)
        return meta

    def _emit_command(self, cmd: str):
        with self._lock:
            self.cmd_seq += 1
            line = f"{self.cmd_seq}\t{cmd}\n"
        print(f"[mpris] cmd #{self.cmd_seq}: {cmd}", flush=True)
        try:
            # Rotation: if the file has grown past the limit, start fresh —
            # seq numbers keep increasing, so the QML filter won't replay old commands.
            mode = "a"
            try:
                if self.cmd_file.stat().st_size > CMD_FILE_MAX_BYTES:
                    mode = "w"
            except OSError:
                pass
            with open(self.cmd_file, mode, encoding="utf-8") as f:
                f.write(line)
                f.flush()
        except OSError as exc:
            print(f"[mpris] write error: {exc!r}", flush=True)

    @dbus.service.method(ROOT_IF)
    def Raise(self):
        return None

    @dbus.service.method(ROOT_IF)
    def Quit(self):
        return None

    @dbus.service.method(PLAYER_IF)
    def Play(self):
        print("[mpris] Play() called", flush=True)
        self._emit_command("Play")

    @dbus.service.method(PLAYER_IF)
    def Pause(self):
        print("[mpris] Pause() called", flush=True)
        self._emit_command("Pause")

    @dbus.service.method(PLAYER_IF)
    def PlayPause(self):
        print("[mpris] PlayPause() called", flush=True)
        self._emit_command("PlayPause")

    @dbus.service.method(PLAYER_IF)
    def Stop(self):
        print("[mpris] Stop() called", flush=True)
        self._emit_command("Stop")

    @dbus.service.method(PLAYER_IF)
    def Next(self):
        print("[mpris] Next() called", flush=True)
        self._emit_command("Next")

    @dbus.service.method(PLAYER_IF)
    def Previous(self):
        print("[mpris] Previous() called", flush=True)
        self._emit_command("Previous")

    @dbus.service.method(PLAYER_IF, in_signature="x")
    def Seek(self, offset):
        return None

    @dbus.service.method(PLAYER_IF, in_signature="ox")
    def SetPosition(self, track_id, position):
        return None

    @dbus.service.method(PLAYER_IF, in_signature="s")
    def OpenUri(self, uri):
        return None

    @dbus.service.method(PROP_IF, in_signature="ss", out_signature="v")
    def Get(self, interface_name, property_name):
        return self._get_prop(interface_name, property_name)

    @dbus.service.method(PROP_IF, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface_name):
        with self._lock:
            if interface_name == ROOT_IF:
                return self._root_props()
            if interface_name == PLAYER_IF:
                return self._player_props()
        return {}

    @dbus.service.method(PROP_IF, in_signature="ssv")
    def Set(self, interface_name, property_name, value):
        if interface_name != PLAYER_IF:
            return
        if property_name == "Volume":
            try:
                vol = max(0.0, min(1.0, float(value)))
            except (TypeError, ValueError):
                return
            self._emit_command(f"Volume {vol:.3f}")

    @dbus.service.signal(PROP_IF, signature="sa{sv}as")
    def PropertiesChanged(self, interface_name, changed_props, invalidated_props):
        pass

    def _root_props(self):
        return dbus.Dictionary({
            "CanQuit": dbus.Boolean(False, variant_level=1),
            "CanRaise": dbus.Boolean(False, variant_level=1),
            "HasTrackList": dbus.Boolean(False, variant_level=1),
            "Identity": dbus.String("On Air", variant_level=1),
            # Icon lookup hint for media controls. Plasma 6 generates no
            # .desktop file for plasmoids, so this is a soft reference either
            # way — kept aligned with the published package id.
            "DesktopEntry": dbus.String("plasma-applet-io.github.mendior.onair", variant_level=1),
            "SupportedUriSchemes": dbus.Array([], signature="s", variant_level=1),
            "SupportedMimeTypes": dbus.Array([], signature="s", variant_level=1),
        }, signature="sv")

    def _player_props(self):
        return dbus.Dictionary({
            "PlaybackStatus": dbus.String(self._state.get("status", "Stopped"), variant_level=1),
            "LoopStatus": dbus.String("None", variant_level=1),
            "Rate": dbus.Double(1.0, variant_level=1),
            "Shuffle": dbus.Boolean(False, variant_level=1),
            "Metadata": dbus.Dictionary(self._build_metadata(), signature="sv", variant_level=1),
            "Volume": dbus.Double(float(self._state.get("volume", 0.75)), variant_level=1),
            "Position": dbus.Int64(0, variant_level=1),
            "MinimumRate": dbus.Double(1.0, variant_level=1),
            "MaximumRate": dbus.Double(1.0, variant_level=1),
            "CanGoNext": dbus.Boolean(bool(self._state.get("canGoNext", False)), variant_level=1),
            "CanGoPrevious": dbus.Boolean(bool(self._state.get("canGoPrevious", False)), variant_level=1),
            "CanPlay": dbus.Boolean(bool(self._state.get("canPlay", False)), variant_level=1),
            "CanPause": dbus.Boolean(bool(self._state.get("canPause", False)), variant_level=1),
            "CanSeek": dbus.Boolean(False, variant_level=1),
            "CanControl": dbus.Boolean(True, variant_level=1),
        }, signature="sv")

    def _get_prop(self, interface_name, property_name):
        with self._lock:
            if interface_name == ROOT_IF:
                props = self._root_props()
            elif interface_name == PLAYER_IF:
                props = self._player_props()
            else:
                props = {}
        if property_name in props:
            return props[property_name]
        # Spec-correct error reply: a None return is not marshallable as a
        # variant, so clients saw a generic failure instead of the real cause.
        raise dbus.exceptions.DBusException(
            f"Unknown property {interface_name}.{property_name}",
            name="org.freedesktop.DBus.Error.UnknownProperty")


def main():
    if len(sys.argv) < 3:
        sys.exit("Usage: mpris.py <state_file> <cmd_file> [host_pid]")
    state_path = Path(sys.argv[1])
    cmd_path = Path(sys.argv[2])
    try:
        host_pid = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    except ValueError:
        host_pid = 0

    cmd_path.parent.mkdir(parents=True, exist_ok=True)
    cmd_path.write_text("")

    print(f"[mpris] starting state={state_path} cmd={cmd_path}", flush=True)
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    print("[mpris] got session bus", flush=True)
    # Unique bus name per instance (MPRIS allows the .instanceN suffix) —
    # two plasmoid instances no longer fight over the same name.
    instance_id = re.sub(r"\D", "", state_path.stem) or str(os.getpid())
    bus_name_str = f"{BUS_NAME}.instance{instance_id}"
    try:
        bus_name = dbus.service.BusName(
            bus_name_str,
            bus,
            do_not_queue=True,
            replace_existing=True,
        )
        print(f"[mpris] acquired bus name {bus_name_str}", flush=True)
    except dbus.DBusException as exc:
        sys.exit(f"Failed to acquire MPRIS bus name: {exc}")

    bridge = MPRISBridge(bus_name, state_path, cmd_path)
    print("[mpris] bridge initialised", flush=True)
    loop = GLib.MainLoop()

    def poll_state():
        try:
            bridge.update_from_state_file()
        except Exception as exc:
            print(f"[mpris] poll error: {exc!r}", flush=True)
        return True

    GLib.timeout_add(300, poll_state)

    # Self-termination watchdog: if the hosting process (plasmashell /
    # plasmoidviewer) is gone, there is nobody left to serve — exit cleanly
    # and remove our files instead of polling as an orphan until next login.
    # (A normal restart replaces us via the launcher anyway; this covers the
    # crash path, where no teardown ever runs.)
    if host_pid > 1:
        def watch_host():
            try:
                os.kill(host_pid, 0)
            except ProcessLookupError:
                print(f"[mpris] host pid {host_pid} is gone — exiting", flush=True)
                for p in (state_path, cmd_path):
                    try:
                        p.unlink()
                    except OSError:
                        pass
                loop.quit()
                return False
            except PermissionError:
                pass  # exists but owned elsewhere (pid reuse) — treat as alive
            return True

        GLib.timeout_add_seconds(5, watch_host)

    print("[mpris] entering main loop", flush=True)

    def handle_signal(signum, frame):
        loop.quit()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, handle_signal)

    try:
        loop.run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
