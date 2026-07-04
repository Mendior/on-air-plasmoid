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

if [[ ! -f "$MPRIS_PY" ]]; then
    echo "mpris.py not found at $MPRIS_PY" >&2
    exit 1
fi

# Tapa AINULT sama state-faili vana daemon (restart-juht) — MITTE teiste
# plasmoidi-instantside daemoneid. Bus-nimed on nüüd instantsi-põhised,
# nii et nimekonflikti pole.
pkill -f "mpris.py $STATE_FILE" 2>/dev/null || true
sleep 0.3

# Koristus: kustuta orvuks jäänud failipaarid, mille daemonit enam ei ole
# (plasmashell'i crash vms). Elus instantside faile EI puututa.
for f in "$RUN_DIR"/arp-mpris-state-*.json; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$STATE_FILE" ]] && continue
    if ! pgrep -f "mpris.py $f" >/dev/null 2>&1; then
        ts="${f##*arp-mpris-state-}"
        ts="${ts%.json}"
        rm -f "$f" "$RUN_DIR/arp-mpris-cmd-$ts.txt" 2>/dev/null
    fi
done

# Koristus teistpidi: tapa daemonid, mille state-fail on kadunud.
for pid in $(pgrep -f "mpris.py $RUN_DIR/arp-mpris-state-" 2>/dev/null); do
    sf=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep 'arp-mpris-state' | head -1)
    if [[ -n "$sf" && ! -e "$sf" ]]; then
        kill "$pid" 2>/dev/null
    fi
done

# Truncate the command file before starting so old commands aren't replayed.
: > "$CMD_FILE"

# Detach with setsid + redirections so the parent shell returns immediately.
setsid -f python3 "$MPRIS_PY" "$STATE_FILE" "$CMD_FILE" >/dev/null 2>&1 < /dev/null
