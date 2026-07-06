#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
# Launcher for the MPRIS daemon. Called from the plasmoid with state and
# cmd file paths. Detaches from the parent so the QML executable engine
# doesn't keep a handle to it.
set -u

if [[ $# -lt 2 ]]; then
    echo "usage: start-mpris.sh <state_file> <cmd_file>" >&2
    exit 1
fi

STATE_FILE="$1"
CMD_FILE="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPRIS_PY="$SCRIPT_DIR/mpris.py"
RUN_DIR="$(dirname "$STATE_FILE")"
# Per-instance daemon log, truncated on every start (a $$-suffixed file would
# accumulate and escape the orphan cleanup below).
ts="${STATE_FILE##*arp-mpris-state-}"
LOG_FILE="$RUN_DIR/arp-mpris-${ts%.json}.log"

if [[ ! -f "$MPRIS_PY" ]]; then
    echo "mpris.py not found at $MPRIS_PY" >&2
    exit 1
fi

# The daemon needs python-dbus and PyGObject — probe here so a missing
# dependency is a visible launcher error instead of a silently dead child.
if ! python3 -c 'import dbus, dbus.service, dbus.mainloop.glib; from gi.repository import GLib' >/dev/null 2>&1; then
    echo "mpris: python-dbus / python-gobject (PyGObject) missing — media keys disabled" >&2
    exit 3
fi

# Kill ONLY the old daemon for this same state file (restart case) — NOT the
# daemons of other plasmoid instances. Bus names are now instance-specific,
# so there is no name conflict.
pkill -f "mpris.py $STATE_FILE" 2>/dev/null || true
sleep 0.3

# Cleanup: remove orphaned file pairs whose daemon is gone
# (plasmashell crash, etc.). Files of live instances are left untouched.
# 30 s age grace: a SECOND instance starting right now may have written its
# state file before its daemon becomes pgrep-visible — real orphans are
# minutes/hours old, startup transients are not.
now=$(date +%s)
for f in "$RUN_DIR"/arp-mpris-state-*.json; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$STATE_FILE" ]] && continue
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo "$now") ))
    [[ $age -gt 30 ]] || continue
    if ! pgrep -f "mpris.py $f" >/dev/null 2>&1; then
        ots="${f##*arp-mpris-state-}"
        ots="${ots%.json}"
        rm -f "$f" "$RUN_DIR/arp-mpris-cmd-$ots.txt" "$RUN_DIR/arp-mpris-$ots.log" 2>/dev/null
    fi
done

# Cleanup the other way around: kill daemons whose WHOLE file pair has
# vanished. Same 30 s grace: a freshly started neighbour daemon exists before
# the QML side writes its state file (~300 ms debounce) — don't kill it.
# Requiring the cmd file to be gone too protects a healthy sibling whose
# state file was raced away above: its cmd file always exists (recreated by
# its launcher and daemon), and legitimate teardown removes both together.
for pid in $(pgrep -f "mpris.py $RUN_DIR/arp-mpris-state-" 2>/dev/null); do
    et=$(ps -o etimes= -p "$pid" 2>/dev/null || echo 0)
    [[ ${et:-0} -gt 30 ]] || continue
    sf=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep 'arp-mpris-state' | head -1)
    cf="${sf/arp-mpris-state-/arp-mpris-cmd-}"
    cf="${cf%.json}.txt"
    if [[ -n "$sf" && ! -e "$sf" && ! -e "$cf" ]]; then
        kill "$pid" 2>/dev/null
    fi
done

# Truncate the command file before starting so old commands aren't replayed.
: > "$CMD_FILE"

# Detach with setsid + redirections so the parent shell returns immediately.
# Daemon output goes to the per-instance log so a crash leaves a diagnosable
# trace instead of vanishing into /dev/null.
setsid -f python3 "$MPRIS_PY" "$STATE_FILE" "$CMD_FILE" >"$LOG_FILE" 2>&1 < /dev/null
