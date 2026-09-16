# OpenBeam

OpenBeam is a menu bar app that does two things, one machine at a time:

- **Send** — publishes a USB or built-in camera (and a microphone, or what the Mac is
  playing) as an NDI source on your local network.
- **Receive** — takes any NDI source on that network and hands it to video calls as a
  webcam, and can send its own audio back.

Point one Mac at the other and the camera on your desk becomes the camera in a call on a
different machine, with no capture card and no OBS.

## Install

1. Download `OpenBeam.dmg` from the [releases page](https://github.com/manuelvegadev/OpenBeam/releases).
2. Open it and drag **OpenBeam** to your Applications folder. Open it from there —
   not from the disk image, or it will not be able to update itself later.
3. The first launch is refused, because OpenBeam is not signed with a paid Apple
   Developer certificate. Open **System Settings → Privacy & Security**, scroll to the
   bottom, and choose **Open Anyway**. macOS asks once.

:::tip
Right-clicking the app and choosing **Open** gets you the same dialog with one less
trip through System Settings.
:::

## Your first send

1. Click the camera icon in the menu bar.
2. Leave the tab on **Send**.
3. Pick your camera under **Camera**. The preview at the top of the menu starts moving.
4. macOS asks for camera, microphone and local network access the first time. All three
   are required: without the local network permission nothing can see the source.

OpenBeam now advertises itself on the network under your machine's name. Anything that
speaks NDI — another Mac running OpenBeam in Receive, OBS with the NDI plugin, a
hardware receiver — can pick it up.

Next: [Send and receive](/guides/send-receive) explains the other half, and
[Audio](/guides/audio) explains how the two ends hear each other.
