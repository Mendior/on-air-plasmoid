#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
#
# The sliding buffer's folder, for the widget that cannot look into one.
#
#   tsslide.sh have DIR
#   tsslide.sh write DIR NAME UPTO          the list's text on stdin
#   tsslide.sh grow DIR NAME FROM UPTO      two lines a segment on stdin
#
# DIR is the folder ffmpeg cuts its segments into (…/buffer-N.hls) and NAME a
# list of the widget's own (play-N.m3u8). The text is the widget's; nothing
# here composes a list, it only puts one where the player finds it whole.
#
# have   answers "__TS_HAVE__ first=A last=B": the oldest and the newest
#        finished segment, as ffmpeg's own list names them. "first=-1 last=-1"
#        while there is none.
# write  puts the list in place in one move, so a reader never sees half of
#        it, and answers "__TS_LIST__ last=UPTO newest=M".
# grow   adds the segments FROM..UPTO that are on disk, as far as they are
#        there without a gap, and answers "__TS_LIST__ last=K newest=M", K
#        being FROM-1 when it added none.
# Anything that cannot be done answers "__TS_LIST_FAIL__" (have: no segments).
set -u

# Only a folder of the widget's own naming: write and grow create files in
# it, and the widget removes it whole when the station stops.
is_buffer() {
    [[ ${1:-} =~ /buffer-[0-9]+\.hls$ && -d $1 ]]
}

# The newest finished segment, from the end of ffmpeg's own list. That list
# is rewritten by a rename each time a segment is done, so it is always
# whole, and its last name is a file that is closed. A stopped writer ends
# the list with one more line, which is why three are looked at.
# Prints the number, -1 when there is none.
newest() {
    local line n=-1
    while IFS= read -r line; do
        [[ $line =~ ^seg-([0-9]+)\.ts$ ]] && n=${BASH_REMATCH[1]}
    done < <(tail -n 3 "$1/live.m3u8" 2>/dev/null)
    echo "$n"
}

have() {
    local dir=${1:-} first="" last=-1
    if is_buffer "$dir"; then
        last=$(newest "$dir")
        # The list's first segment, not the oldest file: ffmpeg keeps one
        # segment its list has dropped and removes it with the next cut.
        first=$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE:\([0-9][0-9]*\)$/\1/p;8q' "$dir/live.m3u8" 2>/dev/null)
    fi
    if [[ $first =~ ^[0-9]+$ && $last -ge $first ]]; then
        echo "__TS_HAVE__ first=$first last=$last"
    else
        echo "__TS_HAVE__ first=-1 last=-1"
    fi
}

fail() {
    echo "__TS_LIST_FAIL__"
    exit 0
}

# The list goes to a file beside its place and is moved onto it: a player
# that reads the list while it is being written would read half of one.
put() {
    local tmp="$1.tmp"
    if cat > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f -- "$tmp" "$1" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$tmp" 2>/dev/null
    return 1
}

write() {
    local dir=${1:-} name=${2:-} upto=${3:-}
    is_buffer "$dir" && [[ $name =~ ^play-[0-9]+\.m3u8$ && $upto =~ ^[0-9]+$ ]] || fail
    # A list that ends in a segment still being cut would hold the player
    # at that name until it is finished. One with nothing in it is what a
    # full disk leaves: ffmpeg goes on making the files and says nothing.
    [ -s "$dir/seg-$upto.ts" ] || fail
    put "$dir/$name" || fail
    echo "__TS_LIST__ last=$upto newest=$(newest "$dir")"
}

grow() {
    local dir=${1:-} name=${2:-} from=${3:-} upto=${4:-} n text
    is_buffer "$dir" && [[ $name =~ ^play-[0-9]+\.m3u8$ && $from =~ ^[0-9]+$ && $upto =~ ^[0-9]+$ ]] || fail
    [ "$upto" -ge "$from" ] && [ -f "$dir/$name" ] || fail
    text=$(cat)
    # Two lines a segment; a text that is short of them would leave the
    # list naming fewer segments than the answer says.
    [ "$(printf '%s\n' "$text" | wc -l)" -ge $(((upto - from + 1) * 2)) ] || fail
    n=$from
    while [ "$n" -le "$upto" ] && [ -s "$dir/seg-$n.ts" ]; do n=$((n + 1)); done
    if [ "$n" -gt "$from" ]; then
        { cat -- "$dir/$name" && printf '%s\n' "$text" | head -n $(((n - from) * 2)); } | put "$dir/$name" || fail
    fi
    echo "__TS_LIST__ last=$((n - 1)) newest=$(newest "$dir")"
}

case "${1:-}" in
    have) shift; have "$@" ;;
    write) shift; write "$@" ;;
    grow) shift; grow "$@" ;;
    *) echo "usage: tsslide.sh have DIR | write DIR NAME UPTO | grow DIR NAME FROM UPTO" >&2; exit 2 ;;
esac
