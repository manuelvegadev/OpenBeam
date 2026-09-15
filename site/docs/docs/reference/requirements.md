# Requirements

## macOS

macOS 15 or later, on Apple silicon or Intel.

## Permissions

OpenBeam asks for these the first time it needs them. All are requested by macOS, and
all can be changed later in System Settings → Privacy & Security.

| Permission | Needed for |
| --- | --- |
| Camera | Capturing a camera in Send mode. |
| Microphone | Capturing audio in Send mode. |
| Local network | Publishing and finding NDI sources, and clipboard sync. Without it nothing on the network can see this machine. |

Because OpenBeam is not notarized, the first launch also needs one trip through
**System Settings → Privacy & Security → Open Anyway**.

## NDI

Nothing to install for **Send**: `libndi.dylib` ships inside the app.

**Receive** needs [NDI Tools](https://ndi.video/tools/) installed once, for its camera
extension and audio driver. macOS asks you to approve the extension the first time, which
no app can do for you.

## Network

Both machines have to be on the same local network, and that network has to allow
multicast and direct connections between clients. Guest and "client isolation" Wi-Fi
networks commonly block exactly this, and they are the usual reason two machines cannot
see each other.
