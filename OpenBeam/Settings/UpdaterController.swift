//
//  UpdaterController.swift
//  OpenBeam
//
//  Sparkle, wired for a menu bar app.
//

import AppKit
import Sparkle
import os

private let log = Logger(subsystem: "com.openbeam.settings", category: "updater")

/// Owns Sparkle's updater for the lifetime of the app.
///
/// OpenBeam is ad-hoc signed, which decides how updates are trusted: Sparkle's
/// code-signature check compares a new build against the running bundle's
/// designated requirement, and an ad-hoc requirement pins a per-binary cdhash,
/// so that check can never pass across an update. The EdDSA signature on the
/// archive is the only thing left — see `SUPublicEDKey` in Info.plist.
///
/// The rest of this class is about not behaving like an app with a Dock icon: a
/// scheduled check that found something must not take over the screen while the
/// user is on the call OpenBeam is feeding.
@MainActor
// Sparkle calls its user driver delegate on the main thread; `@preconcurrency`
// states that rather than scattering `nonisolated` hops through methods that all
// touch main-actor state.
final class UpdaterController: NSObject, @preconcurrency SPUStandardUserDriverDelegate {

    /// Implicitly unwrapped because `self` is the user driver delegate and
    /// cannot be passed before `super.init()`.
    private var controller: SPUStandardUpdaterController!

    /// Raised when a scheduled check found an update that we chose not to show
    /// immediately, and lowered when the session ends. The status item badges
    /// itself from this rather than Sparkle stealing focus.
    var onQuietUpdateStateChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        // `startingUpdater: true` starts it inside the initializer. On failure
        // Sparkle puts up a modal alert a second later, so this is constructed
        // after the status item exists and the app has something on screen.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: self)
    }

    private var updater: SPUUpdater { controller.updater }

    /// The target for a "Check for Updates…" menu item. Sparkle's controller
    /// implements `validateMenuItem:` itself, so the item greys out during a
    /// session without the menu having to know anything about update state.
    var menuTarget: AnyObject { controller }
    var menuAction: Selector { #selector(SPUStandardUpdaterController.checkForUpdates(_:)) }

    func checkForUpdates() { updater.checkForUpdates() }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// Sparkle refuses automatic installation for some updates (a major upgrade,
    /// or one that needs an installer), and the toggle follows it rather than
    /// promising something that will not happen.
    var allowsAutomaticUpdates: Bool { updater.allowsAutomaticUpdates }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    // Note: `updateCheckInterval` is deliberately never written. Sparkle's own
    // header warns that setting it overrides the user's preference; the default
    // comes from `SUScheduledCheckInterval` in Info.plist.

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Never on Sparkle's schedule: a menu bar app interrupting a live NDI
        // send with a window is worse than an update that waits for the user.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        log.info("update \(update.displayVersionString) found in the background")
        onQuietUpdateStateChanged?(true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onQuietUpdateStateChanged?(false)
    }
}
