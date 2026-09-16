# Send and receive

The tabs at the top of the menu decide what this machine does with *video*. They are
exclusive: switching to Receive stops the camera, because one machine never usefully
sends and receives frames at the same time.

Audio is not on the tabs. Either machine can send one audio stream and play one, whichever
tab it is on — see [Audio](/guides/audio).

## Send

The host of the pair. OpenBeam captures a camera and one audio source and publishes them
as an NDI source named after your machine.

- **Camera** — built-in or any connected USB camera.
- **Audio** — a microphone, or what this Mac is playing. See [Audio](/guides/audio).
- **Listen to** and **Play audio on** — the other machine's audio, and where it comes out.
- **NDI** — the source this machine is publishing, or `not publishing` when it has
  nothing to put on the network.
- **Restart NDI** — republishes the source. Useful when a receiver has lost it and you
  would rather not restart the app.

macOS camera effects work here. Open the green camera button in Control Centre and
Portrait, Studio Light, Centre Stage and Reactions all apply to what OpenBeam sends,
because the frames are taken after macOS has processed them.

## Receive

The other end. OpenBeam points the NDI virtual camera at a source on the network, and
that source becomes a webcam for every app on the machine.

1. Switch to **Receive**.
2. Choose a source under **NDI Source**.
3. In Zoom, Meet, Teams or FaceTime, pick the camera **NDI Virtual Camera** and the
   microphone **NDI Audio**.

A machine in Receive can still send: set **Audio** to its system output and the call it is
sitting in becomes audible on the machine you are at. That is the whole of
[Audio](/guides/audio).

Receive needs [NDI Tools](https://ndi.video/tools/) installed once, for its camera
extension and audio driver.

:::info
OpenBeam only tells that extension which source to take. The video and audio go
straight from the network into it, so nothing passes through OpenBeam — and the camera
keeps working after OpenBeam quits. NDI Virtual Input itself never has to be open.
:::

Two things macOS reserves for you, and no app can do on your behalf: approving the
camera extension the first time, and choosing the camera inside the video call app.
