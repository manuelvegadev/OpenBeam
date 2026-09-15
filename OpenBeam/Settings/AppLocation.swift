//
//  AppLocation.swift
//  OpenBeam
//
//  Where the bundle is running from, which decides whether it can update
//  itself or be registered as a login item.
//

import Foundation

/// Two features in this app are silently broken when OpenBeam runs from
/// anywhere but a real install location, and neither macOS nor Sparkle says so:
///
/// - Sparkle will not replace a bundle on a read-only mount (the DMG the app
///   ships in) or one macOS has translocated, and by default does not notify
///   the user when it declines.
/// - `SMAppService` keys a login item on its path, so registering from a
///   mounted DMG writes an entry pointing at a volume that will not exist at
///   the next login — a login item that is broken forever and has to be removed
///   by hand in System Settings.
///
/// So the app asks this once and disables both rather than failing quietly.
enum AppLocation {

    /// Whether the bundle sits somewhere it can be updated and registered from.
    ///
    /// A development build in DerivedData deliberately answers `false`: it is
    /// the same broken case as the DMG, and registering it would leave a login
    /// item pointing into a build directory. Testing either feature means
    /// copying the built app to `/Applications` first.
    /// Resolved once: this is a `realpath` walk plus a home-directory lookup,
    /// and the answer cannot change while the process is alive.
    static let isInstalled: Bool = {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }()
}
