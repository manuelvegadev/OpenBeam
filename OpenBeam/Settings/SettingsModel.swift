//
//  SettingsModel.swift
//  OpenBeam
//
//  The bridge between the AppKit controllers and the SwiftUI settings window.
//

import AppKit
import Observation

/// Everything the settings window can read or change.
///
/// This owns no preference state of its own. Each value already has exactly one
/// owner — `CameraController` persists the pixel format, `ClipSyncManager` its
/// enablement, Sparkle its own defaults, `LaunchAtLogin` the user's intent — and
/// this type mirrors them for SwiftUI and writes straight through. The mirrors
/// are refreshed rather than bound, so nothing here can become a second, quietly
/// diverging source of truth.
@MainActor
@Observable
final class SettingsModel {

    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let clipSync: ClipSyncManager
    @ObservationIgnored private let updater: UpdaterController
    @ObservationIgnored private let launchAtLogin: LaunchAtLogin

    // General
    private(set) var openAtLogin = false
    private(set) var openAtLoginNeedsApproval = false
    private(set) var sendsUYVY = false

    // Updates
    private(set) var checksAutomatically = false
    private(set) var downloadsAutomatically = false
    private(set) var allowsAutomaticUpdates = false
    private(set) var canCheckForUpdates = true
    private(set) var lastUpdateCheck: Date?

    // Clipboard
    private(set) var clipSyncEnabled = false
    private(set) var clipSyncSyncsFiles = true
    private(set) var clipSyncMaxTextBytes = ClipSync.maxTextBytes
    private(set) var clipSyncMaxTransferBytes = ClipSync.maxShareTotalBytes
    private(set) var discoveredPeers: [DiscoveredPeer] = []
    private(set) var pairedPeers: [PairedPeer] = []

    var version: String { AppDelegate.appVersion }

    /// False when the app runs from the DMG or a build directory, where neither
    /// updating nor a login item can work — which is why it gates both the login
    /// item and the update notice. See `AppLocation`.
    var isInstalled: Bool { AppLocation.isInstalled }

    init(camera: CameraController,
         clipSync: ClipSyncManager,
         updater: UpdaterController,
         launchAtLogin: LaunchAtLogin) {
        self.camera = camera
        self.clipSync = clipSync
        self.updater = updater
        self.launchAtLogin = launchAtLogin
        refresh()
    }

    /// Re-reads every owner. Called when the window opens, and whenever ClipSync
    /// reports that peers changed.
    func refresh() {
        let loginItem = launchAtLogin.state
        openAtLogin = loginItem.isOn
        openAtLoginNeedsApproval = loginItem.requiresApproval
        sendsUYVY = camera.pixelFormat == .uyvy422

        checksAutomatically = updater.automaticallyChecksForUpdates
        downloadsAutomatically = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheck = updater.lastUpdateCheckDate

        clipSyncEnabled = clipSync.isEnabled
        clipSyncSyncsFiles = clipSync.preferences.syncsFiles
        clipSyncMaxTextBytes = clipSync.preferences.maxTextBytes
        clipSyncMaxTransferBytes = clipSync.preferences.maxTransferBytes
        let paired = clipSync.pairedPeers
        pairedPeers = paired.sorted { $0.displayName < $1.displayName }
        let pairedIDs = Set(paired.map(\.peerID))
        discoveredPeers = clipSync.discoveredPeers
            .filter { !pairedIDs.contains($0.peerID) }
            .sorted { $0.displayName < $1.displayName }
    }

    // MARK: - General

    func setOpenAtLogin(_ on: Bool) {
        launchAtLogin.set(on)
        refresh()
    }

    func openLoginItemsSettings() {
        LaunchAtLogin.openSystemSettings()
    }

    func setSendsUYVY(_ on: Bool) {
        camera.setPixelFormat(on ? .uyvy422 : .bgra32)
        refresh()
    }

    // MARK: - Updates

    func setChecksAutomatically(_ on: Bool) {
        updater.automaticallyChecksForUpdates = on
        refresh()
    }

    func setDownloadsAutomatically(_ on: Bool) {
        updater.automaticallyDownloadsUpdates = on
        refresh()
    }

    func checkForUpdates() {
        updater.checkForUpdates()
        refresh()
    }

    // MARK: - Clipboard

    // These three go through `ClipSyncManager`, which announces the change on
    // `onStateChanged` — and that already drives a refresh. Refreshing here as
    // well ran the whole mirror twice for one click.

    func setClipSyncEnabled(_ on: Bool) {
        clipSync.isEnabled = on
    }

    // The limits below have no announcement to ride on — the plugins read them
    // when they next need them — so each one refreshes the mirror itself.

    func setClipSyncSyncsFiles(_ on: Bool) {
        clipSync.preferences.syncsFiles = on
        refresh()
    }

    func setClipSyncMaxTextBytes(_ bytes: Int) {
        clipSync.preferences.maxTextBytes = bytes
        refresh()
    }

    func setClipSyncMaxTransferBytes(_ bytes: Int) {
        clipSync.preferences.maxTransferBytes = bytes
        refresh()
    }

    func pair(_ peer: DiscoveredPeer) {
        clipSync.requestPair(with: peer)
    }

    func forget(_ peer: PairedPeer) {
        clipSync.unpair(peerID: peer.peerID)
    }
}
