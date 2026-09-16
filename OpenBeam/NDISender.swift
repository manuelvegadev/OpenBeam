//
//  NDISender.swift
//  OpenBeam
//
//  NDI SDK C API bridge and frame sending.
//

import Foundation
import CoreVideo
import AVFoundation
import Accelerate
import os

final class NDISender: @unchecked Sendable {

    static let sourceName: String = {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty {
            return hostName.hasSuffix(".local") ? String(hostName.dropLast(6)) : hostName
        }
        return "OpenBeam"
    }()

    private var ndiInstance: NDIlib_send_instance_t?
    private let queue = DispatchQueue(label: "com.openbeam.ndi-send", qos: .userInteractive)
    private let semaphore = DispatchSemaphore(value: 1)

    // Stats — protected by statsLock (written on NDI/capture queues, read on main)
    private let statsLock = OSAllocatedUnfairLock(initialState: (sent: Int64(0), bytes: Int64(0), dropped: Int64(0)))

    var framesSent: Int64 { statsLock.withLock { $0.sent } }
    var bytesSent: Int64 { statsLock.withLock { $0.bytes } }
    var droppedFrames: Int64 { statsLock.withLock { $0.dropped } }

    // A copy of the handle readable without touching `queue`. The capture and
    // audio threads consult it on every frame and every buffer, and `queue` is
    // inside NDIlib_send_send_video_v2 for 5-9 ms of every 33 ms frame at
    // 1080p30 — a sync hop onto it stalled them on roughly one frame in four.
    //
    // It does not extend the handle's lifetime: a reader that takes the pointer
    // immediately before stop() can still hand it to libndi afterwards, exactly
    // as the queue hop it replaces could. Closing that window means giving the
    // handle a single owner across start, stop and both send paths, which is a
    // change worth making on its own rather than smuggling in here.
    private let liveInstance = OSAllocatedUnfairLock<NDIlib_send_instance_t?>(initialState: nil)

    var isActive: Bool { liveInstance.withLock { $0 != nil } }

    /// Where audio is de-interleaved before it goes to libndi, grown to the
    /// largest block seen and then reused. A fresh array per block is a malloc
    /// and a zero-fill on the HAL's I/O thread ~94 times a second, and the
    /// allocator lock is the one thing there that can make the thread miss its
    /// deadline.
    ///
    /// The lock is uncontended — one capture path runs at a time — and it is
    /// what keeps a switch between the microphone and the tap from handing the
    /// same buffer to two threads.
    private let scratch = OSAllocatedUnfairLock(initialState: Scratch())

    private struct Scratch {
        private var data: UnsafeMutablePointer<Float>?
        private var capacity = 0

        mutating func storage(for count: Int) -> UnsafeMutablePointer<Float>? {
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

    func start() -> Bool {
        guard NDIRuntime.retain() else { return false }

        let instance: NDIlib_send_instance_t? = Self.sourceName.withCString { namePtr in
            var settings = NDIlib_send_create_t()
            settings.p_ndi_name = namePtr
            settings.p_groups = nil
            settings.clock_video = false  // Camera is our clock; no need for NDI to rate-limit
            settings.clock_audio = false
            return NDIlib_send_create(&settings)
        }

        guard let instance else {
            print("[OpenBeam] NDIlib_send_create failed")
            NDIRuntime.release()
            return false
        }

        queue.sync { ndiInstance = instance }
        liveInstance.withLock { $0 = instance }
        print("[OpenBeam] NDI sender started — source name: \(Self.sourceName)")
        return true
    }

    func send(pixelBuffer: CVPixelBuffer) {
        // Same reason as `isActive`: this runs on the capture thread once per
        // frame, and the async block below revalidates the instance on `queue`
        // anyway, so this only needs to be a cheap early-out.
        guard isActive else { return }

        // Drop frame if previous send is still in progress
        guard semaphore.wait(timeout: .now()) == .success else {
            statsLock.withLock { $0.dropped += 1 }
            return
        }

        let sem = self.semaphore

        queue.async { [weak self] in
            defer { sem.signal() }

            guard let self, let instance = self.ndiInstance else { return }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

            let stride = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

            let fourCC: NDIlib_FourCC_video_type_e
            switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
            case kCVPixelFormatType_32BGRA:        fourCC = NDIlib_FourCC_type_BGRA
            case kCVPixelFormatType_422YpCbCr8:    fourCC = NDIlib_FourCC_type_UYVY
            default:                               return
            }

            var frame = NDIlib_video_frame_v2_t()
            frame.xres = Int32(CVPixelBufferGetWidth(pixelBuffer))
            frame.yres = height
            frame.FourCC = fourCC
            frame.frame_rate_N = 30000
            frame.frame_rate_D = 1001
            frame.picture_aspect_ratio = 0
            frame.frame_format_type = NDIlib_frame_format_type_progressive
            frame.timecode = Int64(NDIlib_send_timecode_synthesize)
            frame.p_data = baseAddress.assumingMemoryBound(to: UInt8.self)
            frame.line_stride_in_bytes = stride
            frame.p_metadata = nil
            frame.timestamp = 0

            NDIlib_send_send_video_v2(instance, &frame)

            self.statsLock.withLock {
                $0.sent += 1
                $0.bytes += Int64(stride) * Int64(height)
            }
        }
    }

