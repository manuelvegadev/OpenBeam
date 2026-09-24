//
//  PlanarAudio.swift
//  OpenBeam
//
//  The shape audio travels in between the network and the speakers.
//

import AVFoundation
import Accelerate
import os

/// One block of planar float audio, valid only for the duration of the call
/// that hands it over. It is the shape libndi delivers, described here so that
/// nothing about NDI reaches into the audio engine.
struct PlanarAudio {
    let data: UnsafePointer<Float>
    let frameCount: Int
    let channelCount: Int
    /// Distance between one channel and the next, in samples.
    let channelStride: Int
    let sampleRate: Double
}

// MARK: - Gathering a capture into one

/// Turns what a capture hands over — an `AudioBufferList` in whatever layout
/// its device happens to use — into one planar block, in storage that is
/// reused rather than allocated per call.
///
/// Both things done with captured audio want that shape: libndi takes planar
/// float, and so does the ring the monitor writes into. Keeping the conversion
/// in one place is also what makes the monitor worth listening to — what it
/// plays is de-interleaved by the same code that de-interleaves what goes on
/// the wire, rather than by a second copy of the idea that could drift from it.
final class PlanarAudioScratch: @unchecked Sendable {

    /// Grown to the largest block seen and then reused. A fresh array per block
    /// is a malloc and a zero-fill on the HAL's I/O thread ~94 times a second,
    /// and the allocator lock is the one thing there that can make the thread
    /// miss its deadline.
    ///
    /// The lock is uncontended — one capture path runs at a time — and it is
    /// what keeps a switch between the microphone and the tap from handing the
    /// same buffer to two threads.
    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    private struct Storage {
        private var data: UnsafeMutablePointer<Float>?
        private var capacity = 0

        mutating func buffer(for count: Int) -> UnsafeMutablePointer<Float>? {
            if capacity < count {
                data?.deallocate()
                data = .allocate(capacity: count)
                capacity = count
            }
            return data
        }

        mutating func release() {
            data?.deallocate()
            data = nil
            capacity = 0
        }
    }

    /// Runs `body` with the block gathered into the scratch — and not at all
    /// when the list is not float32 or carries no frames. The pointer it hands
    /// over is valid for that call and no longer: the next block overwrites it.
    func withPlanar(_ bufferList: UnsafePointer<AudioBufferList>,
                    format: AVAudioFormat,
                    _ body: (PlanarAudio) -> Void) {
        guard format.commonFormat == .pcmFormatFloat32 else { return }

        let channels = Int(format.channelCount)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard channels > 0, buffers.count > 0, let firstData = buffers[0].mData else { return }

        // Frames from the bytes the device actually filled, not from what the
        // buffer could hold.
        let bytesPerFrame = (format.isInterleaved ? channels : 1) * MemoryLayout<Float>.size
        let frames = Int(buffers[0].mDataByteSize) / bytesPerFrame
        guard frames > 0 else { return }

        storage.withLock { storage in
            guard let base = storage.buffer(for: frames * channels) else { return }

            // `floatChannelData` is non-nil for an interleaved buffer too, with
            // one pointer instead of one per channel — so the layout has to be
            // asked about rather than inferred from it. Reading interleaved
            // samples as if they were planar puts both channels in both, which
            // is what a stereo tone through the system tap showed.
            if format.isInterleaved {
                let source = firstData.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels {
                    // A strided gather, which Accelerate vectorises; the scalar
                    // loop it replaces ran 96,000 times a second at 48 kHz.
                    cblas_scopy(Int32(frames),
                                source + channel, Int32(channels),
                                base + channel * frames, 1)
                }
            } else {
                guard buffers.count >= channels else { return }
                for channel in 0..<channels {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { return }
                    (base + channel * frames).update(from: data, count: frames)
                }
            }

            body(PlanarAudio(data: UnsafePointer(base),
                             frameCount: frames,
                             channelCount: channels,
                             channelStride: frames,
                             sampleRate: format.sampleRate))
        }
    }

    deinit {
        storage.withLock { $0.release() }
    }
}
