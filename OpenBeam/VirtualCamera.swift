//
//  VirtualCamera.swift
//  Open Beam
//
//  Control of the NDI Virtual Camera device through CoreMediaIO.
//

import Foundation
import CoreMediaIO

/// The camera extension NDI Tools installs links libndi and receives NDI by
/// itself, so it takes a *source name* rather than frames: nothing of the video
/// passes through us, and the camera keeps running after Open Beam quits.
///
/// The extension declares the name as a custom CoreMediaIO property,
/// `4cc_ndis_glob_0000`, which its own app sets through the public
/// `CMIOObjectSetPropertyData`. Writing it from an unrelated, ad-hoc signed
/// process was verified to work — but it is Vizrt's private property, so every
/// accessor here degrades quietly when it is missing rather than assuming it.
///
/// This is the only place in the app that talks to CoreMediaIO.
enum VirtualCamera {

    static let deviceName = "NDI Virtual Camera"
    static let toolsDownloadURL = URL(string: "https://ndi.video/tools/")!

    /// 'ndis' — the NDI source the extension should receive.
    private static let sourceSelector: CMIOObjectPropertySelector = 0x6E646973

    /// What the extension stores when no source is selected.
    private static let noSource = "None"

    // MARK: - State

    /// Everything the menu asks about the device, read in one pass.
    ///
    /// The questions used to be four separate properties, and answering each
    /// one walked every CoreMediaIO device on the system — which the 1 Hz stats
    /// tick then did three times a second, each call reaching into the DAL and
    /// extension processes. One lookup answers them all.
    struct Status {
        var isInstalled = false
        /// False when NDI Tools is installed but its property is gone, which
        /// means the source has to be picked in NDI Virtual Input instead.
        var canSelectSource = false
        /// The NDI source the virtual camera is receiving, if any.
        var selectedSource: String?
        /// Whether some app is currently taking video from the virtual camera.
        var isInUse = false
    }

    static func status() -> Status {
        guard let device = deviceID else { return Status() }

        var status = Status(isInstalled: true)

        var sourceAddress = address(sourceSelector)
        if CMIOObjectHasProperty(device, &sourceAddress) {
            var settable: DarwinBoolean = false
            status.canSelectSource = CMIOObjectIsPropertySettable(device, &sourceAddress, &settable) == noErr
                && settable.boolValue

            if let name = stringProperty(device, sourceSelector), name != noSource, !name.isEmpty {
                status.selectedSource = name
            }
        }

        var runningAddress = address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var running: UInt32 = 0
        var used: UInt32 = 0
        if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil,
                                     UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr {
            status.isInUse = running != 0
        }

        return status
    }

    /// Points the virtual camera at an NDI source, or at nothing for nil.
    static func select(source: String?) {
        guard let device = deviceID else { return }

        let name = (source?.isEmpty == false) ? source! : noSource
        var address = address(sourceSelector)
        var value = name as CFString
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectSetPropertyData(device, &address, 0, nil,
                                      UInt32(MemoryLayout<CFString>.size), pointer)
        }
        if status != noErr {
            print("[Open Beam] could not set the virtual camera source: \(status)")
        }
    }

    // MARK: - CoreMediaIO plumbing

    /// Looked up on every `status()` rather than cached: the extension's object
    /// ID changes when it is reinstalled or restarted, and status is read on
    /// menu interactions and a 1 Hz tick, not per frame.
    private static var deviceID: CMIOObjectID? {
        for device in devices() where stringProperty(device, CMIOObjectPropertySelector(kCMIOObjectPropertyName)) == deviceName {
            return device
        }
        return nil
    }

    private static func devices() -> [CMIOObjectID] {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func stringProperty(_ object: CMIOObjectID,
                                       _ selector: CMIOObjectPropertySelector) -> String? {
        var address = address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }

        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size == UInt32(MemoryLayout<CFString>.size)
        else { return nil }

        var used: UInt32 = 0
        var value: Unmanaged<CFString>?
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr,
              let value
        else { return nil }

        return value.takeRetainedValue() as String
    }
}
