# Contributing to OpenBeam

Known work that is understood but not done is in [BACKLOG.md](BACKLOG.md), with the
measurements behind each item.

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
| `settings` | Everything under `OpenBeam/Settings/`: the settings window, updates, login item |
| `stats` | `NetTrafficMonitor.swift` and the statistics pipeline |
| `signing` | Entitlements, code-signing settings, provisioning |
| `build` | `scripts/`, the Xcode project, CI workflows |
| `site` | Everything under `site/`: the landing page and the docs |

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

## Changelog

The changelog follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the
version follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Two rules from
those specs decide almost everything here: **a changelog is for humans, not machines**, and
**every version gets an entry**.

`CHANGELOG.md` at the repository root is the record. The GitHub release notes are a copy of
that version's section — `scripts/changelog-section.sh` extracts it and `release.yml`
publishes it — because a release page only exists inside GitHub, while the file travels with
the repository and with the source tarball. It is also what someone reads in Sparkle's window
before letting an update install.

### Writing an entry

Add to the `## [Unreleased]` section as the work lands, rather than reconstructing a release
from its commits afterwards. Group changes under the headings the spec defines, in this order,
omitting the ones with nothing in them:

`Added` · `Changed` · `Deprecated` · `Removed` · `Fixed` · `Security`

An entry is **prose, written for someone using the app**, not a commit subject. One or two
sentences: what changed for them, and — where a bug is involved — the symptom first, so
whoever hit it recognises it in the first line. Several commits that together did one thing
are one entry; a commit that changed nothing a user can see is not an entry at all. A faster
audio path, a shared helper, a test: none of them belong here, however much work they were.

The commit bodies are where the material comes from. They already carry the symptom, the
measurement and the reason; an entry is that, rewritten for someone who was not there.

This is why the workflow does not generate the notes. Generated notes are the commit log, and
the commit log for a release includes the `chore(build)` bump, every refactor and every
scope — noise to a reader who only wants to know whether to update.

### At release time

Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add the compare link at the foot of the
file, and leave a fresh empty `## [Unreleased]` above it. `release.sh` refuses to tag a version
`CHANGELOG.md` does not describe, because by the time CI notices, the tag is already pushed.

## Release

Releases are built by `.github/workflows/release.yml`, which triggers on any tag
matching `v*`. On a macOS runner it runs `scripts/build-dmg.sh` (which produces both
`OpenBeam.dmg` for first-time installs and `OpenBeam-<version>.zip` for Sparkle), then
`scripts/make-appcast.sh` to sign that archive and fold it into the update feed, uploads
all of it to a GitHub Release with that version's changelog section as its notes, and finally
calls `.github/workflows/pages.yml` to publish the site with the new appcast.

The Pages deploy is *called* from the release workflow rather than triggered by
`on: release`, because a release created with `GITHUB_TOKEN` does not trigger workflow
runs. An `on: release` deploy would never fire, and the appcast would never update.

To cut a release, write the changelog entry first (above), then run the script — it is the
rest of the procedure:

```bash
./scripts/release.sh 1.0.2          # bump, commit, tag
./scripts/release.sh 1.0.2 --push   # ...and publish
```

It refuses to run on a dirty tree, a version that already has a tag, or a version
`CHANGELOG.md` says nothing about; warns if
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

`Info.plist` derives `CFBundleVersion` from `MARKETING_VERSION`, because Sparkle compares
`CFBundleVersion` to decide what is newer and `CURRENT_PROJECT_VERSION` is not something
anyone remembers to bump. Do not undo that: an update that reports the same build number
as the version it replaces is an update nobody is ever offered.

## The code signing certificate

Releases are signed with **OpenBeam Code Signing**, a self-signed certificate valid until
2036. What it buys is one identity across releases. macOS files permissions — Screen
Recording, Accessibility — under an app's designated requirement. An ad-hoc build's
requirement is its own hash, so until 2.7.2 every update looked like a new app: its entries
still showed as allowed in System Settings but applied to nothing, and each had to be removed
and added again by hand. Signed with the certificate, the requirement reads
`identifier "manuelvegadev.OpenBeam" and certificate leaf = H"08b7…7681"`, the same for
every build signed with it.

It is not trusted by anything and does not need to be: `codesign` needs to reach the private
key, not to trust the certificate. It does nothing for Gatekeeper, which still warns on the
first install; only a paid Developer ID with notarization does that.

- **CI** gets it from two secrets, `SIGNING_CERTIFICATE_P12` (the `.p12`, base64-encoded)
  and `SIGNING_CERTIFICATE_PASSWORD`; `scripts/import-signing-certificate.sh` puts it in a
  keychain of its own before the build.
- **A Mac** that builds releases needs it in its login keychain. `scripts/build-dmg.sh` signs
  with it when it is there, signs ad hoc with a warning when it is not, and refuses a tag
  build without it — a release that went out ad hoc would reset every user's permissions.
- **Back it up.** Export it from Keychain Access (My Certificates → OpenBeam Code Signing →
  Export, as `.p12`) into a password manager. Losing it is not fatal, since a new
  certificate works the same way, but every user would have to grant the permissions once
  more, as they did moving to this one.

To make a new one, if it is ever lost:

```bash
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = OpenBeam Code Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:3072 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
# macOS only imports a .p12 in the old algorithms, hence -legacy and the rest (OpenSSL 3):
openssl pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -inkey key.pem -in cert.pem -out OpenBeamCodeSigning.p12 -name "OpenBeam Code Signing"
```

## The Sparkle signing key

OpenBeam is not notarized, and until 2.7.2 it was ad-hoc signed, so Sparkle's code-signature
check could not pass across those updates — their designated requirement pinned a per-binary
cdhash. The EdDSA signature on the update archive is what carries an update across that, and
it stays the one thing standing between a user and a hostile update.

Set up once, with Sparkle's tools from the resolved package
(`.derived/SourcePackages/artifacts/sparkle/Sparkle/bin/`):

```bash
./generate_keys                      # stores the private key in your login Keychain
                                     # and prints the public key
./generate_keys -x sparkle_private.key   # export it for CI
```

- The **public** key goes in `Info.plist` as `SUPublicEDKey`.
- The **private** key goes in the GitHub secret `SPARKLE_PRIVATE_KEY`. Back it up
  somewhere safe and delete the exported file.

`scripts/build-dmg.sh` refuses to build while `SUPublicEDKey` is still the placeholder.
With a key Sparkle cannot use, it does not start: every launch opens with a modal
"Unable to Check For Updates — the updater failed to start", "Check for Updates…" stays
greyed out, and no build can ever update itself. The guard is there so that never
reaches a release.

Losing the private key means no installed copy can ever be updated again. Rotating it
requires everyone to reinstall by hand.

## The site

`site/landing` is a Vite + React page and `site/docs` is an Rspress site; the Pages
workflow builds both and serves them at `/` and `/docs/`. Docs content is plain Markdown
under `site/docs/docs/`, organised by what the reader is trying to do — get started,
follow a guide, look something up, or fix something — rather than by feature. Keep new
pages in whichever of those four a reader would look in.
