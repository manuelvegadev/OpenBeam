# Remote Screen over Wi-Fi — Design Proposal

**Status: proposal, nothing implemented.** Remote screen v1 sends raw pixels and is built for a Thunderbolt Bridge ([SCREEN-PROTOCOL.md](SCREEN-PROTOCOL.md)). Off Thunderbolt it falls back to half size and 60 fps, which keeps a session alive but runs at 8–10 fps whenever a window moves (see *Compress the remote screen when it leaves Thunderbolt* in [BACKLOG.md](BACKLOG.md)). This document records what the Wi-Fi between the two Macs can actually carry, which codecs were considered, and the proposed path.

When any of this is built, the wire changes go into SCREEN-PROTOCOL.md first, as its source-of-truth rule requires. Nothing here is normative.

## Measurements

Taken on 2026-09-28 with iperf3 3.21 between the M5 Pro (host) and the M4 Pro (viewer), in the direction the picture travels: host → viewer. One 8–10 s run per figure.

| | Host (M5 Pro) | Viewer (M4 Pro) |
|---|---|---|
| Wi-Fi | 802.11ax, 6 GHz, channel 37, 160 MHz | 802.11ax, 5 GHz, channel 44, 160 MHz |
| Signal / noise | −21 / −96 dBm | −21 / −90 dBm |
| Also on the LAN | — | 2.5 GbE (the default route) |

Two paths were measured: **A**, host Wi-Fi to the viewer's Ethernet, and **B**, Wi-Fi at both ends (the server bound to the viewer's Wi-Fi address; its interface counters confirmed the traffic arrived there).

### Throughput and loss

| | A: Wi-Fi → Ethernet | B: Wi-Fi → Wi-Fi |
|---|---|---|
| TCP, one stream | ~750 Mbit/s | ~1080 Mbit/s |
| UDP 100 / 200 Mbit/s | 0 % lost | 0 % lost |
| UDP 300 Mbit/s | 0.07 % | 0.36 % |
| UDP 400 Mbit/s | 2.5 % | 0.56 % |
| UDP 500 Mbit/s | 5 % | 1.4 % |

About **200 Mbit/s** goes through without loss on either path.

### Latency

Round-trip ping, 200 samples at 100 ms intervals, in ms. "Under load" means a 200 Mbit/s UDP stream was running at the same time.

| | p50 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|
| A, under load | 4.4 | 24 | 50 | 74 | 81 |
| B, under load | 9.4 | 41 | 66 | 89 | 113 |
| B, idle | 6.7 | 47 | 65 | 74 | 78 |

The Thunderbolt Bridge measures 0.4 ms. Here the median is fine, but one packet in ten comes back 25–50 ms late, loaded or not.

### What the numbers say

**Bandwidth is not the problem; the latency tail is.** Any codec that fits in 200 Mbit/s has room to spare. None of them can hide a 50 ms stall, and at 60 fps that is three frames. That tail is the first thing a Wi-Fi mode has to deal with, before any choice of codec.

**Suspected cause: AWDL.** `awdl0`, the interface AirDrop, Universal Control, Sidecar and Continuity share, was active on both Macs. It is known to take the radio off the infrastructure channel periodically, which produces exactly this pattern. Here the host's Wi-Fi was on 6 GHz while AWDL works on 5 GHz channels, so every hop means retuning. Not yet tested: `sudo ifconfig awdl0 down` on both Macs and the ping run again. That breaks AirDrop and Universal Control until `ifconfig awdl0 up` or a restart.

## Codecs considered

### Raw pixels (today)

Right for Thunderbolt, and nothing changes there. Over Wi-Fi, a window drag makes whole ~10 MB frames, and at ~760 Mbit/s that is ~109 ms each.

### PyroWave

A wavelet codec by Hans-Kristian Arntzen, used by Steam Remote Play's low-latency mode (in beta on macOS, Windows and Linux since September 2026). Every frame is coded on its own (intra-only), in 32×32 blocks, on the GPU, taking ~0.1–0.2 ms to encode or decode. A lost packet only blurs one block of one frame.

