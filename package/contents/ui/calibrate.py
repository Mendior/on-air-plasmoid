# -*- coding: UTF-8 -*-
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Microphone sync calibration for On Air.

Measures how far a Bluetooth speaker trails a wired reference by playing a
short click through each sink and timing, with the computer's microphone,
when the sound actually arrives. Two one-sink measurements are taken with
identical plumbing, so every constant (mic path, recording start, paplay
spawn) cancels in the difference — only the speakers' real acoustic lag
remains.

Every click's peak AMPLITUDE at the microphone is measured along with its
arrival time — with all sinks parked at the same volume for the run, the
amplitude ratio between speakers is their real loudness difference at the
listening position, which the widget turns into per-speaker balance trims
(the same trick Sonos sells as Trueplay level matching). Extra sinks beyond
the two timed ones are clicked briefly for their level alone.

Usage: calibrate.py <wired_sink_name> <bt_sink_name> [mic_source] [extra_sink...]
Prints: CALIB_LVL <sink> <amp>   per sink that was heard (peak, int16 scale)
        CALIB_OK <ms>            on success (ms = how much the BT sink trails)
        CALIB_FAIL <reason>
Always exits 0 — a failure is a sentinel, not a crash.
"""
import hashlib
import math
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave

RATE = 48000
CLICK_HZ = 2200.0
CLICK_SECONDS = 0.010
CLICK_REPEATS = 4          # median over several clicks rejects room noise
LEVEL_REPEATS = 2          # extra sinks get two clicks — level AND timing
MAX_EXTRA_SINKS = 6        # keeps the whole run inside the widget's guard
RECORD_SECONDS = 1.9
PLAY_DELAY = 0.6           # recording warm-up before the click is played
ANALYSIS_SKIP = 0.4        # recording start carries a loud mic/AGC pop —
                           # found empirically, it decays for ~0.3 s and
                           # otherwise wins the peak search every time
MIN_SANE_MS = -100.0       # BT ahead of wired by >100 ms means a bad measure
MAX_SANE_MS = 900.0
CLIP_LEVEL = 32000         # |sample| at the int16 rail: the mic is saturating
CLIP_COUNT = 4             # one grazed rail can be honest; a run of them lies
LEADER_SECONDS = 0.35      # quiet hum before the burst: wakes a sleeping
LEADER_HZ = 180.0          # Bluetooth link and opens the speaker's own noise
LEADER_AMP = 900           # gate BEFORE the moment being measured — a JBL
                           # measured cold swallowed clicks whole or shifted
                           # them by hundreds of ms while the link spun up
LEADER_GAP_SECONDS = 0.05

# ── The inaudible stimulus ───────────────────────────────────────────────
# Measured on this hardware (JBL Xtreme 3 over sbc_xq, USB webcam mic):
# the chain carries 18-19 kHz with 45-53 dB of signal-to-noise, and that
# band is acoustically EMPTY — the room's own noise there measures 0.4-2.3
# against 63.8 at 1 kHz. Speech, fans and music simply do not live up
# there, so a sweep nobody can hear is easier to find than a loud click.
# Measured against the click it replaces: five times quieter and four
# times sharper.
#
# 18 kHz is the floor on purpose: below it teenagers hear the sweep. Nothing
# here is guaranteed on other hardware — a cheap speaker on plain SBC is
# cut off around 16 kHz — so every road that uses this falls back to the
# audible click when the band comes back empty.
#
# The CEILING came down from 21 to 19 kHz, and a measurement moved it. A JBL
# Flip 7 on this desk plays 18.5 kHz at full strength and is sixty decibels
# down by 19.5: the codec simply stops. With the sweep running to 21 kHz that
# speaker emitted its first third and nothing more, which left the detector
# comparing a scrap of band energy against a door slam — 15 windows at full
# volume, 7 at the level the group actually plays at, where transients reach
# 4 to 17. Inside 18-19 kHz the same speaker holds 31-33 windows at every
# volume tried, and so does a speaker with no limit at all: a sweep that
# dwells in a narrow band keeps feeding the probes instead of racing past
# them. Narrower is not a compromise for the wideband case, it is better for
# both.
ULTRA_LOW_HZ = 18000.0
ULTRA_HIGH_HZ = 19000.0
ULTRA_LEADER_HZ = ULTRA_LOW_HZ + 0.05 * (ULTRA_HIGH_HZ - ULTRA_LOW_HZ)
                           # The leader sits at the BOTTOM of the band, not in
                           # the middle. Its one job is to wake a sleeping
                           # Bluetooth link, so it belongs at the frequency a
                           # limited codec is likeliest to still carry — with
                           # it in the middle, every speaker that lost the
                           # leader had already lost two of the three probes,
                           # and the link it was meant to wake stayed asleep.
ULTRA_GAP_SECONDS = 0.25   # silence between the leader and the sweep, and it
                           # has to outlast the ROOM, not just the tone. The
                           # leader is 350 ms of steady level inside the very
                           # band the sweep is measured in, so its tail keeps
                           # the gate held; at 50 ms the two arrived as ONE
                           # event, and everything written to step past the
                           # leader keys off the leader being an event of its
                           # own (ULTRA_LEADER_HOLD). What the detector then
                           # timed was the leader's edge — measured live on
                           # the deployed path, a steady reading with the true
                           # sweep 380-400 ms later showing up as a
                           # repeatable "outlier" that two captures agreed on.
                           # Swept offline against room decay (bench/
                           # sim_reverb_leader.py): 50 ms breaks once the tail
                           # reaches 160 ms and 100 ms breaks at 250, while
                           # 250 ms holds to -3..-6 ms across every decay from
                           # anechoic to a full second. The click road keeps
                           # its own short LEADER_GAP_SECONDS — its burst is
                           # 10 ms and has no such neighbour.
ULTRA_SECONDS = 0.06       # long enough to survive a codec, short enough
                           # that the room's echo does not smear the onset
ULTRA_AMP = 6000           # int16; inaudible up here, still well clear of
                           # the band's own noise floor
ULTRA_WINDOW_SECONDS = 0.008   # analysis window: 8 ms is far finer than the
ULTRA_HOP_SECONDS = 0.002      # 60 ms agreement the lag maths works to
ULTRA_MIN_RATIO = 6.0      # band energy over the band's own floor before an
                           # arrival is believed
ULTRA_MIN_ABS = 40.0       # and an absolute floor, so a dead-silent band
                           # cannot make its own noise look like a sweep
ULTRA_MIN_HOLD = 18        # unbroken windows before an event counts as the
                           # sweep. Both sides of this number are measured:
                           # the sweep holds 31-33 windows through every
                           # speaker and level tried (18-20 for one cut at
                           # 18.6 kHz), while a 40 ms broadband bang reaches
                           # 17, a 20 ms one 10, and continuous noise never
                           # forms a run at all. Eighteen sits in that gap.
ULTRA_PLAY_CEILING = 0.55  # the loudest the stimulus may land on the sink's
                           # own rail, as a fraction of full scale.
                           #
                           # The ceiling used to be a flat 112000, chosen so
                           # the stimulus alone sat at 0.9 of full scale — and
                           # 0.9 is the right answer for a sink with nothing
                           # else on it. This check plays over LIVE MUSIC by
                           # design, and the music is on that same rail:
                           # measured off this desk's sink monitor while a
                           # station played, music peaked at 0.31 and the
                           # stimulus periods pinned 153 samples at 32768.
                           #
                           # A clipped 18 kHz tone does not stay up there.
                           # Clipping folds harmonics back under Nyquist: the
                           # third lands at 48000 - 3*18050 = 6.15 kHz, and
                           # measured in that same capture it reached -25 dBFS
                           # against the music's own 1 kHz at -60. Thirty-five
                           # decibels ABOVE the programme, right where hearing
                           # is sharpest — that is the beep, and no amount of
                           # care in the WAV can undo it.
                           #
                           # 0.55 leaves 0.45 for the programme, comfortably
                           # over the 0.31 measured here. It costs 4.4 dB of
                           # stimulus, against a band signal-to-noise measured
                           # at 45-53 dB and detection ratios of 356:1 and
                           # 440:1 on this desk's two speakers — both still two
                           # orders above ULTRA_MIN_RATIO after the cut.
ULTRA_LEVEL_TRIM = 0.1     # play at a TENTH of the level the detector was
                           # tuned at — 20 dB down, and it is still far more
                           # than the measurement needs.
                           #
                           # Measured with a microphone in this room, four
                           # stimulus plays during one periodic check:
                           #
                           #   stimulus, 18-19 kHz, at the mic : -11 dBFS
                           #   the same band with no stimulus  : -71 dBFS
                           #   the music the listener chose    : -29 dBFS
                           #
                           # Sixty decibels over the band's own floor where
                           # ULTRA_MIN_RATIO asks for six (about 16 dB), and
                           # eighteen decibels LOUDER than the programme. That
                           # is the whole reason it is heard: 18 kHz is the
                           # bottom of the band and plenty of adults still
                           # hear it when it is played that hard. The ceiling
                           # cannot move up instead — 19 kHz is where the JBL
                           # stops, which is why it came down from 21.
                           #
                           # A tenth leaves 40 dB over the floor at the mic —
                           # measured on the BLUETOOTH speaker. It is not
                           # enough for every member, and that is what
                           # ULTRA_LEVEL_STEPS is for.
ULTRA_LEVEL_WARMUP = 0.3   # the throwaway capture's level, and the one the
                           # "can this chain carry 18 kHz" question is decided
                           # at. Measured reliable for BOTH members here where
                           # 0.1 was not; see the table below.
ULTRA_LEVEL_STEPS = (ULTRA_LEVEL_TRIM, 0.3, 1.0)
                           # Quiet first, louder only for a member that did not
                           # answer. One fixed level cannot serve both ends of
                           # a room: measured here through the live group with
                           # music playing, three runs per level,
                           #
                           #   0.1  the wired speaker went DEAF in 2 of 4 runs
                           #   0.3  heard in 3 of 3
                           #   1.0  heard in 4 of 4
                           #
                           # The wired output sits at 60 % and reaches the
                           # microphone far quieter than the Bluetooth one at
                           # 98 %, so the level that hides the sweep on one
                           # loses the other — and losing it is not a small
                           # thing: one DRIFT_DEAF shelves that speaker for the
                           # life of the group, which is the whole automatic
                           # road gone.
                           #
                           # Members may be measured at DIFFERENT levels
                           # because the detector is level-blind by
                           # construction: the arrival is taken at half of the
                           # event's OWN peak, and across a 10:1 level range
                           # the reported arrival held to a tenth of a
                           # millisecond (bench/sim_fix.py). The ladder rides
                           # the retries that already exist, so a member that
                           # answers at once still costs exactly one play.
ULTRA_PLAY_MAX = int(65536 * (ULTRA_PLAY_CEILING
                              / (ULTRA_AMP / 32767.0)) ** (1.0 / 3.0))
                           # Derived, not typed: PulseAudio stream volume is
                           # CUBIC (65536 = unity, and 112000 is 4.99x linear,
                           # not the 1.71x it reads like), so a ceiling written
                           # as a PA number drifts silently the moment
                           # ULTRA_AMP moves. Both halves of the arithmetic
                           # live here now.
ULTRA_BRIDGE_WINDOWS = 3   # dips this short do not end an event. Measured on
                           # a quiet speaker in a loud room, one sweep arrived
                           # as runs of 8, 2, 7 and 11 windows split by exactly
                           # one window each — the three probes ripple as the
                           # sweep passes them. Three windows is 6 ms, an order
                           # below the 50 ms that separates leader from sweep.
ULTRA_LEADER_HOLD = 100    # 200 ms. The wake-up leader is 350 ms of steady
                           # tone in the middle of this band and the sweep is
                           # 60 ms, so duration is what tells them apart —
                           # and telling them apart is the whole job, because
                           # a leader timed by mistake slides with the
                           # speaker's loudness while the sweep does not.


def ultra_chirp(seconds=ULTRA_SECONDS, rate=RATE):
    """The inaudible sweep, as unit-amplitude samples.

    A sweep rather than a tone: a single frequency can sit in a room null
    and vanish, while a sweep crossing three kilohertz always has somewhere
    to land. The raised-cosine edges keep it from clicking — an abrupt
    start would put a broadband transient into the AUDIBLE band and undo
    the whole point.
    """
    n = max(1, int(rate * seconds))
    edge = max(1, int(rate * 0.004))
    out = []
    for i in range(n):
        t = i / rate
        env = min(1.0, i / edge, (n - i) / edge)
        phase = 2.0 * math.pi * (ULTRA_LOW_HZ * t
                                 + (ULTRA_HIGH_HZ - ULTRA_LOW_HZ) * t * t / (2.0 * seconds))
        out.append(env * math.sin(phase))
    return out


def _goertzel_mag(samples, hz, rate=RATE):
    """One frequency's magnitude in `samples` — the cheapest honest way to
    ask "how much of this tone is in here" without an FFT dependency."""
    n = len(samples)
    if n == 0:
        return 0.0
    k = int(0.5 + n * hz / rate)
    w = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(w)
    s1 = s2 = 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2 = s1
        s1 = s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return math.sqrt(power) / n if power > 0 else 0.0


def ultra_probe_hz():
    """The three frequencies the band is watched at.

    Fractions of the band rather than fixed frequencies, so moving
    ULTRA_HIGH_HZ moves them with it — the version that hard-coded 19500 in
    the middle went on probing where a narrowed band had nothing to find."""
    span = ULTRA_HIGH_HZ - ULTRA_LOW_HZ
    return (ULTRA_LOW_HZ + 0.15 * span,
            ULTRA_LOW_HZ + 0.50 * span,
            ULTRA_LOW_HZ + 0.85 * span)


def ultra_probe_mags(window, rate=RATE):
    """Each probe on its own. Kept separate because WHEN each one peaks is
    what tells a sweep from a bang: the sweep climbs, so it lights the low
    probe first and the high one 40 ms later, while a slam lights all three
    in the same instant."""
    return tuple(_goertzel_mag(window, hz, rate) for hz in ultra_probe_hz())


def ultra_band_energy(window, rate=RATE):
    """How much sweep-band energy one window carries. Three probes across
    the band, because the sweep passes through each in turn and a single
    probe would only see its own slice of the 60 ms."""
    return sum(ultra_probe_mags(window, rate))


def _ultra_climbs(probe_windows, gate):
    """Did the band energy move UPWARD in frequency, the way a sweep does?

    A sweep lights the low probe first and the high one about 40 ms later.
    A slammed door, a dropped book, a chair dragged across tiles: broadband,
    so all three probes light in the same window. Duration alone does not
    separate them — a 40 ms bang holds the gate as long as the sweep — but
    the climb does.

    Only probes that actually received something take part. A codec that
    stops mid-band leaves its top probe sitting in the room's noise, and
    asking that one when it peaked is asking the room, not the speaker.
    Fewer than two live probes means there is nothing to compare, and an
    event that cannot be told from a transient is not a measurement.
    """
    if not probe_windows:
        return False
    hz = ultra_probe_hz()
    tops = []
    for p in range(len(probe_windows[0])):
        column = [w[p] for w in probe_windows]
        top = max(column)
        tops.append((p, top, column.index(top)))
    strongest = max(t for _p, t, _at in tops)
    if strongest <= 0:
        return False
    # A probe counts as live only against its NEIGHBOURS, not against an
    # absolute bar. Measured on a speaker cut at 18.6 kHz: the top probe
    # still read 177 where the others read 2888 — six per cent, which is
    # leakage past the codec's shoulder, not the sweep. Its peak landed
    # wherever the noise happened to be loudest and dragged the climb test
    # to a verdict the speaker had not earned. A quarter is where the
    # leader's own leakage falls out too: a link waking mid-leader left 92
    # in the neighbouring probe against 551 in its own — seventeen per cent,
    # enough to pass a looser bar and make a steady tone look like a climb.
    live = [(p, at) for p, top, at in tops
            if top >= gate / 3.0 and top >= 0.25 * strongest]
    if len(live) < 2:
        return False
    (first_p, first_at), (last_p, last_at) = live[0], live[-1]
    if last_at < first_at:
        return False
    span = ULTRA_HIGH_HZ - ULTRA_LOW_HZ
    if span <= 0:
        return False
    # Two probes that far apart in the band peak that same fraction of the
    # sweep apart in time — a KNOWN distance, not merely "later". Both ends
    # of the window earn their keep: below it sits the slam, which lights
    # every probe in one instant; above it sits a steady tone whose leakage
    # into a neighbouring probe peaks wherever the room's noise happened to
    # be loudest. Measured on a link waking mid-leader, that leakage peaked
    # 36 windows after the tone's own, against the 10.5 the sweep would
    # give, and a one-sided rule read the remnant as a sweep 210 ms early.
    expect = ((hz[last_p] - hz[first_p]) / span) * (ULTRA_SECONDS / ULTRA_HOP_SECONDS)
    if expect <= 0:
        return False
    return 0.4 * expect <= (last_at - first_at) <= 2.0 * expect


def ultra_arrival(samples, rate=RATE, skip_seconds=ANALYSIS_SKIP):
    """When the inaudible sweep reached the microphone.

    Returns (seconds_from_start, peak_band_energy, floor) or None when the
    band stayed empty — which is the honest answer for a speaker whose
    codec or driver does not carry 18 kHz, and the caller's cue to fall
    back to the audible click.

    Pure: takes samples, touches no hardware, and is what the tests drive.
    """
    if not samples:
        return None
    start = int(skip_seconds * rate)
    if start >= len(samples):
        return None
    win = max(8, int(ULTRA_WINDOW_SECONDS * rate))
    hop = max(1, int(ULTRA_HOP_SECONDS * rate))
    energies = []
    probes = []
    i = start
    while i + win <= len(samples):
        mags = ultra_probe_mags(samples[i:i + win], rate)
        energies.append((i, sum(mags)))
        probes.append(mags)
        i += hop
    if len(energies) < 4:
        return None
    # The floor is the median of the whole run, not of the opening: the
    # sweep occupies a handful of windows out of hundreds, so it cannot
    # lift the median, while an opening-only floor would be fooled by a
    # recorder that started late and caught the sweep in its first breath.
    vals = sorted(e for _, e in energies)
    floor = vals[len(vals) // 2]
    # Measured against the room's own floor, never against the peak: a gate
    # scaled to the peak follows a loud reflection up and reports THAT as
    # the arrival, and the direct sound is what the lag is about. The
    # duration rule below is what keeps a transient out, so the gate does
    # not have to be high — which also keeps the onset steady between
    # captures, where a peak-scaled gate wandered.
    gate = max(ULTRA_MIN_ABS, ULTRA_MIN_RATIO * floor)

    # Cut the capture into EVENTS: unbroken runs of windows over the gate.
    # Judging each event by how long it holds is what lets the leader and
    # the sweep be two different objects instead of two crossings of one
    # threshold. The version that had to guess between them credited a
    # speaker whose codec swallowed the leader with 32 ms it did not have.
    # Small dips do NOT end an event. Three probes across the band means the
    # summed energy ripples as the sweep passes each one, and in a noisy room
    # the dips reach under the gate: measured on a quiet speaker in a loud
    # room, one sweep came back as runs of 8, 2, 7 and 11 windows separated by
    # exactly one window each. Bridging up to ULTRA_BRIDGE_WINDOWS keeps that
    # one sweep one event, and stays far below the 25 windows of silence that
    # separate the leader from the sweep.
    events = []
    run_start = None
    run_end = None
    for k, (_idx, energy) in enumerate(energies):
        if energy >= gate:
            if run_start is None:
                run_start = k
            run_end = k
        elif run_start is not None and run_end is not None \
                and k - run_end > ULTRA_BRIDGE_WINDOWS:
            events.append((run_start, run_end))
            run_start = None
            run_end = None
    if run_start is not None:
        events.append((run_start, run_end))
    # A slam, a clap, a chair leg: broadband, so they reach this band, but
    # measured they hold 17 windows at their loudest against the sweep's 31.
    events = [e for e in events if e[1] - e[0] + 1 >= ULTRA_MIN_HOLD]
    if not events:
        return None

    # What identifies the sweep is not how long it lasts but that it CLIMBS.
    # Duration alone was the first cut and it was the wrong one from both
    # ends: it threw away a sweep still ringing in a live room, and it took a
    # leader clipped short by a late-starting recorder for a sweep and timed
    # it. A steady tone does not climb and neither does a slam.
    climbers = [e for e in events if _ultra_climbs(probes[e[0]:e[1] + 1], gate)]
    if not climbers:
        # Either nothing came back, or the only thing that did was the leader:
        # a link that woke up behind a speaker that cannot carry the rest of
        # the band. Saying nothing is the honest answer — the leader's own
        # crossing slides with loudness, which is the error this rewrite
        # exists to remove.
        return None
    # The sweep follows its own leader, so a climb before a long steady tone
    # belongs to the room rather than to us.
    leader = next((e for e in events
                   if e not in climbers and e[1] - e[0] + 1 >= ULTRA_LEADER_HOLD),
                  None)
    if leader is not None:
        after = [e for e in climbers if e[0] > leader[1]]
        if after:
            climbers = after
    seg = energies[climbers[0][0]:climbers[0][1] + 1]

    # Half of the event's own peak, and the peak is taken from the first
    # sweep-length of it — a reflection arriving after the sweep is over
    # must not lift the reference, or the crossing slides into the echo.
    # Half of one's own peak is what makes this level-blind: across a 10:1
    # level range and four codec limits the reported arrival held to a
    # tenth of a millisecond, where a fixed gate slid with the level.
    ref_windows = max(1, int(round(ULTRA_SECONDS / ULTRA_HOP_SECONDS)))
    peak = max(e for _, e in seg[:ref_windows])
    half = 0.5 * peak
    hit = None
    for j, (idx, energy) in enumerate(seg):
        if energy < half:
            continue
        if j == 0:
            hit = float(idx)
        else:
            prev_idx, prev_e = seg[j - 1]
            rise = energy - prev_e
            frac = 0.0 if rise <= 0 else (half - prev_e) / rise
            hit = prev_idx + frac * (idx - prev_idx)
        break
    if hit is None:
        return None
    # The half-peak point sits inside the rising edge, not at its foot, and
    # an 8 ms window smears that edge by about its own half-width. Backing
    # that out keeps this comparable with the click road, whose arrivals are
    # the burst's own sample index.
    onset = hit / float(rate) - ULTRA_WINDOW_SECONDS * 0.5
    return (max(0.0, onset), peak, floor)


def click_template():
    """The burst's unit-amplitude shape, shared by the WAV writer and the
    matched filter — the filter must correlate against exactly what was
    played, or its sub-sample precision is fiction."""
    n = int(RATE * CLICK_SECONDS)
    return [0.5 * (1.0 - math.cos(2.0 * math.pi * i / n))
            * math.sin(2.0 * math.pi * CLICK_HZ * i / RATE)
            for i in range(n)]


def make_click(path):
    """The measurement stimulus: a third of a second of quiet 180 Hz hum, a
    beat of silence, then the 10 ms raised-cosine burst at 2.2 kHz — sharp
    but speaker-safe. Only the burst is measured; the hum is far too quiet
    (and the wrong shape) to move the matched filter or the peak gate, it
    exists so the sound PATH is already awake when the burst rides it."""
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        ramp = RATE * 0.05  # soft ramp-in, no pop of its own
        for i in range(int(RATE * LEADER_SECONDS)):
            env = min(1.0, i / ramp)
            frames += struct.pack("<h", int(LEADER_AMP * env
                                            * math.sin(2.0 * math.pi * LEADER_HZ * i / RATE)))
        frames += b"\x00\x00" * int(RATE * LEADER_GAP_SECONDS)
        for v in click_template():
            frames += struct.pack("<h", int(24000 * v))
        w.writeframes(bytes(frames))


def read_mono(path):
    with wave.open(path, "rb") as w:
        ch, sw, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    if sw != 2:
        return None, rate
    total = len(raw) // (2 * ch)
    samples = [0] * total
    for i in range(total):
        samples[i] = struct.unpack_from("<h", raw, (i * ch) * 2)[0]
    return samples, rate


def _xcorr_refine(window, coarse_i, tpl, half_s=0.015):
    """Sub-sample click arrival via a matched filter around the coarse peak.

    Correlates the recording with the KNOWN burst shape in a ±half_s
    neighbourhood of the amplitude peak and takes the correlation maximum,
    plus a parabolic fit between neighbouring lags for the sub-sample
    fraction. The magnitude is used so a polarity-inverting mic/speaker
    chain cannot flip the answer. The bare amplitude argmax used to wander
    by whole samples between runs in room noise; the filter integrates over
    all 480 template samples (~22x processing gain) and holds still.
    Returns (float sample index in `window`'s frame — aligned to the burst
    peak so the number means what the old detector's did — and the raw
    correlation peak, which the caller normalizes into a template-match
    score: a true burst is SHAPED like the template, a thump is not).
    """
    half = int(half_s * RATE)
    tn = len(tpl)
    lo = max(0, coarse_i - tn - half)
    hi = min(len(window) - tn, coarse_i + half)
    if hi <= lo:
        return float(coarse_i), 0.0
    corr = [0.0] * (hi - lo + 1)
    best_l, best_c = lo, -1.0
    for lag in range(lo, hi + 1):
        acc = 0.0
        for k in range(tn):
            acc += window[lag + k] * tpl[k]
        c = abs(acc)
        corr[lag - lo] = c
        if c > best_c:
            best_c, best_l = c, lag
    if best_c <= 0.0:
        return float(coarse_i), 0.0
    ci = best_l - lo
    cm = corr[ci - 1] if ci > 0 else 0.0
    cp = corr[ci + 1] if ci + 1 < len(corr) else 0.0
    denom = cm - 2.0 * best_c + cp
    frac = 0.0 if denom == 0.0 else max(-1.0, min(1.0, 0.5 * (cm - cp) / denom))
    tpl_peak = max(range(tn), key=lambda i: abs(tpl[i]))
    return best_l + frac + tpl_peak, best_c


def peak_of(path, tpl=None):
    """(seconds from start, peak amplitude, clipped?) of the click's arrival.

    Returns None when nothing click-like was heard — including when the
    recording itself is truncated or unreadable: one bad capture is one
    failed measurement, never a reason to abort the whole run (an escaped
    wave.Error used to do exactly that from an extra, level-only sink).

    The impulsiveness gate is unchanged from the shipped detector; when a
    template is given, the matched filter then refines WHERE the click sits
    to sub-sample precision. `clipped` reports mic saturation: a rail-flat
    burst still times fine, but its amplitude is a lie and must not feed
    the loudness matching.
    """
    try:
        samples, rate = read_mono(path)
    except Exception:
        return None
    if not samples:
        return None
    start = int(ANALYSIS_SKIP * rate)
    if start >= len(samples):
        return None
    window = samples[start:]
    best, best_i = 0, -1
    clipped = 0
    for i, s in enumerate(window):
        a = abs(s)
        if a >= CLIP_LEVEL:
            clipped += 1
        if a > best:
            best, best_i = a, i
    # A click is impulsive: it must stand far above the noise floor. The
    # floor is the MEDIAN |sample| of the window's opening stretch — before
    # the stimulus arrives — because webcam AGC scales the noise and the
    # click together: a mean over the whole window drifted with the leader
    # hum and an absolute-only threshold silently dropped every click from
    # the quieter speaker after a loud one had ducked the mic's gain.
    if best_i < 0:
        return None
    pos, corr_peak = (float(best_i), 0.0)
    if tpl is not None:
        pos, corr_peak = _xcorr_refine(window, best_i, tpl)
    # The noise floor is measured strictly BEFORE the stimulus began — the
    # burst position minus the leader hum and a margin — so neither the hum
    # nor the burst can inflate it. A recorder that started late (cold
    # spawn) can push the stimulus to the window's edge and leave no
    # pre-roll at all; the floor then falls back to the clamp.
    pre_end = best_i - int((LEADER_SECONDS + LEADER_GAP_SECONDS + 0.05) * rate)
    head = sorted(abs(s) for s in window[:pre_end]) if pre_end >= int(0.05 * rate) else []
    floor = head[len(head) // 2] if head else 60
    med_all = sorted(abs(s) for s in window)[len(window) // 2]
    # Measured on real hardware: after a loud speaker's series, webcam AGC
    # ducks the gain ~10x and the next speaker's clicks land around 800 —
    # 37x above their concurrent floor, unmistakably clicks. The absolute
    # bar only needs to reject quiet garbage in true silence; the ratios
    # carry the discrimination (the whole-window median guards against
    # steady noise when the pre-roll is missing).
    # The matched filter is the judge whenever a template is in hand:
    # the correlation peak normalized by amplitude and template weight
    # says whether the loudest thing is SHAPED like the burst. Measured
    # on this room's real recordings: genuine clicks 0.59-0.61 (even
    # AGC-ducked ones), music transients at most 0.24, keyboard 0.001.
    # Amplitude alone let a daytime room paint "clicks" onto sinks with
    # no speaker attached — their level lines then fed the trims.
    if tpl is not None:
        tpl_l1 = sum(abs(v) for v in tpl)
        match = corr_peak / (best * tpl_l1) if best > 0 else 0.0
        if match < 0.35 or best < 300:
            return None
        # The amplitude bars scale with the filter's confidence. A noisy
        # room (a studio mic over a fan-loud desktop measured a floor of
        # ~540 where the quiet bench sat at ~40) pushes 8x-the-floor out of
        # reach of a speaker the filter recognizes UNMISTAKABLY — measured
        # there: a genuine click at 7.9x the floor with match 0.65, against
        # music transients that never pass 0.24. A strong shape verdict is
        # exactly what buys down the amplitude requirement; a marginal one
        # keeps the full bars.
        if match >= 0.5:
            if best < 4 * max(floor, 60) or best < 2.5 * max(med_all, 1):
                return None
        elif best < 8 * max(floor, 60) or best < 4 * max(med_all, 1):
            return None
    else:
        if best < 600:
            return None
        if best < 8 * max(floor, 60) or best < 4 * max(med_all, 1):
            return None
    return (start + pos) / rate, best, clipped >= CLIP_COUNT


def recorder_args(mic, rec):
    """The microphone capture command line.

    pw-record where PipeWire is native; parecord on plain PulseAudio — it
    ships in the same package as the paplay already used for the clicks, so
    the fallback costs no new dependency. Both finalize the WAV header on
    SIGTERM. parecord gets the sample format pinned because its default
    follows the device, and peak_of only reads 16-bit.
    """
    if shutil.which("pw-record"):
        args = ["pw-record", "--rate", str(RATE), "--channels", "1"]
        if mic:
            args += ["--target", mic]
        return args + [rec]
    args = ["parecord", "--rate=%d" % RATE, "--channels=1",
            "--format=s16le", "--file-format=wav"]
    if mic:
        args += ["--device=" + mic]
    return args + [rec]


def monitor_recorder_args(sink, rec):
    """The capture command line for what a sink is PLAYING — its monitor.

    "<sink>.monitor" is a pulse-compatibility name only: PipeWire has no
    node called that, and pw-record given an unresolvable --target falls
    back to the default SOURCE — the microphone. Both drift recorders then
    hear the same mic and the estimator correlates the mic with itself.
    Native pw-record reaches the monitor by targeting the sink node itself
    with stream.capture.sink; the pulse fallback keeps the .monitor device
    name, which genuinely exists in that layer."""
    if shutil.which("pw-record"):
        return ["pw-record", "--rate", str(RATE), "--channels", "1",
                "-P", "{ stream.capture.sink = true }",
                "--target", sink, rec]
    return ["parecord", "--rate=%d" % RATE, "--channels=1",
            "--format=s16le", "--file-format=wav",
            "--device=" + sink + ".monitor", rec]


def _sink_volume_fraction(sink):
    """The sink's own volume as PulseAudio reports it, 1.0 for 100 %.

    No regex: this file's pure functions are lifted into the tests through a
    namespace that carries only the modules they already use, and one more
    import is one more thing to keep in step.
    """
    try:
        out = subprocess.run(["pactl", "get-sink-volume", sink],
                             capture_output=True, text=True, timeout=3,
                             check=False).stdout
    except Exception:
        return None
    for token in (out or "").split():
        if token.endswith("%") and token[:-1].isdigit():
            return int(token[:-1]) / 100.0
    return None


def ultra_play_volume(fraction, trim=ULTRA_LEVEL_TRIM):
    """Stream volume for the inaudible stimulus at a sink sitting at
    `fraction` of full volume — pure, so the arithmetic is testable.

    Compensating for the sink puts the level that leaves the SPEAKER back
    where the detector was tuned, whatever the listener has the room at.
    Then ULTRA_LEVEL_TRIM takes 20 dB back off, because where it was tuned
    was far louder than it needs to be.

    The trim rides HERE and not on ULTRA_AMP on purpose. A quieter file
    would be a quieter stimulus with the same quantisation noise under it,
    and on a quiet sink this function's own boost would then lift that noise
    into hearing — measured in the file, its audible-band floor sits at
    -66.8 dBFS, and the 30x a very quiet sink asks for would put it at -37.
    Keeping the file at full amplitude and turning the PLAYBACK down moves
    signal and noise together.
    """
    if not fraction or fraction <= 0:
        return ULTRA_PLAY_MAX
    base = 65536.0 * (max(1e-6, trim) ** (1.0 / 3.0))
    return int(min(ULTRA_PLAY_MAX, round(base / fraction)))


def _ultra_volume_for(sink, trim=ULTRA_LEVEL_TRIM):
    return ultra_play_volume(_sink_volume_fraction(sink), trim)


def _record_one(sink, click, mic, rec, seconds=None, volume=65536):
    """One click through `sink` while the mic records into `rec` — the
    shared plumbing under both the calibration and the verify pass. The
    verify listens longer: a click riding the full deployed path (loopback
    buffering plus a Bluetooth link) can arrive most of a second after a
    direct one, and the default window cut its tail off."""
    rp = subprocess.Popen(recorder_args(mic, rec), stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
    try:
        time.sleep(PLAY_DELAY)
        t_play = time.monotonic()
        try:
            subprocess.run(["paplay", "--device", sink,
                            "--volume", str(int(volume)), click],
                           timeout=5, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            # A dying sink can hold paplay past its timeout. That is one
            # FAILED measurement of one sink ("nothing click-like heard"),
            # not a reason to abort the run — letting this escape used to
            # throw away an already-successful timing verdict because one
            # extra, level-only speaker wedged.
            pass
        window = RECORD_SECONDS if seconds is None else seconds
        time.sleep(max(0.0, window - (time.monotonic() - t_play)))
    finally:
        _stop_recorder(rp)


def measure_once(sink, click, mic, tpl=None, seconds=None):
    """One click through `sink`, recorded from `mic`.

    Returns (arrival_seconds, peak_amplitude, clipped) or None when nothing
    click-like was heard.
    """
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        _record_one(sink, click, mic, rec, seconds)
        # Seconds between "told the sink to play" and "mic heard it". The
        # recording started PLAY_DELAY earlier, which is part of the constant
        # that cancels between the two sinks.
        return peak_of(rec, tpl)
    finally:
        try:
            os.unlink(rec)
        except OSError:
            pass


def median(values):
    """The middle value, averaging the two middle ones on an even count.

    Taking the upper of the pair biased every even-length run one step in
    the same direction, and the click runs are even by design (CLICK_REPEATS
    stays an even count). Half a step is small against a 60 ms tolerance,
    but it is a bias rather than noise — it never cancels over repeats."""
    s = sorted(values)
    n = len(s)
    if n == 0:
        return 0
    if n % 2:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2.0


def _is_dead_capture(samples):
    """A hardware-muted microphone delivers EXACT zeros forever — a Yeti's
    own touch-mute is pure DSP inside the mic and invisible to PulseAudio's
    mute flag (measured live: 'Mute: no' over five seconds of flat zero). A
    live capture never sits this low: even a silent room leaves a few LSBs
    of noise and dither on a real ADC."""
    if not samples:
        return True
    return max(abs(s) for s in samples) <= 3


def _usable_mic_name(name):
    """Monitors are not microphones: a monitor 'hears' a click electrically
    the instant it is queued — zero acoustic path, every lag reads ~0 — and
    a calibration against one writes confident nonsense into the lags."""
    return bool(name) and not name.endswith(".monitor")


def _stop_recorder(rp):
    """Stop one recorder and reap it. Safe on None and on an already-dead
    process, so it can be called from the body AND from a finally.

    The leash's SIGTERM arrives as SystemExit on whatever line is running,
    and every capture below spends most of its life asleep waiting for the
    recording to fill. Terminating only on the happy path left `pw-record`
    holding the microphone after a killed run: the leash covers the python,
    never its children.
    """
    if rp is None:
        return
    try:
        rp.terminate()
    except Exception:
        return
    try:
        rp.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            rp.kill()
            # Reap the corpse: an unreaped kill leaves a zombie for the
            # rest of a forty-second run, one per wedged capture.
            rp.wait(timeout=1)
        except Exception:
            pass
    except Exception:
        pass


def _capture_alive(mic, seconds=0.7):
    """Whether a short capture from `mic` carries any signal at all."""
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    rp = None
    try:
        rp = subprocess.Popen(recorder_args(mic, rec), stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        time.sleep(seconds)
        # Stopped here as well as in the finally: the recorder writes its
        # WAV as it goes down, so the file has to be closed before it can
        # be read. The finally then has nothing left to do — which is the
        # point, it only earns its keep when this line is never reached.
        _stop_recorder(rp)
        try:
            samples, _rate = read_mono(rec)
        except Exception:
            return False
        return not _is_dead_capture(samples)
    finally:
        _stop_recorder(rp)
        try:
            os.unlink(rec)
        except OSError:
            pass


# pactl's output is gettext-translated ("Name:" becomes "Nom :" on a French
# desktop) and every parser below matches the English prefixes — the C locale
# is pinned or the mic handover would be silently inert outside English.
# (A function, not a module constant: the test loader lifts assignments into
# a bare namespace where os does not exist.)
def _c_env():
    return dict(os.environ, LC_ALL="C")


def _default_source_name():
    try:
        return subprocess.run(["pactl", "get-default-source"],
                              capture_output=True, text=True, env=_c_env(),
                              timeout=3).stdout.strip()
    except Exception:
        return ""


def _alternative_mics(skip):
    """(name, description) of candidate microphones, monitors excluded."""
    try:
        out = subprocess.run(["pactl", "list", "sources"], capture_output=True,
                             text=True, env=_c_env(), timeout=5).stdout
    except Exception:
        return []
    mics = []
    name = ""
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Name: "):
            name = line[6:].strip()
        elif line.startswith("Description: "):
            if _usable_mic_name(name) and name != skip:
                mics.append((name, line[13:].strip()))
            name = ""
    return mics


def _hearing_score(path, tpl):
    """How well one microphone heard the click: its peak over its own noise.

    A number, not a name. Loudness alone would be a poor judge — a webcam's
    built-in gain can make it read louder than a studio condenser while
    hearing far less of the room, and its noise rises with the gain. The
    ratio is what a measurement can be trusted on. A clipped capture scores
    zero: its amplitude is a rail, not a reading.
    """
    try:
        samples, rate = read_mono(path)
    except Exception:
        return 0.0
    if not samples:
        return 0.0
    hit = peak_of(path, tpl)
    if hit is None or hit[2]:
        return 0.0
    # The quiet part is found from where the burst actually landed, not from
    # the timing constants: reading it as "between the skip and PLAY_DELAY"
    # silently returned zero for every microphone whenever those two crossed,
    # and then the pick fell back to the desktop default without a word.
    start = int(ANALYSIS_SKIP * rate)
    click_i = start + int(hit[0] * rate)
    quiet_end = max(start, click_i - int(0.02 * rate))
    if quiet_end - start >= int(0.05 * rate):
        quiet = samples[start:quiet_end]
    else:
        # The burst sits too early to leave a run-up — listen after it.
        tail = click_i + int(0.05 * rate)
        quiet = samples[tail:] if tail < len(samples) else []
    if len(quiet) < 32:
        return 0.0
    acc = 0.0
    for v in quiet:
        f = float(v)
        acc += f * f
    noise = math.sqrt(acc / len(quiet))
    return hit[1] / (noise + 1.0)


def _ultra_hearing_score(path):
    """The same judgement made on the inaudible sweep: band peak over the
    band's own floor.

    Quieter, and also a better question. The click asks which microphone
    hears the ROOM best, and a webcam with a bright 2 kHz can win that while
    being deaf at 18 — then the sweep road inherits an ear that cannot do
    its job. Measured on a desk with three microphones, scoring on the sweep
    is the only way the pick answers the question the run will actually ask.
    """
    try:
        samples, rate = read_mono(path)
    except Exception:
        return 0.0
    if not samples:
        return 0.0
    got = ultra_arrival(samples, rate)
    if got is None:
        return 0.0
    _seconds, peak, floor = got
    return peak / (floor + 1.0)


def _pick_best_mic(sink, stimulus, tpl, candidates, score=None, volume=65536):
    """The microphone that hears this room best, out of several.

    One burst, everybody listening: each candidate records the same sound at
    the same moment, so the comparison is of the microphones and nothing
    else. The alternative — trusting the system default — picks whatever the
    desktop happened to route notifications through, and on a machine with a
    studio microphone beside a webcam that is a coin toss the measurement
    then pays for.

    The burst is the caller's to choose. Asked for silence, the run hands in
    the inaudible sweep and a scorer to match: the click used to be played
    here regardless, at full volume, so a machine with more than one
    microphone got one loud beep out of a setting that promises none. Only
    ever fired where there was a choice to make, which is why a desk with a
    single microphone never saw it.

    Nothing about the system is changed: no default is moved, no capture
    level touched. Returns a name from `candidates`, or None if not one of
    them heard it.
    """
    recs, procs = {}, {}
    try:
        for name in candidates:
            path = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
            recs[name] = path
            try:
                procs[name] = subprocess.Popen(
                    recorder_args(name, path), stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL)
            except Exception:
                procs[name] = None
        time.sleep(PLAY_DELAY)
        try:
            subprocess.run(["paplay", "--device", sink,
                            "--volume", str(int(volume)), stimulus],
                           timeout=5, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except Exception:
            pass
        time.sleep(0.5)
    finally:
        # Every recorder is stopped on every road out — a listener left
        # running holds a microphone open for the rest of the session.
        for rp in procs.values():
            _stop_recorder(rp)
    judge = score if score is not None else (lambda p: _hearing_score(p, tpl))
    best, best_score = None, 0.0
    for name, path in recs.items():
        try:
            score = judge(path)
        except Exception:
            score = 0.0
        if score > best_score:
            best, best_score = name, score
        try:
            os.unlink(path)
        except OSError:
            pass
    return best


def _resolve_mic(mic):
    """The microphone this run will actually use.

    '' means the system default. A default that is a monitor, or that
    delivers exact zeros (hardware-muted), is swapped for the first
    alternative source that provably hears the room — a muted desk mic must
    not turn the whole feature off while a healthy webcam sits next to it.
    Returns (mic, description-or-None); (None, None) means nothing usable.
    """
    resolved = mic or _default_source_name()
    if _usable_mic_name(resolved) and _capture_alive(mic):
        return mic, None
    for name, desc in _alternative_mics(resolved):
        if _capture_alive(name):
            return name, desc
    return None, None


def find_arrivals(window, tpl, max_peaks):
    """Distinct click arrivals in one recording, seconds within `window`.

    A 1 ms envelope pass finds candidate bursts (≥25 % of the loudest);
    a candidate must be the maximum of its FIXED ±8 ms neighbourhood —
    the old running-reference merge let a rising chain of small steps
    drag the anchor along and fuse spread-out arrivals into one, under-
    reporting the spread. The matched filter then refines each candidate
    and near-duplicates within 8 ms collapse. Arrivals closer than ~8 ms
    still fuse (bounded by the 10 ms burst), which for a sync check reads
    as 'together' — that is exactly why counting peaks can never prove
    every speaker played, and the verify pass checks presence separately.
    """
    block = int(RATE * 0.001)
    if len(window) < block * 2:
        return []
    env = []
    for b in range(0, len(window) - block, block):
        m = 0
        for i in range(b, b + block):
            a = abs(window[i])
            if a > m:
                m = a
        env.append(m)
    top = max(env)
    if top < 1200:
        return []
    thresh = max(1200, top * 0.25)
    cands = []
    n = len(env)
    for i, v in enumerate(env):
        if v < thresh:
            continue
        lo = max(0, i - 8)
        hi = min(n, i + 9)
        if v < max(env[lo:hi]):
            continue
        cands.append(i)
    cands = sorted(sorted(cands, key=lambda i: -env[i])[:max_peaks])
    out = []
    for i in cands:
        coarse = i * block
        lo2 = max(0, coarse - block)
        hi2 = min(len(window), coarse + 2 * block)
        ci = max(range(lo2, hi2), key=lambda k: abs(window[k]))
        # Tight refine window: the candidate is already sample-accurate,
        # and the default ±15 ms would reach a LOUDER neighbouring burst —
        # both candidates then refine onto the same arrival and the spread
        # collapses to zero.
        out.append(_xcorr_refine(window, ci, tpl, 0.003)[0] / RATE)
    out.sort()
    dedup = []
    for t in out:
        if dedup and (t - dedup[-1]) < 0.008:
            continue
        dedup.append(t)
    return dedup


def make_ultra(path):
    """The inaudible stimulus, same shape as make_click one octave above
    hearing: a quiet steady tone to wake a sleeping Bluetooth link and open
    the speaker's noise gate, a beat of silence, then the sweep that is
    actually measured. The leader is up in the band too — an audible hum
    would defeat the point, and a link this does not wake simply fails the
    measurement, which is the caller's cue to fall back to the click."""
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        n_lead = int(RATE * LEADER_SECONDS)
        ramp = RATE * 0.05
        # The leader needs an edge at BOTH ends, and for a long time it had
        # one only where it starts. Stopping a tone at full level is a step,
        # and a step is broadband however high the tone sat: measured in this
        # very file, the audible 100 Hz-16 kHz band peaked at -34.9 dBFS at
        # the leader's last sample, 8.6 dB under the ultrasonic signal the
        # stimulus hides behind — and the ear is some sixty decibels better
        # down there than at 18 kHz. It was heard as a short high tick on
        # every play, which for a check that promises silence is the one
        # defect that matters. Two milliseconds of fall already put it back
        # at the file's own floor (-66.8 dBFS, where the sweep's edges sit);
        # 4 ms is the edge the chirp uses and leaves 173 windows of leader
        # over the gate against the 100 the detector needs to tell it from
        # the sweep.
        fall = max(1, int(RATE * 0.004))
        for i in range(n_lead):
            env = min(1.0, i / ramp, (n_lead - i) / fall)
            frames += struct.pack("<h", int(ULTRA_AMP * 0.35 * env
                                            * math.sin(2.0 * math.pi
                                                       * ULTRA_LEADER_HZ * i / RATE)))
        frames += b"\x00\x00" * int(RATE * ULTRA_GAP_SECONDS)
        for v in ultra_chirp():
            frames += struct.pack("<h", int(ULTRA_AMP * v))
        w.writeframes(bytes(frames))


