//
//  AudioDevices.swift
//  OpenBeam
//
//  The CoreAudio queries the audio routing paths share.
//
//  `AudioController` looks devices up through AVFoundation because a
//  microphone is an `AVCaptureDevice`; outputs are not modelled there at all,
//  so everything about them goes through the HAL directly.
//

import AudioToolbox
import CoreAudio
import Foundation

/// One output device, or whatever the Mac is playing through at the time.
/// Both halves of audio routing are aimed with this: the tap that captures an
/// output on the sending machine, and the player that feeds one on the
/// receiving machine.
enum AudioOutputTarget: Equatable, Sendable {
    case systemDefault
    case device(uid: String)

    /// The device this names right now. `.systemDefault` is a question with a
    /// different answer every time the user changes their output, which is the
    /// whole reason it is a case rather than a resolved device.
    var resolvedDevice: AudioDevices.Device? {
        switch self {
        case .systemDefault:    return AudioDevices.defaultOutput()
        case .device(let uid):  return AudioDevices.device(uid: uid)
        }
    }
}

enum AudioDevices {

    struct Device: Equatable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    // MARK: - Devices

    /// Every device that can play audio, in the order CoreAudio reports them —
    /// which is the order the Sound pane uses, so the menu matches it.
    static func outputs() -> [Device] {
        allDevices().compactMap { id in
            guard channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                  !isPrivateAggregate(id)
            else { return nil }
            return device(id)
        }
    }

    /// Whether this device is an aggregate somebody built to make something
    /// work, rather than one a user assembled in Audio MIDI Setup.
    ///
    /// A private aggregate is hidden from the Sound pane and from every other
    /// process — but not from the one that created it, and that one is us.
    /// `SystemAudioTap` builds one around every tap, so choosing to send the
    /// system audio put "OpenBeam System Audio" in our own list of speakers;
    /// CoreAudio builds its own, `CADefaultDeviceAggregate-<pid>`, for a
    /// client that follows the default device, and that turned up beside it.
    /// Neither is a place anyone means when they name a speaker.
    ///
    /// Being private is the property that makes them ours to hide rather than
    /// the name either happens to carry: a device only this process can see is
    /// by definition not one the user chose. Confirmed by running the same
    /// enumeration from a separate process, which sees neither.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioAggregateDevicePropertyComposition)
        // Absent on anything that is not an aggregate, which is most devices.
        guard AudioObjectHasProperty(id, &address) else { return false }

        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var composition: Unmanaged<CFDictionary>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any]
        else { return false }

        // CFBoolean comes back as a bridged Bool; a plain aggregate has no
        // such key at all.
        return dictionary[kAudioAggregateDeviceIsPrivateKey] as? Bool == true
    }

    static func defaultOutput() -> Device? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr else { return nil }
        return device(id)
    }

    static func device(uid: String) -> Device? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID: CFString = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(systemObject, &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer,
                                       &size, &id)
        }
        guard status == noErr else { return nil }
        return device(id)
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        guard id != kAudioObjectUnknown,
              let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName)
        else { return nil }
        return Device(id: id, uid: uid, name: name)
    }

    /// This process's audio object. A tap that excludes it cannot pick up
    /// audio OpenBeam itself is playing, which is what stops a machine that is
    /// both playing a received stream and tapping that same output from
    /// feeding itself.
    static func currentProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = withUnsafeMutablePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(systemObject, &address,
                                       UInt32(MemoryLayout<pid_t>.size), pidPointer,
                                       &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    // MARK: - Watching the hardware

    /// A property listener that unregisters itself when it is released. Both
    /// audio paths can be pointed at "whatever the Mac is playing through",
    /// which has to go on meaning the same thing after the user plugs in
    /// headphones, and either can have its device unplugged mid-stream.
    final class Observer {

        private var address: AudioObjectPropertyAddress
        private let object: AudioObjectID
        private let queue: DispatchQueue
        private var listener: AudioObjectPropertyListenerBlock?

        init(_ selector: AudioObjectPropertySelector,
             on object: AudioObjectID = AudioDevices.systemObject,
             queue: DispatchQueue,
             handler: @escaping () -> Void) {
            self.object = object
            self.queue = queue
            self.address = AudioDevices.address(selector)

            let listener: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            guard AudioObjectAddPropertyListenerBlock(object, &address, queue, listener) == noErr
            else { return }
            self.listener = listener
        }

        deinit {
            guard let listener else { return }
            // The same queue it was registered with: CoreAudio matches the
            // three together, and a removal that does not match leaves the
            // listener installed on an object we are done with.
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
    }

    // MARK: - CoreAudio plumbing

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Channels per buffer, in the order the I/O proc delivers them — one
    /// buffer per stream. Callers that only want the total sum it.
    static func channelCounts(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }

        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .map { Int($0.mNumberChannels) }
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        channelCounts(device, scope: scope).reduce(0, +)
    }

    // MARK: - Pointing an audio unit at a device

    /// Both engines in the app — the microphone's and the player's — choose
    /// their device this way, and getting the scope or the size wrong fails
    /// silently, so it is written once.
    static func setDevice(_ device: AudioDeviceID, on unit: AudioUnit) {
        var id = device
        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0,
                             &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Which device a unit ended up on, which is not always the one it was
    /// asked for: a unit left on the system default moves under itself.
    static func device(of unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit,
                                   kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global,
                                   0,
                                   &id,
                                   &size) == noErr
        else { return nil }
        return id
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }
}
