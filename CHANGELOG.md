# Changelog

## 2026.19

The audit release. A deep line-by-line review swept every subsystem — alarms, search, sync, calibration, casting, translations — and each claim was independently challenged before anything was touched. What survived is this release: three critical fixes, a calibration that measures in fractions of a millisecond, and a sync that proves itself with the microphone instead of asking to be believed.

- **A hardware-muted microphone no longer turns the feature off.** A mic's own mute button — the touch pad on a desk mic — is pure DSP inside the microphone: every software flag says "not muted" while the capture delivers exact zeros forever (measured live, five flat seconds of it). The calibration and the check now probe the microphone before spending forty seconds of clicks against a deaf ear: a dead or monitor default hands the measurement to the first microphone that provably hears the room (the webcam next to a muted desk mic, credited by name in the result), and only when every microphone is silent does the run stop — immediately, with a verdict that points at the mute light instead of vaguely blaming the room. Bench-proven end to end: with the desk mic touch-muted, the run hands itself to the webcam and lands the lag with both loudness levels in hand.
- **Calibration survives a loud room now.** Bench-tested against a second room — a fan-loud desktop under a sensitive studio microphone, where the noise floor sits an order of magnitude above the quiet bench it was built on — the clicks at the polite 55 % park drowned and every run ended in "no click heard". Three changes close that: the matched filter's amplitude bar now scales with its confidence (a burst it recognizes unmistakably no longer needs to shout eight times over the floor), an inaudible round automatically retries once with the speakers parked louder before giving up, and the check-measure rides at known levels end to end — combined output at acoustic passthrough, balances at full, members at the calibration's own park — instead of whatever the evening left behind. Measured there and then: a run that always failed now lands the Bluetooth lag at 259 ms with both loudness levels in hand, and the deployed-path check caught the room audibly 434 ms out of step where the old thresholds would have called noise an answer — a fabricated verdict that used to feed straight back into the stored lags.
- **An unplugged speaker can no longer silence the morning.** The wake-up alarm's fallback chime trusted the optimistic "casting" flag, set the moment the play command left — a bedroom speaker powered off overnight still looked healthy, the local side stayed muted by design, and the alarm ended in total silence. Cast delivery is now trusted only once a device actually acknowledges the stream (the alarm forces a fresh acknowledgement even for the same station), and an unconfirmed route hands the morning to the built-in chime. Which, second fix, now **loops until someone says "I'm up"** — it is 32 seconds long and used to play exactly once.
- **The alarm's volume is a guest, not a tenant.** The wake-up volume floor used to overwrite the saved volume permanently; it is now a one-shot override that retires on stop, on a manual station pick, or the moment the user touches the volume themselves. And the floor finally reaches cast devices too — a bedroom speaker left whisper-quiet at bedtime would have "woken" nobody.
- **Schedules heal instead of playing dead.** An alarm or recording entry with a mangled schedule used to sit in the list looking armed and never fire; it now recomputes itself from its own wall-clock fields. Two alarms landing on the same tick no longer lose the quiet one silently, a system time-zone change re-anchors every schedule to the wall clock, and "keep the computer awake" holds 12-hour handovers instead of pinning a laptop awake for six days over one Monday alarm.
- **Search stopped gambling.** Three of the five hard-coded directory mirrors no longer resolve at all, and four different features picked one at random with no second attempt — the thumb-up worked "sometimes", the bitrate upgrade was a lottery. Every directory call now fails over through one shared chain, live mirrors first. Genre search finally works (the search field always suggested "jazz"; the query only ever matched names — a tag pass now fills in after the name matches), a network failure honestly says so instead of claiming "no matching stations", and the settings browser no longer skips a page forever after one timeout.
- **Calibration grew up.** The click detector now cross-correlates against the exact burst it played — sub-millisecond arrivals instead of a peak search that wandered in room noise. Every speaker in the group gets its own measured lag (a USB DAC or an HDMI TV used to be assumed instantaneous; they are not), a saturated microphone is reported with the fix instead of silently storing a wrong balance, and one truncated recording costs one measurement, not the whole run.
- **The sync proves itself.** After every successful calibration the widget now clicks through the live combined output and measures, at the microphone, how far apart the room actually arrives — "Sync verified: every speaker within N ms" when it holds, an honest "still N ms apart" when it does not. Presence is checked speaker by speaker first, so a muted or dead speaker fails the check loudly instead of hiding inside a small spread of the survivors.
- **Balances stopped evaporating mid-flight.** A balance slider moved while the sync was still building (or rebuilding) its plumbing was saved but never heard — in one case the volume command went to an audio module that was being torn down at that very moment. Both build acknowledgements now reconcile the room to the stored balances. The Bluetooth join watchdog also queues a second connecting speaker instead of silently abandoning the first, and a lost connection-cycle can no longer freeze the watchdog for the whole session.
- **The sleep timer and the media keys reach cast devices.** Cast-only playback kept the local player idle by design — and the sleep timer counted to zero while the bedroom speaker played all night, media keys did nothing, and the media applet showed "Stopped". All three now treat a casting session as what it is: playing.
- **Device discovery hears every network.** The speaker search went out on one network interface only (the default route) — ethernet-plus-hotspot setups never saw the other side's speakers. It now knocks on every interface, found devices are no longer dropped undescribed when the search itself ran long, and renderers without a UPnP identity stop colliding into one menu row.
- **The settings tabs speak your language — for the first time.** The four category names (Stations, Appearance, Recording, Search) had never entered the translation catalogs; they were English in all eleven languages since the first release. Weekday names, unit suffixes and six glued-together sentences joined the catalogs too, and every language ships complete: 313 of 313 strings.
- **Privacy is opt-in now.** The anonymous listening click to radio-browser.info and the AI track-title cleanup both shipped enabled; anything that leaves the machine should be the user's explicit call, so both now default to off. A choice already made either way is kept.
- Import/export survives spaces in file names, station-directory URLs pass an http(s)-only gate before touching anything, a 200-station list loads in one pass instead of two hundred, the sync sliders introduce themselves to screen readers, and the popup artwork follows the system accent color instead of staying default-green forever.

