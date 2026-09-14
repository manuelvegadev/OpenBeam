# Contributing to Open Beam

## Commits

Every commit message follows [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): summary

Optional body explaining why the change was needed.
```

**Types:** `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`.

**Scopes** name the part of the app the change belongs to:

| Scope | Covers |
| --- | --- |
| `ndi` | `NDISender.swift`, the bundled NDI SDK, frame formats and wire output |
| `camera` | `CameraController.swift`, capture session, pixel formats |
| `audio` | `AudioController.swift`, the capture tap, level metering |
| `clipsync` | Everything under the `ClipSync*` files: discovery, pairing, transport, identity |
| `share` | `SharePlugin.swift`, file transfer |
| `menu` | `AppDelegate.swift`, the status item, preview and stats UI |
| `stats` | `NetTrafficMonitor.swift` and the statistics pipeline |
| `signing` | Entitlements, code-signing settings, provisioning |
| `build` | `scripts/`, the Xcode project, CI workflows |

Write the summary in the imperative, lowercase, with no trailing period, and keep
it under about 72 characters: `fix(clipsync): drop stale peers on disconnect`, not
`Fixed the bug where peers were not dropped.`

### Commits are atomic

One logical change per commit, grouped by scope. A commit should do a single
thing and leave the tree building.

- Do not mix scopes. Changing the NDI sender and the menu layout is two commits,
  even when you wrote them in one sitting.
- Do not mix a refactor with a behaviour change. Land the refactor first, then the
  change on top, so a regression can be bisected to one of them.
- Never `git add -A` when the working tree holds more than one change. Stage the
  files that belong to the commit you are writing, explicitly.
- Unrelated drive-by fixes get their own commit, not a paragraph in someone else's.

A change that genuinely spans scopes — removing an entitlement and moving the
storage it gated, say — is one commit, because neither half builds or makes sense
alone. The test is whether the parts can stand on their own, not how many files
they touch.

## Push

- Work on a branch; `main` is what releases are cut from.
- Rebase onto the latest `main` before pushing rather than merging it back in, so
  history stays linear and release notes read in order.
- Never force-push a branch somebody else may have pulled.
- Push deliberately. Do not push a branch that still has fixup or WIP commits on
  it — squash them first.

## Release

Releases are built by `.github/workflows/release.yml`, which triggers on any tag
matching `v*`. The workflow runs `scripts/build-dmg.sh` on a macOS runner, uploads
`build/OpenBeam.dmg` to a GitHub Release, and generates the release notes from the
commit history — which is the practical reason the commit rules above matter, as
those subjects are what users read on the Releases page.

To cut a release, run the script — it is the whole procedure:

```bash
./scripts/release.sh 1.0.2          # bump, commit, tag
./scripts/release.sh 1.0.2 --push   # ...and publish
```

It refuses to run on a dirty tree or a version that already has a tag, warns if
you are not on `main`, bumps `MARKETING_VERSION` in **every** build configuration
(Debug and Release each carry their own copy), verifies none were missed and that
the project file is still valid, commits that bump alone as
`chore(build): release vX.Y.Z`, and creates the annotated tag.

Nothing is published until the tag is pushed, which is why `--push` is opt-in.
Pushing the tag is the irreversible step: it triggers the workflow that builds the
DMG and creates the public GitHub Release.

Do not bump `MARKETING_VERSION` by hand and do not tag by hand. The two must agree
— the tag is the version on the Releases page, `MARKETING_VERSION` is the version
the app reports about itself, and a bug report naming a version that matches no
build is expensive to chase. `scripts/build-dmg.sh` enforces this: when it builds
from a tag it compares the two and fails the release rather than shipping the
mismatch.

Version numbers are semantic: bump the patch for fixes, the minor for new features,
the major for a change that breaks an existing setup.
