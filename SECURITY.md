# Reporting a security issue

On Air reads a lot of things it did not write: podcast feeds, ICY stream
metadata, directory search results, Bluetooth and LAN device names, and the
addresses behind all of them. Anything that lets one of those reach further
than it should is worth a report.

**Please do not open a public issue for it.** Use GitHub's private reporting
instead — the *Security* tab of this repository, "Report a vulnerability".
That keeps the details between us until there is a fix to ship.

If you would rather not use GitHub, write to the address on the maintainer's
profile and put "On Air security" in the subject.

## What happens next

This is a one-person project, so I answer as a person, not a queue: expect a
first reply within a few days. If the report holds up, the fix goes into the
next release and the release notes describe what changed without naming you
unless you want to be named.

## Worth reporting

- A feed, playlist or search result that can make the widget run a command,
  read a file outside its own directories, or write one
- Anything that renders attacker-supplied text as markup in the interface
- A way to reach a private-network address through the widget's own requests
- Stream URLs, tokens or file paths becoming readable by other users on the
  same machine

## Probably not a security issue

- A station or feed that simply fails to play
- Crashes with no path to running code or reading data
- Findings in `yt-dlp`, `ffmpeg`, `curl` or Qt themselves — report those
  upstream, though tell me if On Air calls them in an unsafe way

## Versions

Fixes land in the newest release. Older versions are not patched separately.
