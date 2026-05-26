//
//  NDISender.swift
//  Open Beam
//
//  NDI SDK C API bridge and frame sending.
//

import Foundation
import CoreVideo
import AVFoundation
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
        return "Open Beam"
    }()

    private var ndiInstance: NDIlib_send_instance_t?
    private let queue = DispatchQueue(label: "com.openbeam.ndi-send", qos: .userInteractive)
    private let semaphore = DispatchSemaphore(value: 1)

    // Stats — protected by statsLock (written on NDI/capture queues, read on main)
    private let statsLock = OSAllocatedUnfairLock(initialState: (sent: Int64(0), bytes: Int64(0), dropped: Int64(0)))

    var framesSent: Int64 { statsLock.withLock { $0.sent } }
    var bytesSent: Int64 { statsLock.withLock { $0.bytes } }
    var droppedFrames: Int64 { statsLock.withLock { $0.dropped } }

    var isActive: Bool { queue.sync { ndiInstance != nil } }

    func start() -> Bool {
        guard NDIlib_initialize() else {
            print("[Open Beam] NDIlib_initialize failed")
            return false
        }

        let instance: NDIlib_send_instance_t? = Self.sourceName.withCString { namePtr in
            var settings = NDIlib_send_create_t()
            settings.p_ndi_name = namePtr
            settings.p_groups = nil
            settings.clock_video = false  // Camera is our clock; no need for NDI to rate-limit
            settings.clock_audio = false
            return NDIlib_send_create(&settings)
        }

        guard let instance else {
            print("[Open Beam] NDIlib_send_create failed")
            NDIlib_destroy()
            return false
        }

        queue.sync { ndiInstance = instance }
        print("[Open Beam] NDI sender started — source name: \(Self.sourceName)")
        return true
    }

    func send(pixelBuffer: CVPixelBuffer) {
        guard queue.sync(execute: { ndiInstance != nil }) else { return }

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
        let instance: NDIlib_send_instance_t? = queue.sync { ndiInstance }
        guard let instance else { return }

        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32 else { return }

        let numChannels = Int(format.channelCount)
        let numSamples = Int(buffer.frameLength)
        guard numChannels > 0, numSamples > 0 else { return }

        var planar = [Float](repeating: 0, count: numSamples * numChannels)

        planar.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }

            if let channelData = buffer.floatChannelData {
                for ch in 0..<numChannels {
                    (base + ch * numSamples).update(from: channelData[ch], count: numSamples)
                }
            } else if let src = buffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) {
                for ch in 0..<numChannels {
                    let dst = base + ch * numSamples
                    for i in 0..<numSamples {
                        dst[i] = src[i * numChannels + ch]
                    }
                }
            } else {
                return
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
        queue.sync {
            if let instance = ndiInstance {
                NDIlib_send_send_video_v2(instance, nil)
                NDIlib_send_destroy(instance)
                ndiInstance = nil
            }
            NDIlib_destroy()
        }
        print("[Open Beam] NDI sender stopped")
    }

    deinit {
        if ndiInstance != nil {
            stop()
        }
    }
}
