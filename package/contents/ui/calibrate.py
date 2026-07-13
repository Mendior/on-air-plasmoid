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

Usage: calibrate.py <wired_sink_name> <bt_sink_name> [mic_source]
Prints: CALIB_OK <ms>   on success (ms = how much the BT sink trails)
        CALIB_FAIL <reason>
Always exits 0 — a failure is a sentinel, not a crash.
"""
import math
import os
import struct
import subprocess
import sys
import tempfile
import time
import wave

RATE = 48000
CLICK_REPEATS = 4          # median over several clicks rejects room noise
RECORD_SECONDS = 1.9
PLAY_DELAY = 0.6           # recording warm-up before the click is played
ANALYSIS_SKIP = 0.4        # recording start carries a loud mic/AGC pop —
                           # found empirically, it decays for ~0.3 s and
                           # otherwise wins the peak search every time
MIN_SANE_MS = -100.0       # BT ahead of wired by >100 ms means a bad measure
MAX_SANE_MS = 900.0


def make_click(path):
    """10 ms raised-cosine burst at 2.2 kHz — sharp but speaker-safe."""
    n = int(RATE * 0.010)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for i in range(n):
            env = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / n))
            val = int(24000 * env * math.sin(2.0 * math.pi * 2200.0 * i / RATE))
            frames += struct.pack("<h", val)
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


def peak_time(path):
    """Seconds from recording start to the click's arrival."""
    samples, rate = read_mono(path)
    if not samples:
        return None
    start = int(ANALYSIS_SKIP * rate)
    if start >= len(samples):
        return None
    window = samples[start:]
    best, best_i = 0, -1
    total = 0
    for i, s in enumerate(window):
        a = abs(s)
        total += a
        if a > best:
            best, best_i = a, i
    mean_abs = total / max(1, len(window))
    # A click is impulsive: it must stand far above the window's own noise
    # floor AND be loud in absolute terms, or we heard nothing click-like.
    if best_i < 0 or best < 1200 or best < 6 * mean_abs:
        return None
    return (start + best_i) / rate


def measure_once(sink, click, mic):
    """One click through `sink`, recorded from `mic`; returns arrival delta."""
    rec = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        args = ["pw-record", "--rate", str(RATE), "--channels", "1"]
        if mic:
            args += ["--target", mic]
        args.append(rec)
        rp = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        try:
            time.sleep(PLAY_DELAY)
            t_play = time.monotonic()
            subprocess.run(["paplay", "--device", sink,
                            "--volume", "65536", click],
                           timeout=5, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            time.sleep(max(0.0, RECORD_SECONDS - (time.monotonic() - t_play)))
        finally:
            rp.terminate()
            try:
                rp.wait(timeout=2)
            except subprocess.TimeoutExpired:
                rp.kill()
        peak = peak_time(rec)
        if peak is None:
            return None
        # Seconds between "told the sink to play" and "mic heard it". The
        # recording started PLAY_DELAY earlier, which is part of the constant
        # that cancels between the two sinks.
        return peak
    finally:
        try:
            os.unlink(rec)
        except OSError:
            pass


def median(values):
    s = sorted(values)
    return s[len(s) // 2]


def main():
    if len(sys.argv) < 3:
        print("CALIB_FAIL usage")
        return
    wired, bt = sys.argv[1], sys.argv[2]
    mic = sys.argv[3] if len(sys.argv) > 3 else ""
    click = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    try:
        make_click(click)
        wired_times, bt_times = [], []
        for _ in range(CLICK_REPEATS):
            t = measure_once(wired, click, mic)
            if t is not None:
                wired_times.append(t)
            t = measure_once(bt, click, mic)
            if t is not None:
                bt_times.append(t)
        if len(wired_times) < 2:
            print("CALIB_FAIL no click heard from the wired speaker")
            return
        if len(bt_times) < 2:
            print("CALIB_FAIL no click heard from the Bluetooth speaker")
            return
        lag_ms = (median(bt_times) - median(wired_times)) * 1000.0
        if not (MIN_SANE_MS < lag_ms < MAX_SANE_MS):
            print("CALIB_FAIL implausible result %.0f ms" % lag_ms)
            return
        print("CALIB_OK %d" % max(0, round(lag_ms)))
    except FileNotFoundError as exc:
        print("CALIB_FAIL missing tool: %s" % exc)
    except Exception as exc:  # a failure must be a sentinel, never a crash
        print("CALIB_FAIL %s" % str(exc)[:120])
    finally:
        try:
            os.unlink(click)
        except OSError:
            pass


main()
