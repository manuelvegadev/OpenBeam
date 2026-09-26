//
//  MonitorMix.swift
//  OpenBeam
//
//  The call's microphone, mixed into what the machine sends, so that the Mac
//  nobody sits at can be listened to from the one somebody does.
//
//  Playing the monitor into the tapped output and letting the tap pick it up
//  was tried first, and it cannot work: a process tap does not capture the
//  process that made it, excluded or not. Measured on the machine in the call
//  while someone spoke: the monitor read peaks of 0.2 from `NDI Audio`, and
//  the tap on the output the monitor was playing into read 0.0 throughout.
//  So the mix is made here, before the audio reaches NDI.
//

import AVFoundation
import Accelerate
import os

/// Two threads meet here. The tap's I/O thread hands over the system audio,
/// which goes into a ring; the microphone's I/O thread takes its own block,
/// adds whatever the ring holds for the same span, and sends the sum.
///
/// The microphone is the clock, not the tap. A tapped output runs no I/O at
/// all while nothing is playing on it, and a mix paced by it would stop the
/// microphone with it; paced by the microphone, a silent system is a ring
/// with nothing in it, which adds nothing — the right answer.
final class MonitorMix: @unchecked Sendable {

    /// Whether the sender is fed from here instead of by the tap. Read on both
    /// I/O threads for every block and set from main.
    private let active = OSAllocatedUnfairLock(initialState: false)
    var isActive: Bool { active.withLock { $0 } }

    /// Replaced by the tap thread when the system audio changes shape, read
    /// by the microphone thread for every block.
    private let background = OSAllocatedUnfairLock<RingBuffer?>(initialState: nil)

    private let backgroundScratch = PlanarAudioScratch()
    private let voiceScratch = PlanarAudioScratch()

    // Touched only by the microphone thread.
    private var mixed = FloatStorage()
    private var pulled = FloatStorage()
    private var pulledList: UnsafeMutableAudioBufferListPointer?

    /// Starting forgets the system audio held so far, so a mix never opens on
    /// audio left over from the last one.
    func setActive(_ isActive: Bool) {
        let changed = active.withLock { active -> Bool in
            defer { active = isActive }
            return active != isActive
        }
        if changed { background.withLock { $0 = nil } }
    }

    /// Called on the tap's I/O thread with the system audio it captured.
    func addBackground(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        backgroundScratch.withPlanar(bufferList, format: format) { audio in
            let ring = background.withLock { ring -> RingBuffer in
                if let ring, ring.sampleRate == audio.sampleRate, ring.channels == audio.channelCount {
                    return ring
                }
                let fresh = RingBuffer(sampleRate: audio.sampleRate, channels: audio.channelCount, health: nil)
                ring = fresh
                return fresh
            }
            ring.write(audio)
        }
    }

    /// Called on the microphone's I/O thread. Hands `send` the microphone's
    /// block with the system audio added — or the microphone alone when there
    /// is none, or when it runs at another rate: resampling one to the other
    /// is not worth doing for a monitor, and the voice is what it is for.
    func mix(_ bufferList: UnsafePointer<AudioBufferList>,
             format: AVAudioFormat,
             send: (PlanarAudio) -> Void) {
        voiceScratch.withPlanar(bufferList, format: format) { voice in
            guard let ring = background.withLock({ $0 }), ring.sampleRate == voice.sampleRate else {
                send(voice)
                return
            }

            let frames = voice.frameCount
            let channels = voice.channelCount
            let system = pull(frames: frames, from: ring)
            let out = mixed.buffer(for: frames * channels)
            for channel in 0..<channels {
                // A mono system mix under a stereo voice goes to both sides.
                vDSP_vadd(voice.data + channel * voice.channelStride, 1,
                          system + min(channel, ring.channels - 1) * frames, 1,
                          out + channel * frames, 1,
                          vDSP_Length(frames))
            }

            send(PlanarAudio(data: out,
                             frameCount: frames,
                             channelCount: channels,
                             channelStride: frames,
                             sampleRate: voice.sampleRate))
        }
    }

    /// Reads `frames` of system audio, planar, silence where the ring had
    /// none.
    private func pull(frames: Int, from ring: RingBuffer) -> UnsafeMutablePointer<Float> {
        let channels = ring.channels
        let data = pulled.buffer(for: frames * channels)

        if pulledList?.count != channels {
            pulledList.map { free($0.unsafeMutablePointer) }
            pulledList = AudioBufferList.allocate(maximumBuffers: channels)
        }
        let list = pulledList!
        for channel in 0..<channels {
            list[channel] = AudioBuffer(mNumberChannels: 1,
                                        mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                        mData: data + channel * frames)
        }

        _ = ring.read(into: list, frames: frames)
        return data
    }

    deinit {
        mixed.release()
        pulled.release()
        pulledList.map { free($0.unsafeMutablePointer) }
    }
}
