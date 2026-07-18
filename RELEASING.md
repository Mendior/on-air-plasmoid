# Releasing On Air

Every shipped regression so far traced back to a skipped step, so the steps
are written down and none of them is optional. CI (`.github/workflows/
check.yml`) runs the same gate on every push; a release additionally needs
the manual matrix below, because several past bugs (blank menu rows, broken
popup layouts) were invisible to every automated check.

## 1. Gate

```bash
scripts/dev.sh check
```

Must be green: Qt6 qmllint, Python compile checks, unit tests, translation
catalogs, regression grep rules, and the offscreen `plasmoidviewer` smoke
test. Fix the cause, not the check.

## 2. Version bump

- `package/metadata.json` → `Version`.
- `CHANGELOG.md` → new section at the top.
- `README.md` → install example filename (`on-air-<version>.plasmoid`).
- User-Agent strings: `grep -rn 'OnAir/' package/` — every versioned hit
  must match the new version (the lint gate fails the release if forgotten).
- If UI strings changed: `scripts/dev.sh i18n` and commit the updated
  `po/` catalogs.

## 3. Real-session test

```bash
scripts/dev.sh install && scripts/dev.sh restart
```

Then the 5-minute matrix on the actual panel — every line, no skipping:

- [ ] Play a station, switch stations, stop playback.
- [ ] Cover art appears on a current-hits station within a few seconds.
- [ ] Search: click previews, ⭐ adds without starting playback.
- [ ] Cast to one device and stop it; check the device really goes silent.
- [ ] Bluetooth row connects a paired speaker and audio moves to it.
- [ ] One-minute recording saves and the notification reports success.
- [ ] Space / M shortcuts work, and do nothing while the search field has focus.
- [ ] Popup opens with sane layout at default size (blank rows, clipped
      buttons and shifted layouts have all shipped before).

## 4. Build and publish

```bash
scripts/dev.sh build          # -> on-air-<version>.plasmoid (7z, not zip)
git tag v<version>
gh release create v<version> --title "On Air <version>" on-air-<version>.plasmoid
```

Release notes: plain English, written for users, no tooling/process chatter.

KDE Store (manual): store.kde.org → product p/2364623 → Edit → Files →
upload the new `.plasmoid`, bump the version field. Use store.kde.org, not
opendesktop.org — only the former shows the Plasma 6 Applets category.

## 5. After any found bug

Every bug that reaches a user gets, in the same fix commit or the next one:

- a unit test (`tests/`) if it is Python logic,
- a grep rule in `scripts/dev.sh lint` if it is a pattern the engine accepts
  silently,
- or a line in the manual matrix above if only human eyes can catch it.

## Recommended repository settings

Branch protection on `main` (Settings → Branches): require a pull request
and the `checks` workflow green before merge. This keeps a broken `main`
from ever being the release base.
