#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Egon Greenberg
#
# SPDX-License-Identifier: LGPL-2.0-or-later
#
# On Air development helper: repo<->install sync, lint, build, quick preview.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO_DIR/package"
# The local install may live under the current plugin id or the pre-rename
# one, depending on when this machine first installed the widget — sync into
# whichever actually exists. With BOTH present any guess could silently sync
# a tree the panel is not running, so refuse and require an explicit choice.
INSTALL_BASE="$HOME/.local/share/plasma/plasmoids"
# Resolve lazily: leave INSTALL_DIR unset when ambiguous so read-only commands
# (lint/check/build/i18n/view/restart) still run; require_install_dir refuses
# only when a command actually touches the install tree.
if [ -z "${INSTALL_DIR:-}" ]; then
  if [ -d "$INSTALL_BASE/io.github.mendior.onair" ] && [ -d "$INSTALL_BASE/org.kde.plasma.advancedradio" ]; then
    :  # both present → stay unset, decide only when needed
  elif [ -d "$INSTALL_BASE/io.github.mendior.onair" ]; then
    INSTALL_DIR="$INSTALL_BASE/io.github.mendior.onair"
  else
    INSTALL_DIR="$INSTALL_BASE/org.kde.plasma.advancedradio"
  fi
fi
require_install_dir() {
  [ -n "${INSTALL_DIR:-}" ] || { echo "ERROR: both io.github.mendior.onair and org.kde.plasma.advancedradio exist under $INSTALL_BASE — set INSTALL_DIR to the tree the panel actually runs"; exit 1; }
}
# NB: /usr/bin/qmllint may be the Qt5 version, which reports NOTHING — the Qt6
# binary is required for real checks.
QMLLINT="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
# Qt6 qmltestrunner (qt6-declarative) — runs the QML logic tests in tests/qml.
QMLTESTRUNNER="${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}"
# locale/ is excluded from both sync directions because the two trees carry
# different catalog domains: a local install keeps the ones built for whichever
# plugin id it was first installed under. The shipped .plasmoid is a separate
# matter — "build" compiles all twelve catalogs into it below.
RSYNC_OPTS=(-a --delete --exclude '__pycache__' --exclude 'locale')

usage() {
  cat <<EOF
Usage: scripts/dev.sh <command>

  install   sync repo package/contents/ -> local install (metadata.json and locale untouched)
  pull      sync local install -> repo package/contents/ (metadata.json and locale untouched)
  lint      Qt6 qmllint (rc + message grep) + Python compile check + metadata.json
            + po validation + regression grep rules + unit tests (QMLLINT=none skips qmllint)
  check     lint + offscreen plasmoidviewer runtime smoke test (run before every release)
  preflight reuse (SPDX) + codespell + yamllint + gitleaks + lychee (links, needs network)
            — slower and partly online, so it runs before a release, not every commit
  i18n      re-extract po/template.pot from the QML sources and msgmerge all po files
  locale-install  compile po/ catalogs into the LOCAL install (old plugin id domain)
  build     build on-air-<Version>.plasmoid into the repo root (7z, compiles po/ -> locale/)
  view      plasmoidviewer on package/ (quick preview without restarting plasmashell)
  restart   systemctl --user restart plasma-plasmashell (reloads the QML)
  doctor    is this machine running the code you think it is? (git vs repo vs
            install vs the panel) — changes nothing; 0 = clean, 1 = skew, 2 = cannot tell
EOF
}

case "${1:-}" in
  install)
    require_install_dir
    rsync "${RSYNC_OPTS[@]}" "$PKG/contents/" "$INSTALL_DIR/contents/"
    # The install keeps its own metadata.json (old plugin id — replacing it
    # would orphan the user's stations/favorites), but the VERSION field must
    # follow the repo or the About page keeps showing a long-gone release.
    python3 - "$PKG/metadata.json" "$INSTALL_DIR/metadata.json" <<'PYEOF'
import json, sys
repo = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
if inst["KPlugin"]["Version"] != repo["KPlugin"]["Version"]:
    inst["KPlugin"]["Version"] = repo["KPlugin"]["Version"]
    json.dump(inst, open(sys.argv[2], "w"), indent=4)
    print("  install version -> " + repo["KPlugin"]["Version"] + " (id untouched)")
