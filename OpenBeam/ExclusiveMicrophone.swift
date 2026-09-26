//
//  ExclusiveMicrophone.swift
//  OpenBeam
//
//  Taking a microphone for OpenBeam alone, so that monitoring it cannot
//  disturb what it hands the call.
//
//  Found on `NDI Audio`, NDI Tools' driver: it splits its audio between the
//  apps reading it instead of giving each a copy, so a monitor reading beside
//  the call left the call ~60 ms of voice then ~30 ms of silence, over and
//  over. Hog mode makes OpenBeam the only reader, which is the one way to hear
//  exactly what that driver produces.
//
//  What hog mode costs is more than the call's audio. macOS will not keep a
//  hogged device as the default input: it moves the default to another
//  microphone — on a MacBook, its own — and ignores being told to move it
//  back, so every app following the default would go from the virtual
//  microphone to a live one in the room. Silence is what taking the
//  microphone was supposed to mean, so whatever becomes the default while it
//  is held is muted. macOS restores the default by itself once the device is
//  given back, crash included; the mute is the one thing left to undo.
//

import CoreAudio
import Foundation

/// Only touched from the main thread: its listener is registered on the main
/// queue, like `MicrophoneRate`'s.
final class ExclusiveMicrophone {

    /// The microphone held, while it is.
    private(set) var device: AudioDevices.Device?

    /// Inputs muted here, which were unmuted before. Only those are unmuted
    /// again: one the user had muted stays the way they left it.
    private var muted: [AudioDevices.Device] = []
    private var defaultObserver: AudioDevices.Observer?

    /// The mutes, written down as they are made. The HAL gives the microphone
    /// back by itself when the process dies; nothing gives back a mute, so a
    /// crash mid-monitor would leave the MacBook's microphone muted for every
    /// app until someone found out why.
    private static let mutedKey = "exclusiveMicrophone.muted"

    init() {
        // What a previous run muted and never got to unmute.
        for uid in UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [] {
            if let device = AudioDevices.device(uid: uid) { AudioDevices.setInputMuted(false, device: device.id) }
        }
        UserDefaults.standard.removeObject(forKey: Self.mutedKey)
    }

    /// False when another process already holds it, and then nothing changes.
    func take(_ microphone: AudioDevices.Device) -> Bool {
        if let device { return device == microphone }
        guard AudioDevices.setHogged(true, device: microphone.id) else { return false }
        device = microphone

        // The move happens after the hog is granted, and not always at once,
        // so it is followed rather than looked for once.
        defaultObserver = AudioDevices.Observer(kAudioHardwarePropertyDefaultInputDevice, queue: .main) { [weak self] in
            self?.silenceDefault()
        }
        silenceDefault()
        return true
    }

    /// Gives the microphone back before unmuting the inputs muted in its
    /// place: macOS moves the default back to it first, so no app following
    /// the default is handed a live microphone on the way out.
    func release() {
        guard let device else { return }
        defaultObserver = nil

        AudioDevices.setHogged(false, device: device.id)
        for input in muted { AudioDevices.setInputMuted(false, device: input.id) }

        muted = []
        self.device = nil
        record()
    }

    private func silenceDefault() {
        guard let device,
              let current = AudioDevices.defaultInput(),
              current != device,
              !muted.contains(current),
              AudioDevices.isInputMuted(current.id) == false,
              AudioDevices.setInputMuted(true, device: current.id)
        else { return }
        muted.append(current)
        record()
    }

    private func record() {
        UserDefaults.standard.set(muted.map(\.uid), forKey: Self.mutedKey)
    }
}
