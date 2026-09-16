//
//  NDIAudioReceiver.swift
//  OpenBeam
//
//  Reception of a source's audio alone, for playing it on this machine.
//

import Foundation

/// A second receiver beside `NDIReceiver`, and deliberately not a mode of it:
/// the preview's receiver lives and dies with the menu and asks for a proxy
/// video stream, while this one has to keep playing with the menu closed and
/// wants no video at all. `NDIlib_recv_bandwidth_audio_only` means the source
/// never encodes video for us — the cost of the second connection is the audio
/// it carries and nothing else.
final class NDIAudioReceiver {

    /// Called on the receive thread. The block points into libndi's own frame,
    /// which is freed as soon as this returns.
    var onAudio: ((PlanarAudio) -> Void)?

    private let session = NDIReceiveSession(label: "ndi-audio-recv", qos: .userInitiated)

    var sourceName: String? { session.sourceName }
    var isRunning: Bool { session.isRunning }

    func start(source: String) {
        session.start(source: source) { settings in
            settings.bandwidth = NDIlib_recv_bandwidth_audio_only
        } capture: { [weak self] instance in
            var audio = NDIlib_audio_frame_v3_t()

            // 100 ms, as in `NDIReceiver`: it is what bounds how long `stop()`
            // takes to be noticed.
            guard NDIlib_recv_capture_v3(instance, nil, &audio, nil, 100) == NDIlib_frame_type_audio
            else { return }

            if let planar = PlanarAudio(audio) { self?.onAudio?(planar) }
            NDIlib_recv_free_audio_v3(instance, &audio)
        }
    }

    func stop() {
        session.stop()
    }
}
