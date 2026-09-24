//
//  KeepAwake.swift
//  OpenBeam
//
//  Keeps the Mac from sleeping, the way KeepingYouAwake and Amphetamine do,
//  so neither is needed alongside OpenBeam.
//
//  Staying awake while idle takes only IOKit power assertions. Staying awake
//  with the lid closed and no external display does not — macOS sleeps on lid
//  close whatever assertions say — and takes `pmset -a disablesleep 1`, which
//  needs root. The user authorizes that once: OpenBeam installs a sudoers rule
//  that allows exactly those two pmset commands and nothing else, and runs
//  them with `sudo -n`. The setting is system-wide and survives this app, so
//  it is reverted on stop, on quit and, after a crash, on the next launch.
//

import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import os

private let awakeLog = Logger(subsystem: "com.openbeam.keepawake", category: "keepawake")

final class KeepAwake {
    static let shared = KeepAwake()

    /// Why the Mac is being kept awake. Manual is the user's choice from the
    /// menu; the others are held by features for as long as they need it.
    enum Reason: Hashable {
        case manual
        case remoteControl
    }

    /// The durations the menu offers; nil is until turned off.
    static let durations: [TimeInterval?] = [nil, 3600, 2 * 3600, 4 * 3600, 8 * 3600]

    /// Main queue, whenever anything the menu or settings show changes.
    var onChange: (() -> Void)?

    private(set) var reasons: Set<Reason> = []
    /// When a timed manual session ends.
    private(set) var manualUntil: Date?
    private var manualTimer: Timer?
    private var batteryTimer: Timer?
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var lidClosedActive = false

    private enum Key {
        static let keepsDisplayOn = "keepAwake.keepsDisplayOn"
        static let staysAwakeLidClosed = "keepAwake.staysAwakeLidClosed"
        static let disableSleepOwned = "keepAwake.disableSleepOwned"
    }

    /// Below this, on battery, lid-closed mode lets go so the Mac can sleep
    /// rather than run flat in a bag.
    static let batteryFloor = 20

    private static let sudoersPath = "/etc/sudoers.d/openbeam-keepawake"

    private init() {}

    // MARK: - Preferences

    /// The display stays on too, not just the system. On by default, as in KeepingYouAwake.
    var keepsDisplayOn: Bool {
        get { UserDefaults.standard.object(forKey: Key.keepsDisplayOn) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.keepsDisplayOn)
            apply()
        }
    }

    /// Manual keep-awake also holds with the lid closed and no external display.
    var staysAwakeLidClosed: Bool {
        get { UserDefaults.standard.bool(forKey: Key.staysAwakeLidClosed) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.staysAwakeLidClosed)
            apply()
        }
    }

    var isActive: Bool { !reasons.isEmpty }

    // MARK: - Lifecycle

    /// Undoes a lid-closed setting a previous run left behind by crashing.
    func launch() {
        if UserDefaults.standard.bool(forKey: Key.disableSleepOwned) {
            awakeLog.info("reverting disablesleep left on by a previous run")
            setDisableSleep(false)
        }
    }

    /// Lets go of everything, lid-closed mode included, before the app quits.
    func shutdown() {
        reasons.removeAll()
        manualTimer?.invalidate()
        apply()
    }

    // MARK: - Turning it on and off

    /// Keeps the Mac awake for `duration`, or until turned off when nil.
    func startManual(for duration: TimeInterval?) {
        manualTimer?.invalidate()
        manualTimer = nil
        manualUntil = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            manualTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.stopManual()
            }
        }
        reasons.insert(.manual)
        apply()
    }

    func stopManual() {
        manualTimer?.invalidate()
        manualTimer = nil
        manualUntil = nil
        reasons.remove(.manual)
        apply()
    }

    /// Held by a feature for as long as it needs the Mac and its display awake.
    func hold(_ reason: Reason) {
        reasons.insert(reason)
        apply()
    }

    func release(_ reason: Reason) {
        reasons.remove(reason)
        apply()
    }

    // MARK: - Assertions and pmset

    /// Brings the assertions and the lid-closed setting in line with the reasons.
    private func apply() {
        let wantsSystem = isActive
        // Remote control needs the display: capture stops when it sleeps.
        let wantsDisplay = reasons.contains(.remoteControl) || (reasons.contains(.manual) && keepsDisplayOn)
        set(&systemAssertion, on: wantsSystem, type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        set(&displayAssertion, on: wantsDisplay, type: kIOPMAssertionTypePreventUserIdleDisplaySleep)

        let wantsLidClosed = reasons.contains(.manual) && staysAwakeLidClosed && !batteryTooLow && lidClosedAuthorized
        if wantsLidClosed != lidClosedActive {
            if setDisableSleep(wantsLidClosed) { lidClosedActive = wantsLidClosed }
        }
        if lidClosedActive, batteryTimer == nil {
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.apply() }
        } else if !lidClosedActive {
            batteryTimer?.invalidate()
            batteryTimer = nil
        }
        onChange?()
    }

    private func set(_ id: inout IOPMAssertionID, on: Bool, type: String) {
        if on, id == 0 {
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "OpenBeam: Keep Awake" as CFString, &id)
            if result != kIOReturnSuccess {
                awakeLog.error("assertion \(type, privacy: .public) failed: \(result, privacy: .public)")
                id = 0
            }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    /// Runs the authorized pmset command; true if it took.
    @discardableResult
    private func setDisableSleep(_ on: Bool) -> Bool {
        let ok = Self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        if ok {
            // Remembered until reverted, so a crash in between is undone on the next launch.
            UserDefaults.standard.set(on, forKey: Key.disableSleepOwned)
            awakeLog.info("disablesleep \(on ? 1 : 0, privacy: .public)")
        } else {
            awakeLog.error("pmset disablesleep \(on ? 1 : 0, privacy: .public) failed")
        }
        return ok
    }

    /// On battery below the floor.
    private var batteryTooLow: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let capacity = d[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            return capacity <= Self.batteryFloor
        }
        return false
    }

    // MARK: - Authorization for lid-closed mode

    /// Whether the sudoers rule is in place, so pmset runs without a password.
    /// Asked of sudo once, then only again after authorizing or removing it.
    var lidClosedAuthorized: Bool {
        if let cached = authorizedCache { return cached }
        let authorized = Self.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        authorizedCache = authorized
        return authorized
    }

    private var authorizedCache: Bool?

    /// Asks for an administrator password once and installs the rule. The rule
    /// is checked with visudo before it goes in, since a broken sudoers file
    /// locks sudo out for everyone.
    func authorizeLidClosed() -> Bool {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("openbeam-keepawake.sudoers")
        do {
            try rule.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let script = "/usr/sbin/visudo -cf '\(temp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(temp.path)' '\(Self.sudoersPath)'"
        guard Self.runAsAdministrator(script, prompt: "OpenBeam needs to be allowed to keep this Mac awake with the lid closed.") else {
            return false
        }
        authorizedCache = nil
        onChange?()
        return lidClosedAuthorized
    }

    /// Removes the rule, turning lid-closed mode off first.
    func removeLidClosedAuthorization() {
        staysAwakeLidClosed = false
        _ = Self.runAsAdministrator("/bin/rm -f '\(Self.sudoersPath)'",
                                    prompt: "OpenBeam will stop being allowed to keep this Mac awake with the lid closed.")
        authorizedCache = nil
        onChange?()
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func runAsAdministrator(_ command: String, prompt: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { awakeLog.error("administrator command failed: \(String(describing: error), privacy: .public)") }
        return error == nil
    }
}
