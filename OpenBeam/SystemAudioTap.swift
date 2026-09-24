//
//  SystemAudioTap.swift
//  OpenBeam
//
//  Capture of what a Mac is *playing*, so Send can put it on the network the
//  same way it puts a microphone there.
//
//  macOS has no input device for this: an output device's audio is reached
//  with a CoreAudio process tap (macOS 14.2+), which is then read through a
//  private aggregate device that holds nothing but the tap. Tapping a device
//  by UID is what lets the menu offer one output rather than "the system mix".
//

import AVFoundation
import Accelerate
import CoreAudio
import os

final class SystemAudioTap: @unchecked Sendable {

    /// Called on the HAL's I/O thread, like `AudioController.onAudio`. The
    /// list points at the HAL's own memory and is only valid for the call —
    /// `NDISender` copies out of it synchronously.
    var onAudio: ((UnsafePointer<AudioBufferList>, AVAudioFormat) -> Void)?

    /// Where a block that took too long is counted, as in `AudioController`.
    var health: AudioHealth?

    private let peakLock = OSAllocatedUnfairLock(initialState: Float(0))
    var currentPeak: Float { peakLock.withLock { $0 } }

    /// The device being tapped, which for `.defaultOutput` is whichever one
    /// that resolves to right now.
    private let deviceLock = OSAllocatedUnfairLock<AudioDevices.Device?>(initialState: nil)
    var currentDevice: AudioDevices.Device? { deviceLock.withLock { $0 } }
    var isRunning: Bool { currentDevice != nil }

    /// Every mutation of the tap runs here, so a device change arriving while
    /// the menu is starting one cannot interleave with it.
    private let queue = DispatchQueue(label: "com.openbeam.system-audio-tap")
    /// CoreAudio's notices arrive here rather than on `queue`, which is the
    /// queue that also tears listeners down: removing a listener from the
    /// queue it is delivered on is the one way these two can wait on each
    /// other.
    private let listenerQueue = DispatchQueue(label: "com.openbeam.system-audio-tap.listener")

    private var target: AudioOutputTarget?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var observers: [AudioDevices.Observer] = []

    // MARK: - Lifecycle

    func start(target: AudioOutputTarget) {
        queue.async {
            self.target = target
            self.teardown()
            self.setUp()
            self.observeHardware()
        }
    }

    func stop() {
        queue.async {
            self.target = nil
            self.observers = []
            self.teardown()
        }
    }

    // MARK: - Setup

    /// Builds tap → aggregate → I/O proc, or leaves everything torn down and
    /// says why. A missing device is not an error worth shouting about: it is
    /// what the user sees when they unplug the interface they picked.
    private func setUp() {
        guard let target else { return }

        guard let device = target.resolvedDevice else {
            print("[OpenBeam] system audio: no device for \(target)")
            return
        }

        let description = CATapDescription(excludingProcesses: Self.ownProcess,
                                           deviceUID: device.uid,
                                           stream: 0)
        description.name = "OpenBeam"
        description.isPrivate = true
        // The point is to send what the user is listening to, not to take it
        // away from them.
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            print("[OpenBeam] AudioHardwareCreateProcessTap failed for \(device.name)")
            return
        }
        tapID = tap

        guard let format = tapFormat(tap), let tapUID = AudioDevices.string(tap, kAudioTapPropertyUID) else {
            print("[OpenBeam] system audio: the tap has no readable format")
            teardown()
            return
        }
        self.format = format

