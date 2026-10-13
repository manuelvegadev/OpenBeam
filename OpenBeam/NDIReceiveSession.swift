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
            let running = { self.state.withLock { $0.running && $0.generation == generation } }
            let make = { (url: String?) in Self.makeReceiver(source: source, url: url, configure: configure) }

            guard var receiver = make(nil) else {
                print("[OpenBeam] NDIlib_recv_create_v3 failed for \(source) (\(self.name))")
                self.state.withLock { if $0.generation == generation { $0.running = false } }
                NDIRuntime.release()
                return
            }
            print("[OpenBeam] \(self.name) started — source: \(source)")

            // By name at once, wherever libndi goes; over the Thunderbolt cable
            // as soon as a route to the source's Mac turns up. The route is
            // looked up elsewhere — it can wait on mDNS and discovery for
            // seconds, and this queue is taking frames off the stream.
            var pinned: String?
            let found = OSAllocatedUnfairLock<String?>(initialState: nil)
            var connectedAt = Date(), checkedAt = Date(), lookedUpAt = Date.distantPast
            while running() {
                capture(receiver)
                guard -checkedAt.timeIntervalSinceNow >= 1 else { continue }
                checkedAt = Date()
                if NDIlib_recv_get_no_connections(receiver) > 0 { connectedAt = checkedAt }

                if pinned != nil {
                    // Pinned to the cable, a receiver does not fall back by itself
                    // when the cable goes or the other Mac's address changes.
                    guard -connectedAt.timeIntervalSinceNow >= 3, let byName = make(nil) else { continue }
                    print("[OpenBeam] \(self.name) lost \(source) over Thunderbolt — back to finding it by name")
                    NDIlib_recv_destroy(receiver)
                    (receiver, pinned, connectedAt) = (byName, nil, Date())
                } else if let url = found.withLock({ url in defer { url = nil }; return url }) {
                    guard let overCable = make(url) else { continue }
                    if Self.connect(overCable, whileCapturing: receiver, capture, until: running) {
                        print("[OpenBeam] \(self.name) on \(source) over Thunderbolt at \(url)")
                        NDIlib_recv_destroy(receiver)
                        (receiver, pinned, connectedAt) = (overCable, url, Date())
                    } else {
                        NDIlib_recv_destroy(overCable)
                    }
                } else if -lookedUpAt.timeIntervalSinceNow >= 10 {
                    lookedUpAt = checkedAt
                    DispatchQueue.global(qos: .utility).async {
                        guard running(), let url = NDIRoute.thunderboltURL(for: source) else { return }
                        found.withLock { $0 = url }
                    }
                }
            }

            NDIlib_recv_destroy(receiver)
            NDIRuntime.release()
            print("[OpenBeam] \(self.name) stopped")
        }
    }

    private static func makeReceiver(source: String, url: String?,
                                     configure: (inout NDIlib_recv_create_v3_t) -> Void) -> NDIlib_recv_instance_t? {
        source.withCString { namePtr in
            (url ?? "").withCString { urlPtr in
                var ndiSource = NDIlib_source_t()
                ndiSource.p_ndi_name = namePtr
                if url != nil { ndiSource.p_url_address = urlPtr }

                var settings = NDIlib_recv_create_v3_t()
                settings.source_to_connect_to = ndiSource
                settings.allow_video_fields = false
                settings.p_ndi_recv_name = nil
                configure(&settings)
                return NDIlib_recv_create_v3(&settings)
            }
        }
    }

    /// Make before break: `old` keeps playing until `new` is connected, for up
    /// to three seconds. What `new` queued meanwhile is dropped, so the switch
    /// adds no delay. False if it never connected.
    private static func connect(_ new: NDIlib_recv_instance_t, whileCapturing old: NDIlib_recv_instance_t,
                                _ capture: (NDIlib_recv_instance_t) -> Void, until running: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while running(), Date() < deadline {
            capture(old)
            guard NDIlib_recv_get_no_connections(new) > 0 else { continue }
            var video = NDIlib_video_frame_v2_t(), audio = NDIlib_audio_frame_v3_t(), metadata = NDIlib_metadata_frame_t()
            while true {
                switch NDIlib_recv_capture_v3(new, &video, &audio, &metadata, 0) {
                case NDIlib_frame_type_video: NDIlib_recv_free_video_v2(new, &video)
                case NDIlib_frame_type_audio: NDIlib_recv_free_audio_v3(new, &audio)
                case NDIlib_frame_type_metadata: NDIlib_recv_free_metadata(new, &metadata)
                default: return true
                }
            }
        }
        return false
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
              frame.no_samples > 0, (1...64).contains(frame.no_channels),
              // A second of storage is allocated per rate further down, so a
              // sender claiming billions of Hz would ask for gigabytes.
              (8_000...384_000).contains(frame.sample_rate)
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
