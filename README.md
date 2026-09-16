# OpenBeam

<p align="center">
<img width="678" height="419" alt="image" src="https://github.com/user-attachments/assets/0742cb95-6864-40ca-a8ff-3f2164280688" /><br>
   <em>Blurred image for privacy reasons</em>
</p>


A lightweight native macOS menu bar app that sends a USB webcam as an NDI source on the local network — and, on the machine at the other end, turns that source into a webcam again.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![NDI](https://img.shields.io/badge/NDI-SDK%206-green)

## Features

- **Native** — AppKit and SwiftUI, no Electron, no browser tech, no OBS required
- **Menu bar only** — lives in the system tray with a live camera preview
- **Send and Receive** — one machine sends its camera, the other receives it and hands it to video calls as a webcam
- **NDI output** — advertises your machine name as the NDI source, visible to any NDI receiver on the local network
- **Camera selection** — switch between built-in and external USB cameras
- **Audio routing, both ways** — either machine can send a microphone or its own system audio, and either can play what it receives through speakers you pick
- **macOS Camera Effects** — works with Apple's built-in portrait mode, background replacement, and reactions (via the green camera button)
- **Live statistics** — resolution, capture/NDI FPS, data rate, frame counts
- **Clipboard sync** — copy on one machine, paste on another, between devices you pair by hand
- **Updates itself** — a daily check that adds a line to the menu instead of interrupting your call
- **Lightweight** — no GPU compositing overhead, direct pixel buffer passthrough to NDI

## Send and Receive

The tabs at the top of the menu pick what this machine does with *video*. The two are
exclusive — receiving stops the camera and the preview's own source of frames. Audio is not
tied to them: see [Audio](#audio).

- **Send** — capture a camera and one audio source and publish them as an NDI source. This is
  the host of the pair.
- **Receive** — pick any NDI source on the network and point the NDI virtual camera at it. The
  source then shows up in Zoom, Meet, Teams or FaceTime as the camera `NDI Virtual Camera` and
  the microphone `NDI Audio`.

Receive needs [NDI Tools](https://ndi.video/tools/) installed once, for its camera extension and
audio driver. OpenBeam only tells that extension which source to take: the video and audio go
straight from the network into it, so nothing passes through this app and the camera keeps
working after OpenBeam quits. NDI Virtual Input itself never has to be open.

Two things macOS reserves for the user: approving the extension the first time, and choosing
`NDI Virtual Camera` / `NDI Audio` inside the video call app. No app can do either for you.

## Audio

Video goes one way; audio goes both. A machine sends one audio stream and plays one, whichever
tab it is on, which is what makes the pair a conversation rather than a broadcast.

The menu is grouped by direction, and every line says what it is set to:

```
Sending                              Receiving
  Camera: Insta360 Link                NDI Source: macos          (Receive)
  Audio: Mic — Shure MV7                 or Listen to: macos-work (Send)
  NDI: macos                           Play audio on: AirPods Pro
```

| Line | Direction | What it decides |
|---|---|---|
| **Camera** | out | which webcam is published (Send only) |
| **Audio** | out | the one audio stream this machine publishes: `Mic — …` or `System audio — …` |
| **NDI Source** | in | which source feeds the virtual camera — and so what this machine hears (Receive only) |
| **Listen to** | in | which source this machine hears, when it is not receiving one already (Send only) |
| **Play audio on** | in | which speakers that comes out of |

`Listen to` and `Play audio on` are the two halves of hearing something: *which* stream, and
*where* it comes out. Receive needs no `Listen to` because `NDI Source` already named one.

**Audio** offers a microphone or **system audio** — what the Mac is playing through one of its
outputs, captured with a CoreAudio process tap. `Default output` follows whatever the Mac is
using at the time; anything else stays on the device you named, and comes back on its own after
being unplugged and plugged in again. OpenBeam excludes itself from the tap, and never mutes
what it captures: you go on hearing what you are sending. Each tab remembers its own choice —
Send starts at the system microphone, Receive at `None`, so a machine only puts its audio on the
network once you have said so.

### The pair in a video call

The case this is shaped around: you are at machine **A**, the call is on machine **B**.

```
   A — Send                                           B — Receive
   the desk you sit at                                the one in the meeting

   Camera: webcam ──┐                              ┌──► NDI Virtual Camera ──┐
                    ├─► NDI "macos" ═══════════════┤                          ├─► Meet / Teams
   Audio: Mic ──────┘   video + audio              └──► NDI Audio ───────────┘
   (your voice)

   Play audio on ◄──── NDI "macos-work" ◄═══════════════ Audio: System audio
   (your headphones)    audio only                       (a tap on B's output —
          ▲                                               what the meeting is saying)
          │
   Listen to: macos-work
   (which source the line above plays)
```

Set B first: until B's **Audio** is set, it publishes nothing and A's **Listen to** has nothing
to offer. The menu's `NDI:` line on B says whether it is publishing.

On B, **Play audio on** stays at `None` in this setup: A's voice is already going into the call
as a virtual microphone, and playing it out of B's speakers as well would only put it in B's
room.

Use headphones at A. A's microphone is what the call hears, and A's speakers are playing the
call: on speakers, the meeting hears itself back. OpenBeam captures a microphone raw, with no
echo canceller of its own.

Capturing an output needs macOS 15, where a bundled app may tap audio without a separate
permission. Playing needs nothing at all.

## Install

Download `OpenBeam.dmg` from [Releases](https://github.com/manuelvegadev/OpenBeam/releases), open it, and drag OpenBeam to Applications. Open it from there rather than from the disk image — an app cannot update itself while running from a read-only mount.

OpenBeam is signed, but not with a paid Apple Developer certificate, so the first launch needs one trip through **System Settings → Privacy & Security → Open Anyway**. Updates after that install themselves, and each one is verified against an EdDSA key built into the app.

> No NDI SDK installation needed — `libndi.dylib` is bundled inside the app.

Full documentation is at **[openbeam.manuelvega.dev](https://openbeam.manuelvega.dev)**, and
what changed in each version is in [CHANGELOG.md](CHANGELOG.md).

## Settings

**Settings…** in the menu bar opens a window with three panes: **General** (open at login, UYVY sending), **Updates** (automatic checks, background downloads, the running version) and **Clipboard** (sync, and the devices you have paired).

## Requirements

- macOS 15 or later

## Building from source

Building requires the [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/).

1. **Install the NDI SDK**

   Download from [ndi.video](https://ndi.video/for-developers/ndi-sdk/) and run the installer. The SDK installs to `/Library/NDI SDK for Apple/`.

2. **Clone the repo**

   ```bash
   git clone https://github.com/manuelvegadev/OpenBeam.git
   cd OpenBeam
   ```

3. **Copy NDI SDK files into the project**

   ```bash
   cp /Library/NDI\ SDK\ for\ Apple/include/*.h NDI/
   cp /Library/NDI\ SDK\ for\ Apple/lib/macOS/libndi.dylib NDI/
   ```

4. **Open and build**

   ```bash
   open OpenBeam.xcodeproj
   ```

   Build and run (⌘R). The app appears as a camera icon in the menu bar.

## Architecture

```
OpenBeam/
├── AppDelegate.swift         # Menu bar UI, mode switching, pipeline wiring, stats
├── CameraController.swift    # AVCaptureSession, camera switching
├── AudioController.swift     # Microphone capture (AVAudioEngine)
├── SystemAudioTap.swift      # Capture of an output device: what the Mac is playing
├── AudioDevices.swift        # CoreAudio device queries shared by both audio paths
├── AudioOutputPlayer.swift   # Plays received audio on a chosen output, with a jitter buffer
├── NDISender.swift           # NDI C API bridge, async frame sending
├── NDIReceiver.swift         # NDI reception for the preview and the level meter
├── NDIAudioReceiver.swift    # Audio-only NDI reception, for playing it on this machine
├── NDIFinder.swift           # Discovery of NDI sources on the network
├── NDIRuntime.swift          # Refcounted NDIlib_initialize / NDIlib_destroy
├── VirtualCamera.swift       # Points the NDI virtual camera at a source (CoreMediaIO)
├── BridgingHeader.h          # Exposes NDI C headers to Swift
└── Info.plist                # Camera/network permissions, LSUIElement
NDI/
├── *.h                       # NDI SDK headers (not included — see Setup)
└── libndi.dylib              # NDI runtime library (not included)
```

**Frame pipeline — Send:**

```
AVCaptureSession → CVPixelBuffer → NDIlib_send_send_video_v2
                                 → CALayer.contents (preview)
```

Frames pass directly from the camera to NDI with no intermediate processing. macOS system camera effects (portrait, background, studio light) are applied by the OS before frames reach the app.

**Audio pipeline**, which is the same on both machines and runs in either mode:

```
microphone ─┐
            ├─→ NDIlib_send_send_audio_v2                        (one or the other)
output tap ─┘

NDIlib_recv (audio only) → jitter buffer → AVAudioEngine → the chosen output device
```

**Frame pipeline — Receive:**

```
OpenBeam ──CMIOObjectSetPropertyData('ndis')──→ NDI camera extension ──→ any video call app
                                                 (receives the source itself)

NDIlib_recv (proxy stream) → CALayer.contents (preview, only while the menu is open)
```

The full-resolution video never passes through OpenBeam: the extension and the `NDIAudio` HAL
driver each receive the source themselves. All OpenBeam does is write the source name into the
extension's custom CoreMediaIO property, which is what NDI Virtual Input does too.

Audio played into the room is the exception — that one does pass through OpenBeam, because
nothing else would play it.

## Building a DMG

To create a distributable `.dmg` installer:

```bash
./scripts/build-dmg.sh
```

This builds a Release configuration, embeds `libndi.dylib` inside the app bundle, and creates `build/OpenBeam.dmg`. Users just drag OpenBeam.app to Applications.

To cut an actual release, use `./scripts/release.sh <version>` instead — it bumps the version, commits and tags in one step, and pushing that tag builds and publishes the DMG through GitHub Actions. See [CONTRIBUTING.md](CONTRIBUTING.md#release).

> **Note:** For distribution to others, you should sign with a Developer ID certificate and notarize with Apple. See [Apple's documentation on notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Credits

- [NDI](https://ndi.video/) — Network Device Interface SDK by Vizrt. OpenBeam uses the NDI SDK to broadcast video over the local network.
- [Phosphor Icons](https://phosphoricons.com/) — app icon and menu bar icon use the Phosphor webcam glyph.

## License

[MIT](LICENSE) © 2026 Manuel Vega.

The bundled NDI SDK (`libndi.dylib`) is redistributed under Vizrt's own NDI SDK licence and is
not covered by the above. NDI® is a registered trademark of Vizrt NDI AB.