    func send(audioBuffer buffer: AVAudioPCMBuffer) {
        send(audio: buffer.audioBufferList, format: buffer.format)
    }

    /// The shape both capture paths have underneath. The microphone's engine
    /// hands out an `AVAudioPCMBuffer`; the tap has a raw buffer list, and
    /// wrapping it in one of those per callback would be an object allocated on
    /// the I/O thread only to be taken apart again here.
    ///
    /// Runs on the audio thread roughly every 10-20 ms; same reason as the
    /// video path for not hopping onto `queue` to read the handle.
    func send(audio bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let instance = liveInstance.withLock({ $0 }),
              format.commonFormat == .pcmFormatFloat32
        else { return }

        let numChannels = Int(format.channelCount)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard numChannels > 0, buffers.count > 0, let firstData = buffers[0].mData else { return }

        // Frames from the bytes the device actually filled, not from what the
        // buffer could hold.
        let bytesPerFrame = (format.isInterleaved ? numChannels : 1) * MemoryLayout<Float>.size
        let numSamples = Int(buffers[0].mDataByteSize) / bytesPerFrame
        guard numSamples > 0 else { return }

        scratch.withLock { scratch in
            guard let base = scratch.storage(for: numSamples * numChannels) else { return }

            // `floatChannelData` is non-nil for an interleaved buffer too, with
            // one pointer instead of one per channel — so the layout has to be
            // asked about rather than inferred from it. Reading interleaved
            // samples as if they were planar puts both channels in both, which
            // is what a stereo tone through the system tap showed.
            if format.isInterleaved {
                let source = firstData.assumingMemoryBound(to: Float.self)
                for channel in 0..<numChannels {
                    // A strided gather, which Accelerate vectorises; the scalar
                    // loop it replaces ran 96,000 times a second at 48 kHz.
                    cblas_scopy(Int32(numSamples),
                                source + channel, Int32(numChannels),
                                base + channel * numSamples, 1)
                }
            } else {
                guard buffers.count >= numChannels else { return }
                for channel in 0..<numChannels {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { return }
                    (base + channel * numSamples).update(from: data, count: numSamples)
                }
            }

            var frame = NDIlib_audio_frame_v2_t()
            frame.sample_rate = Int32(format.sampleRate)
            frame.no_channels = Int32(numChannels)
            frame.no_samples = Int32(numSamples)
            frame.timecode = Int64(NDIlib_send_timecode_synthesize)
            frame.p_data = base
            frame.channel_stride_in_bytes = Int32(numSamples * MemoryLayout<Float>.size)
            frame.p_metadata = nil
            frame.timestamp = 0
            NDIlib_send_send_audio_v2(instance, &frame)
        }
    }

    func restart() -> Bool {
        stop()
        resetStats()
        return start()
    }

    func resetStats() {
        statsLock.withLock { $0 = (0, 0, 0) }
    }

    func stop() {
        // Cleared before the teardown so no further frames are handed in.
        liveInstance.withLock { $0 = nil }
        queue.sync {
            if let instance = ndiInstance {
                NDIlib_send_send_video_v2(instance, nil)
                NDIlib_send_destroy(instance)
                ndiInstance = nil
                NDIRuntime.release()
            }
        }
        print("[OpenBeam] NDI sender stopped")
    }

    deinit {
        if ndiInstance != nil {
            stop()
        }
        scratch.withLock { $0.release() }
    }
}