PYEOF
    echo "OK: package/contents -> $INSTALL_DIR/contents (metadata id and locale untouched)"
    echo "To reload the QML: scripts/dev.sh restart"
    ;;
  pull)
    require_install_dir
    # pull --delete overwrites the repo copy; committed work is recoverable
    # from git, uncommitted edits are gone for good. --porcelain also catches
    # staged and untracked files (a new NewThing.qml has no blob to recover).
    [ -z "$(git -C "$REPO_DIR" status --porcelain -- package/contents)" ] \
      || { echo "refusing pull: uncommitted or untracked changes in package/contents"; exit 1; }
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
    # Catalog FRESHNESS: the committed template.pot must carry every i18n()
    # string the QML actually uses. A feature commit that skips `dev.sh i18n`
    # ships its new strings English-only in all eleven languages — it
    # happened, nothing caught it, so now this does. Same extraction as the
    # i18n task, msgids compared as sets (references/line numbers move
    # freely and must not fail the gate).
    if command -v xgettext >/dev/null 2>&1; then
      potfresh="$(mktemp)"; potlist="$(mktemp)"
      ( cd "$REPO_DIR" && find "package/contents" -name '*.qml' | sort > "$potlist" \
        && xgettext --from-code=UTF-8 -C -kde -ci18n -ki18n:1 -ki18nc:1c,2 -ki18np:1,2 -ki18ncp:1c,2,3 \
          --no-wrap -o "$potfresh" --files-from="$potlist" 2>/dev/null )
      fresh_ids="$(msgattrib --no-wrap --no-obsolete "$potfresh" 2>/dev/null | grep '^msgid ' | sort -u)"
      have_ids="$(msgattrib --no-wrap --no-obsolete "$REPO_DIR/po/template.pot" 2>/dev/null | grep '^msgid ' | sort -u)"
      missing="$(comm -23 <(printf '%s\n' "$fresh_ids") <(printf '%s\n' "$have_ids"))"
      rm -f "$potfresh" "$potlist"
      if [ -n "$missing" ]; then
        echo "lint FAILED: template.pot is stale — run scripts/dev.sh i18n. Missing:"
        printf '%s\n' "$missing" | head -10
        exit 1
      fi
    fi
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
    # 2) Notifications go through notify() ONLY. A KNotification with
    #    autoDelete self-destructs after its first close, the QML id turns
    #    null, and every direct dlNotification use after that throws —
    #    aborting the caller mid-function (the 2026.18 calibration left the
    #    stream at volume 0 exactly this way). notify() wraps the object in
    #    a try/catch; nothing else may touch it, and autoDelete stays off.
    ndirect="$(grep -c 'dlNotification\.sendEvent' "$PKG/contents/ui/main.qml" || true)"
    if [ "${ndirect}" != "1" ]; then
      echo "lint FAILED: dlNotification.sendEvent appears ${ndirect}x in main.qml — direct use outside notify() (must be exactly 1)"
      fail=1
    fi
    bad_autodel="$(grep -rn 'autoDelete:[[:space:]]*true' "$PKG/contents/ui" --include='*.qml' || true)"
    if [ -n "$bad_autodel" ]; then
      echo 'lint FAILED: autoDelete: true on a declared Notification (self-deletes after first close, id turns null):'
      printf '%s\n' "$bad_autodel"; fail=1
    fi
    # 3) Every versioned OnAir/<x.y> User-Agent must match metadata.json —
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
    rc=0
    out="$(timeout 25 env QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
           QT_LOGGING_RULES='qml.debug=true;js.debug=true;default.debug=true' \
           plasmoidviewer -a "$PKG" 2>&1)" || rc=$?
    # /usr/share/plasma is the viewer's own shell (desktopcontainment etc.),
    # which emits unrelated TypeErrors — only our package's messages count.
    bad="$(printf '%s\n' "$out" | grep -v '/usr/share/plasma/' | grep -Ei 'duplicat|syntax|unavailable|non-existent|binding loop|typeerror|referenceerror|error loading' || true)"
    if [ -n "$bad" ]; then printf 'runtime FAILED:\n%s\n' "$bad"; exit 1; fi
    # 124 = timeout expiry, the NORMAL success path here (the viewer never
    # exits on its own); any other nonzero exit is a crash, which can slip
    # past the keyword grep when it happens after the load marker.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
      echo "runtime FAILED: viewer exit $rc"
      echo "--- viewer output (last 100 lines) ---"
      printf '%s\n' "$out" | tail -n 100
      exit 1
    fi
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
  preflight)
    # Slower, partly network-bound checks that belong before a release rather
    # than before every commit. Each tool is optional: a machine without it
    # says so and the rest still run, so this never blocks work on a fresh
    # checkout. 2026-07-26 this pass caught a dead attribution link that had
    # sat in the public README since the first release.
    fail=0
    if command -v reuse >/dev/null 2>&1; then
      if reuse lint --quiet; then echo "reuse OK"
      else echo "preflight FAILED: reuse"; fail=1; fi
    else echo "NB: reuse not installed — SPDX headers unchecked"; fi

    if command -v codespell >/dev/null 2>&1; then
      # Spell-check exactly what the repo ships: git ls-files leaves working
      # drafts out of the scan without having to name them. po/ is twelve
      # languages of not-English, LICENSE is not ours to edit, and the rest
      # of the filter is binaries.
      # The ignore list holds three real words the dictionary does not know:
      # "retuned" (what the caretaker does to a room), and "te", a local
      # holding a title-equality score in SearchLogic. A gate that is red on
      # false positives is a gate people learn to skip, which is the whole
      # reason this one exists.
      if (cd "$REPO_DIR" && git ls-files \
            | grep -vE '^(po/|LICENSES/|LICENSE$|screenshots/)' \
            | grep -vE '\.(png|ogg)$' \
            | xargs -d '\n' codespell --ignore-words-list='unparseable,retuned,te,derails' -q 3); then
        echo "codespell OK"
      else echo "preflight FAILED: codespell"; fail=1; fi
    else echo "NB: codespell not installed"; fi

    if command -v yamllint >/dev/null 2>&1; then
      # Warnings are style; only errors gate the release.
      if yamllint --no-warnings .github/; then echo "yamllint OK"
      else echo "preflight FAILED: yamllint"; fail=1; fi
    else echo "NB: yamllint not installed"; fi

    if command -v gitleaks >/dev/null 2>&1; then
      # Scan what the repo ships, not what happens to sit in the directory.
      # "gitleaks dir ." walks .gitignore'd files too, so one local appletsrc
      # backup — full of stream tokens, and unpublishable by construction —
      # kept this gate red for something no commit could ever carry. A gate
      # that is always red teaches you to skip it. git ls-files draws the
      # same line the codespell step above already draws.
      scan="$(mktemp -d)"
      # The copy and the scan fail differently and must SAY so: one verdict
      # line for both read "gitleaks found something" when it was the copy
      # that broke, sending you hunting for a secret that was never there.
      # Both still fail closed — a gate that cannot look is not a green gate.
      if ! (cd "$REPO_DIR" && git ls-files -z | xargs -0 cp --parents -t "$scan"); then
        echo "preflight FAILED: could not stage tracked files for the secret scan"; fail=1
      elif gitleaks dir "$scan" --no-banner --redact -l error >/dev/null 2>&1; then
        echo "gitleaks OK"
      else echo "preflight FAILED: gitleaks found something — inspect locally, do not paste it"; fail=1; fi
      [ -n "$scan" ] && rm -rf "$scan"
    else echo "NB: gitleaks not installed"; fi

    if command -v lychee >/dev/null 2>&1; then
      # Network: keep the concurrency low so a doc full of links to one host
      # does not look like a scraper.
      if lychee --max-concurrency 4 --no-progress --quiet README.md SECURITY.md docs/; then
        echo "lychee OK"
      else echo "preflight FAILED: broken links"; fail=1; fi
    else echo "NB: lychee not installed — links unchecked"; fi

    [ "$fail" -eq 0 ] || exit 1
    echo "preflight OK"
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
    require_install_dir
    # Compile the po catalogs into the LOCAL install so the panel widget is
    # translated too. The published package gets its own catalogs at build
    # time; the regular install/pull sync deliberately never touches locale/.
    #
    # The domain follows THIS MACHINE's install id, which is not the same on
    # both: the home machine still runs the old org.kde.plasma.advancedradio
    # tree, the work machine only has io.github.mendior.onair. This used to be
    # hardcoded to the old id, so on the work machine it wrote catalogs under a
    # domain KDE never looks up and the widget stayed English no matter how
    # many times this ran.
    domain="plasma_applet_$(basename "$INSTALL_DIR")"
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
    # ALL of contents/, not just ui/: config/config.qml lives one level up
    # and its four i18n() category names were never extracted — the settings
    # dialog's tabs stayed English in every translation.
    # Paths are REPO-RELATIVE: absolute paths would embed this machine's
    # home directory into the public catalogs (they did — 400+ references),
    # and a reference comment only helps a translator when it points inside
    # the repo. The kde-format flags make msgfmt --check actually validate
    # %1/%2 placeholders in translations from now on.
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    ( cd "$REPO_DIR" && find "package/contents" -name '*.qml' | sort > "$tmp" \
      && xgettext --from-code=UTF-8 -C -kde -ci18n -ki18n:1 -ki18nc:1c,2 -ki18np:1,2 -ki18ncp:1c,2,3 \
        --flag=i18n:1:kde-format --flag=i18nc:2:kde-format \
        --flag=i18np:1:kde-format --flag=i18np:2:kde-format \
        --flag=i18ncp:2:kde-format --flag=i18ncp:3:kde-format \
        --package-name='plasma_applet_io.github.mendior.onair' \
        --msgid-bugs-address='https://github.com/Mendior/on-air-plasmoid/issues' \
        --copyright-holder='Egon Greenberg' \
        -o po/template.pot --files-from="$tmp" 2>/dev/null )
    # xgettext always emits its own placeholder title and author lines. The
    # template is the first file a translator downloads, so it carries the
    # same header the catalogs do instead of FIRST AUTHOR <EMAIL@ADDRESS>.
    # The tags below are data for that rewrite, not this file's own licensing —
    # reuse would otherwise read the sed delimiter as part of the expression.
    # REUSE-IgnoreStart
    sed -i '1s|.*|# Translation template for On Air.|;
            2s|.*|# SPDX-FileCopyrightText: 2026 Egon Greenberg|;
            3s|.*|# SPDX-License-Identifier: LGPL-2.0-or-later|;
            4{/FIRST AUTHOR/d};
            s|^"Last-Translator: FULL NAME <EMAIL@ADDRESS>|"Last-Translator: Egon Greenberg|' \
        "$REPO_DIR/po/template.pot"
    # REUSE-IgnoreEnd
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
  doctor)
    # Three questions nobody could answer without archaeology, and every one
    # of them has already cost a night: is the repo where I think it is, does
    # the install match it, and is the PANEL running that install?
    #
    # The last one is the one that bites. QML is read once at plasmashell
    # start, while calibrate.py is exec'd from disk on every run — so an
    # install without a restart leaves one generation of QML driving another
    # generation of python, which is exactly how a calibration came to store
    # 44 ms in a room that measures 150.
    # Every read below is wrapped so it cannot ABORT the run. This is a
    # diagnostic: dying halfway is the one behaviour it must never have, and
    # under `set -euo pipefail` a grep that legitimately finds nothing does
    # exactly that — measured, on the first draft of this very command.
    doctor_rc=0
    # Not require_install_dir: an ambiguous or missing install is "cannot
    # tell" (2), not "skew" (1), and the difference matters to whoever reads
    # the exit code instead of the text.
    if [ -z "${INSTALL_DIR:-}" ]; then
      echo "machine : $(hostname)"
      echo "install : both plugin ids exist under $INSTALL_BASE — set INSTALL_DIR to the tree the panel runs"
      echo "verdict : cannot tell — see the lines above"
      exit 2
    fi
    echo "machine : $(hostname)   install: $INSTALL_DIR"

    # 1. git — the commit, and whether anything is unshared or uncommitted.
    git_head="$(git -C "$REPO_DIR" log --format='%h %s' -1 2>/dev/null || echo '(no git)')"
    git_dirty="$( { git -C "$REPO_DIR" status --porcelain 2>/dev/null || true; } | wc -l)"
    git_ab="$(git -C "$REPO_DIR" rev-list --left-right --count origin/main...HEAD 2>/dev/null || echo '? ?')"
    echo "git     : $git_head"
    if [ "$git_dirty" -gt 0 ]; then
      echo "          ${git_dirty} uncommitted file(s) — this work exists on THIS machine only"
      doctor_rc=1
    fi
    case "$git_ab" in
      "0	0") echo "          in step with origin/main" ;;
      "? ?") echo "          no origin/main to compare against"; if [ "$doctor_rc" -eq 0 ]; then doctor_rc=2; fi ;;
      *)     echo "          origin/main vs HEAD: $git_ab (behind/ahead) — fetch or push before trusting this tree"
             doctor_rc=1 ;;
    esac

    # 2. repo vs install. Checksums, not timestamps: `install` syncs with
    # plain -a (size+mtime), so a same-size same-mtime difference would be
    # invisible to anything cheaper. Dry-run — this command never writes.
    #
    # Only CONTENT changes and deletions are counted. rsync also itemizes
    # attribute-only lines, and a bare line count made a directory's mtime
    # read as a changed file: `git checkout` or the release recipe's
    # `read-tree` rewrite mtimes without touching a byte, and doctor would
    # then order install+restart over identical code — a gate that cries
    # wolf teaches people to ignore it, which is the whole thing this
    # command exists to prevent.
    skew="$( { rsync -ainc --dry-run "${RSYNC_OPTS[@]}" \
                 "$PKG/contents/" "$INSTALL_DIR/contents/" 2>/dev/null || true; } \
             | grep -cE '^([<>ch][fdLDS]|\*deleting)' || true)"
    if [ "$skew" -eq 0 ]; then
      echo "install : matches package/contents"
    else
      echo "install : ${skew} file(s) differ from package/contents — run: scripts/dev.sh install && scripts/dev.sh restart"
      doctor_rc=1
    fi

    # 3. install vs the running panel. ctime, never mtime: rsync -a preserves
    # the SOURCE mtime, so an installed file's mtime can predate the install
    # by days. ctime is when this machine's inode was written, i.e. the
    # install moment. And the marker must come from the CURRENT plasmashell —
    # an older pid's line would happily "prove" a shell that no longer runs.
    pshell_pid="$(systemctl --user show -P ExecMainPID plasma-plasmashell 2>/dev/null || echo 0)"
    # A missing install tree is a normal answer on a machine that never
    # installed the widget, and `find` on it exits nonzero.
    newest_inst="$( { find "$INSTALL_DIR/contents" -path '*/locale/*' -prune -o -type f \
                        \( -name '*.qml' -o -name '*.js' \) -printf '%C@\n' 2>/dev/null || true; } \
                    | sort -rn | head -1 | cut -d. -f1)"
    # The marker is asked for only once the shell is known to run, and the
    # no-match case is neutralised: a journal that has rotated past the load
    # is "cannot tell", not a reason to stop talking.
    loaded_at=""
    if [ -n "${pshell_pid:-}" ] && [ "${pshell_pid:-0}" != "0" ]; then
      loaded_at="$(journalctl --user _PID="$pshell_pid" -o short-unix --no-pager 2>/dev/null \
                     | { grep -F '[ARP] widget loaded' || true; } | tail -1 | cut -d. -f1)"
    fi
    if [ "${pshell_pid:-0}" = "0" ] || [ -z "${pshell_pid:-}" ]; then
      echo "panel   : plasmashell is not running — cannot tell what is loaded"
      if [ "$doctor_rc" -eq 0 ]; then doctor_rc=2; fi
    elif [ -z "$newest_inst" ]; then
      echo "panel   : nothing installed at $INSTALL_DIR — cannot tell what the panel runs"
      if [ "$doctor_rc" -eq 0 ]; then doctor_rc=2; fi
    elif [ -z "$loaded_at" ]; then
      echo "panel   : no '[ARP] widget loaded' from pid $pshell_pid — the widget may not be on a panel, or the journal has rotated"
      if [ "$doctor_rc" -eq 0 ]; then doctor_rc=2; fi
    elif [ "$loaded_at" -ge "$newest_inst" ]; then
      echo "panel   : running the installed QML (loaded $(date -d "@$loaded_at" '+%F %H:%M:%S'), newest install $(date -d "@$newest_inst" '+%F %H:%M:%S'))"
    else
      echo "panel   : STALE — installed at $(date -d "@$newest_inst" '+%F %H:%M:%S') but the panel loaded at $(date -d "@$loaded_at" '+%F %H:%M:%S'); run: scripts/dev.sh restart"
      doctor_rc=1
    fi

    case "$doctor_rc" in
      0) echo "verdict : this machine is running the code you think it is" ;;
      1) echo "verdict : SKEW — see the lines above" ;;
      *) echo "verdict : cannot tell — see the lines above" ;;
    esac
    exit "$doctor_rc"
    ;;
  *)
    usage
    exit 1
    ;;
esac
