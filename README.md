# On Air 📻

**A beautiful internet radio widget for KDE Plasma 6** — worldwide station search, one-click track downloads, offline library, media keys, and a 2026-grade UI.

![On Air](screenshots/onair.png)

## Features

- 🎨 **Modern 2026 UI** — animated aurora backdrop, spinning vinyl fallback art, cascading list animations, LIVE & bitrate pills, pulsing equalizers, emerald accent design
- 🌍 **Worldwide station search** — type a country name ("Finland") or genre ("jazz") and discover stations from the radio-browser.info catalogue (~50 000 stations). Click to preview, ⭐ to keep
- 🎵 **Live track info** — artist & title from ICY metadata or the Qt FFmpeg backend, with album art lookup (iTunes/Deezer)
- ⬇ **One-click track downloads** — grab the song that's playing right now at maximum quality (original audio, no re-encoding) via `yt-dlp`. Optional AI title cleanup via Claude CLI
- 📚 **My Music** — built-in offline library page for your downloaded tracks
- 🕐 **Recently played history** — the last 30 tracks with timestamps; download a song you missed half an hour ago
- ⏰ **Sleep timer** with progress ring and gentle 30-second fade-out
- 🎹 **MPRIS integration** — media keys and the Plasma media controls just work
- 🔊 Auto-bitrate upgrade, scroll-wheel volume, keyboard navigation (`/`, arrows, Space, M, Esc), mini-equalizer on the panel icon

## Requirements

- **KDE Plasma 6** (any distribution: Kubuntu, Fedora KDE, openSUSE, Arch/CachyOS, Manjaro…)
- Qt 6 Multimedia with the FFmpeg backend (default on most distros)

Optional (features degrade gracefully without them):

| Package | Enables |
|---|---|
| `python-requests` | ICY track titles on streams the Qt backend can't read |
| `python-dbus`, `python-gobject` | MPRIS media keys / media controls |
| `yt-dlp` + `ffmpeg` | Track downloads |
| `inotify-tools` | Zero-polling MPRIS command channel |
| `claude` (Claude Code CLI) | Optional AI cleanup of messy radio titles |

## Install

**From KDE Store (recommended):** right-click your desktop or panel → *Add Widgets* → *Get New Widgets* → search **On Air**, or get it from the [KDE Store page](https://store.kde.org/p/2364623).

**Manual:**
```bash
kpackagetool6 --type Plasma/Applet --install package
# or from the release file:
kpackagetool6 --type Plasma/Applet --install on-air-2026.1.plasmoid
```

## Usage tips

- **Click** a search result to preview it — **⭐** adds it to your stations & favorites
- **Hover** a station row for the ⭐ and 🗑 buttons (removal asks twice — no accidents)
- **Scroll** on the volume button or the panel icon to change volume
- The **⬇ button** on the now-playing page downloads the current track to `~/Music/OnAir`
- The **folder button** in the footer opens **My Music** — your offline library and play history

## Credits & License

**On Air** (2026 edition) by **Egon Greenberg** — new UI, bug fixes, worldwide search, downloads, offline library, MPRIS/metadata engine.

Based on [Advanced Radio Player](https://store.kde.org/p/1972502) by **Yuri Saurov**.

Licensed under **LGPL-2.0-or-later**. See [LICENSE](LICENSE).