## 2026.18

- **The sync engine moved into its own home.** Everything combined-output — the loopbacks and their delays, per-speaker balances and channel modes, exclusions, the microphone calibration, the join watchdog and the default-sink etiquette — now lives in `SyncEngine.qml` behind one narrow seam, instead of being woven through the widget's main file. The seam is what makes it testable: a mock-driven harness now exercises the whole state machine end to end — enable/disable round-trips, answers arriving from superseded generations, the exact shell commands built for the loopbacks (delays, channel maps, quoting of hostile device names), the calibration loudness math with its cubic fold-back, the watchdog's reconnect cycle and the default-sink steal watch. Twenty-five new tests; the main file shed a quarter of its weight; the extraction was cross-checked line by line against the previous code, which caught four missed call-site rewrites before they could ship. No behavior change intended, none found after the fixes.

## 2026.17

Wake up to the radio — and the sync engine's last rough edges, sanded.

- **Wake-up alarms.** Next to the scheduled recordings on the My Music page: pick a station, a time, once/daily/weekly and a volume, and the widget starts playing on its own. An evening's leftovers don't stand in the way — a running sleep fade or pending sleep timer is cancelled the moment the alarm fires. The volume has a floor of 15 %, because an alarm set to silent is not an alarm; if the station cannot come alive within half a minute (network down, stream dead), a built-in chime takes over — an alarm that fails must fail loudly, never quietly. An alarm missed while the machine was off says so afterwards; one missed by a suspend still fires up to an hour late, on wake. "Keep the computer awake until the alarm" holds a single self-releasing sleep inhibitor — no background daemon, nothing to leak. If cast devices are selected, the alarm plays through them: waking up to the same bedroom speaker the evening ended on is the point.
- **The first QML logic tests.** The scheduling math behind alarms and scheduled recordings moved into its own file and runs under qmltestrunner — locally in the lint gate and in CI. Every release-breaking bug so far has lived on the QML side, out of reach of the Python tests; this is the start of the net for that class.
- **The sync stopped fighting over the default output.** While the sync is on, the combined output re-asserted itself as the system default on every internal rebuild — including every fine-tune slider move — silently overriding a default the user had deliberately pointed elsewhere. It now reclaims the default only from members of its own group and from sinks that appeared just that second (the switch-on-connect steal it was built against); a default moved by hand to anything else stands.
- **The re-enable bounce picks a polite stop.** Re-enabling the sync momentarily routes playback through another output to force a real re-attach; it used to grab the first device on the list, which could be a Bluetooth speaker in another room. It now prefers the device that was playing before the sync, then a wired group member — a speaker deliberately ticked out of the group is never blipped first.
- **A hung calibration cleans up after itself.** The measurement's own restore commands are the only place that knows every parked volume, so the measurement is now killed inside the guard window if it wedges — the sinks come back from their parked 55 % and the loopbacks from full, no matter how the run dies. And when the loudness pass replaces balances that were set by hand earlier, the result notification says so instead of doing it silently.
- **The join watchdog stopped calling its own cure a failure.** Its automatic connection cycle takes up to ~27 s end to end, and the ~30 s give-up could declare "did not join" while that cycle was still working. The countdown now holds during the cycle and restarts after it, so the reconnected speaker gets the full window again.
- **Calibration works on plain PulseAudio.** The microphone capture falls back from pw-record to parecord, which ships in the same package as the paplay the clicks already use — no new dependency.
- **The player renamed itself on the media bus.** It now appears as `org.mpris.MediaPlayer2.onair` (with the usual instance suffix) instead of the inherited `…advancedradio` — scripts that matched the old name need the new one. The media controls themselves are unaffected.
- Every handled failure in the cast bridge now leaves a trace on stderr (stdout stays reserved for the results the widget parses) — silent except-and-move-on branches made "why doesn't my TV appear" undebuggable.
- **An abandoned sync toggle can no longer haunt the system default.** Flipping the sync on and straight off (or an enable failing outright) left the "restore this output later" note behind — and every later login then silently re-pointed the system default sink at it, forever. The note is now cleared on every path that abandons an enable, consumed once at startup, and the startup restore itself only acts when the default still points at the widget's own swept sink.
- **Loudness matching now equalizes what the room actually plays.** The calibration compares speakers at one parked volume — pure sensitivity — but playback runs at each sink's own level, so a sink sitting at 40 % came out trimmed as if it were at 100 %. Each sink's real volume now rides along with the measurement and is folded back into the trim math (volumes are cubic), so the matched loudness is the one the listener hears.
- **One wedged speaker can no longer abort a calibration.** A dying sink holding the click player hostage used to throw away the whole run — including the already-successful delay measurement. It now costs exactly its own level line, and the run is covered end to end by new tests that execute the real script against stub audio tools.
- **Rebuild bookkeeping made generation-proof.** A stale rebuild answer arriving after a quick sync off/on could adopt superseded audio modules next to the fresh ones (audible phasing); rebuilds now carry their generation and stale answers are unloaded on sight. A new speaker's registration retries also get a fresh budget instead of inheriting one exhausted by some earlier stuck sink, and an enable whose speakers were all still registering waits for them instead of declaring failure.

