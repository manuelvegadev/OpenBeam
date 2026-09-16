//
//  NDIReceiver.swift
//  OpenBeam
//
//  NDI reception for the menu preview and the level meter.
//

import Foundation
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

    private let session = NDIReceiveSession(label: "ndi-recv", qos: .userInitiated)
    private let peakLock = OSAllocatedUnfairLock(initialState: Float(0))
    private let statsLock = OSAllocatedUnfairLock(initialState: (received: Int64(0), bytes: Int64(0)))

    var sourceName: String? { session.sourceName }
    var isRunning: Bool { session.isRunning }
    var framesReceived: Int64 { statsLock.withLock { $0.received } }
    var bytesReceived: Int64 { statsLock.withLock { $0.bytes } }

    /// Peak of the last audio frame, in the same 0...1 shape the meter already
    /// reads from `AudioController`.
    var currentPeak: Float { peakLock.withLock { $0 } }

    // MARK: - Lifecycle

    func start(source: String) {
        resetStats()

        session.start(source: source) { settings in
            // BGRA is what the preview's zero-copy CGContext path wants.
            settings.color_format = NDIlib_recv_color_format_BGRX_BGRA
            settings.bandwidth = NDIlib_recv_bandwidth_lowest
        } capture: { [weak self] instance in
            var video = NDIlib_video_frame_v2_t()
            var audio = NDIlib_audio_frame_v3_t()

            // The 100 ms timeout is what bounds how long `stop()` takes to be
            // noticed.
            switch NDIlib_recv_capture_v3(instance, &video, &audio, nil, 100) {
            case NDIlib_frame_type_video:
                self?.handle(video: video)
                NDIlib_recv_free_video_v2(instance, &video)

            case NDIlib_frame_type_audio:
                if let planar = PlanarAudio(audio) {
                    self?.peakLock.withLock {
                        $0 = AudioLevel.peak(planar: planar.data,
                                             frames: planar.frameCount,
                                             channels: planar.channelCount,
                                             channelStride: planar.channelStride)
                    }
                }
                NDIlib_recv_free_audio_v3(instance, &audio)

            default:
                break
            }
        }
    }

    func stop() {
        session.stop()
        peakLock.withLock { $0 = 0 }
    }

    func resetStats() {
        statsLock.withLock { $0 = (0, 0) }
    }

    // MARK: - Frames

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

    deinit {
        stop()
    }
}
