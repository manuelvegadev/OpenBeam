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
    private var configurationObserver: NSObjectProtocol?
    /// The engine a restart is still being tried for; cleared by stop(), so a
    /// controller the app has stopped or restarted is left alone.
    private var pendingRestart: AVAudioEngine?
    private(set) var currentDeviceID: String?

    /// Called on the I/O thread once per cycle, with the list the device just
    /// filled. It is valid for the duration of the call and no longer.
    var onAudio: ((UnsafePointer<AudioBufferList>, AVAudioFormat) -> Void)?

    /// Where a block that took too long is counted. Set by the one place that
    /// wires the pipeline; nil in any other use of this class.
    var health: AudioHealth?

    // Most recent peak sample magnitude (linear 0…1). Written on the I/O
    // thread, read on main.
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
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("[OpenBeam] Input format reports 0 channels or 0 Hz — engine will not deliver audio")
            return
        }

        // A sink rather than a tap. `installTap` treats its buffer size as a
        // hint and, on macOS, hands out 4096 frames whatever it is asked for —
        // 85 ms at 48 kHz, which the listener waits for before the first sample
        // of each block can leave, and which the far end's cushion then has to
        // be big enough to ride out. The sink is called once per I/O cycle with
        // the device's own buffer: 512 frames, measured, or about 10 ms.
        let sink = AVAudioSinkNode { [weak self] _, frameCount, bufferList in
            guard let self else { return noErr }
            // The whole block is timed, not just our part of it: what matters
            // to the device is when this thread comes back, and everything
            // downstream of here runs on it.
            let start = DispatchTime.now().uptimeNanoseconds
            self.peakLock.withLock { $0 = AudioLevel.peak(bufferList) }
            self.onAudio?(bufferList, format)
            self.health?.captured(frames: Int(frameCount),
                                  sampleRate: format.sampleRate,
                                  work: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)

        do {
            try engine.start()
            self.engine = engine
            self.currentDeviceID = device.uniqueID
            // The engine stops itself when the device changes shape — its rate
            // reset under it, as MicrophoneRate does — and stayed silent after.
            // Built again once the device has settled, if it is still ours.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let self, self.engine === engine, !engine.isRunning else { return }
                    print("[OpenBeam] Audio input changed configuration — restarting")
                    self.restart(engine, deviceID: deviceID, attempt: 1)
                }
            }
            print("[OpenBeam] Audio started: \(device.localizedName) — \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        } catch {
            print("[OpenBeam] AVAudioEngine start failed: \(error)")
        }
    }

    /// Builds the engine again on the same device. Never falls back to the
    /// default input: that can be the call's microphone, and one more reader of
    /// it is what breaks its audio. A device still settling gets a few tries.
    private func restart(_ stopped: AVAudioEngine, deviceID: String?, attempt: Int) {
        if let deviceID, AVCaptureDevice(uniqueID: deviceID) == nil {
            print("[OpenBeam] Audio input went away — not restarting")
            return
        }
        start(deviceID: deviceID)
        guard engine == nil, attempt < 5 else { return }
        // start() failed. Owed a retry unless something stops or restarts
        // this controller first: both go through stop(), which clears this.
        pendingRestart = stopped
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt)) { [weak self] in
            guard let self, self.pendingRestart === stopped else { return }
            self.restart(stopped, deviceID: deviceID, attempt: attempt + 1)
        }
    }

    func stop() {
        pendingRestart = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        engine = nil
        currentDeviceID = nil
        peakLock.withLock { $0 = 0 }
    }
}
