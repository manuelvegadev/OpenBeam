# Remote Screen Protocol v1

Lets one paired device (the **viewer**) see another (the **host**) and drive it with its own mouse and keyboard. Built for two Macs on the same desk joined by a Thunderbolt Bridge, where bandwidth is plentiful and latency is what matters: frames travel as uncompressed pixels, only the regions that changed, with no codec in the path.

> **Source-of-truth rule.** This document is the canonical specification, in the same sense as [CLIPBOARD-PROTOCOL.md](CLIPBOARD-PROTOCOL.md). Whenever a decision affects what goes on the wire — message layouts, crypto, key derivation strings, limits — update this file first, then the implementations.

## Goals

- Only a **paired** ClipSync peer can start a session, and only if the host's user **allowed that peer** to control this device.
- Every byte of pixels and input is **encrypted and authenticated**.
- **Lossless**: the viewer shows exactly the host's pixels, at the host's frame rate.
- **Latency first**: nothing waits for anything it does not need. No codec, no frame queue, no retransmission of stale frames.

## Why no codec

Measured between an M4 Pro and an M5 Pro over a Thunderbolt 5 bridge (2026-09-23):

| | Value |
|---|---|
| Bridge throughput, one TCP stream | ~67 Gbit/s |
| 3440×1440 BGRA at 120 fps, whole frames | ~19 Gbit/s |
| Same, changed regions only (desktop use) | ~0.5–2 Gbit/s |
| AES-256-GCM, one core | ~46 Gbit/s |
| Capture → photon, 120 Hz source on a 120 Hz viewer | ~20–28 ms |

A codec would add encode and decode time and lose detail to save bandwidth this link does not need. Links too slow for raw pixels (Wi-Fi, the internet) are out of scope for v1.

## Conventions

As in ClipSync:
- All multi-byte integers are **big-endian**.
- Floating-point fields are IEEE-754 binary64, big-endian.
- Control payloads are JSON; binary values inside JSON are **standard base64**.