def _raw_arrival_ultra(sink, ultra_wav, mic, seconds=3.2, trim=ULTRA_LEVEL_TRIM):
    """One capture's sweep arrival, seconds within the analysis window, or
    None when the band came back empty — a speaker whose codec or driver
    stops before 18 kHz, which is a real and common thing.

    The default window is sized for the DEPLOYED path, where a loopback's
    buffering can hold a sweep the better part of a second. A sweep aimed
    straight at a sink lands inside 1.3 s of the capture starting (0.6 s of
    warm-up, 0.46 s of stimulus before the sweep itself, then the link), so
    the direct callers pass a shorter one and get the same answer in less
    time — which is what keeps a run that measures with BOTH stimuli inside
    the widget's guard."""
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        _record_one(sink, ultra_wav, mic, rec, seconds,
                    volume=_ultra_volume_for(sink, trim))
        try:
            samples, rate = read_mono(rec)
        except Exception:
            return None
        got = ultra_arrival(samples, rate)
        return None if got is None else got[0]
    finally:
        try:
            os.unlink(rec)
        except OSError:
            pass


ULTRA_REPEATS = 3          # a median needs three; two that agree would let
                           # a pair of matching outliers through, and the
                           # click road's worst runs came in pairs
ULTRA_AGREE_S = 0.025      # two captures of one member must land this close
                           # before their number is believed. 25 ms is the
                           # widget's own "in sync" threshold: a disagreement
                           # smaller than that cannot change any verdict, and
                           # a bigger one means the chain is not steady enough
                           # to be measured right now.
