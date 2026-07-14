# On Air 📻

**A beautiful internet radio widget for KDE Plasma 6** — worldwide station search, one-click track downloads, offline library, media keys, and a 2026-grade UI.

![On Air](screenshots/onair.png)

## Features

- 🎨 **Modern 2026 UI** — animated aurora backdrop, spinning vinyl fallback art, cascading list animations, LIVE & bitrate pills, pulsing equalizers, emerald accent design
- 🌍 **Worldwide station search** — type a country name ("Finland") or genre ("jazz") and discover stations from the radio-browser.info catalogue (~50 000 stations). Click to preview, ⭐ to keep
- 🎵 **Live track info** — artist & title from ICY metadata or the Qt FFmpeg backend, with album art lookup (iTunes/Deezer)
- ⏺ **Stream recording** — one click records the station you're listening to as a bit-exact copy (no re-encoding), straight into your library, with a track-list sidecar. **Scheduled recordings** capture a show once, daily or weekly — even while nothing is playing
- ⬇ **One-click track downloads** — grab the song that's playing right now at maximum quality (original audio, no re-encoding) via `yt-dlp`. Optional AI title cleanup via Claude CLI
- 📚 **My Music** — built-in offline library page for your downloaded tracks and recordings
- 🕐 **Recently played history** — the last 30 tracks with timestamps; download a song you missed half an hour ago
- ⏰ **Sleep timer** with progress ring and gentle 30-second fade-out
- ⏰ **Wake-up alarms** — wake to a station of your choice, once, daily or weekly, at your volume; a built-in chime takes over if the station can't start, and the widget can keep the computer awake until it's time
- 🎹 **MPRIS integration** — media keys and the Plasma media controls just work
- 📺 **Cast to TVs, soundbars & network speakers** — Chromecast/Nest and any DLNA renderer (Samsung/LG/Sony TVs, Bose/Sonos soundbars, WiFi speakers). The stream goes straight to the device, which does the decoding, so your PC stays quiet and cool (a real help on older machines). Volume and station switching stay in the widget. DLNA needs no extra packages at all. Google Home speaker groups appear as one device and play in perfect sync
- 🎧 **Bluetooth speakers, one click — pairing included** — paired devices are listed right in the cast menu, and "Pair a new speaker…" finds nearby ones and pairs, trusts and connects them in a single click; playback moves over as soon as the system picks the speaker up
- 🔊 **All local outputs, in sync** — one switch plays through every local speaker at once, with real per-output buffer delays and a live fine-tune slider, so nothing echoes; works on PipeWire and plain PulseAudio alike. Each speaker carries its own balance, can play stereo, left, right or a mono mix (two speakers on L and R make a true stereo pair), and any speaker can sit an evening out with one tick — all remembered per device
- 🎤 **Microphone auto-calibration** — one button plays clicks through each speaker and the microphone does the rest: the Bluetooth lag is timed and set automatically, and every speaker's loudness is matched at the listening position — both remembered per device
- 👍 **Thank the stations** — a vote button and anonymous listening clicks (station id only, on by default, one switch in settings turns them off) feed the radio-browser.info rankings, so the stations you love become easier to find for everyone; ❤️ saves songs to a local liked list
- 🩹 **Self-healing stations** — when a saved station's stream dies because it moved servers, the widget finds its current address on radio-browser.info; a move on the station's own domain is saved, anything else plays as a session-only backup so nothing in the directory can rewrite your list
- ↕️ **Reorder stations right in the list** — hover arrows or Ctrl+Up/Down, in the main list and in favorites, without interrupting playback
- 🌐 **11 languages** — English, French, German, Italian, Dutch, Spanish, Brazilian Portuguese, Polish, Ukrainian, Swedish, Estonian
- 🔊 Auto-bitrate upgrade, scroll-wheel volume, keyboard navigation (`/`, arrows, Space, M, Esc), mini-equalizer on the panel icon

## Requirements

- **KDE Plasma 6** (any distribution: Kubuntu, Fedora KDE, openSUSE, Arch/CachyOS, Manjaro…)
- Qt 6 Multimedia with the FFmpeg backend (default on most distros)

Optional (features degrade gracefully without them):