## 2026.16

Stereo pairs, and the group finally takes requests.

- **Stereo pairs.** Every speaker in the sync group got a channel button next to its balance: stereo (the default), left only, right only, or a mono mix of both. Two speakers set to L and R become a true stereo pair with the room between them; the mono mix suits a lone speaker in the kitchen that would otherwise miss half the song. Implemented as the loopback's own channel map and measured before shipping (on PipeWire — plain PulseAudio takes the same pactl commands, but the pair modes were not bench-tested there): a single explicit position takes exactly that source channel — full level, zero bleed — while duplicate-position maps turned out half-broken in pactl and were left alone. Remembered per device, like everything else here.
- **A speaker can sit an evening out.** Each speaker row now carries a tick — untick the bedroom and the group plays on without it, no disconnecting, no re-pairing. The choice is remembered; a speaker excluded into absurdity is self-correcting: if the remembered exclusions would leave the group empty, flipping the sync on clears them, because the explicit action of right now outranks the leftovers of some earlier evening. The join watchdog respects the choice too — it will not drag an excluded speaker back in.

## 2026.15

The sync looks after itself now: speakers walk themselves into the group, and the calibration levels the room's loudness while it is at it.

- **A Bluetooth speaker that connects without its audio no longer needs a second try.** Some speakers (the JBL Xtreme 3 on the test bench, notoriously) report "Connected: yes" with no audio profile behind it, so their output never appears — and the fix everyone eventually finds by hand is "connect it again". The widget now watches every connect that should join the sync all the way in: a missing loopback gets a rebuild, a sink that never shows up gets the connection cycled once automatically, and if half a minute of that leads nowhere it says so instead of leaving a silently absent speaker.
- **The mid-build retry window covers slow sinks now.** A Bluetooth sink can register up to ~6 s after the connect finishes; the old window gave up at 4.5 s, right before the speaker arrived.
- **One calibration, two results: delay and loudness.** The microphone already times every speaker's click — now it reads each click's height too. With every sink parked at the same volume for the run, the amplitude ratio between speakers is their real loudness difference at the listening position: the quietest speaker becomes the reference and the louder ones are trimmed down to it, straight into the per-speaker balances (software volumes are cubic, so the ratio lands as its cube root). Every speaker in the group is measured, not just the timed pair, and nothing is ever boosted — no headroom surprises, no clipping.

