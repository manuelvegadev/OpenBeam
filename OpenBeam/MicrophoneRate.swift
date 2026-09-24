//
//  MicrophoneRate.swift
//  OpenBeam
//
//  Keeping the virtual microphone at the rate of the stream it carries.
//
//  Found on `NDI Audio`, NDI Tools' driver: it receives the stream by itself,
//  offers 44.1 and 48 kHz, and at 44.1 it does not resample a 48 kHz stream —
//  it plays each block short and fills the rest with silence, which a call
//  hears as a robotic voice cut ~10 times a second. Measured on a recording
//  from the machine in the call: ~60 ms of voice, then 20–50 ms of digital
//  silence, every ~97 ms. Setting the device to 48 kHz made it clean.
//
//  Nothing here is about that driver, though. Whichever microphone the
//  received audio goes into — `AppDelegate.receiveMicrophone` says which — is
//  one no user looks at the rate of, and macOS keeps whatever rate a device
//  was last given by any app. Running it at the stream's own rate is the one
//  setting that asks nothing of the driver, so that is the one kept.
//

import CoreAudio
import Foundation

/// Watches one input device and puts it back at the stream's rate whenever it
/// is found anywhere else. Only touched from the main thread: its listener is
/// registered on the main queue, and what it has to say goes into the menu.
final class MicrophoneRate {

    /// NDI's own rate, and the one every sender we know of uses. What the
    /// device is held at until a stream has said otherwise.
    static let defaultRate: Float64 = 48_000

    /// Past this many corrections in `fightWindow`, something is putting it
    /// back on purpose, and each correction is itself a glitch in the call.
    /// Better to stop and say so than to fight it for the whole meeting.
    private static let maxCorrections = 3
    private static let fightWindow: TimeInterval = 60

    struct Target: Equatable {
        let device: AudioDevices.Device
        let rate: Float64
    }

    enum Notice: Equatable {
        /// It was found at `from` and has been put at `to`.
        case corrected(device: String, from: Float64, to: Float64)
        /// Something keeps setting `by`, and correcting has stopped.
        case overridden(device: String, by: Float64, wants: Float64)
    }

    /// What the menu should say, or nil when there is nothing to say.
    private(set) var notice: Notice? {
        didSet { if notice != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private var target: Target?
    private var rateObserver: AudioDevices.Observer?
    private var corrections: [Date] = []
    private var gaveUp = false

    /// Points it at a microphone, or at none. Called whenever the answer might
    /// have changed, and costs a comparison when it has not.
    ///
    /// Letting go leaves the device at whatever rate it is: this machine no
    /// longer feeding it does not make the rate it was given wrong.
    func watch(_ newTarget: Target?) {
        guard newTarget != target else { return }

        if newTarget?.device != target?.device {
            // A different microphone is a different history.
            reset()
            rateObserver = newTarget.map { target in
                AudioDevices.Observer(kAudioDevicePropertyNominalSampleRate, on: target.device.id,
                                      queue: .main) { [weak self] in
                    self?.enforce()
                }
            }
        }
        target = newTarget
        enforce()
    }

    /// Clears the notice and nothing else. A correction has already been made
    /// by the time there is one to read, so reading it is the end of it.
    func dismiss() {
        notice = nil
    }

    /// Starts correcting again after giving up — once the app that kept
    /// changing it has been quit.
    func retry() {
        reset()
        enforce()
    }

    private func reset() {
        corrections = []
        gaveUp = false
        notice = nil
    }

    // MARK: -

    /// Called on every change of target and every change of rate, our own
    /// included: the one we cause finds the device already right and ends
    /// there.
    private func enforce() {
        guard !gaveUp, let target else { return }
        let device = target.device
        guard let current = AudioDevices.nominalRate(of: device.id), current != target.rate else { return }

        // A device that cannot run at the stream's rate is left alone: there
        // is nothing better to put it at.
        guard AudioDevices.supports(rate: target.rate, device: device.id) else { return }

        let now = Date()
        corrections = corrections.filter { now.timeIntervalSince($0) < Self.fightWindow }
        guard corrections.count < Self.maxCorrections else {
            gaveUp = true
            notice = .overridden(device: device.name, by: current, wants: target.rate)
            print("[OpenBeam] \(device.name) keeps returning to \(Int(current)) Hz — no longer correcting it")
            return
        }

        guard AudioDevices.setNominalRate(target.rate, of: device.id) else {
            print("[OpenBeam] \(device.name) is at \(Int(current)) Hz and could not be set to \(Int(target.rate))")
            return
        }
        corrections.append(now)
        notice = .corrected(device: device.name, from: current, to: target.rate)
        print("[OpenBeam] \(device.name) was at \(Int(current)) Hz — set to \(Int(target.rate))")
    }
}
