#!/usr/bin/env bash
# On Air arendus-abiline: sünk repo<->install, lint, build, kiirtest.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO_DIR/package"
INSTALL_DIR="$HOME/.local/share/plasma/plasmoids/org.kde.plasma.advancedradio"
# NB: /usr/bin/qmllint on Qt5 versioon, mis QML-vigu EI raporteeri — vaja on Qt6 oma.
QMLLINT="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
# locale/ on välistatud mõlemast sünkist: lokaalne install (vana plugin-ID) hoiab oma
# vana-domeeni tõlkeid; avaldatav pakett on inglise-keelne ja locale't ei sisalda.
RSYNC_OPTS=(-a --delete --exclude '__pycache__' --exclude 'locale')

usage() {
  cat <<EOF
Kasutus: scripts/dev.sh <käsk>

  install   sünk repo package/contents/ -> lokaalne install (metadata.json ja locale jäävad puutumata)
  pull      sünk lokaalne install -> repo package/contents/ (metadata.json ja locale jäävad puutumata)
  lint      Qt6 qmllint (rc + lai grep) + Python compile-check + metadata.json valideerimine
  build     ehita on-air-<Version>.plasmoid repo juurkataloogi (7z)
  view      plasmoidviewer package/ peal (kiirtest ilma plasmashelli restardita)
  restart   systemctl --user restart plasma-plasmashell (laadib QML-i uuesti)
EOF
}

case "${1:-}" in
  install)
    rsync "${RSYNC_OPTS[@]}" "$PKG/contents/" "$INSTALL_DIR/contents/"
    echo "OK: package/contents -> $INSTALL_DIR/contents (metadata.json ja locale puutumata)"
    echo "QML uuesti laadimiseks: scripts/dev.sh restart"
    ;;
  pull)
    rsync "${RSYNC_OPTS[@]}" "$INSTALL_DIR/contents/" "$PKG/contents/"
    echo "OK: $INSTALL_DIR/contents -> package/contents (metadata.json ja locale puutumata)"
    ;;
  lint)
    fail=0
    while IFS= read -r -d '' f; do
      rc=0; raw="$("$QMLLINT" "$f" 2>&1)" || rc=$?
      # Ainult teate-read (qmllint trükib ka koodi-väljavõtteid, mis võivad
      # sisaldada sõna "error"); Qt6 hoiatab ka puhtal koodil ([unqualified] jm),
      # aga duplikaat/süntaks/viga peavad lindi kukutama; nonzero-exit alati.
      out="$(printf '%s\n' "$raw" | grep -E '^(Warning|Error):' | grep -Ei 'duplicat|syntax|unavailable|error' || true)"
      if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
        printf '== %s (rc=%s)\n%s\n' "$f" "$rc" "${out:-$raw}"; fail=1
      fi
    done < <(find "$PKG" -name '*.qml' -print0)
    # compile() püüab ka compile-faasi SyntaxError'id (nt 'return' väljaspool
    # funktsiooni), mida ast.parse ei näe, ega tekita __pycache__ prügi.
    python3 -c 'import sys
for p in sys.argv[1:]: compile(open(p).read(), p, "exec")' "$PKG/contents/ui/reader.py" "$PKG/contents/ui/mpris.py"
    python3 -c "import json; json.load(open('$PKG/metadata.json'))"
    bash -n "$PKG/contents/ui/start-mpris.sh"
    if [ "$fail" -eq 0 ]; then echo "lint OK"; else echo "lint EBAÕNNESTUS"; fi
    exit "$fail"
    ;;
  build)
    ver="$(python3 -c "import json; print(json.load(open('$PKG/metadata.json'))['KPlugin']['Version'])")"
    out="$REPO_DIR/on-air-$ver.plasmoid"
    rm -f "$out"
    (cd "$PKG" && 7z a -tzip "$out" contents metadata.json -xr'!__pycache__' >/dev/null)
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
