# Audio

Video goes one way; audio goes both. Whichever tab a machine is on, it sends one audio
stream and plays one — and that is what makes a pair of Macs a conversation rather than a
broadcast.

The menu is grouped by direction, and every line carries its own answer:

```
Sending                                  Receiving
  Camera: Insta360 Link                    NDI Source: macos           (Receive)
  Audio: Mic — Shure MV7                     or Listen to: macos-work  (Send)
  NDI: macos                               Play audio on: AirPods Pro
```

| Line | Direction | What it decides |
| --- | --- | --- |
| **Audio** | out | the one audio stream this machine publishes: `Mic — …` or `System audio — …` |
| **Listen to** | in | which source this machine hears, when it is not already receiving one |
| **Play audio on** | in | which speakers that comes out of |

`Listen to` and `Play audio on` are the two halves of hearing something: *which* stream,
and *where* it comes out. Receive has no `Listen to` because **NDI Source** already named
one.

## What Audio can send

**A microphone** — the system default, a specific input, or none.

**System audio** — what the Mac is playing through one of its outputs, captured with a
CoreAudio process tap. `Default output` follows whatever the Mac is using at the time;
anything else stays on the device you named, and comes back on its own after being
unplugged and plugged in again.

OpenBeam excludes itself from the tap, so a machine playing a received stream out of the
very device it is tapping cannot feed itself. It never mutes what it captures either: you
go on hearing what you are sending.

Each tab remembers its own choice. Send starts at the system microphone, Receive at
`None` — a machine only puts its audio on the network once you have said so, and the
menu's `NDI:` line tells you whether it is.

## The pair in a video call

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

| | A — Send | B — Receive |
| --- | --- | --- |
| Video | camera → NDI | NDI → `NDI Virtual Camera` → the call |
| Your voice | **Audio**: microphone → NDI | NDI → `NDI Audio` → the call |
| The call's voices | **Listen to** B, **Play audio on** your headphones | **Audio**: system audio → NDI |

Set B first. Until its **Audio** is chosen it publishes nothing, and A's **Listen to** has
nothing to offer.

On B, leave **Play audio on** at `None` in this setup: A's voice is already going into the
call as a virtual microphone, and playing it out of B's speakers as well would only put it
in B's room.

:::warning
Use headphones at A. A's microphone is what the call hears and A's speakers are playing
the call, so on speakers the meeting hears itself back. OpenBeam captures a microphone
raw, with no echo canceller of its own.
:::

## Latency and drift

The received stream is held for 80 ms before it starts playing. The two machines' clocks
are independent — the sending card decides how much audio arrives, the receiving one how
fast it leaves — so the buffer drifts in one direction or the other however good the
network is. It throws the excess away if it falls more than 240 ms behind, and goes quiet
to refill if it runs dry.

## Requirements

Capturing an output needs macOS 15, where a bundled app may tap audio without a separate
permission. Playing needs nothing at all. Neither half needs NDI Tools — that is only for
the virtual camera and its `NDI Audio` driver.