ULTRA_SLOT_SECONDS = 1.8   # how much of ONE shared capture each member owns.
                           # The stimulus is 660 ms and a sweep aimed straight
                           # at a sink lands inside ~500 ms of it, so 1.8 s
                           # leaves the room's tail somewhere to die before the
                           # next member starts. The extractor searches by this
                           # SCHEDULE rather than by what the previous member
                           # did, so one silent speaker cannot shift the window
                           # the next one is found in.
ULTRA_ROUND_TRIES = 4      # shared captures a check may spend. Three are read
                           # for their middle; the fourth is there because a
                           # round does get lost — measured, one in five — and
                           # losing one must not cost the verdict.
                           #
                           # It used to be three, and two that agreed were
                           # enough. Both were wrong for ordinary hardware. A
                           # lost round left two, the two missed each other by
                           # 28 ms against a 25 ms window, and the check said
                           # nothing; measured over five runs each, that cost
                           # the webcam one verdict in five and a fourth round
                           # bought both microphones five out of five.
                           #
                           # And agreement was never proof: two readings that
                           # were BOTH wrong agreed inside 22 ms and published
                           # 145 ms where the room was 46. A middle of three
                           # cannot be carried by one bad round, and two bad
                           # ones have to agree with a good one to matter.
                           #
                           # Why a shared capture at all — measured on this
                           # desk, eight back-to-back captures of ONE speaker:
                           #
                           #   sink monitor : 1212.9 ms, 14 times out of 16
                           #   microphone   : scattered over 45-68 ms
                           #
                           # The playback starts on time; it is the MICROPHONE
                           # capture whose start wanders (a USB mic waking from
                           # suspend). One capture per member put that wander
                           # straight into the difference between two speakers,
                           # which is the only number this road produces. A/B
                           # over six rounds each, same room, same minute:
                           #
                           #   a capture per member : sd 30.8 ms, range 80.7
                           #   one shared capture   : sd 11.8 ms, range 24.1
                           #
                           # and three consecutive shared rounds came in at
                           # 1771.8 / 1771.8 / 1773.0. The detector was never
                           # the problem: benched against known truth through
                           # 400 ms of reverberation it reads the pair to
                           # 0.14 ms.
