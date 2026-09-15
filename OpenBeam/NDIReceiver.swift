//
//  NDIReceiver.swift
//  Open Beam
//
//  NDI reception for the menu preview and the level meter.
//

import Foundation
import Accelerate
import CoreGraphics
import os

/// Receives the source the virtual camera is pointed at, purely so the menu can
/// show what is going out. The extension does the real reception at full
/// resolution, so this one asks for `bandwidth_lowest` — libndi's proxy stream,
/// a fraction of the data — and runs only while the menu is open.
final class NDIReceiver: @unchecked Sendable {

    /// Called on the receive queue, like `CameraController.onFrame`. The image
    /// is built here rather than handing out a pixel buffer: libndi's frame is
    /// only valid until it is freed at the bottom of the capture loop, and
    /// drawing straight out of it saves copying every frame into a buffer whose
    /// only purpose would be to be copied again by `CGContext.makeImage()`.
    var onFrame: ((CGImage) -> Void)?

    private(set) var sourceName: String?

    private let queue = DispatchQueue(label: "com.openbeam.ndi-recv", qos: .userInitiated)
    /// A generation rather than a plain flag: `start()` can be called while the
    /// previous loop is still inside its 100 ms capture timeout, and a shared
    /// flag would let the old loop see the new `true` and keep the queue —
    /// which is serial — busy forever, so the new session never ran.
    private let state = OSAllocatedUnfairLock(initialState: (generation: 0, running: false))
    private let peakLock = OSAllocatedUnfairLock(initialState: Float(0))
    private let statsLock = OSAllocatedUnfairLock(initialState: (received: Int64(0), bytes: Int64(0)))

    var isRunning: Bool { state.withLock { $0.running } }
    var framesReceived: Int64 { statsLock.withLock { $0.received } }
    var bytesReceived: Int64 { statsLock.withLock { $0.bytes } }

    /// Peak of the last audio frame, in the same 0...1 shape the meter already
    /// reads from `AudioController`.
    var currentPeak: Float { peakLock.withLock { $0 } }

    // MARK: - Lifecycle

    func start(source: String) {
        stop()

        guard NDIRuntime.retain() else { return }

        sourceName = source
        resetStats()
        let generation = state.withLock { current -> Int in
            current.generation += 1
            current.running = true
            return current.generation
        }

        queue.async { [weak self] in
            guard let self else { return }

            let created: NDIlib_recv_instance_t? = source.withCString { namePtr in
                var ndiSource = NDIlib_source_t()
                ndiSource.p_ndi_name = namePtr

                var settings = NDIlib_recv_create_v3_t()
                settings.source_to_connect_to = ndiSource
                // BGRA is what the preview's zero-copy CGContext path wants.
                settings.color_format = NDIlib_recv_color_format_BGRX_BGRA
                settings.bandwidth = NDIlib_recv_bandwidth_lowest
                settings.allow_video_fields = false
                settings.p_ndi_recv_name = nil
                return NDIlib_recv_create_v3(&settings)
            }

            guard let created else {
                print("[Open Beam] NDIlib_recv_create_v3 failed for \(source)")
                self.state.withLock { if $0.generation == generation { $0.running = false } }
                NDIRuntime.release()
                return
            }

            print("[Open Beam] NDI receiver started — source: \(source)")
            self.captureLoop(created, generation: generation)

            NDIlib_recv_destroy(created)
            NDIRuntime.release()
            print("[Open Beam] NDI receiver stopped")
        }
    }

    func stop() {
        let wasRunning = state.withLock { current -> Bool in
            let previous = current.running
            current.running = false
            return previous
        }
        guard wasRunning else { return }

        sourceName = nil
        peakLock.withLock { $0 = 0 }
    }

    func resetStats() {
        statsLock.withLock { $0 = (0, 0) }
    }

    // MARK: - Receive loop

    /// Runs on `queue` for as long as the receiver is live. The 100 ms timeout
    /// is what bounds how long `stop()` takes to be noticed.
    private func captureLoop(_ instance: NDIlib_recv_instance_t, generation: Int) {
        while state.withLock({ $0.running && $0.generation == generation }) {
            var video = NDIlib_video_frame_v2_t()
            var audio = NDIlib_audio_frame_v3_t()

            switch NDIlib_recv_capture_v3(instance, &video, &audio, nil, 100) {
            case NDIlib_frame_type_video:
                handle(video: video)
                NDIlib_recv_free_video_v2(instance, &video)

            case NDIlib_frame_type_audio:
                handle(audio: audio)
                NDIlib_recv_free_audio_v3(instance, &audio)

            default:
                break
            }
        }
    }

    private func handle(video frame: NDIlib_video_frame_v2_t) {
        guard let data = frame.p_data else { return }

        let width = Int(frame.xres)
        let height = Int(frame.yres)
        let stride = Int(frame.line_stride_in_bytes)
        guard width > 0, height > 0, stride > 0 else { return }

        statsLock.withLock {
            $0.received += 1
            $0.bytes += Int64(stride) * Int64(height)
        }

        // Same flags as the preview's BGRA path in AppDelegate: the receiver
        // asks libndi for BGRX_BGRA.
        guard let context = CGContext(data: data,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: stride,
                                      space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                                  CGBitmapInfo.byteOrder32Little.rawValue),
              let image = context.makeImage()
        else { return }

        onFrame?(image)
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private func handle(audio frame: NDIlib_audio_frame_v3_t) {
        guard frame.FourCC == NDIlib_FourCC_audio_type_FLTP,
              let data = frame.p_data,
              frame.no_samples > 0, frame.no_channels > 0
        else { return }

        let samples = Int(frame.no_samples)
        let channels = Int(frame.no_channels)
        let channelStride = Int(frame.channel_stride_in_bytes)

        var peak: Float = 0
        for channel in 0..<channels {
            let base = (data + channel * channelStride).withMemoryRebound(to: Float.self, capacity: samples) { $0 }
            var channelPeak: Float = 0
            vDSP_maxmgv(base, 1, &channelPeak, vDSP_Length(samples))
            peak = max(peak, channelPeak)
        }

        peakLock.withLock { $0 = min(peak, 1) }
    }

    deinit {
        stop()
    }
}
