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
- **macOS Camera Effects** — works with Apple's built-in portrait mode, background replacement, and reactions (via the green camera button)
- **Live statistics** — resolution, capture/NDI FPS, data rate, frame counts
- **Clipboard sync** — copy on one machine, paste on another, between devices you pair by hand
- **Updates itself** — a daily check that adds a line to the menu instead of interrupting your call
- **Lightweight** — no GPU compositing overhead, direct pixel buffer passthrough to NDI

## Send and Receive

The tabs at the top of the menu pick what this machine does. The two are exclusive — receiving
stops the camera, the microphone and this machine's own NDI source.

- **Send** — capture a camera and a microphone and publish them as an NDI source. This is the
  host of the pair.
- **Receive** — pick any NDI source on the network and point the NDI virtual camera at it. The
  source then shows up in Zoom, Meet, Teams or FaceTime as the camera `NDI Virtual Camera` and
  the microphone `NDI Audio`.

Receive needs [NDI Tools](https://ndi.video/tools/) installed once, for its camera extension and
audio driver. OpenBeam only tells that extension which source to take: the video and audio go
straight from the network into it, so nothing passes through this app and the camera keeps
working after OpenBeam quits. NDI Virtual Input itself never has to be open.

Two things macOS reserves for the user: approving the extension the first time, and choosing
`NDI Virtual Camera` / `NDI Audio` inside the video call app. No app can do either for you.

## Install

Download `OpenBeam.dmg` from [Releases](https://github.com/manuelvegadev/OpenBeam/releases), open it, and drag OpenBeam to Applications. Open it from there rather than from the disk image — an app cannot update itself while running from a read-only mount.

OpenBeam is signed, but not with a paid Apple Developer certificate, so the first launch needs one trip through **System Settings → Privacy & Security → Open Anyway**. Updates after that install themselves, and each one is verified against an EdDSA key built into the app.

> No NDI SDK installation needed — `libndi.dylib` is bundled inside the app.

Full documentation is at **[manuelvegadev.github.io/OpenBeam](https://manuelvegadev.github.io/OpenBeam/)**.

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
├── AppDelegate.swift        # Menu bar UI, mode switching, pipeline wiring, stats
├── CameraController.swift   # AVCaptureSession, camera switching
├── NDISender.swift           # NDI C API bridge, async frame sending
├── NDIReceiver.swift         # NDI reception for the preview and the level meter
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

**Frame pipeline — Receive:**

```
OpenBeam ──CMIOObjectSetPropertyData('ndis')──→ NDI camera extension ──→ any video call app
                                                 (receives the source itself)

NDIlib_recv (proxy stream) → CALayer.contents (preview, only while the menu is open)
```

The full-resolution video never passes through OpenBeam: the extension and the `NDIAudio` HAL
driver each receive the source themselves. All OpenBeam does is write the source name into the
extension's custom CoreMediaIO property, which is what NDI Virtual Input does too.

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