ULTRA_DIRECT_SECONDS = 3.2  # capture window for a sweep aimed at a sink.
                            # The SAME window the periodic check listens for,
                            # deliberately: two roads that measure the same
                            # pair through different windows disagree by a
                            # fixed amount forever, and then each one spends
                            # its life correcting the other. Measured here,
                            # shortening it to 2.0 moved the answer 17 ms.


def _ultra_pair_lag(wired, bt, ultra_wav, mic, raw=None):
    """How far the Bluetooth speaker trails the wired one, in ms, measured
    with the inaudible sweep — or None when this chain cannot carry it or
    the captures would not settle on one answer.

    `raw`, when given, receives every capture per sink (seconds within its
    own analysis window) whether or not a verdict came out of them. On
    2026-07-28 a run stored 44 where this room measures ~150-160, and no
    trace existed of what the captures actually read — the number could not
    be questioned, only overwritten. The captures are the evidence; the
    caller prints them.

    This is the number that ends up in the fine-tune field, and the clicks
    were not earning it. Measured on this desk, same room, same two
    speakers, same afternoon: the sweep returned 146, 148, 154, 156, 156,
    156, 158 and 164 over eight runs, a spread of 18 ms around a median of
    156. Three runs of the click road, minutes apart, gave a flat failure
    ("no click heard from the Bluetooth speaker"), a 58 and a 153 — and it
    was the 58 that a real calibration wrote into the map, leaving the room
    a hundred milliseconds out with a confident number on screen.

    The click's matched filter is not the weak part; it is very good at
    saying WHERE a burst sits once the burst is there. What it cannot do is
    make a Bluetooth speaker play one reliably at the moment it is asked,
    and a lag built from a burst that never arrived is worse than no lag at
    all. The sweep gets played the same way but survives the link, and
    nobody in the room has to hear any of it.

    Both arrivals come from the same stimulus in the same run, which is the
    only thing that makes their difference mean anything.
    """
    # The session's first recorder spawn starts capturing late and would
    # shift whichever speaker went first against the other. It doubles as
    # the capability probe: a chain that cannot carry 18 kHz says so here,
    # before any time is spent on repeats.
    if _raw_arrival_ultra(wired, ultra_wav, mic, ULTRA_DIRECT_SECONDS) is None:
        return None
    got = {}
    # INTERLEAVED, and this is the opposite of what the clicks do on purpose.
    # The clicks are measured in bursts so a Bluetooth link holds one power
    # state across the repeats — right for comparing LOUDNESS, wrong for
    # timing. Measured on this desk, same speakers, minutes apart: bursting
    # the sweep gave 82 and 84 ms, interleaving it gave 138 and 136, and the
    # ear had already put the room near 145. A Bluetooth sink played again
    # immediately after itself still has its buffer part full and starts
    # sooner — a state it is never in while music runs. Alternating puts it
    # back where the listener actually finds it.
    acc = {wired: [], bt: []}
    for _ in range(ULTRA_REPEATS):
        for sink in (wired, bt):
            t = _raw_arrival_ultra(sink, ultra_wav, mic, ULTRA_DIRECT_SECONDS)
            if t is not None:
                acc[sink].append(t)
    if raw is not None:
        for sink in (wired, bt):
            raw[sink] = list(acc[sink])
    for sink in (wired, bt):
        if len(acc[sink]) < 2:
            return None
        # A bare median stood here, and with two captures a median is just
        # their mean — one wild capture dragged the stored lag by half its
        # own error, and nothing outvoted anything. The drift probe has
        # demanded two captures inside ULTRA_AGREE_S ever since it published
        # a 652/608/518 spread as three different verdicts; the calibration
        # is the road that PERSISTS a number, so it holds itself to at least
        # that. No agreeing pair means no answer, not a compromise.
        got[sink] = _two_that_agree(acc[sink], ULTRA_AGREE_S)
        if got[sink] is None:
            return None
    return (got[bt] - got[wired]) * 1000.0


