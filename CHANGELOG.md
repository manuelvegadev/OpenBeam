# Changelog

All notable changes to OpenBeam are recorded here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

One number covers the whole app. A version's entry is what its GitHub release page says and
what someone reads before letting Sparkle install it, so it is written for the person
deciding whether to take the update — not assembled from commit subjects.

## [Unreleased]

## [2.6.1] - 2026-09-16

### Fixed

- **OpenBeam quit when you opened Settings a second time.** Closing the settings window left
  the app pointing at a window that no longer existed, so the next **Settings…** crashed
  instead of opening. The first open of a session was always fine, which is why this took a
  while to show itself. The pairing dialog was one step away from the same fault and is fixed
  alongside it.

## [2.6.0] - 2026-09-16

### Added

- **Copied images travel between machines.** Take a screenshot, copy it, and paste it on the
  other Mac as a picture — no file to find, no round trip through a folder. A copied picture
  is sent as PNG rather than as the uncompressed bitmap the clipboard offers beside it, so a
  Retina screenshot crosses the network as about 660 KB instead of 15 MB, and the other
  representations are rebuilt on arrival for apps that ask for those.

- **A switch for it in Settings → Clipboard**, beside the one for files, so text-only syncing
  stays available. The transfer limit applies to images too: anything larger is left alone
  rather than sent, and an oversized one arriving from elsewhere is refused.

### Note

When what you copy is both a picture and text — an image copied from a web page leaves its
address on the clipboard beside it — the picture is what travels.

## [2.5.0] - 2026-09-16

### Fixed

- **Clipboard sync could not be set up at all.** Pressing **Pair** did nothing, on either
  machine, with no dialog and no error. The two devices exchanged their opening handshake at
  the same moment, which meant neither could sign it against the other's identity the way the
  other checked for — so every attempt was dropped before a pairing request was ever sent. If
  you have never got two machines paired, this is why.

- **A pairing could end up one-sided.** The device that accepted saved the pair; the device
  that asked never heard back, because the answer was discarded before it left the machine.
  The two then disagreed about whether they were paired, and nothing in the app said so.

- **Forgetting a device on one machine stranded the other.** The pair could not be set up
  again until it was forgotten on both. A device you already confirmed can now ask again and
  be accepted without a second confirmation.

- **Any machine on the network could write to your clipboard.** Pairing gated what was sent
  but not what was accepted, so clipboard contents from an unpaired device were applied. They
  are now ignored, as are any other messages that arrive out of turn.

### Added

- **Both machines now show the same pairing window**, with the same six-digit code to compare
  and the same fingerprint. The one being asked shows **Accept** and **Reject**; the one
  asking shows the code it is waiting on, and says so if the other device declines, never
  answers, or goes away. Before this, the machine you pressed Pair on showed nothing at all.

- **Limits in the Clipboard settings.** A switch for whether copied *files* travel with the
  clipboard, a cap on the size of text that gets sent, and a cap on file transfers that is
  enforced in both directions — anything larger is left alone rather than sent, and an
  oversized transfer arriving from elsewhere is refused.

### Changed

- **"Sync the clipboard" is remembered between launches.** It only ever lived in memory, so
  each launch guessed from whether anything was paired.

- **Paired devices are listed before discovered ones**, since what already works is what you
  open that pane to check on.

## [2.4.0] - 2026-09-15

### Added

- **Audio travels in both directions.** Until now audio only went where the video went. Either
  machine can now publish one audio stream and play one, whichever tab it is on — which is what
  lets the Mac sitting in a video call send that call's audio back to the Mac you are at, so
  the pair is a conversation rather than a broadcast. Three lines in the menu decide it:
  **Audio**, what this machine sends; **Listen to**, which source it hears; and **Play audio
  on**, which speakers that comes out of.

- **A Mac's own output as an audio source.** **Audio** offers what this Mac is playing, not
  only what a microphone hears, captured with a CoreAudio process tap. `Default output` follows
  whatever the Mac is using at the time, and a named device comes back on its own after being
  unplugged and plugged in again. OpenBeam leaves itself out of what it taps — so a machine
  playing a received stream out of the very device it is tapping cannot feed itself — and never
  mutes what it captures, so you go on hearing what you are sending.

- **Playback on a device you choose.** A received stream can come out of any output on the
  machine, held for 80 ms first so that network jitter is not a click, and it keeps playing
  while the menu is closed.

