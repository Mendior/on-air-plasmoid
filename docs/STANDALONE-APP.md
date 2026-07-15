# On Air as a standalone app (Kirigami + Flatpak)

The widget only reaches Plasma users. A standalone app of the same code
reaches every Linux desktop through Flathub — and later Windows and Android,
because Kirigami builds there too. This is the plan; the widget stays, the
two share the code.

## Why Flatpak can't ship the plasmoid directly

A plasmoid is an extension loaded INTO plasmashell, not a process of its
own. Flatpak ships applications. So the path is: extract the UI into a
shared QML module, add a thin Kirigami shell around it, package THAT.

## Architecture

```
src/
  shared/           ← everything that exists today, made host-agnostic
    NowPlaying.qml, StationList.qml, CastMenu.qml, …
    cast.py, reader.py, calibrate.py (unchanged)
  plasmoid/         ← thin wrapper: PlasmoidItem + panel icon + Plasmoid.configuration
  app/              ← thin wrapper: Kirigami.ApplicationWindow + system tray
    main.cpp        ← QApplication, KConfig, QProcess bridge
```

Host-specific seams (the only things the shared code may not touch
directly):

| Today (plasmoid)             | Abstraction              | App implementation      |
|------------------------------|--------------------------|-------------------------|
| `Plasmoid.configuration.*`   | `Config` singleton       | KConfig                 |
| `P5Support.DataSource` exec  | `Exec.run(cmd, sentinel)`| QProcess (C++, ~100 loc)|
| panel icon / tooltip         | `Host.trayHint(...)`     | KStatusNotifierItem     |
| popup show/hide              | `Host.visible`           | main window             |

Everything else — stations, playback, casting, Bluetooth, sync,
calibration, likes, recording, downloads — is already plain QML+Python and
moves into `shared/` as-is.

## Phases

1. **Seam extraction** (in the plasmoid, no user-visible change): route all
   `Plasmoid.configuration` reads/writes and `executable.exec` calls through
   two singletons. Gate: `dev.sh check` stays green, widget behaves
   identically. This is the risky step, so it ships alone.
2. **Kirigami shell**: `app/` with a window, tray icon, MPRIS (the daemon
   already exists), KConfig-backed Config. Gate: the app plays radio,
   casts, records on a GNOME session.
3. **Flatpak manifest**: `org.kde.Platform` runtime, bundle python deps
   (requests, pychromecast) in the sandbox, `--socket=pulseaudio`
   `--share=network` `--device=dri`; test click/vote/cast/BT from inside
   the sandbox (bluetoothctl needs `--socket=system-bus` + portal care —
   degrade gracefully where the sandbox says no).
4. **Flathub submission**: appstream metainfo, screenshots, OARS. Examples
   to crib from: NeoChat, Kasts, Tokodon (all Kirigami, all on Flathub).

## Effort and order

Phase 1 ≈ two evenings, 2 ≈ a week of evenings, 3-4 ≈ a weekend plus
review round-trips. Nothing here blocks widget releases; `shared/` is a
move, not a rewrite. Start after the current feature wave has had a quiet
release or two.

## Verified in the sandbox (2026-07-15)

The plan's biggest unknown is settled. On a real machine (CachyOS,
pipewire-pulse protocol v35), inside `org.freedesktop.Platform//24.08`
with nothing but `--socket=pulseaudio`:

```
pactl load-module module-null-sink sink_name=onair_sandbox_test   → loaded
pactl load-module module-loopback source=…monitor latency_msec=120 → loaded
pactl list short sinks                                             → visible
pactl unload-module …                                              → clean
```

The whole SyncEngine premise — null sink + per-speaker delayed loopbacks
driven over the pulse socket — works from inside a Flatpak sandbox as-is.
The sandbox bind-mounts the host's native pulse socket and pipewire-pulse
applies no module-loading restriction to it. Phase 2's risk budget just
shrank to the bluetoothctl/system-bus question; corrections to the audit
notes: use `--system-talk-name=org.bluez` (a blanket `--socket=system-bus`
gets rejected in Flathub review), and `cast.py` needs no pychromecast
bundling for DLNA (pure stdlib) — only the optional Chromecast path and
reader.py's optional `requests` want extras.