def _stored_pair_ms(lag_ms):
    """The number CALIB_OK may store, or None when there is no such number.

    The map cannot deploy a negative pair — the wired reference is the
    frame's zero — so the old line clamped every settled negative to 0 in
    silence. Two different rooms hid behind that clamp: a hair below zero
    is a genuinely simultaneous pair rounded down by capture noise, and
    zero IS its honest number inside the 25 ms in-step bar; a settled
    reading further down is a transient state (a flushed Bluetooth buffer
    runs ahead until its stream re-rolls, measured at -149 ms once) that
    must be remeasured, not stored as a confident zero."""
    if lag_ms <= -(ULTRA_AGREE_S * 1000.0):
        return None
    return max(0, round(lag_ms))


def _print_raw(by, arrivals):
    """One line per timed sink: the stimulus that produced the captures and
    every arrival it gave, in ms within each capture's own window. Printed
    on failures too — a run that refuses is exactly the one whose captures
    are worth reading the next morning."""
    for sink, ts in arrivals.items():
        if ts:
            print("CALIB_RAW %s %s %s"
                  % (by, sink, " ".join("%.1f" % (t * 1000.0) for t in ts)))


def _raw_arrival(sink, click, mic):
    """The loudest moment of one capture, seconds within the analysis
    window — no shape gate, the verify's agreement check is the judge."""
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        _record_one(sink, click, mic, rec, 3.2)
        try:
            samples, rate = read_mono(rec)
        except Exception:
            return None
        if not samples:
            return None
        start = int(ANALYSIS_SKIP * rate)
        if start >= len(samples):
            return None
        window = samples[start:]
        best_i = max(range(len(window)), key=lambda i: abs(window[i]))
        best = abs(window[best_i])
        # The bar is the ROOM's, not a constant: a studio mic over a
        # fan-loud desktop idles at a median of ~540, and a fixed 200 let
        # every capture of pure noise report an "arrival" — three of those
        # agree by chance often enough to feed a fabricated residual into
        # the stored lags. Standing 4x above the capture's own median is
        # the same impulsiveness the calibration demands.
        med = sorted(abs(s) for s in window)[len(window) // 2]
        if best < max(200, 4 * med):
            return None  # nothing rose above the room
        return best_i / rate
    finally:
        try:
            os.unlink(rec)
        except OSError:
            pass


def _room_is_loud(mic, seconds=1.5):
    """One stimulus-free capture: True when the SILENT room already carries
    an impulse that would pass the arrival gate. The verify measures each
    speaker by its loudest moment, so a room with its own loud transients
    (music left playing, a conversation) can hand a fabricated arrival to
    the agreement check — this catches that before a single click is played
    and lets the caller ask for a quiet room instead of storing noise."""
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    rp = None
    try:
        rp = subprocess.Popen(recorder_args(mic, rec), stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        time.sleep(seconds)
        # Closed here so the WAV can be read, and again in the finally so a
        # run killed during that sleep does not walk away from a recorder
        # holding the microphone.
        _stop_recorder(rp)
        try:
            samples, rate = read_mono(rec)
        except Exception:
            return False  # can't tell — don't block the check on a read error
        if not samples:
            return False
        start = int(ANALYSIS_SKIP * rate)
        window = samples[start:] if start < len(samples) else samples
        if not window:
            return False
        best = max(abs(s) for s in window)
        med = sorted(abs(s) for s in window)[len(window) // 2]
        # The same shape a real arrival must clear (max(200, 4*med)), but
        # asked of a room with NO click in it: if silence already spikes
        # that high, a click cannot be told apart from the noise.
        return best >= max(200, 4 * med)
    finally:
        _stop_recorder(rp)
        try:
            os.unlink(rec)
        except OSError:
            pass


def _two_that_agree(times, tol=0.06):
    """The mean of the CLOSEST pair within `tol` of each other, else None.

    It used to take the first pair that fitted, which on three captures of
    a Bluetooth chain meant a 55 ms disagreement could win over a 3 ms one
    sitting right next to it — the loosest reading the tolerance allows,
    chosen by list order.
    """
    best = None
    best_gap = None
    for i in range(len(times)):
        for j in range(i + 1, len(times)):
            gap = abs(times[i] - times[j])
            if gap <= tol and (best_gap is None or gap < best_gap):
                best_gap = gap
                best = (times[i] + times[j]) / 2.0
    return best


def _set_mutes(sinks, muted):
    """Best-effort hardware mute for the verify's isolation — a missing
    pactl (test rig) just means the isolation is skipped."""
    for s in sinks:
        try:
            subprocess.run(["pactl", "set-sink-mute", s, "1" if muted else "0"],
                           timeout=3, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except Exception:
            pass


def _mute_states(sinks):
    """Each sink's mute flag right now, so the isolation can hand back what
    it borrowed instead of a guess.

    Unmuting everything at the end is only correct if nothing was muted to
    begin with. A speaker the listener had silenced on purpose — one leg of
    a stereo pair, a TV in another room — came back on after a check it had
    no part in, and the login replay carried that forward.

    A sink whose state cannot be read is left out: absent from the map means
    absent from the restore, which is the one answer that cannot be wrong.
    """
    out = {}
    for s in sinks:
        try:
            r = subprocess.run(["pactl", "get-sink-mute", s], timeout=3,
                               capture_output=True, text=True)
        except Exception:
            continue
        # "Mute: yes" / "Mute: no" — and gettext translates the WORD on a
        # localized desktop, so the C locale pinned for the rest of this
        # file's pactl parsing carries this too.
        txt = (r.stdout or "").strip().lower()
        if txt.endswith("yes"):
            out[s] = True
        elif txt.endswith("no"):
            out[s] = False
    return out


def _restore_mutes(prev):
    """Put back exactly what `_mute_states` recorded, sink by sink."""
    for s, was_muted in prev.items():
        _set_mutes([s], was_muted)


def _start_leash():
    """Die with the session that asked for the measurement.

    A run that outlives its launcher is a phantom clicking into a room where
    no UI can stop it. The old test — getppid() == 1 — could never fire:
    this process is launched under `timeout`, so its parent is that wrapper,
    and when the session's shell dies it is the SHELL that gets reparented,
    never us. The launcher therefore hands its own pid down in the
    environment; when that pid is gone, so is our reason to keep clicking.
    The getppid check stays as the fallback for a direct invocation.
    """
    try:
        leash = int(os.environ.get("ONAIR_LEASH_PID", "0"))
    except ValueError:
        leash = 0

    def _watch_parent():
        while True:
            time.sleep(1)
            gone = os.getppid() == 1
            if leash > 0 and not gone:
                try:
                    os.kill(leash, 0)
                except ProcessLookupError:
                    gone = True
                except OSError:
                    pass
            if gone:
                os.kill(os.getpid(), signal.SIGTERM)
                return

    threading.Thread(target=_watch_parent, daemon=True).start()


def cmd_verify(argv):
    """calibrate.py verify <combined_sink> <mic> <sink…> — the check-measure.

    Each speaker is measured ALONE, but through the LIVE combined sink —
    the others hardware-muted for two seconds — so every click rides the
    full deployed path: null sink, loopback delay, the device's own
    buffering, the Bluetooth link, the air. This is the path music takes
    and the one the listener's ears grade.

    The earlier design listened for overlapping arrivals in one shared
    recording, and it was optimistically blind twice over: in-sync
    arrivals fuse (uncountable), and a speaker much quieter at the mic
    slipped under the envelope threshold entirely — its arrival vanished
    and the spread read zero no matter how far out of step it really was.
    Field case: a Bluetooth speaker whose loopback buffering never showed
    up in the direct-click calibration read "spread 0" while trailing
    audibly. Sequential isolation has no such blind spot, and the
    recorder's spawn clock is stable enough to compare across consecutive
    captures (measured: ±1 ms over four spawns after the warm-up).

    Prints VERIFY_LAG <sink> <ms> per speaker (offset against the first),
    then VERIFY_OK <spread_ms>; VERIFY_PARTIAL <sink> when a speaker was
    not heard through the path (muted, off, dead route — the room is NOT
    confirmed); VERIFY_FAIL <reason> otherwise; always returns.
    """
    try:
        if len(argv) < 3:
            print("VERIFY_FAIL usage")
            return
        # The isolation mutes OTHER speakers while one is measured. If the
        # widget's guard timeout kills this process mid-member, a plain
        # SIGTERM would skip every finally-block and leave the machine's
        # audio half muted — not ours to break. Convert it to a normal
        # exit so the unmutes always run.
        signal.signal(signal.SIGTERM, lambda s, f: (_ for _ in ()).throw(SystemExit(1)))

        _start_leash()
        sink, mic = argv[0], argv[1]
        sinks = argv[2:2 + 8]
        # A muted member cannot answer through any path, and its silence
        # reads exactly like a dead route -- which is how a leg muted for a
        # phone call got filed as PARTIAL and shelved off the drift watch
        # for the life of the group. Same rule as the periodic check: sit
        # it out and say so by name. A state that cannot be read counts as
        # unmuted, so a machine without pactl changes nothing.
        all_members = sinks
        vmuted = _mute_states(all_members)
        for s in all_members:
            if vmuted.get(s):
                print("VERIFY_MUTED %s" % s)
        if any(vmuted.get(s) for s in all_members):
            kept = [s for s in all_members if not vmuted.get(s)]
            if len(kept) < 2:
                # One speaker cannot be out of step with itself, and a
                # verdict measured over the survivor would read as the
                # whole room's.
                print("VERIFY_FAIL members muted")
                return
            # Only the MEASURED list shrinks. The isolation below keeps
            # muting the whole room: a sat-out member whose mute the
            # listener lifts mid-run would otherwise leak its own late
            # copy of the stimulus into every capture that follows.
            sinks = kept
        # What the LISTENER's hand last showed, member by member. The
        # isolation reads every sink's mute right before muting it, so
        # those reads keep this current -- and it is what tells a mute the
        # listener threw from one our own restore failed to lift.
        listener_intent = dict(vmuted)
        # Same mic discipline as the calibration: a hardware-muted default
        # (or a monitor) must fail fast and honestly — or hand over to a
        # microphone that actually hears the room.
        mic, _vdesc = _resolve_mic(mic)
        if mic is None:
            print("VERIFY_FAIL microphone silent")
            return
        # Two stimulus-free captures BEFORE any click: the verify grades a
        # speaker by its loudest moment, so a room already full of loud
        # transients (music left playing, a TV) would let noise pose as an
        # arrival and store a fabricated residual. Require BOTH to be loud
        # so a single stray thump never fails an honest quiet room; the
        # widget turns this verdict into "pause other audio and try again".
        # The inaudible sweep is tried FIRST, and it changes what "quiet
        # enough" even means: speech, music and fans do not live at 18-19
        # kHz, so a room that is busy to the ear is silent to this
        # measurement. The audible precheck therefore guards only the
        # fallback, where it belongs — it used to fail honest rooms while
        # the sweep would have measured them fine.
        ultra = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
        click = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
        try:
            make_ultra(ultra)
            make_click(click)
            tpl = click_template()
            # The session's first recorder spawn starts capturing late and
            # would shift the first speaker's clock against the others. That
            # throwaway capture earns its keep twice: it also decides which
            # stimulus this chain can carry, ONCE, before any member is
            # measured. Deciding per member would be worse than useless —
            # the lag is a DIFFERENCE between two arrivals, and two
            # arrivals found through different signals are not comparable.
            # The warm-up asks a MEMBER, not the group. Played into the
            # group every speaker renders the same sweep at its own delay,
            # and the overlapping copies scramble which probe peaks when —
            # measured on this desk through the live group: the low probe
            # peaked in window 17, the high one in 24 and the middle one in
            # 28, so the climb the detector needs was inside out and the
            # whole inaudible road was refused for a pair of speakers that
            # both answer perfectly when addressed on their own (13213 and
            # 10362 against a gate of 86). The measurement itself already
            # isolates members; the gate that decides whether it may run has
            # to be measured the same way. Ask them in turn, give up only
            # when nobody answers.
            use_ultra = _ultra_allowed() and any(
                _raw_arrival_ultra(m, ultra, mic, ULTRA_DIRECT_SECONDS,
                                   trim=ULTRA_LEVEL_WARMUP) is not None
                for m in (sinks or [sink]))
            if not use_ultra and _ultra_only():
                # The listener asked for a measurement nobody can hear, and
                # this chain cannot deliver one. Clicking anyway is the one
                # thing the setting exists to prevent — say so instead, and
                # let the widget explain what would fix it.
                print("VERIFY_FAIL inaudible unavailable")
                return
            if not use_ultra:
                measure_once(sink, click, mic, tpl)
                # Only the audible click needs a quiet room. The sweep lives
                # where speech and music do not, so a room that is busy to
                # the ear measures fine — which is why this gate moved here
                # instead of standing in front of everything.
                if _room_is_loud(mic) and _room_is_loud(mic):
                    print("VERIFY_FAIL room not quiet")
                    return
            arrivals = {}
            # Bluetooth members are measured FIRST, and with a longer
            # settle: a real JBL Flip 7 was measured to drop its first
            # burst(s) for ~1 s after the OTHER member's hardware
            # mute/unmute cycle — with BT measured last and a 0.3 s
            # settle, 2 of 3 verify runs ended in a false PARTIAL on a
            # perfectly healthy leg.
            ordered = sorted(sinks,
                             key=lambda s: (0 if s.startswith("bluez_") else 1, s))
            for member in ordered:
                # The WHOLE room minus the one under measurement, sat-out
                # members included: their mute is re-asserted every round,
                # so a mid-run unmute cannot pollute the capture, and the
                # restore hands back whatever state the round began with.
                others = [s for s in all_members if s != member]
                agreed = None
                # Bound before the try below ever runs: the unsteady-or-deaf
                # question reads it after the loop, and a mute call that
                # throws would otherwise leave it unbound.
                times = []
                # The level this member answered at, held across both rounds
                # so its captures stay comparable with each other.
                heard_at = None
                for round_no in range(2):
                    was = {}
                    try:
                        # The mute call sits INSIDE the try: the guard's
                        # SIGTERM arrives as SystemExit mid-line, and landing
                        # in the middle of _set_mutes with the finally not yet
                        # armed would leave half the room hardware-muted.
                        # The read comes first and the finally puts back only
                        # what it managed to read, so the restore is right
                        # however far either call got.
                        was = _mute_states(others)
                        # Read before OUR mute lands: this is the listener's
                        # own hand, and the conviction below leans on it.
                        listener_intent.update(was)
                        _set_mutes(others, True)
                        # let the mutes land — and give a Bluetooth chain
                        # its post-mute wake-up time (longer on the retry).
                        time.sleep((0.9 + 0.5 * round_no)
                                   if member.startswith("bluez_") else 0.3)
                        # A burst that rode a Bluetooth codec and a speaker
                        # DSP arrives SMEARED — the template-match gate that
                        # guards the direct clicks would call it noise
                        # (measured 0.02 against the direct clicks' 0.6).
                        # Through the deployed path the discriminator is
                        # AGREEMENT instead: a real buffered arrival repeats
                        # at the same offset click after click (measured
                        # twice within 50 ms); room noise does not repeat.
                        # Raw loudest-moment per capture, up to three tries
                        # for two that agree.
                        times = []
                        # The sweep road answers to the drift probe's own
                        # settle rule. The default 60 ms window was wider
                        # than this room's measured capture spread, and on
                        # 2026-07-29 it blessed two garbage arrivals that
                        # agreed at ~419 ms late — the fold then wrote that
                        # into the map and the room played inverted. The
                        # clicks road keeps the wide window: its loudest-
                        # moment arrivals carry no matched filter and 25 ms
                        # would starve it in an ordinary room.
                        vtol = ULTRA_AGREE_S if use_ultra else 0.06
                        for vAttempt in range(3):
                            # Same ladder the periodic check climbs: quiet
                            # first, louder only for a member still unheard,
                            # and once it answers it keeps that level for the
                            # rest of its captures. The clicks road has no
                            # ladder — it is already as loud as it gets.
                            vStep = heard_at if heard_at is not None else \
                                ULTRA_LEVEL_STEPS[min(vAttempt,
                                                      len(ULTRA_LEVEL_STEPS) - 1)]
                            t = (_raw_arrival_ultra(sink, ultra, mic, trim=vStep)
                                 if use_ultra
                                 else _raw_arrival(sink, click, mic))
                            if t is not None:
                                if use_ultra:
                                    heard_at = vStep
                                times.append(t)
                            agreed = _two_that_agree(times, vtol)
                            if agreed is not None:
                                break
                    finally:
                        _restore_mutes(was)
                    agreed = _two_that_agree(times, vtol)
                    if agreed is not None:
                        break
                    # One more round for a speaker that slept through the
                    # first — a missed arrival is usually the device waking
                    # up, not a dead leg.
                    time.sleep(0.4)
                if agreed is None:
                    # A mute that landed AFTER the entry check leaves the
                    # same total silence a dead route would -- the periodic
                    # check takes this second look before convicting, and
                    # this road's window is far longer.
                    if _mute_states([member]).get(member):
                        # Two hands can have thrown that switch. If the
                        # listener's last-seen state says muted, the member
                        # sits out by name. If it says unmuted, the mute is
                        # OUR isolation's restore gone wrong on a drowsy
                        # sink -- filing that as the listener's would keep
                        # the speaker silenced past every safety net, so
                        # repair it and refuse to grade a run measured
                        # under our own leak.
                        if listener_intent.get(member):
                            print("VERIFY_MUTED %s" % member)
                            continue
                        _set_mutes([member], False)
                        print("VERIFY_UNSTEADY %s" % member)
                        return
                    # WHICH stimulus went unheard decides what the silence
                    # means. A speaker that misses the audible click has
                    # nothing audible behind it; one that misses the sweep
                    # may be a perfectly good speaker whose codec stops
                    # before 18 kHz — and the widget must not evict it for
                    # that. Said out loud so the caller can tell them apart.
                    print("VERIFY_BY %s" % ("sweep" if use_ultra else "clicks"))
                    if use_ultra and times:
                        # Heard, but the captures would not settle inside the
                        # window. Deafness is a property of the CHAIN and
                        # gets a member shelved off the drift watch for the
                        # life of the group; unsteadiness is a property of
                        # the moment. Filing this under PARTIAL did exactly
                        # that shelving to a band-capable speaker.
                        print("VERIFY_UNSTEADY %s" % member)
                        return
                    print("VERIFY_PARTIAL %s" % member)
                    return
                arrivals[member] = agreed
            measured = [m for m in sinks if m in arrivals]
            if len(measured) < 2 and len(all_members) >= 2:
                # Muting mid-run took the comparison away just as muting
                # up front would have.
                print("VERIFY_FAIL members muted")
                return
            if not measured:
                print("VERIFY_FAIL members muted")
                return
            base = min(arrivals.values())
            for member in measured:
                print("VERIFY_LAG %s %d" % (member,
                                            round((arrivals[member] - base) * 1000.0)))
            spread = (max(arrivals.values()) - base) * 1000.0
            print("VERIFY_OK %d" % max(0, round(spread)))
        finally:
            for _f in (ultra, click):
                try:
                    os.unlink(_f)
                except OSError:
                    pass
    except Exception as exc:  # a failure must be a sentinel, never a crash
        print("VERIFY_FAIL %s" % str(exc)[:120])


# ── Passive drift estimation from program material ───────────────────────
# No clicks, no interruption: capture what the room is PLAYING (mic) next
# to what was SENT (the combined sink's monitor) and cross-correlate their
# energy ENVELOPES. Each speaker's path shows up as a correlation peak at
# its total delay; in sync the peaks merge into one, drifted apart they
# split — the separation IS the inter-speaker error, and the (unknown,
# common) capture start skew cancels out of it. Envelopes at 500 Hz keep
# the pure-python correlation fast (~740 lags x ~4000 blocks) with ±2-4 ms
# resolution — plenty against the 25 ms audibility bar.

DRIFT_SECONDS = 8.0
DRIFT_ENV_MS = 2                # envelope block: 2 ms -> 500 Hz
DRIFT_MIN_LAG_S = 0.02          # below this the peaks are one blur anyway
DRIFT_MAX_LAG_S = 1.5
DRIFT_SPLIT_MIN_MS = 25         # a second peak closer than this is sidelobe
DRIFT_SECOND_PEAK = 0.4         # second arrival must be a REAL echo of the first
DRIFT_MIN_CORR = 0.25           # below this the material carried no timing


def _envelope(samples, rate, block_ms=DRIFT_ENV_MS):
    n = max(1, int(rate * block_ms / 1000.0))
    out = []
    for i in range(0, len(samples) - n, n):
        acc = 0
        for j in range(i, i + n):
            v = samples[j]
            acc += v * v
        out.append(math.sqrt(acc / float(n)))
    return out


def _drift_estimate(mic_samples, mon_samples, rate):
    """One verdict line for a simultaneous mic + monitor capture pair.

    Returns "DRIFT_QUIET" (nothing playing / dead mic), "DRIFT_NOSIG"
    (material too flat to carry timing), or "DRIFT_EST <ms>" where 0
    means the arrivals merge into one peak (in sync)."""
    if _is_dead_capture(mic_samples) or _is_dead_capture(mon_samples):
        return "DRIFT_QUIET"
    env_rate = 1000.0 / DRIFT_ENV_MS
    a = _envelope(mic_samples, rate)
    b = _envelope(mon_samples, rate)
    n = min(len(a), len(b))
    if n < int(2.0 * env_rate):
        return "DRIFT_QUIET"
    a, b = a[:n], b[:n]
    ma = sum(a) / n
    mb = sum(b) / n
    a = [v - ma for v in a]
    b = [v - mb for v in b]
    ea = math.sqrt(sum(v * v for v in a)) or 1.0
    eb = math.sqrt(sum(v * v for v in b)) or 1.0
    lo = int(DRIFT_MIN_LAG_S * env_rate)
    hi = min(int(DRIFT_MAX_LAG_S * env_rate), n - int(0.5 * env_rate))
    if hi <= lo:
        return "DRIFT_NOSIG"
    corr = []
    for lag in range(lo, hi):
        s = 0.0
        for t in range(lag, n):
            s += a[t] * b[t - lag]
        corr.append(s / (ea * eb))
    i1 = max(range(len(corr)), key=lambda i: corr[i])
    c1 = corr[i1]
    if c1 < DRIFT_MIN_CORR:
        return "DRIFT_NOSIG"
    guard = int(DRIFT_SPLIT_MIN_MS * env_rate / 1000.0)
    rest = [(i, c) for i, c in enumerate(corr) if abs(i - i1) > guard]
    if not rest:
        return "DRIFT_EST 0"
    i2, c2 = max(rest, key=lambda p: p[1])
    if c2 < DRIFT_SECOND_PEAK * c1:
        return "DRIFT_EST 0"
    # Rhythm guard, learned from a live false positive: music with a
    # steady beat is SELF-similar in its envelope (120 BPM = a 500 ms
    # period), and that self-similarity paints a second cross-correlation
    # peak exactly one beat away from the true one — measured live as a
    # phantom "508 ms split" on an in-sync room. If the MONITOR's own
    # autocorrelation is high at the candidate separation, the second
    # peak is the music, not a speaker: this material cannot answer.
    lag_d = abs(i2 - i1)
    auto = 0.0
    for t in range(lag_d, n):
        auto += b[t] * b[t - lag_d]
    auto /= (eb * eb)
    if auto > 0.3:
        return "DRIFT_NOSIG"
    ms = lag_d * 1000.0 / env_rate
    return "DRIFT_EST %d" % round(ms)


def _ultra_allowed():
    """Settings can switch the inaudible sweep off. Dogs hear to about
    60 kHz and cats past that, so 18-19 kHz is not silence to them — it is
    a quiet high note. This sweep is 12 dB quieter than the click it
    replaced and lasts 60 ms, which is a different animal from the
    continuous 20-65 kHz repellers the distress studies looked at, but
    "my dog reacts to it" is not an argument an owner should have to win."""
    return os.environ.get("ONAIR_NO_ULTRA", "") != "1"


def _ultra_only():
    """Whether the inaudible sweep is the ONLY stimulus this run may use.

    The setting reads "measure with a tone too high to hear", and an
    unattended check that quietly falls back to clicks breaks that promise
    in the one place it matters: the listener is in the room, the music is
    playing, and the beeps arrive anyway. A calibration the user just
    started is a different matter — they are sitting there waiting for a
    measurement, and its own button says it plays clicks.
    """
    return os.environ.get("ONAIR_ULTRA_ONLY", "") == "1"


def _drift_members(rest):
    """(sink, applied_lag_ms) pairs off the tail of argv, or [] if the tail
    is not well-formed -- an empty list drops the probe onto the passive
    road, which is the right answer when we cannot trust the arithmetic.

    Pairs rather than a "sink=lag" spelling: the sink name is PipeWire's to
    choose, and betting that it never contains our separator buys nothing.
    """
    if len(rest) % 2 != 0:
        return []
    out = []
    for i in range(0, len(rest), 2):
        sink = rest[i]
        if not sink:
            continue
        try:
            lag = float(rest[i + 1])
        except (TypeError, ValueError):
            return []
        out.append((sink, lag))
    return out


def ultra_arrivals_in_slots(samples, rate, plays, slot_seconds=ULTRA_SLOT_SECONDS):
    """Where each member's sweep landed inside ONE capture.

    `plays` is when each member was TOLD to play, in seconds from the start of
    the capture. A member's sweep can only be inside its own slot, so the
    windows come from that schedule and not from where the previous member was
    found — one silent speaker would otherwise slide the window its neighbour
    is searched in, and the neighbour's arrival would be credited to it.

    Returns one entry per slot: seconds from THAT member's own play to its
    sweep, or None. Not from the start of the capture — the slots are spaced
    by the schedule, and an answer measured from the capture would carry that
    spacing into the difference between two members and report a room 800 ms
    out that is perfectly in tune. What survives is the capture's own start
    offset, which is the same unknown for every member in here and cancels
    where it is supposed to.

    Pure — takes samples, touches no hardware, and is what the tests drive.
    """
    out = []
    for t0 in plays:
        a = int(max(0.0, t0) * rate)
        b = min(len(samples), int((max(0.0, t0) + slot_seconds) * rate))
        # Too little left to hold a stimulus: say nothing rather than guess.
        if b - a < int(rate * (LEADER_SECONDS + ULTRA_GAP_SECONDS)):
            out.append(None)
            continue
        # The recorder's opening pop belongs to the beginning of the CAPTURE,
        # so only a slot that reaches back into it has to skip anything.
        got = ultra_arrival(samples[a:b], rate,
                            skip_seconds=max(0.0, ANALYSIS_SKIP - max(0.0, t0)))
        out.append(None if got is None
                   else got[0] + a / float(rate) - max(0.0, t0))
    return out


def ultra_rounds_verdict(rounds, lags_ms, tol_ms):
    """Two shared captures that agree, folded into per-member landings.

    Each round is one capture's arrivals, one entry per member, None where a
    member went unheard. Only DIFFERENCES within a round carry meaning: the
    capture's own start time is unknown — measured, it wanders over 45-68 ms —
    and it cancels between members of the same round and nowhere else. So the
    agreement is checked on differences, the answer is a difference, and two
    rounds are never mixed into one verdict.

    Two that agree is the quick answer. When none of them agree, three or more
    still have one between them: the MEDIAN. Requiring agreement was measured
    to be the thing that shuts ordinary hardware out — round-to-round scatter
    on this desk runs 10-20 ms with a 25 ms window, so a pair lands inside it
    only sometimes, and which microphone happens to succeed is luck rather
    than quality. Head to head in the same room, the studio microphone
    scattered 63.8 ms across four rounds while the webcam scattered 22.3, and
    an earlier four-round sample had said the opposite. The median needs no
    two readings to agree with each other, which is the whole point.

    Returns (landings, spread_ms) with landings relative to the first member
    heard, or None when there is nothing to say. Pure.
    """
    # The middle of three or more. There is no quicker path on purpose: two
    # readings that agree are not two readings that are right, and a pair of
    # equally wrong ones published 145 ms in a room measuring 46.
    if len(rounds) < 3:
        return None
    heard = [k for k in range(len(lags_ms))
             if sum(1 for r in rounds if r[k] is not None) >= 3]
    if len(heard) < 2:
        return None
    ref = heard[0]
    per = {}
    for r in rounds:
        if r[ref] is None:
            continue
        for k in heard:
            if r[k] is None:
                continue
            per.setdefault(k, []).append(
                (r[k] - r[ref]) * 1000.0 + lags_ms[k] - lags_ms[ref])
    mid = {}
    for k in heard:
        v = sorted(per.get(k, []))
        if len(v) < 3:
            return None
        med = (v[len(v) // 2] if len(v) % 2
               else 0.5 * (v[len(v) // 2 - 1] + v[len(v) // 2]))
        # A middle is only an answer when the readings actually gather around
        # it. 120, 220 and 320 has a middle too, and it is not a room — it is
        # a chain that cannot be read today, which is what DRIFT_UNSTEADY is
        # for. Most of them have to sit near it; one flyer may not.
        near = sum(1 for x in v if abs(x - med) <= 1.5 * tol_ms)
        if near * 2 <= len(v):
            return None
        mid[k] = med
    base = None
    for r in rounds:
        if r[ref] is not None:
            base = r[ref] * 1000.0 + lags_ms[ref]
            break
    vals = [mid[k] for k in heard]
    return ({k: base + mid[k] for k in heard}, max(vals) - min(vals))


def _shared_round(members, ultra_wav, mic, trim, slot_seconds=ULTRA_SLOT_SECONDS):
    """One capture; every member played into it in turn.

    The whole point is the single clock: the microphone's start is unknown but
    it is the SAME unknown for every member in here, so it drops out of the
    differences this road exists to produce.
    """
    plays = [PLAY_DELAY + i * slot_seconds for i in range(len(members))]
    total = PLAY_DELAY + len(members) * slot_seconds + 0.4
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        rp = subprocess.Popen(recorder_args(mic, rec), stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        pps = []
        try:
            begun = time.monotonic()
            for i, (sink, _lag) in enumerate(members):
                # Each play is held to its own slot: the extractor searches by
                # this schedule, so a play that drifted late would be hunted
                # for in the wrong window. The play is NOT waited on — a
                # dying sink used to hold a blocking paplay for its full 5 s
                # timeout, which pushed every later member ~3 s past its own
                # slot while the extractor kept searching on schedule: the
                # stalled member's neighbours were the ones that went unheard,
                # and in a two-speaker room that shelved the healthy one and
                # retired the whole check. Fire, move on, reap at the end.
                time.sleep(max(0.0, plays[i] - (time.monotonic() - begun)))
                try:
                    pps.append(subprocess.Popen(
                        ["paplay", "--device", sink, "--volume",
                         str(int(_ultra_volume_for(sink, trim))), ultra_wav],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                except OSError:
                    # A player that cannot even start costs this member its
                    # slot, nobody else's.
                    pass
            time.sleep(max(0.0, total - (time.monotonic() - begun)))
        finally:
            _stop_recorder(rp)
            for pp in pps:
                # The sweep is 660 ms against a 1.8 s slot, so a player still
                # alive here is wedged on its sink — the capture is over and
                # nothing it could still say matters.
                try:
                    if pp.poll() is None:
                        pp.kill()
                    pp.wait()
                except Exception:
                    pass
        try:
            samples, rate = read_mono(rec)
        except Exception:
            return [None] * len(members)
        return ultra_arrivals_in_slots(samples, rate, plays, slot_seconds)
    finally:
        try:
            os.unlink(rec)
        except OSError:
            pass


def _drift_by_ultra(combined, members, mic):
    """How far apart the speakers land TODAY, in ms, or None when this
    chain cannot carry the inaudible signal.

    `members` is a list of (sink, applied_lag_ms) pairs.

    The automatic check was passive for one reason only: a click every six
    minutes would have been intolerable, so it correlated whatever the
    music happened to carry and shrugged when the material was flat --
    which is where "too quiet to tell" came from. Nobody hears the sweep,
    so that compromise is gone: the check plays its own signal and
    measures instead of guessing. It also needs no volume parking and no
    hardware mutes, because the music never has to get out of its way.

    The lag has to be added back by hand, and getting this wrong is worse
    than not measuring at all. Music reaches a member through a loopback
    carrying that member's latency_msec, which is the whole compensation;
    a sweep played STRAIGHT at the member sink goes round it and times the
    bare hardware. Take those raw arrivals as the answer and a perfectly
    calibrated room reports the full spread the calibration exists to
    cancel -- 150 ms on this desk -- and the caretaker sets off an
    automatic re-verify every six minutes forever. arrival + applied_lag
    is where the ear actually hears that speaker, so the spread of THAT is
    the drift, and it is zero on a room still in tune."""
    # A muted member cannot be heard and must not be judged: the sweep into
    # it comes back as silence however healthy the speaker is, and silence
    # here reads as deafness — which shelves it for the LIFE of the group.
    # A listener who muted one leg for a phone call got that leg unwatched
    # for the rest of the session. Sit it out for this check instead; a
    # state that cannot be read counts as unmuted, so a machine without
    # pactl changes nothing.
    mstates = _mute_states([m[0] for m in members])
    members = [m for m in members if not mstates.get(m[0])]
    if len(members) < 2:
        return None
    ultra = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        make_ultra(ultra)
        # The session's first recorder spawn starts capturing late and
        # would shift the first member against the rest. The same
        # throwaway the manual measurement uses earns its keep twice here
        # too: it also decides whether this chain carries 18 kHz at all.
        # The warm-up goes where the MEASUREMENT goes: straight at a member.
        # It used to be played into the combined sink, which is a different
        # road entirely — the group's master rides on it, and at the 40 % a
        # room is usually left at the sweep arrives about three times
        # quieter (measured off the member's own monitor: 46 direct, 15
        # through the group). Below the gate, and the whole inaudible road
        # was refused for a pair of speakers that both carry the band
        # perfectly well when addressed directly.
        # It asked exactly one member — whichever happened to be first in
        # the list — and a group led by a speaker that stops before 18 kHz
        # had the whole inaudible road refused on its behalf. Which member
        # leads is an accident of enumeration order, so ask them in turn and
        # give up only when nobody answers at all.
        # Rounds, not per-member captures. A round plays every member into
        # ONE recording, so the microphone's own start time — measured
        # wandering over 45-68 ms while the playback stayed put — is a
        # constant inside it and cancels out of every difference taken from
        # it. Two rounds that agree are the verdict; they are never mixed,
        # because two arrivals from two captures carry two different unknowns
        # and their difference is exactly the noise this removes.
        lags = [m[1] for m in members]
        rounds = []
        # Heard in ANY round, even one that could not be used. A round needs
        # two members to hold a difference, so a room where only one speaker
        # answers produces no usable round at all — and reading deafness off
        # the usable rounds alone then called that one speaker deaf too, which
        # shelves it for the life of the group. It answered every time.
        heard_ever = set()
        step_i = 0
        for _ in range(ULTRA_ROUND_TRIES):
            got = _shared_round(members, ultra, mic,
                                ULTRA_LEVEL_STEPS[min(step_i,
                                                      len(ULTRA_LEVEL_STEPS) - 1)])
            heard_ever.update(k for k, v in enumerate(got) if v is not None)
            heard = sum(1 for v in got if v is not None)
            if heard >= 2:
                rounds.append(got)
            # Somebody was missed: the next round goes louder. A round is only
            # worth having when the members that matter are all inside it, so
            # the ladder is climbed by the ROUND and never by one member.
            if heard < len(members):
                step_i += 1
            verdict = ultra_rounds_verdict(rounds, lags, ULTRA_AGREE_S * 1000.0)
            if verdict is not None:
                break
        else:
            verdict = ultra_rounds_verdict(rounds, lags, ULTRA_AGREE_S * 1000.0)

        if verdict is None:
            # Heard, but never twice the same. That is a room the check cannot
            # read today, not a room out of tune — and saying so is the honest
            # answer, because the caller shelves a DEAF member for the life of
            # the group and must not do that to an unsteady one.
            # Deafness is read off what was heard in ANY round, never off the
            # usable ones: with one speaker silent no round can hold a
            # difference, so none is usable, and reading it the other way
            # called the speaker that answered every single time deaf too.
            # And a round that heard NOBODY testifies about the capture, not
            # the speakers: a microphone whose processing stops under 18 kHz
            # reads exactly like every speaker going deaf at once, and
            # shelving the whole room on that evidence killed the check for
            # the session. Only a chain that heard somebody has proven it
            # can carry the band at all.
            if heard_ever:
                # Read the mutes AGAIN before convicting. The entry check
                # clears a member muted before the probe, but a mute landing
                # in the first seconds of this ~20 s measurement leaves the
                # same total silence -- and the shelf it earns lasts the
                # life of the group. Muted now explains silent throughout.
                still_muted = _mute_states(
                    [m[0] for j, m in enumerate(members) if j not in heard_ever])
                for k, (sink, _lag) in enumerate(members):
                    if k not in heard_ever and not still_muted.get(sink):
                        print("DRIFT_DEAF %s" % sink)
            # Two or more answered and still no pair could be made of them.
            # That is a room the check cannot read today, not a chain that
            # cannot carry the band — and the distinction matters, because the
            # caller shelves a DEAF member for the life of the group.
            if len(heard_ever) >= 2:
                print("DRIFT_UNSTEADY %s" % members[min(heard_ever)][0])
            return None

        landings, spread = verdict
        for k, (sink, _lag) in enumerate(members):
            if k in landings:
                # WHERE each speaker lands, not just how far apart the pair is.
                # The spread is unsigned by construction, so it can say "18 ms
                # out" and never which way — and that is the difference between
                # complaining and correcting.
                print("DRIFT_EAR %s %d" % (sink, round(landings[k])))
        # Deaf is "never heard in ANY round" — the same rule the no-verdict
        # road uses, and the verdict road forgot. The verdict only carries
        # members with three steady readings, and the ladder makes that gap
        # ordinary: a member that needed the louder rung misses round one,
        # answers rounds two and three, and holds two readings when the
        # steady pair verdicts and the loop breaks. Heard twice is not deaf,
        # and the shelf lasts the life of the group.
        deaf = [members[k][0] for k in range(len(members)) if k not in heard_ever]
        # Same second look the no-verdict road takes: silence explained by
        # a mute that landed mid-probe is not deafness.
        still_muted = _mute_states(deaf)
        deaf = [s for s in deaf if not still_muted.get(s)]
        for sink in deaf:
            # Named, not just counted: the caller remembers these and stops
            # PLAYING into them. Opening a stream on a sink is not free even
            # when nothing comes back.
            print("DRIFT_DEAF %s" % sink)
        # Never a silent truncation: a speaker outside the measurement is a
        # speaker whose drift nobody is watching — deaf or merely short of
        # rounds — and that belongs in the log rather than inside a number
        # that looks complete.
        left_out = sum(1 for k in range(len(members)) if k not in landings)
        if left_out:
            print("DRIFT_PARTIAL %d" % left_out)
        return spread
    finally:
        try:
            os.unlink(ultra)
        except OSError:
            pass


def cmd_drift(argv):
    if not argv:
        print("DRIFT_NOSIG")
        return
    combined = argv[0]
    # The same mic discipline the calibration and the verify apply. Without
    # it the default source can be a MONITOR of the very sink recorded on
    # the other channel — the two captures are then the same signal, the
    # correlation is perfect, and a room that never gets listened to reports
    # itself in sync forever.
    mic, _ddesc = _resolve_mic(argv[1] if len(argv) > 1 else "")
    if mic is None:
        print("DRIFT_QUIET")
        return
    # The inaudible road first, when the caller named the members and the
    # user has not switched the sweep off. It answers on material the
    # passive correlation cannot read at all -- talk radio, a quiet
    # passage, anything without a beat -- and it answers with a measured
    # arrival difference instead of a correlation peak, so the rhythm
    # false positive the passive road needs a guard against cannot happen.
    members = _drift_members(argv[2:])
    if members and _ultra_allowed():
        spread = _drift_by_ultra(combined, members, mic)
        if spread is not None:
            print("DRIFT_EST %d" % round(spread))
            return
    mic_f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    mon_f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    procs = []
    try:
        # One outer finally owns the WAVs: a recorder Popen that raises
        # (binary missing) must still unlink BOTH temp files, not just
        # reap the recorder it never started.
        try:
            procs.append(subprocess.Popen(recorder_args(mic, mic_f),
                                          stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL))
            procs.append(subprocess.Popen(monitor_recorder_args(combined, mon_f),
                                          stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL))
            time.sleep(DRIFT_SECONDS)
        finally:
            for p in procs:
                try:
                    p.terminate()
                    p.wait(timeout=2)
                except Exception:
                    try:
                        p.kill()
                        p.wait(timeout=1)
                    except Exception:
                        pass
        mic_s, rate = read_mono(mic_f)
        mon_s, _ = read_mono(mon_f)
    finally:
        for f in (mic_f, mon_f):
            try:
                os.unlink(f)
            except OSError:
                pass
    if not mic_s or not mon_s:
        print("DRIFT_QUIET")
        return
    print(_drift_estimate(mic_s, mon_s, rate))


def main():
    # The widget's guard runs EVERY mode under `timeout`, which SIGTERMs a
    # run that overran (a dying sink holding each paplay for its full 5 s).
    # A plain SIGTERM skips every finally-block — the calibration leaks its
    # click and recording WAVs, and the drift probe leaves two recorder
    # children holding the microphone open indefinitely. Convert it up
    # front so the finally blocks always run; cmd_verify re-installs the
    # same conversion around its own mute bookkeeping. SystemExit is not
    # caught by `except Exception`, so the sentinel protocols are unchanged.
    signal.signal(signal.SIGTERM, lambda s, f: (_ for _ in ()).throw(SystemExit(1)))
    # The leash belongs to EVERY mode, not just the verify: a calibration
    # left behind by a dead session clicks through the room for a full
    # minute, and a drift probe holds the microphone open the whole time.
    _start_leash()
    if len(sys.argv) > 1 and sys.argv[1] == "drift":
        try:
            cmd_drift(sys.argv[2:])
        except Exception:
            # The caller reads sentinels, never tracebacks — a missing
            # recorder binary is "cannot tell", not a stack dump.
            print("DRIFT_NOSIG")
        return
    if len(sys.argv) > 1 and sys.argv[1] == "verify":
        cmd_verify(sys.argv[2:])
        return
    if len(sys.argv) < 3:
        print("CALIB_FAIL usage")
        return
    wired, bt = sys.argv[1], sys.argv[2]
    mic = sys.argv[3] if len(sys.argv) > 3 else ""
    extras = sys.argv[4:4 + MAX_EXTRA_SINKS]
    # Which exact script produced this verdict. The widget reads the QML at
    # shell start but spawns this file fresh from disk on every run, so the
    # two can be generations apart: on 2026-07-28 an install landed between
    # a button press and the code it was written against, and proving which
    # detector had stored a bad lag took filesystem timestamps the next
    # day. The hash makes that a one-line journal answer.
    try:
        with open(__file__, "rb") as _self:
            print("CALIB_SRC %s" % hashlib.sha256(_self.read()).hexdigest()[:12])
    except OSError:
        pass
    click = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    ultra = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        # The microphone must provably hear ANYTHING before forty seconds of
        # clicks are spent against it — and a dead default must not end the
        # story while another mic in the room works.
        mic, mic_desc = _resolve_mic(mic)
        if mic is None:
            print("CALIB_FAIL microphone silent")
            return
        # With more than one microphone in the machine, WHICH one is not the
        # desktop's business to decide. The system default is whatever the
        # session last routed a notification through; a room measurement
        # deserves the ear that actually hears the room. Everyone listens to
        # one click and the best hearing wins — measured, not guessed, and
        # the winner is printed so the widget can ask for it again instead
        # of re-deciding on every run. Costs one click, and only when there
        # is a choice to make.
        # "" means "the system default" to the recorder, so the name has to
        # be resolved before anything can be compared or remembered.
        _mic_pool = [n for n, _d in _alternative_mics("")]
        _mic_now = mic or _default_source_name()
        if _usable_mic_name(_mic_now) and _mic_now not in _mic_pool:
            _mic_pool.append(_mic_now)
        if len(_mic_pool) > 1:
            # Asked for silence, the pick stays silent too. This used to
            # play the click no matter what the setting said — one full-
            # volume 2.2 kHz burst before an otherwise inaudible run, heard
            # on a desk with three microphones. It never showed up where the
            # work was done because the block only fires when there is more
            # than one to choose from, and that machine has one.
            if _ultra_only():
                make_ultra(ultra)
                _picked = _pick_best_mic(wired, ultra, None, _mic_pool,
                                         score=_ultra_hearing_score,
                                         volume=_ultra_volume_for(wired))
            else:
                make_click(click)
                _picked = _pick_best_mic(wired, click, click_template(), _mic_pool)
            if _picked:
                if _picked != _mic_now:
                    mic_desc = next((d for n, d in _alternative_mics("")
                                     if n == _picked), mic_desc)
                mic = _picked
                _mic_now = _picked
        if _usable_mic_name(_mic_now):
            print("CALIB_MICNAME %s" % _mic_now)
        if mic_desc:
            # The description is a DEVICE's own words (a Bluetooth mic
            # advertises any name it likes) — strip it to an inert charset
            # and one line so it cannot smuggle CALIB_* tokens into the
            # stdout parsing or markup into the notification. The underscore
            # is NOT in that charset: every token this script speaks carries
            # one ("CALIB_OK 500"), and a speaker free to advertise itself as
            # one could dictate a lag the microphone never measured.
            safe_desc = "".join(c if c.isalnum() or c in " .()-" else " "
                                for c in str(mic_desc))[:60].strip()
            print("CALIB_MIC %s" % (safe_desc or "another microphone"))
        make_click(click)
        tpl = click_template()
        wired_times, bt_times = [], []
        amps = {wired: [], bt: []}
        clipped_sinks = {}

        def note(sink, m, times):
            if m is None:
                return
            t, amp, clipped = m
            if times is not None:
                times.append(t)
            # A saturated burst still times fine, but its amplitude is the
            # microphone's rail, not the speaker's loudness — it must never
            # feed the level matching.
            if clipped:
                clipped_sinks[sink] = True
            else:
                amps.setdefault(sink, []).append(amp)

        # One throwaway click before anything counts: the session's very
        # first recorder spawn starts capturing late (half a second observed
        # on real hardware) and would shift one measurement's clock against
        # every other. Then each sink is measured as a BURST — all its
        # clicks back to back — so a Bluetooth link stays in one power state
        # across the repeats instead of drifting through sniff-mode between
        # interleaved turns.
        # The TIMING comes off the sweep whenever the chain carries it, and
        # it goes first: it is the number that lands in the fine-tune field,
        # and it is the one the clicks kept getting wrong. The clicks still
        # run below — the loudness matching needs a sound the microphone can
        # measure an amplitude of, which an inaudible one is not — but their
        # timing is now the FALLBACK, for a chain that stops before 18 kHz.
        ultra_lag = None
        sweep_raw = {}
        sweep_wild = None
        if _ultra_allowed():
            make_ultra(ultra)
            ultra_lag = _ultra_pair_lag(wired, bt, ultra, mic, sweep_raw)
            _print_raw("sweep", sweep_raw)
            if ultra_lag is not None and not (MIN_SANE_MS < ultra_lag < MAX_SANE_MS):
                sweep_wild = ultra_lag
                ultra_lag = None   # a wild sweep reading defers to the clicks
        # This is where the beeping actually lived. The sweep times the pair
        # inaudibly, and then the clicks ran ANYWAY — because the loudness
        # matching needs a sound whose amplitude at the microphone means
        # something, and 19 kHz does not: a speaker's response up there says
        # nothing about how loud it plays music. So the balance costs clicks,
        # always did, and the setting that promised silence never covered it.
        # Asked to stay inaudible, the run now measures the timing and skips
        # the balance, saying which part it left out.
        # Asked for silence and the sweep came back empty: there is nothing
        # left this run may play. The refusal used to sit in an `elif` under
        # `if not skip_levels`, where skip_levels was itself only true when
        # the sweep HAD worked — so the branch could never be reached, and a
        # chain that failed the sweep went on to click with the box ticked.
        if _ultra_only() and ultra_lag is None:
            # A sweep that answered, settled AND got rejected by the sanity
            # window is neither of the refusals below: the band provably
            # crossed the room, the number was just not believable. Calling
            # that "unavailable" would send the user moving the microphone
            # against their own CALIB_RAW evidence — the clicks road already
            # names this case, so use its words.
            if sweep_wild is not None:
                print("CALIB_FAIL implausible result %.0f ms" % sweep_wild)
                return
            # Two different refusals wearing one message would send the user
            # chasing the wrong fix: "unavailable" means the chain never
            # carried the band (move the microphone, or allow the clicks),
            # while captures that landed but agreed on nothing are a room
            # that would not sit still for the measurement — trying again is
            # the whole advice.
            unsettled = any(len(ts) >= 2
                            and _two_that_agree(ts, ULTRA_AGREE_S) is None
                            for ts in sweep_raw.values())
            print("CALIB_FAIL inaudible %s"
                  % ("reading would not settle" if unsettled else "unavailable"))
            return
        skip_levels = _ultra_only()
        if skip_levels:
            print("CALIB_NOLEVELS")
        else:
            measure_once(wired, click, mic, tpl)
            for _ in range(CLICK_REPEATS):
                note(wired, measure_once(wired, click, mic, tpl), wired_times)
            for _ in range(CLICK_REPEATS):
                note(bt, measure_once(bt, click, mic, tpl), bt_times)
            _print_raw("clicks", {wired: wired_times, bt: bt_times})
        # A speaker that never answered a click has no LEVEL, which costs it
        # its balance trim — but it no longer costs the whole run its
        # verdict, because the sweep already timed it. That failure is not
        # rare on a Bluetooth speaker: three runs by hand on this desk gave
        # one flat "no click heard from the Bluetooth speaker".
        click_ref = None
        if ultra_lag is None:
            if len(wired_times) < 2:
                print("CALIB_FAIL no click heard from the wired speaker")
                return
            if len(bt_times) < 2:
                print("CALIB_FAIL no click heard from the Bluetooth speaker")
                return
            # The clicks persist a number too, so they answer to the same
            # settle rule as the sweep. This road once wrote a confident 58
            # into a room whose truth was ~153: a burst the Bluetooth
            # speaker never played leaves the matched filter picking a
            # noise peak, and noise peaks scatter between captures where a
            # real click repeats itself. A bare median split the difference
            # with the garbage; now no agreeing pair means no verdict.
            wired_at = _two_that_agree(wired_times, ULTRA_AGREE_S)
            bt_at = _two_that_agree(bt_times, ULTRA_AGREE_S)
            if wired_at is None or bt_at is None:
                print("CALIB_FAIL clicks would not settle")
                return
            lag_ms = (bt_at - wired_at) * 1000.0
            if not (MIN_SANE_MS < lag_ms < MAX_SANE_MS):
                print("CALIB_FAIL implausible result %.0f ms" % lag_ms)
                return
            click_ref = wired_at
            # Which ear answered, so a run that reads oddly later can be
            # told apart from one that measured the other way.
            print("CALIB_BY clicks")
        else:
            lag_ms = ultra_lag
            print("CALIB_BY sweep")
        # Extra speakers get a couple of clicks each — and since every click
        # is timed anyway, their lag against the wired reference rides along
        # as CALIB_XLAG: a USB DAC or an HDMI TV in the group is off by its
        # own real amount, not by an assumed zero. One that stays silent
        # simply gets no lines; the timing verdict above is already in the
        # bag either way.
        #
        # An XLAG is a CLICK arrival minus the reference's CLICK arrival, and
        # that stays true when the sweep timed the Bluetooth speaker: each
        # difference is taken inside the stimulus that produced it, which is
        # the only way two arrivals can be subtracted from each other at all.
        # With no click heard from the reference there is nothing to subtract
        # from, so the extras simply go unmeasured this run — better than a
        # lag against a moment nobody observed.
        # When the clicks timed the pair, the extras subtract from the SAME
        # settled wired arrival the pair verdict used — one observed moment,
        # not two flavours of it. The sweep road keeps the click median: its
        # pair number never came from the clicks at all.
        if click_ref is not None:
            wired_ref = click_ref
        else:
            wired_ref = median(wired_times) if wired_times else None
        extra_times = {}
        for sink in ([] if skip_levels else extras):
            if sink in amps or sink in extra_times:
                continue
            extra_times[sink] = []
            for _ in range(LEVEL_REPEATS):
                note(sink, measure_once(sink, click, mic, tpl), extra_times[sink])
        for sink, vals in amps.items():
            if vals:
                print("CALIB_LVL %s %d" % (sink, median(vals)))
        for sink in clipped_sinks:
            if not amps.get(sink):
                # Every burst from this sink saturated the mic — no honest
                # level was measured. The widget keeps the old balance and
                # can tell the user to back the volume off.
                print("CALIB_CLIP %s" % sink)
        for sink, ts in extra_times.items():
            if len(ts) < LEVEL_REPEATS or wired_ref is None:
                continue
            # The extras persist a number too, so they answer to the pair's
            # settle rule: a plain mean here still carried half of a noise
            # peak's error into the map after both pair roads had learned to
            # refuse it. No agreeing clicks means this extra simply goes
            # unmeasured this run, same as one that stayed silent.
            x_at = _two_that_agree(ts, ULTRA_AGREE_S)
            if x_at is None:
                continue
            x_ms = (x_at - wired_ref) * 1000.0
            if MIN_SANE_MS < x_ms < MAX_SANE_MS:
                print("CALIB_XLAG %s %d" % (sink, round(x_ms)))
        # The wired speaker IS this frame's zero — the Bluetooth lag above
        # and every CALIB_XLAG are differences against it, and none of them
        # means anything without knowing which speaker they were subtracted
        # from. Naming it lets the widget clear whatever that sink was
        # carrying from an older frame. Leaving it is not a cosmetic
        # problem: measured on this desk, a stale 154 sitting under a fresh
        # 171 left the two speakers 17 ms apart in the delays where the
        # microphone had just measured 156, and the room read as calibrated
        # while it was a sixth of a second out.
        stored = _stored_pair_ms(lag_ms)
        if stored is None:
            print("CALIB_FAIL implausible result %.0f ms" % lag_ms)
            return
        print("CALIB_REF %s" % wired)
        print("CALIB_OK %d" % stored)
    except FileNotFoundError as exc:
        print("CALIB_FAIL missing tool: %s" % exc)
    except Exception as exc:  # a failure must be a sentinel, never a crash
        print("CALIB_FAIL %s" % str(exc)[:120])
    finally:
        for _wav in (click, ultra):
            try:
                os.unlink(_wav)
            except OSError:
                pass


if __name__ == "__main__":
    # Guarded, because this file is imported as well as run: the drift tests
    # load it with importlib, and a bare call ran main() with pytest's own
    # argv — resolving a microphone and starting a run against "sinks" named
    # after test files. Nothing came of it, but a test suite that reaches for
    # the microphone is a test suite that can make sound.
    main()
