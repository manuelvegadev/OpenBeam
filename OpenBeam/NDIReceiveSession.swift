//
//  NDIReceiveSession.swift
//  OpenBeam
//
//  The half of a receiver that is the same whichever frames it wants.
//
//  Two receivers run in this app — the preview's, which lives with the menu and
//  asks for a proxy video stream, and the audio one, which plays on regardless
//  and asks for no video at all. What differs between them is a line of
//  settings and what they do with a frame; everything else — the serial queue,
//  the libndi lifecycle, the refcount pairing and the generation guard — was
//  the same code twice, including the invariant that is easy to get wrong.
//

import Foundation
import os

final class NDIReceiveSession: @unchecked Sendable {

    /// The source this session is on, or nil when it is stopped.
    private(set) var sourceName: String?

    /// A generation rather than a plain flag: `start()` can be called while the
    /// previous loop is still inside its capture timeout, and a shared flag
    /// would let the old loop see the new `true` and keep the queue — which is
    /// serial — busy for ever, so the new session never ran.
    private let state = OSAllocatedUnfairLock(initialState: (generation: 0, running: false))
    private let queue: DispatchQueue
    private let name: String

    var isRunning: Bool { state.withLock { $0.running } }

    init(label: String, qos: DispatchQoS) {
        name = label
        queue = DispatchQueue(label: "com.openbeam.\(label)", qos: qos)
    }

    /// `settings` fills in the bandwidth and colour format; `capture` is one
    /// turn of the loop — it takes a frame, does something with it and frees
    /// it — and is called until the session is stopped.
    func start(source: String,
               settings configure: @escaping (inout NDIlib_recv_create_v3_t) -> Void,
               capture: @escaping (NDIlib_recv_instance_t) -> Void) {
        stop()

        guard NDIRuntime.retain() else { return }

        sourceName = source
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
                settings.allow_video_fields = false
                settings.p_ndi_recv_name = nil
                configure(&settings)
                return NDIlib_recv_create_v3(&settings)
            }

            guard let created else {
                print("[OpenBeam] NDIlib_recv_create_v3 failed for \(source) (\(self.name))")
                self.state.withLock { if $0.generation == generation { $0.running = false } }
                NDIRuntime.release()
                return
            }

            print("[OpenBeam] \(self.name) started — source: \(source)")
            while self.state.withLock({ $0.running && $0.generation == generation }) {
                capture(created)
            }

            NDIlib_recv_destroy(created)
            NDIRuntime.release()
            print("[OpenBeam] \(self.name) stopped")
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
    }

    deinit {
        stop()
    }
}

// MARK: - Decoding a libndi audio frame

extension PlanarAudio {

    /// The one place that reads libndi's audio frame layout. Both receivers
    /// want the same five values out of it, and the FourCC check and the
    /// byte-stride conversion are exactly where a wrong assumption about that
    /// layout would hide.
    ///
    /// Valid only until the frame is freed, which is the contract `PlanarAudio`
    /// already carries.
    init?(_ frame: NDIlib_audio_frame_v3_t) {
        guard frame.FourCC == NDIlib_FourCC_audio_type_FLTP,
              let data = frame.p_data,
              frame.no_samples > 0, frame.no_channels > 0, frame.sample_rate > 0
        else { return nil }

        let stride = Int(frame.channel_stride_in_bytes) / MemoryLayout<Float>.size
        let samples = Int(frame.no_samples)
        guard stride >= samples else { return nil }

        self.init(data: data.withMemoryRebound(to: Float.self,
                                               capacity: stride * Int(frame.no_channels)) { $0 },
                  frameCount: samples,
                  channelCount: Int(frame.no_channels),
                  channelStride: stride,
                  sampleRate: Double(frame.sample_rate))
    }
}