| Package | Enables |
|---|---|
| `python-requests` | ICY track titles on streams the Qt backend can't read |
| `python-dbus`, `python-gobject` | MPRIS media keys / media controls |
| `ffmpeg` | Stream recording (instant + scheduled) |
| `yt-dlp` + `ffmpeg` | Track downloads |
| `inotify-tools` | Zero-polling MPRIS command channel |
| `python-chromecast` (pychromecast) | Cast to Chromecast / Nest devices (DLNA TVs and speakers work without it) |
| `claude` (Claude Code CLI) | Optional AI cleanup of messy radio titles |

## Install

**From KDE Store (recommended):** right-click your desktop or panel → *Add Widgets* → *Get New Widgets* → search **On Air**, or get it from the [KDE Store page](https://store.kde.org/p/2364623).

**Manual:**
```bash
kpackagetool6 --type Plasma/Applet --install package
# or from the release file:
kpackagetool6 --type Plasma/Applet --install on-air-2026.16.plasmoid
```

## Usage tips

- **Click** a search result to preview it — **⭐** adds it to your stations & favorites
- **Hover** a station row for the ⭐, 🗑 and ↑/↓ reorder buttons (removal asks twice — no accidents); Ctrl+Up/Down moves the focused row
- In the **favorites view** the arrows reorder your favorites list itself — your order, not the main list's
- **Scroll** on the volume button or the panel icon to change volume
- The **⬇ button** on the now-playing page downloads the current track to `~/Music/OnAir`
- The **folder button** in the footer opens **My Music** — your offline library and play history

## Multi-room playback and sync

Ticking several devices in the cast menu plays the same station everywhere, but each device pulls and buffers the stream on its own — so separately-picked rooms typically sit a few seconds apart. That offset is inherent to how Cast and DLNA handle live radio (neither protocol exposes latency control for live streams), so no player can line them up perfectly.

**For perfectly synced speakers**, create a speaker group in the **Google Home app** from your Cast-capable devices. Google keeps group members clock-synced to the sample, and the group shows up in the cast menu as a single device — pick it and every speaker in it plays as one.

A Bluetooth speaker adds its own 100–300 ms of codec latency on top, so it can never be in exact sync with network devices either.

*Roadmap:* true whole-home sync across mixed devices (DLNA + Bluetooth + local) would need a [Snapcast](https://github.com/badaix/snapcast)-style timestamped-audio server — a separate project, noted here so it isn't forgotten.

## Recording

- Press the **⏺ REC button** on the now-playing page to record the station you're listening to. Press again to stop. The recording is a bit-exact stream copy (original quality) saved to `~/Music/OnAir`, with a `.tracks.txt` file listing the songs and their timestamps.
- **Scheduled recordings** live on the **My Music page** (the stopwatch button): pick a station, a start time, a duration and *once / daily / weekly* — the widget records it in the background, even if you're not listening. A red dot on the panel icon shows when a recording is running.
- One recording runs at a time, and every recording has a hard length cap (Settings → *Recording*, default 3 hours) so a forgotten REC can't fill your disk.
- **Format** (Settings → *Recording*): *Original stream* (bit-exact copy — recommended; radio streams are already compressed, so this IS the maximum quality), *MP3* (high-quality re-encode for maximum device compatibility) or *WAV* (uncompressed PCM for editing — very large files, no quality gain).
- **Personal use only.** Recording internet radio for your own, non-commercial use is a recognised private-copy exception in the EU (Directive 2001/29/EC art. 5(2)(b)) and many other jurisdictions, and these public streams carry no copy protection that would be circumvented. Do **not** share, upload or commercially exploit recordings — that is outside the exception. You are responsible for complying with the laws of your country.

## Credits & License

**On Air** (2026 edition) by **Egon Greenberg** — new UI, bug fixes, worldwide search, downloads, offline library, MPRIS/metadata engine.

Based on [Advanced Radio Player](https://store.kde.org/p/1972502) by **Yuri Saurov**.

Licensed under **LGPL-2.0-or-later**. See [LICENSE](LICENSE).

*Note: the track download and stream recording features are tools provided as-is, intended for personal use only; users are responsible for complying with local laws and the terms of the services they use.*
