# Updating

OpenBeam checks for its own updates once a day and tells you when one is ready.

## How it behaves

OpenBeam is a menu bar app, and it is usually feeding a camera into a call you are
actually on. So a background check that finds an update never takes over the screen:
it adds an **Update available — Install…** item at the top of the menu and waits for
you. Clicking that — or **Check for Updates…** — brings up the usual Sparkle window with
the release notes.

You can change all of this under **Settings → Updates**:

- **Check for updates automatically** — the daily check. On by default.
- **Download updates in the background** — fetches the update before you ask, so
  installing it is immediate.
- **Check Now** — asks right away.

## OpenBeam must be in Applications

An app cannot replace itself while it is running from a read-only disk image, and macOS
additionally isolates apps launched straight from a download. OpenBeam detects both and
says so in **Settings → Updates** rather than failing silently — but the fix is the
same either way: move it to your Applications folder and open it from there.

## Why macOS still warns about OpenBeam

OpenBeam is signed, but not with a paid Apple Developer certificate, and it is not
notarized. That is what produces the warning on first launch.

It does not make updates unverified. Every update archive is signed with an EdDSA key
whose public half is compiled into the app, and OpenBeam refuses any update that key
does not vouch for. An attacker who took over the download server still could not get an
update installed.