- **An Audio guide** at [openbeam.manuelvega.dev/docs/guides/audio](https://openbeam.manuelvega.dev/docs/guides/audio),
  including the one setup this was shaped around: you at machine A, the call on machine B.

### Changed

- **The menu is grouped into Sending and Receiving, and every line says what it is set to** —
  `Camera: Insta360 Link`, `Audio: Mic — Shure MV7`, `Play audio on: AirPods Pro`. Three items
  about audio read as three ways of saying the same thing without that.

- **`Microphone` is now `Audio`**, because a microphone is one of the things it can send rather
  than the only one.

- **Receiving no longer takes this machine off the network.** A Mac in Receive publishes a
  source of its own when, and only when, it has audio to send back; the menu's `NDI:` line says
  whether it does.

- **The audio source is remembered per tab.** Send starts at the system microphone and Receive
  at `None`, so no machine begins publishing audio because it was updated.

### Note

Use headphones on the machine you sit at. Its microphone is what the call hears and its
speakers are playing that call, so on speakers the meeting hears itself back — OpenBeam
captures a microphone raw, with no echo canceller of its own.

## [2.3.1] - 2026-09-15

### Changed

- **The site and the update feed moved to `openbeam.manuelvega.dev`.** The landing page is now
  the root of that domain and the documentation sits under `/docs`.

## [2.3.0] - 2026-09-15

### Added

- **OpenBeam updates itself.** A daily check that adds a line to the menu instead of
  interrupting whatever you are doing, and an update that is verified against an EdDSA key
  built into the app before it is installed.

- **A Settings window**, with three panes: General (open at login, UYVY sending), Updates
  (automatic checks, background downloads, the running version) and Clipboard (sync, and the
  devices you have paired).

- **A site and documentation** at `openbeam.manuelvega.dev`: a landing page, and guides
  organised by what you are trying to do rather than by feature.

### Fixed

- **GitHub reported the project as unlicensed.** The README claimed MIT and no `LICENSE` file
  existed. The licence also now says what it does not cover: the bundled `libndi.dylib` is
  redistributed under Vizrt's own NDI SDK licence.

## [2.2.0] - 2026-09-14

### Added

- **Receive.** A second mode that points the NDI virtual camera at any source on the network,
  so the machine at the other end hands that source to Zoom, Meet, Teams or FaceTime as a
  webcam. Needs [NDI Tools](https://ndi.video/tools/) installed once, for its camera extension
  and audio driver.

## [2.1.1] - 2026-09-14

### Fixed

- **Clipboard sync could take the app down when a device went away.** Bonjour handles were
  released outside the source's cancel handler, which is the one place they can be freed
  safely.

### Changed

- **Sending costs less.** The frame path no longer hops onto the send queue to read the NDI
  handle, which had been stalling roughly one frame in four at 1080p30.

## [2.1.0] - 2026-09-14

### Changed

- **The app is idle while its menu is closed**, and the preview fades back in when you open it
  rather than appearing mid-motion.

## [2.0.0] - 2026-09-14

### Changed

- **CamNDI is now OpenBeam**, in the app, the bundle and the repository.

### Added

- **The NDI source is named after your machine**, so a receiver picking it from a list can tell
  which Mac it is.
- **UYVY 4:2:2 output**, for receivers that prefer it to BGRA.
- **Wire traffic in the statistics**, alongside the capture and NDI figures.

### Fixed

- **Clipboard sync lost its pairings and its peers.** Discovery moved to `dns_sd`, the identity
  is persisted, and the logs say enough to tell a dropped peer from a refused one.
- **A UVC camera with a macOS video effect filled the log** with `Using R709` messages from
  Apple's Portrait framework, several a second.

## [1.0.1] - 2026-03-16

### Added

- **An app icon and a menu bar icon of its own**, rather than the placeholder.

### Fixed

- **The app did not build on Xcode 16.4**, over an `accessibilityLabel` call.

## [1.0.0] - 2026-03-16

### Added

- **The first release.** A menu bar app that captures a USB or built-in camera and publishes it
  as an NDI source on the local network, with a live preview, camera selection, macOS camera
  effects and statistics.

[Unreleased]: https://github.com/manuelvegadev/OpenBeam/compare/v2.6.1...HEAD
[2.6.1]: https://github.com/manuelvegadev/OpenBeam/compare/v2.6.0...v2.6.1
[2.6.0]: https://github.com/manuelvegadev/OpenBeam/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/manuelvegadev/OpenBeam/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/manuelvegadev/OpenBeam/compare/v2.3.1...v2.4.0
[2.3.1]: https://github.com/manuelvegadev/OpenBeam/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/manuelvegadev/OpenBeam/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/manuelvegadev/OpenBeam/compare/v2.1.1...v2.2.0
[2.1.1]: https://github.com/manuelvegadev/OpenBeam/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/manuelvegadev/OpenBeam/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/manuelvegadev/OpenBeam/compare/v1.0.1...v2.0.0
[1.0.1]: https://github.com/manuelvegadev/OpenBeam/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/manuelvegadev/OpenBeam/releases/tag/v1.0.0
