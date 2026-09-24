//
//  AudioController.swift
//  OpenBeam
//
//  AVAudioEngine-based audio capture. We use AVAudioEngine instead of
//  AVCaptureAudioDataOutput because the latter's audioSettings path on macOS
//  produces malformed target ASBDs ("5 bytes high-aligned") that crash the
//  internal AudioConverter for many devices, including CMIO-extension audio
//  inputs. AVAudioEngine talks straight to the HAL and delivers Float32 in
//  the device's native channel layout — no in-process conversion required.
//

import AVFoundation
import os

final class AudioController: NSObject, @unchecked Sendable {

    private var engine: AVAudioEngine?
    private(set) var currentDeviceID: String?

    var onAudio: ((AVAudioPCMBuffer) -> Void)?

    /// Where a block that took too long is counted. Set by the one place that
    /// wires the pipeline; nil in any other use of this class.
    var health: AudioHealth?

    // Most recent peak sample magnitude (linear 0…1). Written on the audio
    // tap thread, read on main.
    private let peakLock = OSAllocatedUnfairLock(initialState: Float(0))
    var currentPeak: Float { peakLock.withLock { $0 } }

    static var availableInputs: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func start(deviceID: String? = nil) {
        stop()

        // AVAudioEngine — unlike AVCaptureSession — does not trigger the system
        // microphone permission prompt. Ask explicitly the first time.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.start(deviceID: deviceID) }
            }
            return
        case .denied, .restricted:
            print("[OpenBeam] Microphone access not authorized")
            return
        default:
            break
        }

        let device: AVCaptureDevice?
        if let deviceID, let specific = AVCaptureDevice(uniqueID: deviceID) {
            device = specific
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let device else {
            print("[OpenBeam] No audio device found")
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let unit = input.audioUnit, let halDevice = AudioDevices.device(uid: device.uniqueID) {
            AudioDevices.setDevice(halDevice.id, on: unit)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            print("[OpenBeam] Input format reports 0 channels — engine will not deliver audio")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // The whole block is timed, not just our part of it: what matters
            // to the device is when this thread comes back, and everything
            // downstream of here runs on it.
            let start = DispatchTime.now().uptimeNanoseconds
            let peak = AudioLevel.peak(buffer)
            self.peakLock.withLock { $0 = peak }
            self.onAudio?(buffer)
            self.health?.captured(frames: Int(buffer.frameLength),
                                  sampleRate: format.sampleRate,
                                  work: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }

        do {
            try engine.start()
            self.engine = engine
            self.currentDeviceID = device.uniqueID
            print("[OpenBeam] Audio started: \(device.localizedName) — \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        } catch {
            print("[OpenBeam] AVAudioEngine start failed: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        currentDeviceID = nil
        peakLock.withLock { $0 = 0 }
    }
}
