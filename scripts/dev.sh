#!/usr/bin/env bash
# On Air development helper: repo<->install sync, lint, build, quick preview.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO_DIR/package"
INSTALL_DIR="$HOME/.local/share/plasma/plasmoids/org.kde.plasma.advancedradio"
# NB: /usr/bin/qmllint may be the Qt5 version, which reports NOTHING — the Qt6
# binary is required for real checks.
QMLLINT="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
# Qt6 qmltestrunner (qt6-declarative) — runs the QML logic tests in tests/qml.
QMLTESTRUNNER="${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}"
# locale/ is excluded from both sync directions: a local install (old plugin
# id) keeps its old-domain translations; the published package is English-only
# and ships no locale.
RSYNC_OPTS=(-a --delete --exclude '__pycache__' --exclude 'locale')

usage() {
  cat <<EOF
Usage: scripts/dev.sh <command>

  install   sync repo package/contents/ -> local install (metadata.json and locale untouched)
  pull      sync local install -> repo package/contents/ (metadata.json and locale untouched)
  lint      Qt6 qmllint (rc + message grep) + Python compile check + metadata.json
            + po validation + regression grep rules + unit tests (QMLLINT=none skips qmllint)
  check     lint + offscreen plasmoidviewer runtime smoke test (run before every release)
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
    # QMLLINT=none skips the qmllint pass only — for CI runners without Qt6;
    # every other check below still runs there.
    if [ "$QMLLINT" != "none" ]; then
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
    fi
    # compile() also catches compile-phase SyntaxErrors (e.g. 'return' outside
    # a function) that ast.parse misses, and writes no __pycache__ litter.
    python3 -c 'import sys
for p in sys.argv[1:]: compile(open(p).read(), p, "exec")' "$PKG/contents/ui/reader.py" "$PKG/contents/ui/mpris.py" "$PKG/contents/ui/cast.py" "$PKG/contents/ui/calibrate.py"
    python3 -c "import json; json.load(open('$PKG/metadata.json'))"
    bash -n "$PKG/contents/ui/start-mpris.sh"
    # Translations: every .po must compile cleanly (a bad one would silently
    # ship a broken catalog).
    for po in "$REPO_DIR"/po/*.po; do
      [ -e "$po" ] || continue
      msgfmt --check -o /dev/null "$po" || { echo "lint FAILED: $po"; exit 1; }
    done
    # Static rules distilled from shipped regressions — qmllint and the
    # runtime smoke are both blind to these classes.
    #
    # 1) A ListModel ROLE named "model" shadows the delegate's model object
    #    and renders every row blank (2026.8 cast menu). Only the quoted key
    #    form is a role — `required property var model` is the legitimate
    #    model-object accessor and stays allowed.
    bad_model="$(grep -rnE '"model"[[:space:]]*:' "$PKG/contents/ui" --include='*.qml' || true)"
    if [ -n "$bad_model" ]; then
      echo 'lint FAILED: a role/property named "model" shadows the delegate model object:'
      printf '%s\n' "$bad_model"; fail=1
    fi
    # 2) Every versioned OnAir/<x.y> User-Agent must match metadata.json —
    #    the release ritual used to rely on remembering a grep.
    ver="$(python3 -c "import json; print(json.load(open('$PKG/metadata.json'))['KPlugin']['Version'])")"
    bad_ua="$(grep -rhoE 'OnAir/[0-9][0-9.]*' "$PKG" | sort -u | grep -vx "OnAir/$ver" || true)"
    if [ -n "$bad_ua" ]; then
      echo "lint FAILED: User-Agent version(s) [$(printf '%s' "$bad_ua" | tr '\n' ' ')] do not match metadata.json Version $ver"
      fail=1
    fi
    # Unit tests (cast.py dispatch/DLNA parsing, reader.py field extraction).
    # pytest comes from the system or via uv; with neither present this only
    # warns locally — CI always runs them.
    if [ -d "$REPO_DIR/tests" ]; then
      if python3 -c 'import pytest' 2>/dev/null; then
        (cd "$REPO_DIR" && python3 -m pytest tests/ -q) || { echo "lint FAILED: unit tests"; exit 1; }
      elif command -v uv >/dev/null 2>&1; then
        (cd "$REPO_DIR" && uv run --with pytest python -m pytest tests/ -q) || { echo "lint FAILED: unit tests"; exit 1; }
      else
        echo "NB: pytest unavailable (no system pytest, no uv) — unit tests skipped here, CI runs them"
      fi
    fi
    # QML logic tests (alarm/recording scheduling math). qmltestrunner ships
    # with qt6-declarative; where it is absent this only notes the skip — the
    # CI qml job always runs it. QMLTESTRUNNER=none skips explicitly.
    if [ -d "$REPO_DIR/tests/qml" ] && [ "$QMLTESTRUNNER" != "none" ]; then
      if [ -x "$QMLTESTRUNNER" ]; then
        (cd "$REPO_DIR" && QT_QPA_PLATFORM=offscreen "$QMLTESTRUNNER" -silent -input tests/qml) \
          || { echo "lint FAILED: qml tests"; exit 1; }
        echo "qml tests OK"
      else
        echo "NB: qmltestrunner unavailable ($QMLTESTRUNNER) — QML tests skipped here, CI runs them"
      fi
    fi
    if [ "$fail" -eq 0 ]; then echo "lint OK"; else echo "lint FAILED"; fi
    exit "$fail"
    ;;
  check)
    "$0" lint
    # Runtime smoke test. qmllint does not see engine-level load errors (e.g.
    # nesting a child into a type with no default property — the exact bug
    # that shipped broken in 2026.7.2), only the QML engine reports those.
    # QT_FORCE_STDERR_LOGGING is required or Qt logs go to journald instead.
    command -v plasmoidviewer >/dev/null 2>&1 \
      || { echo "runtime FAILED: plasmoidviewer not installed (plasma-sdk)"; exit 1; }
    # QT_LOGGING_RULES: console.log must reach stderr even when the developer's
    # environment disables qml/js debug output — the positive assertion below
    # would otherwise false-FAIL a perfectly healthy widget.
    out="$(timeout 25 env QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
           QT_LOGGING_RULES='qml.debug=true;js.debug=true;default.debug=true' \
           plasmoidviewer -a "$PKG" 2>&1 || true)"
    # /usr/share/plasma is the viewer's own shell (desktopcontainment etc.),
    # which emits unrelated TypeErrors — only our package's messages count.
    bad="$(printf '%s\n' "$out" | grep -v '/usr/share/plasma/' | grep -Ei 'duplicat|syntax|unavailable|non-existent|binding loop|typeerror|referenceerror|error loading' || true)"
    if [ -n "$bad" ]; then printf 'runtime FAILED:\n%s\n' "$bad"; exit 1; fi
    # Positive assertion: the widget must PROVE it came up — main.qml logs this
    # marker from Component.onCompleted (keep the two literals in sync). The
    # keyword grep above passed vacuously when the viewer crashed instantly or
    # a load failure was phrased outside its keyword set ("is not a type").
    LOAD_MARKER='[ARP] widget loaded'
    if ! printf '%s\n' "$out" | grep -qF "$LOAD_MARKER"; then
      echo "runtime FAILED: load marker \"$LOAD_MARKER\" missing from viewer output"
      # A failing gate must show its evidence — without the raw viewer output
      # there is nothing to diagnose a load failure from (especially in CI).
      echo "--- viewer output (last 100 lines) ---"
      printf '%s\n' "$out" | tail -n 100
      exit 1
    fi
    echo "runtime OK"
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
