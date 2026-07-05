# Changelog

## 2026.3

The recording release — plus 24 bug fixes from a second deep audit.

### New: Stream recording ⏺
- **One-click REC** on the Now Playing page captures the live stream to `~/Music/OnAir` as a **bit-exact copy** (`ffmpeg -c copy`, no re-encoding — original quality). The file appears in My Music immediately.
- **Scheduled recordings**: record a show once, daily or weekly (station + start time + duration) — works even while nothing is playing. If the widget starts mid-window (e.g. after a reboot), it records the remainder instead of skipping.
- A `.tracks.txt` sidecar logs the track titles with timestamps while you record — no lossy per-track splitting.
- Clear indicators everywhere: red `● REC` timer in the footer, a recording bar with a stop button on My Music, a pulsing red dot on the panel icon, desktop notifications when a recording is saved.
- **Format choice** (Settings → Recording): *Original stream* (bit-exact, recommended), *MP3* (high-quality VBR re-encode for device compatibility) or *WAV* (uncompressed for editing). An MP3 stream recorded "as MP3" is kept bit-exact instead of being re-encoded.
- Safety by design: one recording at a time, a hard duration cap (Settings → Recording, default 3 h) so a forgotten recording can never fill the disk, and orphan cleanup after a Plasma crash.
- *Recordings are for personal use only — do not redistribute them.* The feature does not circumvent any copy protection (plain public HTTP/ICY streams).

### Fixed — playback & engine
- A delayed auto-bitrate lookup could hijack a just-started local file (or a removed station's neighbour) and restart the radio — all direct-start paths now invalidate in-flight lookups.
- Stop is now truly final: a pending bitrate-fallback can no longer restart playback ~0.6 s after an explicit stop.
- Media-key commands can no longer get stuck for minutes in a rare MPRIS wakeup race; two widget instances no longer kill each other's daemon at startup.
- `'::'` in track titles rendered correctly again (a trailing-whitespace trim ate the protocol separator).
- A transient network error no longer permanently disables track titles for the session; malformed ICY headers (negative/huge metaint) are rejected safely.

### Fixed — security & robustness
- Station names and track titles are now always rendered as plain text — a malicious station could previously inject HTML (including remote image loading) into the UI.
- The download-finished detector now uses a unique command sentinel, so a track title containing tool text can no longer confuse it.
- Station URLs containing an apostrophe no longer break the metadata reader.

### Fixed — My Music & settings
- `~/...` in the download folder setting is now expanded (downloads no longer land in a literal `~` directory).
- Files with `#` or `?` in the name play correctly; names like "Mr. Brightside.mp3" are no longer shown as "Mr".
- Renaming a station in settings no longer silently drops its favorite mark; removing one of two stations with the same URL deletes the right one; empty-URL entries can no longer be added.
- Adding a station from the popup (⭐) while the settings window is open is no longer lost on Apply.
- The station search in settings no longer hangs on "Please wait…" if a mirror returns a bad response; Clear Results always restores the default list.

### Fixed — keyboard & UI
- The numpad Enter key now works everywhere Return does; Esc returns from My Music to the station list instead of closing the popup.
- Web search results are now keyboard-focusable and screen-reader accessible, with a visible focus ring.
- Screen-reader activation of toggle buttons works correctly (Toggle action handled).
- The default popup is now tall enough to show the complete Now Playing page on a fresh install.
- Short country codes ("uk") work in the web search; the "Searching the web…" indicator no longer disappears mid-retry.

## 2026.2

Hardening & polish release, based on a full code audit.

### Security
- **Track-title AI cleanup is now sandboxed.** The untrusted ICY stream title is passed to the optional `claude` CLI via stdin with `--allowedTools "" --strict-mcp-config`, so a malicious station name can no longer trigger any tool/command execution.

### Accessibility
- Custom round buttons are now exposed to screen readers (Orca) and are keyboard-reachable (Tab) and activatable (Space/Enter), with a visible focus ring.

### Fixes
- **MPRIS:** `Stop`/`Pause` no longer start playback — only `PlayPause` toggles.
- **MPRIS:** state/command files and the D-Bus bus name now derive from the stable per-applet id instead of a timestamp — no more orphaned "ghost" media entries after a Plasma restart, and two widget instances no longer collide.
- **Downloads:** a missing `yt-dlp` now shows a clear "yt-dlp is not installed" message instead of a confusing generic error.

### New settings (now exposed in the config UI)
- **Follow system accent color** — opt in to recolor the whole UI with your Plasma accent instead of the built-in emerald theme (off by default).
- Download **format** (best / mp3 / opus / mp4), download **folder**, and the optional **title cleanup** toggle are now all configurable from Settings.

### Housekeeping
- All source comments translated to English.
- Cleaned up package metadata (license, authors, removed stale localized descriptions); default download folder is `~/Music/OnAir`.

## 2026.1

First public release. Modern animated UI, worldwide station search (radio-browser.info), live track info with album art, one-click track downloads (yt-dlp) with an offline library, recently-played history, MPRIS media keys, sleep timer, and more. Based on Advanced Radio Player by Yuri Saurov.
