# Changelog

## 2026.11

Every local speaker at once, stations that follow their streams when they move, and a cast/Bluetooth layer gone over with a fine-tooth comb.

- **All local outputs, in sync.** A new switch in the cast menu plays through every local output at the same time — wired speakers are delayed to match Bluetooth (PipeWire's latency compensation), so multi-speaker listening stops echoing. Costs a fraction of a percent of CPU while active, nothing when off. Network devices can't join: they buffer on their own schedule and expose no latency control — for Cast-to-Cast sync, a Google Home speaker group already appears here as one device.
- **Self-healing stations.** Stations change servers and the saved URL rots as a dead entry. When playback of a list station fails, the widget now looks the station up on radio-browser.info (whose own probes know which addresses work right now) and auditions the best match — exact name beats a contains-match, same domain beats everything. Only an address that actually buffers replaces the dead one, with a notification saying the station moved. One lookup per station per ten minutes, previews and local files never heal, off-switch next to the bitrate option.
- **Cover art: no more grey silhouettes.** Deezer returns a valid-looking placeholder URL for artists without a photo, and it was being cached as a real cover for the whole session. Placeholder URLs are rejected on every field now, so the art chain ends in a real image or the station logo.
- **A speaker-subsystem audit fixed seventeen bugs.** The ones you might have hit: stopping while casting also stops an instant recording; checking a device after a stop no longer autoplays the last station; a local file is no longer silenced for a device that cannot play it; devices checked while idle all start when playback begins, not just the newest; the volume slider leaves merely-selected idle devices alone; the device menu merges scan results instead of clearing, so the checked row of a playing device no longer vanishes mid-scan; the cast button's second click actually closes the menu, and Esc works there now; a Bluetooth speaker that reconnected on its own is routed to immediately instead of never; disconnecting a device disarms its pending auto-route; the "output disappeared" notification no longer fires on Bluetooth profile-switch flicker; one powered-off speaker no longer stalls the whole device discovery (cache re-verification and DLNA descriptions run in parallel); and SOAP commands keep their exact header case for the case-sensitive renderer firmware out there.
- **Hung helpers can't strand the widget anymore.** Every bluetoothctl call and yt-dlp run under hard time caps — a wedged bluez daemon used to freeze the Bluetooth menu for the whole session, and one stalled download blocked every future one.
- **The smoke test now proves the widget actually loads.** plasmoidviewer in CI had no containment to load the applet into, so the runtime check had been green while checking nothing. The widget now logs a load marker that the gate requires (with the full viewer output printed on failure), and CI installs plasma-desktop so there is something to load into.

## 2026.10.2

- **Device discovery no longer plays the lottery.** SSDP and mDNS run over UDP, and idle devices routinely sleep through a query — so each opening of the cast menu used to find a different subset of your speakers and TVs. Devices seen before are now remembered (30 days) and re-verified with one direct request each, which either proves them alive or they really are offline; six consecutive scans on a real five-device network now return the identical list. Also fixed the mDNS helper throwing away all of its output when listing took longer than the timeout — partial results are kept now.

## 2026.10.1

- Hovering the panel icon now shows what's playing — artist and title, with the station name underneath — instead of the stock widget name and description. While casting, the tooltip also says which device is playing. Requested by @CGA11 in issue #4. When nothing plays, the tooltip stays as before.

## 2026.10

Cover art that actually shows up, Bluetooth speakers in the cast menu, and a safety net of tests under the whole thing.

- **Cover art is far more reliable.** Four separate causes, all fixed:
  - A failed lookup (timeout, rate limit, network blip) was remembered as "this track has no art" for the whole session — and radio repeats its playlist, so one bad moment kept a track coverless all day. Only a real "no match" answer is cached now, and even that is retried after half an hour.
  - Lookups now go to Deezer first, one request at a time — station zapping no longer trips iTunes' strict rate limit (which answers 403 and used to poison the cache, see above).
  - Titles separated with "–", "—" or " / " now split into artist and title properly, and bitrate junk like "128 kbps" is stripped from search queries. This also fixes those tracks in the play history and the media controls.
  - When an artwork URL turns out broken (404, dead image), the widget now falls back to the station image or logo instead of pinning the vinyl placeholder.
- **Bluetooth speakers, one click.** The cast menu lists your paired Bluetooth audio devices with their connection state. Click one to connect — playback moves to it as soon as the system registers the speaker (matched by device address, so it can't grab the wrong output). Click again to disconnect; failures show a notification instead of nothing. Pairing new devices still lives in System Settings.
- **Speaker groups and multi-room, honestly.** Devices ticked separately each buffer the stream on their own, so rooms can play a few seconds apart — that's inherent to Cast/DLNA live radio and no player can fix it. For perfectly synced speakers, group them in the Google Home app: the group appears in the cast menu as a single device (now labeled as a speaker group) and plays sample-accurate everywhere. The menu explains this when you pick multiple devices; the README has the full story.
- If your chosen output device disappears mid-play (speaker off, HDMI unplugged), the widget now tells you it fell back to the system default instead of switching silently. Deliberately choosing "System default output" stays silent.
- Un-ticking and quickly re-ticking the same cast device could leave it playing — the second, identical stop command was silently dropped by the command runner. Every cast command is now unique.
- The station list no longer disables itself on systems where Qt cannot determine the network state (it stayed "offline" forever and blocked all playback); only a definite "disconnected" counts as offline now. Station logos also re-sync once a stream actually starts playing, which covers those systems after login.
- DLNA discovery hardening: the device list is snapshotted under its lock, and the discovery socket is closed deterministically on error paths.
- Under the hood: a unit-test suite for the Python helpers (argv dispatch, ICY field extraction, DLNA descriptor parsing), new lint rules distilled from past regressions, CI on every push — including a real QML load test on a current Plasma 6 stack — and a written release checklist (RELEASING.md).

## 2026.9.1

- New translations: French, Italian and Dutch — complete catalogs, no partial ones, same as the rest. That makes 11 languages.

## 2026.9

Casting grew up: multi-room, Bluetooth outputs and a proper off switch.

- **The cast menu now uses checkboxes** — tick several devices and the station plays on all of them at once. Unticking a device stops that device (previously, switching devices left the old one playing with no way to silence it from the widget — reported the same day 2026.8.1 shipped). "Stop casting everywhere" does what it says.
- **"This computer" is part of the same list**: it uncheckes itself when you pick the first network device (no PC talking over the TV), and you can tick it back for whole-house listening — local playback plus every selected device.
- **Pick the local output right in the menu** — headphones, HDMI or a paired Bluetooth speaker. The choice is remembered; if the Bluetooth speaker disconnects, playback falls back to the system default instead of going silent.
- **Frontier Silicon radios (Ruark, Roberts…) now actually play.** These renderers silently discard a stream pushed with spec-escaped metadata and then refuse to start ("Transport is locked"); packing the same metadata as CDATA makes them play — verified on a Ruark R5se, from standby too. Other renderers still get the spec-compliant form as a fallback. A failed push also no longer strands the radio in an empty "Music player" screen.
- Volume and station switches now reach every selected device, and one unreachable device no longer tears down casting on the rest.

## 2026.8.1

- Fixed the cast menu showing blank rows: the device list gained a field named `model` in 2026.8, which shadowed the delegate's own model object in QML, so device names stopped rendering. Renamed the field and switched the delegate to per-role properties. Caught minutes after release; the 2026.8 casting backend itself was fine.

## 2026.8

Casting now covers far more than Chromecast.

- **Cast to any DLNA/UPnP device** — smart TVs (Samsung, LG, Sony…), soundbars (Bose, Sonos…), AV receivers and WiFi speakers now show up in the cast menu next to Cast devices. Same model as before: the stream URL is handed to the device, which decodes and buffers it itself, so your computer does no audio work while casting.
- DLNA casting is built entirely on the Python standard library — **no new dependencies**. The cast button now appears even without `python-chromecast`; that package is only needed for Chromecast/Nest devices to show up.
- Discovery got more robust along the way: renderers that sleep through the first multicast query (some soundbars do) are found via a retried direct query, and setups where a local firewall eats SSDP replies fall back to probing mDNS-visible devices directly. Verified against a Bose Smart Soundbar 900, a Samsung Q-series TV and a Chromecast-based TV on a real network.
- Known limit, honestly stated: some Frontier Silicon based radios (Ruark, Roberts…) advertise DLNA but refuse pushed streams while idle; the widget reports "could not cast" instead of failing silently. AirPlay-only devices (Apple TV, HomePod) are not supported — Linux has no lightweight way to stream to them without pairing and a persistent transcoding process, which would defeat the low-CPU design.

## 2026.7.3

- Emergency fix: 2026.7.2 failed to load at all ("Type FullRepresentation unavailable"). The My Music fix in that release nested a `Connections` element inside `FolderListModel`, which has no default property, so the whole popup failed to parse. If you installed 2026.7.2, update immediately — nothing else changed in this release.

## 2026.7.2

- **My Music no longer lists your home directory on a fresh install** (issue #3, thanks @ChimanaTech). Until the first download created `~/Music/OnAir`, the folder didn't exist — and Qt's folder model silently falls back to the process working directory when that happens, which under plasmashell is your home. So the page showed whatever audio files were lying around in `$HOME`, and freshly downloaded tracks (saved to the real folder) never appeared there. The library folder is now created up front and the page only ever reads from it.

## 2026.7.1

- Casting actually casts now. The widget was invoking its cast helper without the command word, so playing to a device (and the device volume/stop calls) failed with "bad arguments" while discovery worked — which made it look tantalizingly close. Caught within hours of the release; the whole chain has now been verified end to end against a real device on the local network.

## 2026.7

The casting release.

### New — cast to Chromecast, Nest and Cast-enabled TVs
- **Send the radio to a Cast device.** A new cast button on the Now Playing page lists the Chromecasts, Nest speakers and Cast-enabled TVs on your network; pick one and the station plays there. Pick *This computer* to bring it back.
- **It's genuinely light on your PC.** The stream URL is handed to the device, which does all the decoding and buffering itself — your computer stops decoding audio entirely while casting. On an older or low-powered machine that's a real, measurable drop in CPU and memory use, not just a convenience.
- Volume and station switching stay in the widget and drive the device; stopping playback frees the device for other apps.
- Needs the `python-chromecast` package. Without it the cast button simply doesn't appear — nothing else changes. No Cast device is ever contacted unless you open the cast menu yourself.

### Fixed
- The station-name marquee in the settings list now repeats on hover as intended.
- The "Server status" line in the settings search info dialog no longer fails to render the last-checked time (a stray undefined reference).

## 2026.6

Reordering and translations — the two most-wished-for conveniences.

### New — reorder your stations right in the popup
- **Stations can finally be reordered without opening the settings.** Hover (or keyboard-focus) a row and use the new up/down arrows — or press **Ctrl+Up / Ctrl+Down**. Works in the main list and in the favorites view.
- **Favorites keep their own order.** The favorites view now follows the order of your favorites list itself, not the main list's — move your morning station to the top and it stays there. (Your existing favorites keep the order they were added in until you move something.)
- Reordering never interrupts playback, and the arrows hide while a search filter is active — moving rows in a filtered list would reorder things you can't see.

### New — translations
- On Air now speaks **Estonian, German, Polish, Ukrainian, Spanish, Brazilian Portuguese and Swedish** (English remains the source language). All 205 strings, no partial catalogs.
- Groundwork included: string extraction is scripted, so future releases can keep the catalogs complete.

### Fixed
- **The station search in settings can no longer hang on "Please wait…" forever.** QML silently ignores the XMLHttpRequest timeout everyone assumed was working — every network timeout in the settings pages was dead code. They now use a real watchdog that aborts the request, so a dead mirror rotates to the next one instead of hanging the page. Same fix for the logo fetcher.
- A superseded station search no longer keeps retrying in the background alongside the new one (a subtle double-query bug in the same code path).
- A stream error no longer throws away your keyboard position in the station list.
- Two settings messages inherited from the original applet had typos (one even contained a Cyrillic letter С that looked like a Latin C) — cleaned up.

## 2026.5.1

- **Much lower CPU while playing (issue #2).** The mini equalizer on the panel icon ran continuous animations for the whole playback session, keeping the window repainting at the full display refresh rate — the main reason plasmashell could sit at ~10% CPU while the radio played. The bars are now driven by ~8 discrete updates per second (they read like a real spectrum meter), and they stop ticking entirely while the panel is hidden. All equalizer instances (panel icon, station list, Now Playing) share the saving.

## 2026.5

Reliability release: recordings now tell the truth, scheduled recordings survive interruptions, and a handful of long-standing everyday annoyances are gone.

### Fixed — recording honesty
- **"Recording saved ✓" no longer lies.** Previously the only check was "the file is not empty" — a recording cut short by a dying stream or a full disk was still reported as a success. The widget now looks at ffmpeg's actual exit code, whether the recording ran its full length, and whether the file size is plausible for its duration. A capture that ended early is reported as **"Recording interrupted (12:34 captured)"** — you keep the partial file, but you know it's partial.
- **Interrupted scheduled recordings resume.** A schedule entry used to be moved to its next occurrence the moment recording *started* — so if the stream died five minutes into a two-hour show, that was it: the rest of the window was silently thrown away. The entry now advances only after the recording actually finishes; if it's interrupted mid-window, the widget picks it back up within 30 seconds and records the remainder. "Missed" is only reported when the whole window has truly closed, and repeat notifications for the same occurrence are deduplicated.

### Fixed — everyday annoyances
- **The sleep timer now keeps wall-clock time.** It used to count timer ticks, which simply pause while the machine is suspended — "sleep in 30 minutes", a 20-minute suspend, and the radio played 20 minutes longer than asked. The timer now targets a fixed deadline, so it fires when it should even across suspend/resume (and if the deadline passed during sleep, it stops immediately on wake, with the fade shortened to whatever time is left).
- **Your volume finally sticks.** Adjusting the volume (wheel, slider, media controls, mute toggle) only lasted until the next stop — then it snapped back to the setting from the config dialog. The level you set is now remembered and used everywhere the volume gets reset. Mute is deliberately not remembered: unmuting brings back the last audible level instead of starting silent.

### Fixed — fewer writes, fewer leftovers
- **Track history no longer rewrites your config file on every song.** With the radio on all day, that was hundreds of small disk writes for a nice-to-have list. History is now saved at most once every 30 seconds, and always flushed when the popup closes or the widget goes away.
- **The MPRIS helper cleans up after a Plasma crash.** If plasmashell died, its media-keys daemon kept polling as an orphan until the next login. The daemon now watches its hosting process and exits cleanly (removing its runtime files) when that process is gone. It also stopped re-reading its state file 3× per second when nothing changed — a small but permanent background saving.

## 2026.4

Widget resizing fixed (#1), four dead default stations replaced, and a stability/accessibility round across the whole codebase.

### Fixed — widget resizing (issue #1)
- **The widget can now actually be resized — and it stays resized.** A hardcoded maximum size (~576×648 px) silently clamped every enlarge attempt back, which looked exactly like "it always returns to its original size". Thanks to @Driglu4it for the report. The only limit now is your screen.
- Bonus: extra height you drag out goes into the cover art on Now Playing.
- Shrinking the popup below the natural height of the Now Playing page now scrolls the page instead of clipping the playback buttons out of reach.

### Fixed — default stations
- Four of the twenty bundled stations had quietly died over the years: *Radio Mirchi* (404), *#1980s Zoom* (403), *.977 Country* (403) and *NRJ* (a hanging connection that never errored out). All four now point to live, stable streams — the streamtheworld ones via the permanent redirector instead of a hardcoded edge node that expires. Every bundled station was probe-tested. (Only fresh installs are affected; your own station list is never touched.)

### Fixed — playback & MPRIS
- Removing the widget (or toggling MPRIS off) could leave its state/command files and helper processes behind: the cleanup command killed its own shell mid-chain. Teardown is now split into independent commands, with a delayed second sweep for restart races.
- A missing command file no longer sends the media-keys watcher into a tight process-respawn loop (the file is created up front, and instant failures back off to one retry per second).
- With two widget instances, a startup cleanup sweep could kill the healthy neighbour's daemon after a rare file race; it now requires the instance's whole file pair to be gone.
- If the MPRIS daemon can't start at all (python-dbus or PyGObject missing), the launcher now reports it — previously the daemon just died into /dev/null and media keys were silently dead. Daemon output goes to a small per-instance log now.
- A local track that plays to its end no longer stays in the header as a stale "now playing".
- Play (button or Space) after previewing a search result or playing a local file works as a proper toggle again, and the station list highlights the right row. Middle-click "play last station" on the panel icon recovers from the same situation.
- Starring a web search result while the radio is playing no longer silently stops the music — playback resumes once the list is updated.
- REC can no longer be started during the ~0.4 s stop fade (such a recording used to survive the stop and run until its duration cap). Track titles also recover properly after an automatic bitrate fallback.

### Fixed — security & data safety
- The "Downloading:" label was the one remaining place that rendered a stream-controlled string as rich text — a malicious station could inject HTML there. Plain text now, like everywhere else.
- Web search results are only accepted with http(s) URLs — defence in depth for everything a stream URL later touches (player, saved config, ffmpeg).
- "Re-fetch all" station logos no longer wipes a hand-entered logo URL when the lookup finds nothing better.
- The stations backup export no longer goes through `echo`, which corrupts backslash escapes on some shells.
- Track titles that genuinely start or end with an apostrophe (*'39*, *Rockin'*) are no longer mangled by the ICY parser.
- The metadata reader now has a real OS-level runtime cap — a slow-drip stream could previously keep it downloading for hours past its supposed 20-second limit. And if python-requests isn't installed, it says so once instead of crash-respawning six times per station start.

### Accessibility
- Station rows, My Music files, history entries and the panel icon now announce themselves to screen readers; the per-row delete and favorite buttons are keyboard-reachable (they used to exist only on mouse hover).
- The volume popup is fully keyboard-operable (arrow keys adjust in 5% steps, Esc closes and returns focus); the scheduler form fields have accessible labels.
- The global Space/M shortcuts stay quiet while a text field or spinner has focus.

### Settings, UI & packaging
- The automatic highest-bitrate switch is now a visible setting (Settings → Appearance) instead of a hidden config key.
- The recording scheduler's Add button now explains when a source can't be recorded (HLS/playlists) instead of doing nothing.
- The REC and download pulse animations no longer burn CPU while the popup is closed.
- Six dead config keys inherited from the original applet were removed, and the `.plasmoid` package now ships the LGPL license text it always should have.

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

### Fixed — station logos now load reliably
- Station logos are downloaded **once** into a persistent disk cache (`~/.cache/onair-favicons/`) and always shown from there — instant after every Plasma restart, offline included. Previously they lived only in process memory and re-downloaded (or silently failed) on every restart.
- Downloads use a full browser User-Agent — some hosts rejected Qt's bare default UA with 403, so those logos never appeared at all.
- Failed downloads are retried (once per day, and whenever the network comes back up — the post-login race was the main reason logos "sometimes" vanished); every cached file is validated as a real image, and a corrupted cache entry self-heals by falling back to the remote URL.

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
