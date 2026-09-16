# Backlog

Known work that is understood but not done. Each entry records what was measured,
so the case does not have to be rebuilt from scratch before acting on it.

Numbers below were taken on an M4 Pro with an Insta360 Link at 1920×1080, sending
BGRA, unless stated otherwise.

## Skip encoding when nothing is receiving

**Impact: ~25% of a core, continuously.** `NDIlib_send_send_video_v2` takes ~8.5 ms
per call at 1080p with no receiver connected, and `AppDelegate`'s frame handler
calls it 30 times a second regardless. That is roughly 254 ms of CPU per second
spent compressing frames nobody asked for — the single largest remaining cost in
the app, larger than everything already optimised put together.

`NDIlib_send_get_no_connections(instance, 0)` reports the current consumer count.
Gate the send on it, polling at a low rate rather than per frame, and keep
capturing so the preview and stats stay live.

Worth confirming first whether libndi already short-circuits internally: the
measured 8.5 ms with no receiver was *higher* than the 5.9 ms measured with one,
which is the opposite of what a short-circuit would produce and is not explained.

## Give the NDI handle a single owner

`NDISender` keeps the handle in two places: `ndiInstance`, guarded by `queue`, and
a copy behind `liveInstance`'s lock for the hot paths. A reader that takes the
pointer immediately before `stop()` can still hand it to libndi after the instance
is destroyed. The window is narrow and pre-existing — the `queue.sync` hop that
`liveInstance` replaced had exactly the same hole — but it is real.

Closing it means one owner across `start`, `stop`, `send(pixelBuffer:)` and
`send(audioBuffer:)`. Holding a lock across the libndi call is not the answer: the
audio path runs on the audio tap thread, where an unbounded wait is worse than the
race. Something like a generation counter, or moving audio onto `queue` with the
samples copied first, is the shape to explore.

Related: `send(audioBuffer:)` calls libndi directly from the audio thread while
video sends run on `queue`, so two threads can be inside the same send instance at
once. The SDK's guarantees here should be checked before relying on it.

## Send BGRX instead of BGRA

**Measured 7–8% faster:** 6.49 ms mean per send against 7.03 for BGRA, median 6.65
against 7.16, over 150 calls at 1080p with a receiver attached.

The alpha channel is provably unused — every pixel AVFoundation delivers has alpha
255, verified by sampling full frames. `BGRX` tells the receiver so, which also
saves it compositing a channel that carries no information.

Held back from a patch release because it changes the declared wire format, which
is compatibility surface for receivers. It belongs in a minor.

## Blur the preview intro per frame instead of pre-baking a ladder

`runPreviewIntro` builds nine progressively sharper copies of the first frame and
steps through them with a discrete keyframe animation, because Core Animation
cannot interpolate between images. Everything else follows from that: a state
machine to hold live frames back so they do not stomp the animation, two animation
keys to remove on close, and an intro that shows a frozen frame rather than live
motion.

Blurring each frame as it arrives — radius from elapsed time, `15 · (1 − t)²` until
t reaches the duration, then passing frames through untouched — deletes the ladder,
the keyframe animation, both animation keys and the `PreviewIntro` state, and
leaves the write path as one unconditional `layer.contents = cgImage`. The preview
would also be live during the intro instead of frozen.

Cost is comparable: ~0.44 ms per quarter-size blur either way, spread across the
0.45 s rather than front-loaded onto the menu opening.

Not done because it changes an animation that was tuned by eye, so it needs to be
judged the same way rather than swapped in on the strength of the code being
tidier.

## Hang the stats on their own submenu

`statsSubmenu` is the only submenu without `delegate = self`; the others update on
demand through `menuNeedsUpdate`. Because of that, the stats timer and the `nettop`
sampling are gated on the *top-level* menu, so they run while the user is browsing
Camera or Audio, where the figures cannot be seen.

Setting the delegate and moving the start/stop into `menuWillOpen(statsSubmenu)` /
`menuDidClose(statsSubmenu)` puts stats on the same on-demand mechanism as every
other submenu. Accepted cost: the rates show placeholders for the first second
after hovering in, the same delay already accepted on menu open.

## Send can pick the NDI virtual camera as its input

With NDI Tools installed, `AVCaptureDevice.default(for: .video)` can resolve to
`NDI Virtual Camera`, so Send starts by capturing the virtual camera instead of a
webcam — observed on this machine, where the preview showed the NDI test pattern
the extension was receiving. Harmless there, but if that extension is pointed at
this machine's own source it closes a loop.

Receive now makes the virtual camera far more likely to be installed, so the
default deserves to be pickier: skip devices whose `localizedName` is the virtual
camera (or, better, whose transport type is not a real capture device) when no
camera has been chosen yet. The chosen camera is also not persisted across
launches, which is the other half of the same gap.

## Mix a microphone into the system audio being sent

Send puts one audio source on the network because NDI carries one audio stream,
so choosing a machine's output means giving up its microphone. Talking over what
the machine is playing — a demo with commentary — needs both, which means a
mixer: the two arrive at different rates and block sizes, from two threads, so
it is a ring per source, a resampler and a gain per input rather than an
addition.

Deliberately not built. The exclusive picker is what a routing choice looks like
when it is one decision, and it is worth knowing whether anyone reaches for the
mix before paying for it.

## Nothing cancels the echo on the machine you sit at

The pair now carries audio both ways, which puts one machine's speakers and its
microphone in the same room and the same call: on speakers rather than
headphones, the meeting hears itself back. OpenBeam captures a microphone raw.

macOS has the piece that fixes it — the Voice Processing I/O unit, which is an
`AUVoiceIO` output unit set on the capture device, and cancels what that device
is playing out of what it hears. It is not free: it takes the device rather than
a stream, it resamples and gates and gains inside itself, and it changes what a
microphone sounds like even when nothing is playing. So it belongs behind a
setting rather than in the capture path, and it wants its own pass.

Documented here rather than in the README because the workaround — headphones —
is the one most people are using already.

## Catch up on drift by skipping a quiet block, not the oldest one

`AudioOutputPlayer`'s ring throws away the excess when the stream falls more than
240 ms behind, which is the bluntest correction there is: whatever was in those
samples is audibly gone. Choosing the quietest block within the excess instead,
and only taking a loud one when no quiet one has come along for a few seconds,
makes the same correction inaudible.

Not done because the correction has not been seen to fire: NDI clocks its own
audio and a LAN's jitter fits inside the cushion. It is worth building the first
time someone reports a click on a long call.

## Unverified

The preview intro animation has not been looked at since the cleanup pass that
moved the ladder construction off the main thread and replaced two booleans with a
state enum. The animation code itself is unchanged and the logic was reasoned
through, but nobody has watched it since.

A cheap way to check it objectively, which is how the original opacity bug was
found: screen-record the menu opening, then read the mean luma of the preview
region per frame with
`ffprobe -f lavfi -i "movie=rec.mov,crop=...,signalstats" -show_entries frame_tags=lavfi.signalstats.YAVG`.
A working fade is a ramp across roughly `0.45 s × 60` frames; the bug showed up as
a single-frame jump of +35.
