#!/usr/bin/env bash
# On Air development helper: repo<->install sync, lint, build, quick preview.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO_DIR/package"
INSTALL_DIR="$HOME/.local/share/plasma/plasmoids/org.kde.plasma.advancedradio"
# NB: /usr/bin/qmllint may be the Qt5 version, which reports NOTHING — the Qt6
# binary is required for real checks.
QMLLINT="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
# locale/ is excluded from both sync directions: a local install (old plugin
# id) keeps its old-domain translations; the published package is English-only
# and ships no locale.
RSYNC_OPTS=(-a --delete --exclude '__pycache__' --exclude 'locale')

usage() {
  cat <<EOF
Usage: scripts/dev.sh <command>

  install   sync repo package/contents/ -> local install (metadata.json and locale untouched)
  pull      sync local install -> repo package/contents/ (metadata.json and locale untouched)
  lint      Qt6 qmllint (rc + message grep) + Python compile check + metadata.json validation
  build     build on-air-<Version>.plasmoid into the repo root (7z)
  view      plasmoidviewer on package/ (quick preview without restarting plasmashell)
  restart   systemctl --user restart plasma-plasmashell (reloads the QML)
EOF
}

case "${1:-}" in
  install)
    rsync "${RSYNC_OPTS[@]}" "$PKG/contents/" "$INSTALL_DIR/contents/"
    echo "OK: package/contents -> $INSTALL_DIR/contents (metadata.json and locale untouched)"
    echo "To reload the QML: scripts/dev.sh restart"
    ;;
  pull)
    rsync "${RSYNC_OPTS[@]}" "$INSTALL_DIR/contents/" "$PKG/contents/"
    echo "OK: $INSTALL_DIR/contents -> package/contents (metadata.json and locale untouched)"
    ;;
  lint)
    fail=0
    while IFS= read -r -d '' f; do
      rc=0; raw="$("$QMLLINT" "$f" 2>&1)" || rc=$?
      # Only message lines (qmllint also prints code excerpts, which may
      # contain the word "error"); Qt6 also warns on clean code ([unqualified]
      # etc.), but duplicates/syntax/errors must fail the lint; a nonzero exit
      # always fails it.
      out="$(printf '%s\n' "$raw" | grep -E '^(Warning|Error):' | grep -Ei 'duplicat|syntax|unavailable|error' || true)"
      if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
        printf '== %s (rc=%s)\n%s\n' "$f" "$rc" "${out:-$raw}"; fail=1
      fi
    done < <(find "$PKG" -name '*.qml' -print0)
    # compile() also catches compile-phase SyntaxErrors (e.g. 'return' outside
    # a function) that ast.parse misses, and writes no __pycache__ litter.
    python3 -c 'import sys
for p in sys.argv[1:]: compile(open(p).read(), p, "exec")' "$PKG/contents/ui/reader.py" "$PKG/contents/ui/mpris.py"
    python3 -c "import json; json.load(open('$PKG/metadata.json'))"
    bash -n "$PKG/contents/ui/start-mpris.sh"
    if [ "$fail" -eq 0 ]; then echo "lint OK"; else echo "lint FAILED"; fi
    exit "$fail"
    ;;
  build)
    ver="$(python3 -c "import json; print(json.load(open('$PKG/metadata.json'))['KPlugin']['Version'])")"
    out="$REPO_DIR/on-air-$ver.plasmoid"
    rm -f "$out"
    (cd "$PKG" && 7z a -tzip "$out" contents metadata.json -xr'!__pycache__' >/dev/null)
    # LGPL requires the license text to accompany every distributed copy.
    (cd "$REPO_DIR" && 7z a -tzip "$out" LICENSE >/dev/null)
    echo "OK: $out"
    ;;
  view)
    exec plasmoidviewer -a "$PKG"
    ;;
  restart)
    systemctl --user restart plasma-plasmashell
    ;;
  *)
    usage
    exit 1
    ;;
esac
