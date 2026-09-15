//
//  LaunchAtLogin.swift
//  OpenBeam
//
//  The "open at login" preference, backed by SMAppService.
//

import Foundation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.openbeam.settings", category: "login")

/// Registers OpenBeam as a login item, and keeps that registration honest
/// across updates.
///
/// macOS keys a login item on the bundle's path *and* its code signature. Open
/// Beam is ad-hoc signed, so its cdhash changes with every build — including the
/// one Sparkle installs over the running app — and the registration can come
/// back `.notRegistered` afterwards. The system is therefore not a safe place to
/// store *what the user asked for*: that lives here, in defaults, and is
/// reconciled with the system on every launch.
///
/// Not main-actor isolated: `AppDelegate` is not either, and this touches only
/// `SMAppService` and defaults, both of which are safe to call from anywhere.
final class LaunchAtLogin {

    private static let intentKey = "openAtLogin"
    private let service = SMAppService.mainApp

    /// What the user asked for. Survives an update that drops the registration.
    private(set) var intent: Bool {
        get { UserDefaults.standard.bool(forKey: Self.intentKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.intentKey) }
    }

    /// Whether the app may offer the preference at all.
    var isAvailable: Bool { AppLocation.isInstalled }

    /// Everything the UI needs, from a single read of the registration.
    ///
    /// `SMAppService.status` is a synchronous XPC round-trip to the login-item
    /// database, so the two questions the settings pane asks — is it on, and is
    /// macOS holding it for approval — are answered from one call rather than
    /// one each.
    struct State {
        /// What the switch shows: the user's intent, not the system's
        /// bookkeeping, so a registration macOS dropped behind our back does not
        /// silently flip the UI off before `reconcile()` has put it back.
        let isOn: Bool
        /// The user switched it off in System Settings, which no app may override.
        let requiresApproval: Bool
    }

    var state: State {
        let requiresApproval = service.status == .requiresApproval
        return State(isOn: intent && !requiresApproval, requiresApproval: requiresApproval)
    }

    func set(_ on: Bool) {
        intent = on
        apply(on)
    }

    /// Re-registers when the user wants the app at login but the system has
    /// forgotten — which is the expected state after Sparkle installs an update.
    func reconcile() {
        guard isAvailable, intent, service.status == .notRegistered else { return }
        log.info("login item was dropped, re-registering")
        apply(true)
    }

    private func apply(_ on: Bool) {
        guard isAvailable else { return }
        do {
            if on {
                // Registering an already-registered service throws rather than
                // being a no-op, so the current status decides.
                if service.status != .enabled { try service.register() }
            } else {
                try service.unregister()
            }
        } catch {
            log.error("could not \(on ? "register" : "unregister") the login item: \(error.localizedDescription)")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
