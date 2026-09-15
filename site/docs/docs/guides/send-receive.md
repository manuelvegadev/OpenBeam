# Send and receive

The tabs at the top of the menu decide what this machine does. They are exclusive:
switching to Receive stops the camera, the microphone and this machine's own NDI source,
because one machine never usefully sends and receives at the same time.

## Send

The host of the pair. OpenBeam captures a camera and a microphone and publishes them as
an NDI source named after your machine.

- **Camera** — built-in or any connected USB camera.
- **Microphone** — the system default, a specific input, or off.
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

Receive needs [NDI Tools](https://ndi.video/tools/) installed once, for its camera
extension and audio driver.

:::info
OpenBeam only tells that extension which source to take. The video and audio go
straight from the network into it, so nothing passes through OpenBeam — and the camera
keeps working after OpenBeam quits. NDI Virtual Input itself never has to be open.
:::

Two things macOS reserves for you, and no app can do on your behalf: approving the
camera extension the first time, and choosing the camera inside the video call app.