## 2026.14.1

Hotfix round for the sync, found on real hardware within hours of 2026.14.

- **The volume keys move the whole room now.** They act on the system default sink, which stayed on the wired output the whole time — so "volume up" never reached the Bluetooth speaker. While the sync is on, the combined output takes over as the system default (its volume provably scales every speaker's feed) and hands the default back on disable, on failed loads, and after a crash. The master starts at 100% so enabling never jumps the loudness.
- **A speaker mid-connect can no longer poison the sync.** Loading a loopback whose sink is still registering does not fail — pactl quietly attaches it to the default sink, which while the sync is on is the combined sink itself: a silent feedback loop, and the just-connected speaker sat out of the group until the sync was toggled by hand. Every loopback load is now gated on its sink actually existing, with a short-fuse retry for the skipped one.
- **"Playing" but silent, fixed.** Re-enabling the sync recreates the combined sink under the same name, and the same-id device assignment looked like a no-op — the player's stream stayed bound to the dead node. The route now bounces through another output first, forcing a real re-attach.
- **Bluetooth connects verify themselves.** The verdict comes from the device's actual Connected state (bluez can finish a connect after the client times out), a sleeping speaker gets one automatic retry, and the route window covers the whole retry path. An awake speaker connects in about three seconds, measured.

## 2026.14

One volume for the whole house — and the sync engine went through a hardening pass on real hardware.

- **Group volume with per-speaker balance.** The volume slider was already the master for every target; now each speaker and device also carries its own balance (5–100 % of the master), so quiet desk speakers and a boomy soundbar keep their relationship while one slider drives the room. Balance rows sit right under each picked device in the cast menu, and under the sync switch for local speakers. Every balance is remembered per device — Cast/DLNA by uuid, Bluetooth by address, wired outputs by sink — and survives restarts.
- **Volume moves ride the sync delays.** The master is applied to the stream itself, upstream of the combined output, so on local speakers a volume change travels through each speaker's own delay together with the music — turning the room down cannot smear the sync. Local balances go on the widget's own loopbacks only: other applications' audio and the speaker's own volume buttons stay untouched.
- **A joining device keeps its loudness.** A network device picked into the group adopts the level it is already playing at (its ratio to the master becomes its balance) instead of jumping to the master level on the first slider move. Two new cast.py commands (get-volume, dlna-get-volume) read the level back, with dispatch tests to match.
- Calibration raises the widget's own loopbacks to full for the clicks and puts the balance back right after — a heavily trimmed speaker would otherwise measure as silence.
- **Calibration now silences the radio for its clicks.** Calibrating while music played — the natural moment to reach for it — either drowned the clicks (every measurement failed) or let a drum hit win the peak search, and a plausible-but-wrong delay was remembered for the speaker. The stream mutes for the few seconds of measurement and comes right back; results up to 900 ms are accepted now (slow televisions are real), with the fine-tune slider to match.
- **Sync engine edge cases, fixed on real PipeWire.** Flipping the sync switch off and on quickly could leave every speaker with two differently-delayed audio paths — the exact echo the feature exists to prevent — until the next login; stale setups now dismantle themselves on arrival. Connecting a Bluetooth speaker while the sync is on no longer steals the music onto that speaker alone: it joins the group. A crash while the sync was active no longer loses your chosen output device. Plain PulseAudio systems now take Bluetooth speakers into the group too (they name their sinks differently than PipeWire). Two widget instances no longer dismantle each other's sync at login.
- **Station healing keeps your address book yours.** The catalog it heals from is publicly writable, so a name-lookalike entry could have permanently replaced a saved station's address. A healed address is saved only when it lives on the station's own domain; anything else plays as a session-only backup with a notification, and your saved address stays put.
- **Clicks and votes stopped depending on mirror luck.** The station-identity lookup behind them picked one random directory mirror; a single slow mirror silently disabled both the listening click and the vote button for a day. Mirrors are now tried in order, only a real "not in the catalog" answer is remembered, and all directory calls identify themselves with the widget's User-Agent.
- The cast menu scrolls when it outgrows the popup instead of clipping its top rows (the sync switch lives there), and the calibration signal path is pinned by unit tests in both directions — a detector that fires on noise would write a wrong delay into your settings.

## 2026.13

The sync calibrates itself, and the stations finally get thanked.

- **Microphone auto-calibration.** Tuning the sync slider by ear works, but nobody should have to: "Calibrate with the microphone" plays a few loud clicks through the wired reference and the Bluetooth speaker, records them with the computer's microphone, and times when each click actually arrived — the difference IS the lag, measured acoustically the way commercial room-calibration systems do it. Speaker volumes are raised for the clicks and restored right after. Verified on real hardware: a JBL Xtreme 3 measured 166 ms behind a wired desk speaker, squarely in the expected A2DP range.
- **Per-device sync memory.** A JBL and a pair of AirPods lag differently, so each speaker's calibration is remembered by its address and the right number loads whenever that speaker connects. Several Bluetooth speakers at once are all held to the slowest one's schedule, each faster device waiting exactly its share. The manual slider stays for fine-tuning and updates the connected device's memory too.
- **Thank the stations.** The worldwide catalog this widget searches ranks stations by clicks and votes — and until now we took without giving back. When a station actually starts playing, an anonymous click goes to radio-browser.info (station id only, nothing about you; off-switch in settings). The 👍 on the now-playing page casts a real vote — the same votes the search results are ordered by, one per station per ten minutes.
- **❤️ Liked songs.** Liking saves the track to a local list behind a flip on the My Music history header — same rows, same download button, per-row removal. Five hundred entries, kept locally, nothing leaves the machine.
- A standalone-app plan (Kirigami + Flathub, for every Linux desktop) now lives in docs/STANDALONE-APP.md.

## 2026.12

The sync that actually syncs, and Bluetooth pairing without leaving the menu.

- **The combined output was rebuilt on real delays.** The first version leaned on latency compensation, which trusts what a Bluetooth box claims about itself — and an A2DP speaker keeps its real buffering to itself, so the wired outputs never waited long enough. It also combined every sink it saw, including an equalizer's effect input, which doubled the audio through a second path with phasing no delay could fix. Now one null sink feeds one loopback per real hardware output, each with an actual buffer delay; Bluetooth keeps the base, the wired outputs wait the slider amount on top. Tuning is audible within a second without interrupting playback, stereo is pinned, the whole thing runs on plain PulseAudio just as well (only `pactl` is used), and it costs about half a percent of CPU while active — nothing when off.
- **Pair a new speaker from the menu.** "Pair a new speaker…" scans for nearby unpaired audio devices and one click pairs, trusts and connects — the music follows onto it, and failures say what to do instead of nothing. System Settings no longer needed for the common case.
- **The menu says how everything is connected.** A proper title row, WiFi and Bluetooth section headers with icons, connection-type icons on every device row, and honest hints for an empty Bluetooth list: a dead adapter ("check System Settings") reads differently from "nothing paired yet". The combined output introduces itself by a human name in every output picker instead of a raw node id. Speakers that only announce themselves via the device-class icon (LE-Audio models) pass the device filter now.
- Review fixes before this went out: overlapping slider moves can no longer double the loopbacks, pairing and connecting can't fight over the auto-route, and a too-fast enable/disable/enable can't strand the sync switch in an unswitchable state.

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
