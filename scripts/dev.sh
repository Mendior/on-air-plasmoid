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
  lint      Qt6 qmllint (rc + message grep) + Python compile check + metadata.json + po validation
  i18n      re-extract po/template.pot from the QML sources and msgmerge all po files
  locale-install  compile po/ catalogs into the LOCAL install (old plugin id domain)
  build     build on-air-<Version>.plasmoid into the repo root (7z, compiles po/ -> locale/)
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
    # Translations: every .po must compile cleanly (a bad one would silently
    # ship a broken catalog).
    for po in "$REPO_DIR"/po/*.po; do
      [ -e "$po" ] || continue
      msgfmt --check -o /dev/null "$po" || { echo "lint FAILED: $po"; exit 1; }
    done
    if [ "$fail" -eq 0 ]; then echo "lint OK"; else echo "lint FAILED"; fi
    exit "$fail"
    ;;
  build)
    ver="$(python3 -c "import json; print(json.load(open('$PKG/metadata.json'))['KPlugin']['Version'])")"
    out="$REPO_DIR/on-air-$ver.plasmoid"
    rm -f "$out"
    # Compile translations into the package. The catalog domain must match
    # the PUBLISHED plugin id (the local install has a different id and keeps
    # its own catalogs — locale/ is excluded from install/pull syncs).
    domain="plasma_applet_$(python3 -c "import json; print(json.load(open('$PKG/metadata.json'))['KPlugin']['Id'])")"
    rm -rf "$PKG/contents/locale"
    for po in "$REPO_DIR"/po/*.po; do
      [ -e "$po" ] || continue
      lang="$(basename "$po" .po)"
      dir="$PKG/contents/locale/$lang/LC_MESSAGES"
      mkdir -p "$dir"
      msgfmt --check -o "$dir/$domain.mo" "$po"
      echo "  locale: $lang"
    done
    (cd "$PKG" && 7z a -tzip "$out" contents metadata.json -xr'!__pycache__' >/dev/null)
    # LGPL requires the license text to accompany every distributed copy.
    (cd "$REPO_DIR" && 7z a -tzip "$out" LICENSE >/dev/null)
    echo "OK: $out"
    ;;
  locale-install)
    # Compile the po catalogs into the LOCAL install under its OLD plugin id
    # (org.kde.plasma.advancedradio) so the panel widget is translated too.
    # The published package gets its own catalogs at build time; the regular
    # install/pull sync deliberately never touches locale/.
    domain="plasma_applet_org.kde.plasma.advancedradio"
    for po in "$REPO_DIR"/po/*.po; do
      [ -e "$po" ] || continue
      lang="$(basename "$po" .po)"
      dir="$INSTALL_DIR/contents/locale/$lang/LC_MESSAGES"
      mkdir -p "$dir"
      msgfmt --check -o "$dir/$domain.mo" "$po"
      echo "  install locale: $lang"
    done
    echo "OK: reload with scripts/dev.sh restart (full effect after re-login)"
    ;;
  i18n)
    find "$PKG/contents/ui" -name '*.qml' | sort > /tmp/onair-qml-files.txt
    xgettext --from-code=UTF-8 -C -kde -ci18n -ki18n:1 -ki18nc:1c,2 -ki18np:1,2 -ki18ncp:1c,2,3 \
      --package-name='plasma_applet_io.github.mendior.onair' \
      --msgid-bugs-address='https://github.com/Mendior/on-air-plasmoid/issues' \
      -o "$REPO_DIR/po/template.pot" --files-from=/tmp/onair-qml-files.txt 2>/dev/null
    for po in "$REPO_DIR"/po/*.po; do
      [ -e "$po" ] || continue
      msgmerge --no-wrap -q --update --backup=off "$po" "$REPO_DIR/po/template.pot"
      printf '%s: ' "$(basename "$po")"
      msgfmt --statistics -o /dev/null "$po" 2>&1
    done
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
