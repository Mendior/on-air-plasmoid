<!--
SPDX-FileCopyrightText: 2026 Egon Greenberg
SPDX-License-Identifier: LGPL-2.0-or-later
-->

# Triage — reading a bug report

The order below is the order the fields appear in the report, and it is the
order to read them, because each one narrows what the next can mean. Most of
what a report needs to be actionable is knowable before touching the code; the
job here is to turn a description into a reproducible claim or an honest "I
cannot tell yet, here is what would settle it."

## What the fields tell you

**Audio backend** — the single most useful line for anything about Now
Playing, and the one most reports never thought to include. The command lists
which multimedia plugin Qt loaded:

- `libffmpegmediaplugin.so` only → the FFmpeg backend. It never maps an ICY
  `StreamTitle` to a track title (measured across Qt 6.7–6.11), so the widget
  falls back to its own `reader.py` poller and titles refresh every few
  seconds. A "titles never update" report from an FFmpeg-only machine is
  usually a poller problem, not a metadata one.
- `libgstreamermediaplugin.so` present → the GStreamer backend, whose
  `icydemux` does deliver the title. Here the widget latches onto Qt and
  retires the poller — so if Qt then goes quiet mid-stream, titles freeze
  until the next station change. This is the exact shape of issue #10
  (Fedora, which ships the GStreamer backend); an FFmpeg-only machine cannot
  reproduce it. When a report about frozen titles comes in, this line decides
  which of two completely different mechanisms you are looking at.

**Version** — check it against the newest release before anything else; a
surprising number of reports are already fixed. `git log` the area between
their version and HEAD before claiming a cause.

**Plasma version and distribution** — the LTS distributions (Kubuntu, Debian)
ship an older Qt, and a few bugs live only there: a reserved word the newer
parser accepts and the LTS parser rejects (2026.24 shipped one), an API that
moved. If the reporter is on an LTS and the machine here is rolling, the
parser difference alone can be the whole bug.

**Journal output** — the widget tags its own lines `[ARP]`. Look for
`exec missing (exit 127)` / `exec timeout (exit 124)`: those name a tool the
reporter's machine does not have (pactl on a box without PipeWire,
bluetoothctl, ffmpeg) or a command that hung — a silent failure the widget
now says out loud once a session. The `qt.multimedia` startup line, if
present, corroborates the backend field.

## Before you answer

- Reproduce on the machine here first. If it will not reproduce, say so
  plainly and name what differs (their backend, their Qt, their distro) — an
  honest "I could not reproduce this on my setup, so this rests on the
  mechanism, not on seeing it" is a better answer than a guessed fix.
- Every number in the reply is a measurement, not a memory. If you cite Qt
  behaviour, cite the versions you checked.
- Do not promise a fix a release does not yet carry. If the answer is "fixed
  in the next version," the reply and the release go out together.

## The three already-closed reports, as worked examples

- **#2** (plasmashell ~10 % CPU): a background poll running far too often;
  caught with `pidstat` before and after, fixed in v2026.5.1.
- **#3** (FLAC stutter on connect): the relay tap handed the player the live
  edge with no cushion; fixed by a burst-on-connect head start. Left open
  until the reporter confirmed, because it would not reproduce here.
- **#10** (titles freeze until you switch tabs): the backend-dependent latch
  above. Root cause proven from Qt source plus a live measurement; the fix is
  a watchdog that re-arms the poller when Qt goes quiet.
