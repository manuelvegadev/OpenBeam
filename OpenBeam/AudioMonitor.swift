//
//  AudioMonitor.swift
//  OpenBeam
//
//  Hearing what this machine is putting on the network, rather than only
//  watching the meter move.
//
//  A bar says audio is arriving. It does not say it is arriving intact, which
//  is the question a stream that has gone robotic raises — and the answer is
//  only ever a second away from the ear.
//
//  What it can and cannot settle: playing anywhere needs a cushion and a
//  device clock of its own, so a click heard here may be the monitor's rather
//  than the source's. Hearing the capture already broken, on the machine it is
//  captured on, rules the network and the far end's driver out in one go —
//  which is the half of the question that nothing else in the app can answer.
//

import AVFoundation
import os

/// Plays back a capture on an output of the user's choosing: in Send, what was
/// just handed to NDI, so that a stream can be judged before it leaves the
/// machine; in Receive, the loopback OpenBeam plays into, as the call hears it.
///
/// Receive never opens a microphone that a driver fills by itself, such as
/// `NDI Audio`: that driver splits its audio between the apps reading it, so
/// listening to it broke the call. There the received stream is monitored
/// instead, through its own player — see `AppDelegate.monitoredAudio`.
final class AudioMonitor: @unchecked Sendable {

    private let player = AudioOutputPlayer()
    private let scratch = PlanarAudioScratch()

    /// Read on the audio thread for every block and written from the menu, so
    /// it is the one piece of state here that needs protecting. The player's
    /// own `isPlaying` cannot stand in for it: nothing is built until the
    /// first block arrives, so a monitor gated on that would never start.
    private let running = OSAllocatedUnfairLock(initialState: false)

    var isRunning: Bool { running.withLock { $0 } }

    func start(target: AudioOutputTarget) {
        player.start(target: target)
        running.withLock { $0 = true }
    }

    func stop() {
        running.withLock { $0 = false }
        player.stop()
    }

    /// Called on the audio thread, with the list the capture just delivered.
    /// The block is gathered and copied here and nothing of it is kept, so a
    /// monitor that is off costs one lock and a comparison.
    func play(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard isRunning else { return }
        scratch.withPlanar(bufferList, format: format) { self.player.play($0) }
    }
}
