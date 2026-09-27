#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
#
# The buffer writer's two safety nets for a host that dies without running
# its teardown, which is what a crash or a kill does.
#
#   tsguard.sh watch SHELL_PID HOST_PID WRITER_PID [SECONDS]
#   tsguard.sh sweep DIR SINCE_EPOCH_SECONDS
#
# Measured on the bench 2026-09-23: with the viewer killed mid-preview, the
# relay writer's shell was taken in by systemd --user and the whole chain
# (sh, timeout, curl, ffmpeg -t 3600) kept copying a FLAC station into the
# cache at ~128 KiB/s, for nobody, until its hour ran out. The only thing
# that ever stopped it was the widget's own teardown.
#
# No set -e on purpose: a probe that fails here is an answer (the process is
# gone), not an error to stop on.
set -u

# One /proc/PID/stat read and no process of its own: the watch asks this
# every tick for as long as the radio plays, and the sleep between two ticks
# is the only process the watch starts. The command name sits in parentheses
# and may itself hold spaces or parentheses, so the fixed fields are counted
# from the LAST ") ".
# Sets ST_STATE, ST_PARENT and ST_START; false when the process is gone.
read_stat() {
    local line
    { read -r line < "/proc/$1/stat"; } 2>/dev/null || return 1
    line=${line##*) }
    # shellcheck disable=SC2086  # the split into fields is the point
    set -- $line
    ST_STATE=$1 ST_PARENT=$2 ST_START=${20:-}
    [ "$ST_STATE" != Z ]
}

# Whether a shell is still where it was started: alive, and still the child
# of the host that started it. An orphaned shell is taken in by init or the
# session's subreaper, so its parent changes. That is the question rather
# than "is the host pid alive": a dead host's number can be handed out
# again, a changed parent cannot be faked.
still_home() {
    [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 1
    read_stat "$1" && [ "$ST_PARENT" = "$2" ]
}

watch() {
    local shell=${1:-} host=${2:-} writer=${3:-} every=${4:-5} born
    [[ $shell =~ ^[0-9]+$ && $host =~ ^[0-9]+$ && $writer =~ ^[0-9]+$ ]] || {
        echo "tsguard watch: SHELL HOST WRITER must be pids" >&2
        exit 2
    }
    # No /proc, no way to tell an orphan from a healthy writer. Guessing
    # would stop live radio; standing down leaves the old behaviour.
    read_stat "$writer" || exit 0
    born=$ST_START
    while :; do
        sleep "$every"
        # The writer ended on its own (window cap, stop, stream end). The
        # start time makes sure the number is still the same process before
        # anything is sent to it.
        read_stat "$writer" && [ "$ST_START" = "$born" ] || exit 0
        still_home "$shell" "$host" && continue
        # The same signal the stop road sends: ffmpeg closes the file, curl
        # leaves on the broken pipe, and the shell (if it is still there)
        # removes the pid and url files after its wait.
        kill -INT "$writer" 2>/dev/null
        exit 0
    done
}

sweep() {
    local dir=${1:-} since=${2:-} f x n w sh host stopped=0 removed=0 living=" "
    [[ -n $dir && $since =~ ^[0-9]+$ ]] || {
        echo "tsguard sweep: DIR SINCE" >&2
        exit 2
    }
    if [ ! -d "$dir" ]; then
        echo "__TS_SWEEP__ stopped=0 removed=0"
        exit 0
    fi
    for f in "$dir"/writer-*.pid; do
        [ -f "$f" ] || continue
        n=${f##*/writer-}
        n=${n%.pid}
        w="" sh="" host=""
        # "writer shell host". A file written before the owner was recorded
        # has one field, and its writer can only be a leftover.
        read -r w sh host _ < "$f" 2>/dev/null
        # Ours only if its argv still names this arm's buffer: a pid file
        # can outlive its writer and the number go to someone else.
        if [[ $w =~ ^[0-9]+$ ]] && read_stat "$w" \
            && grep -qzF -- "$dir/buffer-$n." "/proc/$w/cmdline" 2>/dev/null; then
            if still_home "$sh" "$host"; then
                # A living widget's writer: this session's own arm racing the
                # sweep, or a second widget that shares the directory.
                living="$living$n "
                continue
            fi
            kill -INT "$w" 2>/dev/null && stopped=$((stopped + 1))
        fi
        for x in "$f" "$dir/url-$n.cfg" "$dir"/buffer-"$n".* "$dir"/serve-"$n".*; do
            [ -e "$x" ] && rm -f -- "$x" && removed=$((removed + 1))
        done
    done
    # What is left without a pid file: writers that already ended (the guard
    # stopped them, or the window cap did) and left their buffer, which can be
    # hundreds of megabytes of FLAC. Only files older than this session — a
    # url file written a moment ago is this session's arm between its url
    # write and its launch, and taking it kills that writer at birth.
    while IFS= read -r -d '' f; do
        n=${f##*/}
        n=${n#*-}
        n=${n%%.*}
        case "$living" in *" $n "*) continue ;; esac
        rm -f -- "$f" && removed=$((removed + 1))
    done < <(find "$dir" -maxdepth 1 -type f \
        \( -name 'buffer-*' -o -name 'url-*.cfg' -o -name 'serve-*' -o -name 'writer-*.pid' \) \
        ! -newermt "@$since" -print0 2>/dev/null)
    echo "__TS_SWEEP__ stopped=$stopped removed=$removed"
}

case "${1:-}" in
    watch) shift; watch "$@" ;;
    sweep) shift; sweep "$@" ;;
    *) echo "usage: tsguard.sh watch SHELL HOST WRITER [SECONDS] | sweep DIR SINCE" >&2; exit 2 ;;
esac