        // The tapped device is a member of the aggregate, not only its clock.
        //
        // An aggregate holding nothing but the tap is tempting — it delivers
        // exactly one buffer, the tap's — and it works on macOS 15. On macOS 26
        // it runs and delivers silence: measured on a MacBook Pro's speakers,
        // peak 0.0004 against 0.108 for the same tap with the device in the
        // list. Whatever changed, the construction that captures on both is the
        // one that puts the device in, so that is the one used everywhere.
        //
        // The cost is the buffer list: a device with inputs of its own — a USB
        // interface's microphone — puts those ahead of the tap's channels, and
        // `tapBufferIndex` is what skips them.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenBeam System Audio",
            kAudioAggregateDeviceUIDKey: "dev.manuelvega.openbeam.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            // Invisible in the Sound pane and in every other app.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]

        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice) == noErr else {
            print("[OpenBeam] AudioHardwareCreateAggregateDevice failed for \(device.name)")
            teardown()
            return
        }
        aggregateID = aggregateDevice

        // Which buffer the tap's channels arrive in: the sub-device's own
        // inputs come first, one buffer per stream.
        let tapBuffer = Self.bufferIndex(skipping: AudioDevices.channelCount(device.id, scope: kAudioObjectPropertyScopeInput),
                                         in: aggregateDevice)
        // Captured by value: the I/O block must read nothing it has to lock for.
        let tapChannels = format.channelCount

        // nil for the queue means the block runs on the HAL's I/O thread, the
        // same shape as the microphone path: peak, one de-interleaving copy and
        // a non-blocking libndi send.
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDevice, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.format else { return }

            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard tapBuffer < buffers.count, buffers[tapBuffer].mNumberChannels == tapChannels else { return }

            // A one-buffer list over the tap's own slice, so the format and the
            // samples describe the same thing. The tap is interleaved, which is
            // one buffer however many channels it carries.

            var tapList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffers[tapBuffer])
            let start = DispatchTime.now().uptimeNanoseconds
            withUnsafePointer(to: &tapList) { list in
                self.peakLock.withLock { $0 = AudioLevel.peak(list) }
                self.onAudio?(list, format)
            }
            // The tap is interleaved, so its frames are the buffer's bytes
            // divided by one frame across every channel.
            let frames = Int(tapList.mBuffers.mDataByteSize)
                / (Int(tapChannels) * MemoryLayout<Float>.size)
            self.health?.captured(frames: frames,
                                  sampleRate: format.sampleRate,
                                  work: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        guard status == noErr, let procID else {
            print("[OpenBeam] AudioDeviceCreateIOProcIDWithBlock failed for \(device.name)")
            teardown()
            return
        }
        ioProcID = procID

        guard AudioDeviceStart(aggregateDevice, procID) == noErr else {
            print("[OpenBeam] AudioDeviceStart failed for \(device.name)")
            teardown()
            return
        }

        deviceLock.withLock { $0 = device }
        // The buffer index is logged because it is the one thing here that
        // depends on the device rather than on us: it is 0 for a device with no
        // inputs of its own, which is most of them.
        print("[OpenBeam] System audio started: \(device.name) — \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, tap buffer \(tapBuffer)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        format = nil
        peakLock.withLock { $0 = 0 }
        deviceLock.withLock { $0 = nil }
    }

    /// Re-taps when the hardware moves under us: a new default output while
    /// following it, or the chosen device coming back after being unplugged.
    ///
    /// A change is followed after a pause rather than at once. One physical
    /// event is several property changes — a Bluetooth headset switching
    /// profile changes its rate and then the default device — and re-tapping on
    /// the first of them tears the tap down in the middle of the rest.
    private static let settleDelay = 0.3

    private func observeHardware() {
        let rebuild: () -> Void = { [weak self] in
            guard let self else { return }
            guard let target = self.target else { return }
            let wanted = target.resolvedDevice
            // The device list changes for reasons that have nothing to do with
            // us; only a different device is worth interrupting audio for.
            guard wanted != self.deviceLock.withLock({ $0 }) else { return }
            self.teardown()
            self.setUp()
        }

        let onChange: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + Self.settleDelay) { rebuild() }
        }

        observers = [
            AudioDevices.Observer(kAudioHardwarePropertyDevices, queue: listenerQueue, handler: onChange),
            AudioDevices.Observer(kAudioHardwarePropertyDefaultOutputDevice, queue: listenerQueue, handler: onChange),
        ]
    }

    // MARK: - Helpers

    /// Our own audio object, excluded from the tap so that a machine playing a
    /// received stream out of the very device it is tapping cannot feed itself.
    private static let ownProcess: [AudioObjectID] = {
        guard let object = AudioDevices.currentProcessObject() else { return [] }
        return [object]
    }()

    /// The buffer the tap's channels start in, given how many channels the
    /// aggregate carries ahead of them. Stream boundaries are where buffers
    /// break, so the count is walked rather than divided.
    private static func bufferIndex(skipping channels: Int, in aggregate: AudioObjectID) -> Int {
        guard channels > 0 else { return 0 }

        var skipped = 0
        for (index, count) in AudioDevices.channelCounts(aggregate, scope: kAudioObjectPropertyScopeInput).enumerated() {
            guard skipped < channels else { return index }
            skipped += count
        }
        return 0
    }

    private func tapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var address = AudioDevices.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    deinit {
        queue.sync { teardown() }
    }
}