In addition:
- **Host time** (`…HostNs` fields) is nanoseconds on the host's monotonic clock (`CLOCK_UPTIME_RAW` on macOS, the same base as `mach_absolute_time`). **Viewer time** (`…ViewerNs`) is the same on the viewer.
- The two clocks are never compared directly: see [Clock probe](#ping--pong-both-directions). Timestamps exist for latency measurement; correctness never depends on them.

## Overview

```
viewer                                              host
  │── screen.request ─────────── ClipSync ────────────►│  checks "allow control" for this peer
  │◄──────────────────────────── ClipSync ── screen.offer (endpoints, port, key)
  │
  │══ video connection:  preamble, BIND ══════════════►│
  │◄══════════════════ FRAME, FRAME, FRAME … ══════════│  whole frame first, then changed regions
  │
  │══ input connection:  preamble, BIND ══════════════►│
  │══ EVENT, EVENT, PING, RELEASE_ALL … ══════════════►│  injected as local input
  │◄═══════════════════════════════════════ PONG … ════│
  │
  │── screen.stop ────────────── ClipSync ────────────►│  (either side, any time)
```

Setting up and tearing down a session happens inside an existing ClipSync session, as encrypted payloads. The pixels and the input travel on two dedicated TCP connections of their own, because ClipSync's JSON-and-base64 frames were built for clipboards, not gigabits.

## Control payloads (inside ClipSync)

These are ClipSync v1 encrypted payloads (see *Payload Types* in the ClipSync spec). A peer that does not know them ignores them, as it ignores any unknown `kind`.

### `screen.request` — viewer asks to see and control the host

```json
{
  "kind": "screen.request",
  "requestID": "<UUID v4>",
  "maxWidth": 3440,
  "maxHeight": 1440,
  "maxFPS": 120,
  "displayID": 5,
  "originID": "<viewer peerID>"
}
```

- `maxWidth` × `maxHeight` is the viewer's target area in **physical pixels**, normally the panel it will show the host on. The host captures its display scaled to the **largest size that fits within it and keeps the host display's aspect ratio**, with both dimensions rounded down to even numbers.
- `maxFPS` is optional. It is a ceiling: the host sends no more often than this, and otherwise sends a frame whenever its screen changes.
- `displayID` is optional: the host display to share first, typically the one this viewer chose last time (see `screen.displays`). A host that no longer has it shares its main display.

### `screen.offer` — host accepts

```json
{
  "kind": "screen.offer",
  "requestID": "<echoed>",
  "sessionID": "<base64 16 B>",
  "key": "<base64 32 B>",
  "port": 53812,
  "endpoints": [
    { "address": "169.254.35.239", "link": "thunderbolt" },
    { "address": "192.168.1.20",   "link": "ethernet" },
    { "address": "192.168.1.21",   "link": "wifi" }
  ],
  "display": { "name": "Odyssey G85SB", "width": 3440, "height": 1440, "refreshHz": 120 },
  "originID": "<host peerID>"
}
```

- `sessionID` and `key` are fresh random values from a CSPRNG, **used for one session only**. They never leave the encrypted ClipSync session.
- `port` is a TCP port the host listens on for **this session only**. Both data connections use it.
- `endpoints` lists the host's IPv4 addresses. `link` is one of `"thunderbolt"`, `"ethernet"`, `"wifi"`, `"other"`. The viewer tries them in the order **thunderbolt, ethernet, other, wifi** and uses the first one that connects within 1 s. Link-local addresses are expected (a Thunderbolt Bridge usually has only a `169.254.0.0/16` address), which is why the host lists them instead of the viewer resolving a name.
- `display` describes what the frames will contain. `width` × `height` is the capture size chosen from the request, not the display's own mode.
- The host MUST stop listening if both data connections have not bound within **10 s** of sending the offer, and MUST then treat the session as ended.

### `screen.decline` — host refuses

```json
{
  "kind": "screen.decline",
  "requestID": "<echoed>",
  "reason": "not_allowed" | "busy" | "needs_screen_recording" | "needs_accessibility" | "other",
  "originID": "<host peerID>"
}
```

- `not_allowed`: the host's user has not allowed this peer. The host MUST send this whenever that permission is off; it is never granted implicitly by pairing.
- `busy`: another session is already running. A host serves **one session at a time**.
- `needs_screen_recording` / `needs_accessibility`: the host lacks the OS permission to capture, or to inject input. The host SHOULD also tell its own user.

### `screen.displays` — host tells the viewer its displays

```json
{
  "kind": "screen.displays",
  "sessionID": "<base64 16 B>",
  "displays": [
    { "id": 5, "name": "Odyssey G85SB", "width": 6192, "height": 2592,
      "x": 0, "y": 0, "pointWidth": 3096, "pointHeight": 1296, "refreshHz": 120, "main": true },
    { "id": 1, "name": "Built-in Retina Display", "width": 3024, "height": 1964,
      "x": 3096, "y": 400, "pointWidth": 1512, "pointHeight": 982, "refreshHz": 120, "main": false }
  ],
  "current": 5,
  "originID": "<host peerID>"
}
```

- Sent once both data connections are bound, and again whenever the set of displays, their arrangement, or the shared one changes.
- `x`, `y`, `pointWidth`, `pointHeight` place each display in the host's desktop, in points, with the main display's top left at 0,0: enough for a viewer to draw the arrangement as the host's own display settings do. `width` and `height` are the display's pixels in its current mode.
- Mirrored displays appear once. `current` is the display the frames show.

### `screen.select` — viewer asks for another display

```json
{ "kind": "screen.select", "sessionID": "<base64 16 B>", "displayID": 1, "originID": "<viewer peerID>" }
```

The host switches capture to that display without ending the session: the next `FRAME` is whole, at that display's size (fitted to the request as before), pointer positions from then on are normalized to it, and a `screen.displays` with the new `current` follows. An unknown or vanished display is ignored.

### Reconnecting

A viewer whose session ended for any reason but a deliberate one (`screen.stop` with `user`, `revoked`), or the user closing it, MAY ask again with a fresh `screen.request`, and keep asking for a while. It gets a new session with new keys. A host that receives a request from the peer it is already serving ends the old session and answers the new one, since that peer has evidently lost the old one; a request from anyone else while busy is declined with `busy`.

### `screen.stop` — either side ends the session

```json
{
  "kind": "screen.stop",
  "sessionID": "<base64 16 B>",
  "reason": "user" | "revoked" | "display_lost" | "error" | "other",
  "originID": "<sender peerID>"
}
```

- `revoked`: the host's user turned off the permission, or unpaired the viewer, mid-session.
- `display_lost`: the captured display went away (unplugged, or the host went to sleep).

A session also ends, without any message, when either data connection closes. It does **not** end when the ClipSync session that set it up closes: ClipSync replaces connections as peers reconnect or change networks, and the data connections' own keepalive already tells whether the other side is there. Control messages for a running session travel on whatever ClipSync session is current. On any ending, the host releases every key and button the viewer held down (see `RELEASE_ALL`), closes both data connections and forgets `sessionID` and `key`.

## Data connections

### Preamble (cleartext)

Right after connecting, the viewer sends 8 bytes in the clear, before anything else:

```
magic    4 B   "OBSC" (0x4F 0x42 0x53 0x43)
version  1 B   0x01
channel  1 B   0x01 = video, 0x02 = input
reserved 2 B   0x00 0x00
```

Everything after the preamble, in both directions, is **records**.

### Records

```
length      UInt32   byte length of what follows (ciphertext + tag), at most 1 MiB + 16
ciphertext  length − 16 bytes
tag         16 B     AES-256-GCM tag
```

- **Cipher**: AES-256-GCM with **empty AAD**. It was chosen over ChaCha20-Poly1305, which ClipSync uses, because both Macs have AES hardware: 46 against 8 Gbit/s on one core. That difference matters for whole frames at 19 Gbit/s.
- **Nonce**: `0x00000000 (4 B) || counter (UInt64)`. Each key has its own counter, starting at 0 and incremented after every record. The counter is **not sent**: TCP delivers records in order, so both ends know it. A record that fails to decrypt means the stream is corrupt or forged, and the receiver MUST close the connection.
- **Plaintext**: at most **1 MiB** per record. The decrypted records of one direction concatenate into a byte stream, and the messages below are read from that stream. **Message and record boundaries are independent**: a whole frame spans many records, and a record may carry the end of one message and the start of the next. This lets a receiver decrypt pixels while the rest of a frame is still arriving.

### Keys

Each direction of each connection has its own key, derived from the offer's `key` and `sessionID`:

```
k(label) = HKDF-SHA256(ikm = key, salt = sessionID, info = label, length = 32)

video, viewer → host : k("obscreen-v1 video v2h")   carries BIND only
video, host → viewer : k("obscreen-v1 video h2v")
input, viewer → host : k("obscreen-v1 input v2h")
input, host → viewer : k("obscreen-v1 input h2v")
```

Separate keys per direction mean nonces never collide, even though every counter starts at 0.

### `BIND` (viewer → host, first message on each connection)

```
type       UInt8     0x30
channel    UInt8     same as the preamble's
reserved   2 B       0
sessionID  16 B
```

The host checks that the preamble's channel matches, that the record decrypted with the key for that channel, and that `sessionID` is the one it offered. Any failure closes the connection. A second `BIND` for a channel already bound closes the new connection, not the old one. Only once **both** channels are bound does the host start capturing.

## Video channel (host → viewer)

After `BIND`, only the host speaks on this connection.

### `FRAME`

```
type          UInt8    0x01
flags         UInt8    bit 0: whole frame (the only rect covers the frame); other bits 0
reserved      2 B      0
pixelFormat   UInt32   0x42475241 "BGRA"
frameIndex    UInt64   1, 2, 3 … per session; gaps allowed (frames merged away on the host)
width         UInt32   frame size in pixels; matches `display` in the offer until it changes
height        UInt32
rectCount     UInt32   1 … 256
reserved      4 B      0
captureHostNs UInt64   the refresh the frame was composited for
sendHostNs    UInt64   when the host started sending it
inputSeq      UInt64   last EVENT injected before captureHostNs; 0 if none yet
inputHostNs   UInt64   when that EVENT was injected
rects         rectCount × { x UInt32, y UInt32, width UInt32, height UInt32 }
pixels        for each rect in order: height rows of width × 4 bytes, top to bottom, no padding
```

The header is 64 bytes, then `16 × rectCount` bytes of rects, then `Σ width × height × 4` bytes of pixels.

**Pixels.** Each pixel is 4 bytes in the order blue, green, red, alpha, 8 bits each, in the **sRGB** color space. Alpha is always 255 and receivers MAY ignore it.

**Frame rules:**
- The **first `FRAME`** of a session, the first after `width` or `height` changes, and the first after a `REQUEST_FULL` MUST be whole frames (`flags` bit 0). A receiver MAY close the connection on a partial frame it has nothing to apply to.
- A partial frame's rects replace those regions of the viewer's current picture. Everything outside them is unchanged.
- Rects lie fully inside the frame and MAY overlap. Overlapping pixels are identical, because every rect comes from the same captured image.
- **Newest wins, nothing is lost.** When the host captures a new image before the previous one has been sent, it drops the older image but keeps its changed regions, merging them into the newer one's. Any region that changed is always resent from the newest pixels. The viewer never needs a frame it did not get.
- When the merged regions exceed **256 rects**, the host sends their bounding box as one rect instead; when they cover **more than 60 %** of the frame, it sends a whole frame.

**Pauses and size changes.** A host MAY stop sending frames for a while and resume later; the viewer keeps showing the last picture. Hosts do this while the operating system reconfigures displays (a mode change, a monitor waking or switching inputs): capture pauses when the change begins and resumes about a second after it ends, starting with a whole frame, at whatever size the display's new mode gives. If the captured display is gone, the host waits up to **15 s** for it to return before ending the session with `display_lost`.

**Slower links.** Raw pixels suit Thunderbolt. When the viewer's connections arrive on any other kind of link, the host SHOULD halve the requested size and send at most 60 frames per second. The first frame, being whole, tells the viewer the size. This keeps a session alive when a cable comes out; it does not make Wi-Fi pleasant. Measured over Wi-Fi at ~760 Mbit/s, dragging windows sent whole ~10 MB frames at 8–10 fps. A compressed path for non-Thunderbolt links is future work (see BACKLOG.md).

`inputSeq` and `inputHostNs` let the viewer measure the time from input to photon: the first frame shown carrying a given `inputSeq` is the first frame that could show that event's effect.

## Input channel

### `EVENT` (viewer → host)

48 bytes:

```
type           UInt8    0x10
kind           UInt8    1 move, 2 button down, 3 button up, 4 scroll,
                        5 key down, 6 key up, 7 modifiers changed, 8 media key
button         UInt8    kinds 2–3: 0 left, 1 right, 2 middle, 3–31 other buttons
                        kind 4: 1 if x/y are precise (trackpad, points), 0 if lines (wheel)
                        kind 8: 1 pressed, 0 released
clicks         UInt8    kinds 2–3: click count, 1 for single, 2 for double …
                        kind 8: 1 if this press is a key repeat; else 0
keyCode        UInt16   kinds 5–7: macOS virtual keycode (kVK_*)
                        kind 8: media key type (NX_KEYTYPE_*: 0 volume up, 1 volume down,
                        2 brightness up, 3 brightness down, 7 mute, 16 play, 17 next, 18 previous …)
                        else 0
scrollPhase    UInt8    kind 4: NSEvent.Phase raw value; else 0
momentumPhase  UInt8    kind 4: momentum NSEvent.Phase raw value; else 0
flags          UInt64   modifier flags in CGEventFlags bit positions (Fn = 0x800000)
x              Float64  kinds 1–3: 0…1 from the host display's left edge; kind 4: horizontal delta
y              Float64  kinds 1–3: 0…1 from the host display's top edge;  kind 4: vertical delta
seq            UInt64   1, 2, 3 … per session, no gaps
sentViewerNs   UInt64   when the viewer sent it
```

- **Pointer** positions are **absolute and normalized** to the captured display. The viewer maps its own coordinates through the frame's on-screen rectangle, so a letterboxed or scaled view still lands on the right pixel. The host scales to its display's bounds in points. A `move` while any button is held is a drag.
- **Keys** travel as **physical keycodes**, never as characters. The host's own input source turns them into characters, so layouts, dead keys and input methods behave as they would locally. `flags` is authoritative: the host sets it on every key event it posts.
- **Modifiers** (kind 7) are sent whenever the modifier state changes, Fn included, with `keyCode` naming the modifier key that changed.
- **Media keys** (kind 8) are the keys macOS delivers apart from the keyboard proper: volume, brightness, play and skip. They are optional for the viewer — whether they act on the viewer's Mac or the host is the user's choice — and a host posts them as the system would.
- Events are injected in `seq` order as they arrive. The host never coalesces or delays them.

### `RELEASE_ALL` (viewer → host)

```
type      UInt8   0x11
reserved  7 B     0
```

The host posts a release for every key and mouse button it believes is down, then clears its modifier state. The viewer sends this whenever it stops forwarding input: its window loses focus, the pointer leaves the host's picture while no button is held, or the user presses the release shortcut. The host does the same by itself whenever a session ends. Together these guarantee that no key stays stuck on the host.

### `REQUEST_FULL` (viewer → host)

```
type      UInt8   0x12
reserved  7 B     0
```

Asks for the next `FRAME` to be whole. It is for a viewer that lost its picture (for example after recreating its GPU resources). It is not needed at session start.

### `PING` / `PONG` (both directions)

```
PING (viewer → host):  type UInt8 0x20, reserved 7 B, viewerNs UInt64                  — 16 bytes
PONG (host → viewer):  type UInt8 0x21, reserved 7 B, viewerNs UInt64 (echoed), hostNs UInt64 — 24 bytes
```

The host answers each `PING` at once. The viewer sends one every 100 ms. This serves as the session's **keepalive** in both directions: the host ends the session (`screen.stop`, `reason: "error"`) after **3 s** without any message on the input channel, and the viewer ends it after **3 s** without a `PONG`. Without the second rule, a host that went to sleep or lost its cable would leave the viewer waiting on a TCP connection that may take minutes to fail.

It is also the **clock probe**. From a round trip `t0 → t1` (viewer time), with the host's reply `h`:

```
offset = h − (t0 + t1) / 2            // host clock minus viewer clock
```

Of recent samples, the one with the smallest `t1 − t0` gives the best estimate. A host timestamp `T` corresponds to viewer time `T − offset`. Over a Thunderbolt Bridge the round trip is about 0.3 ms, so the estimate is good to about ±0.15 ms.

## Permissions

A host MUST decline (`not_allowed`) unless its user has turned on control for **that specific paired peer**. That setting is **off** for every peer by default, including peers paired before this protocol existed. Turning it off during a session ends the session (`revoked`). Unpairing a peer does the same.

While a session runs, the host MUST show its own user that it is being viewed and controlled, and MUST offer a way to end it from the host itself.

## Limits Summary

| Limit | Value |
|---|---|
| Concurrent sessions per host | 1 |
| Data connections per session | 2 (video, input) |
| Time to bind both after `screen.offer` | 10 s |
| Record plaintext max | 1 MiB |
| Rects per `FRAME` | 256 |
| Frame width, height | 1 … 16384 |
| Keepalive interval / timeout | 100 ms / 3 s |
| Endpoint connect attempt | 1 s each |

## Versioning

- The preamble's `version` is `0x01`. A host that sees another value closes the connection.
- Message types a receiver does not know are an error on the data channels, unlike ClipSync payloads: the stream has no length prefix per message, so an unknown one cannot be skipped. New message types require a version bump.
- New control payload fields may be added freely; unknown JSON keys are ignored.

## Change Log

- **v1 (2026-09-23)**: initial revision.