- **Available:** MIT licence, [Themaister/pyrowave](https://github.com/Themaister/pyrowave), under active development. The C API is not yet stable.
- **macOS:** the repository carries a native Metal port in `metal/`, maintained by Sam Lantinga. It has no Vulkan or MoltenVK and is about twice as fast as the Vulkan build running on KosmicKrisp. Its README calls it an AI-assisted, "quick and dirty" port that upstream will not maintain and "may be removed entirely at some point".
- **Bandwidth:** built for 200+ Mbit/s on Ethernet. It uses ~1.5 bits per pixel at 1080p60 (4:2:0), and a desktop needs more than a game because text suffers first:

  | Size | 60 fps | 120 fps |
  |---|---|---|
  | 3096×1296 | ~360 Mbit/s | ~720 Mbit/s |
  | 1548×648 (the half-size fallback) | ~90 Mbit/s | ~180 Mbit/s |

  Full size is past the ~200 Mbit/s this Wi-Fi carries without loss. Half size fits.
- **Poor fit for a desktop:** it codes every frame whole, so a still screen with a blinking cursor costs as much as a scrolling one. Wavelets at these rates also blur and ring around sharp edges, which is fine in games and noticeable in text.
- **Not decisive here:** its sub-millisecond encode is its selling point, and that gain disappears under 50 ms network stalls.

**Verdict:** not for Wi-Fi. Worth revisiting for a wired-Ethernet tier (1–10 GbE between Macs), where raw pixels do not fit and HEVC's extra milliseconds would be the largest delay left. Adopting it means vendoring a library, which needs the owner's sign-off first.

### HEVC through VideoToolbox (proposed)

HEVC is H.265, the successor to H.264: it needs roughly half the bitrate of H.264 for the same quality. VideoToolbox drives the hardware media engine in Apple silicon. There is no dependency to add and no CPU or GPU load, and the encoder has a real-time mode. Inter-frame prediction means an unchanging screen costs almost nothing, which suits a desktop far better than an intra-only codec.

### Others

- **H.264 through VideoToolbox:** the same machinery. It needs more bitrate for the same text quality. A fallback if HEVC's low-latency mode turns out to be missing or slow.
- **x264 / x265:** software encoders. They are excellent, but they cost CPU, are slower than the hardware, and are GPL. They offer nothing over VideoToolbox here.

## Proposal

A second video path, used only when the viewer's connections arrive on a link other than Thunderbolt:

1. **Encoder (host):** `VTCompressionSession`, HEVC, real-time, no frame reordering (no B-frames), and intra refresh instead of periodic keyframes, so no single frame spikes the bitrate. Target a few tens of Mbit/s at the half-size fallback, and allow up to about 100 Mbit/s, well inside the 200 Mbit/s the link carries without loss.
2. **Negotiation:** the viewer advertises the codecs it can decode in `screen.request`, and the host names the one it chose in `screen.offer`. An older peer that says nothing keeps getting raw pixels.
3. **Wire:** a `FRAME` variant carrying one encoded picture and its length instead of rects. The data channel has no per-message length, so unknown message types cannot be skipped. That makes this a protocol version bump, or a new `pixelFormat` whose layout is defined in the spec. To be decided when SCREEN-PROTOCOL.md is updated.
4. **Decoder (viewer):** `VTDecompressionSession` feeding the existing Metal canvas. Always show the newest decoded picture and never queue.
5. **Transport:** stay on TCP at first. Below 200 Mbit/s this link lost nothing over UDP, and TCP keeps the stream intact for inter-frame prediction. If head-of-line stalls show up in the input-to-photon numbers, UDP with intra refresh is the next step.

Expected cost: a few milliseconds of encode plus decode and some softening of fine text. Thunderbolt makes both unnecessary, so it keeps raw pixels.

## Open questions

- Does turning off AWDL remove the latency tail? This is the cheapest test and should come first.
- Does VideoToolbox's low-latency rate control support HEVC on current macOS, or only H.264? Verify against the SDK headers before designing around it.
- What are the encode and decode times at 1548×648 and 3096×1296 on the M4 Pro and M5 Pro? Measure them in a prototype under `experiments/`.
- Is HEVC 4:4:4 available from the hardware encoder? 4:2:0 smears colored text.
- Would the half-size fallback still be needed once frames are compressed, or can Wi-Fi carry full size at 60 fps?

## Sources

- [Pyrowave video codec now in beta — Steam Remote Play](https://steamcommunity.com/groups/homestream/discussions/0/564794422009744473)
- [I designed my own ridiculously fast game streaming video codec — PyroWave](https://themaister.net/blog/2025/06/16/i-designed-my-own-ridiculously-fast-game-streaming-video-codec-pyrowave/)
- [Themaister/pyrowave](https://github.com/Themaister/pyrowave) and its `metal/README.md`
