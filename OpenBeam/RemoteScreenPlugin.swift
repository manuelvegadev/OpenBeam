//
//  RemoteScreenPlugin.swift
//  OpenBeam
//
//  Remote screen over ClipSync (SCREEN-PROTOCOL.md). As a host it answers a
//  paired peer's `screen.request` — only if the user allowed that peer — and
//  runs the session; as a viewer it asks a peer for its screen and shows it.
//  ClipSync carries the four control payloads; the pixels and the input travel
//  on the session's own connections.
//

import AppKit
import CoreGraphics
import Metal
import os

private let pluginLog = Logger(subsystem: "com.openbeam.remotescreen", category: "plugin")

/// Remote screen choices, kept in user defaults and read on each use.
enum RemoteScreenPreferences {
    private static let allowedPeersKey = "remoteScreen.allowedPeers"
    private static let sendsMediaKeysKey = "remoteScreen.sendsMediaKeys"
    private static let capturesSystemShortcutsKey = "remoteScreen.capturesSystemShortcuts"
    private static let opensFullScreenKey = "remoteScreen.opensFullScreen"
    private static let showsStatsKey = "remoteScreen.showsStats"
    private static let requestsRetinaKey = "remoteScreen.requestsRetina"
    private static let preferredDisplaysKey = "remoteScreen.preferredDisplays"

    /// The host display last chosen for each peer, asked for again next time.
    static func preferredDisplay(for peerID: String) -> UInt32? {
        (UserDefaults.standard.dictionary(forKey: preferredDisplaysKey)?[peerID] as? Int).map(UInt32.init)
    }

    static func setPreferredDisplay(_ id: UInt32, for peerID: String) {
        var all = UserDefaults.standard.dictionary(forKey: preferredDisplaysKey) ?? [:]
        all[peerID] = Int(id)
        UserDefaults.standard.set(all, forKey: preferredDisplaysKey)
    }

    /// Peers allowed to see and control this Mac. Nobody is by default, and
    /// pairing alone never adds anyone.
    static func isAllowed(_ peerID: String) -> Bool {
        allowedPeers.contains(peerID)
    }

    static func setAllowed(_ allowed: Bool, peerID: String) {
        var peers = allowedPeers
        if allowed { peers.insert(peerID) } else { peers.remove(peerID) }
        UserDefaults.standard.set(peers.sorted(), forKey: allowedPeersKey)
    }

    private static var allowedPeers: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: allowedPeersKey) ?? [])
    }

    /// Volume, brightness and playback keys go to the host while the viewer has
    /// the focus. Off by default: the host's sound usually plays on this Mac.
    static var sendsMediaKeys: Bool {
        get { UserDefaults.standard.bool(forKey: sendsMediaKeysKey) }
        set { UserDefaults.standard.set(newValue, forKey: sendsMediaKeysKey) }
    }

    /// Every key, global shortcuts included, goes to the host while the viewer has the focus.
    static var capturesSystemShortcuts: Bool {
        get { UserDefaults.standard.object(forKey: capturesSystemShortcutsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: capturesSystemShortcutsKey) }
    }

    static var opensFullScreen: Bool {
        get { UserDefaults.standard.object(forKey: opensFullScreenKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: opensFullScreenKey) }
    }

    /// Ask for the host's full HiDPI pixels (6192×2592 for a desktop that looks
    /// like 3096×1296) instead of the panel's (3440×1440). Drawn 1:1 into a HiDPI
    /// viewer, with no rescaling of our own; about 3.4× the pixels to send. On by
    /// default: side by side, text was visibly sharper than at panel resolution.
    static var requestsRetina: Bool {
        get { UserDefaults.standard.object(forKey: requestsRetinaKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: requestsRetinaKey) }
    }

    /// Frame rate and latency, drawn over the picture.
    static var showsStats: Bool {
        get { UserDefaults.standard.bool(forKey: showsStatsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showsStatsKey) }
    }
}

final class RemoteScreenPlugin: @unchecked Sendable {
    /// On the main queue, whenever hosting or viewing starts or stops.
    var onStateChanged: (() -> Void)?
    /// Sends a control payload to one paired peer, opening a ClipSync session
    /// if there is none; false when the peer cannot be reached at all.
    var send: ((Data, String) -> Bool)?

    private let identity: ClipSyncIdentity

    // The session this Mac hosts, if any. One at a time, per the spec.
    private let lock = NSLock()
    private var hosting: (peerID: String, session: RemoteScreenHost)?

    // Screens this Mac is viewing, by peer. Main thread only, like every method that touches it.
    private struct Viewing {
        var requestID: String
        var viewer: RemoteScreenViewer?
        var window: RemoteScreenWindowController?
        var timeout: DispatchWorkItem?
        /// While a dropped session is being re-established: when to give up.
        var reconnectUntil: Date?
    }
    private var viewing: [String: Viewing] = [:]

    /// How long a dropped session keeps trying to come back — long enough for a
    /// Mac to wake or a cable to be plugged back in.
    private static let reconnectWindow: TimeInterval = 60

    init(identity: ClipSyncIdentity) {
        self.identity = identity
    }

    /// The peer currently controlling this Mac.
    var hostingPeerID: String? {
        lock.lock()
        defer { lock.unlock() }
        return hosting?.peerID
    }

    func isViewing(_ peerID: String) -> Bool { viewing[peerID] != nil }

    // MARK: - Viewing another Mac

    /// Asks `peer` for its screen; the window opens when the offer arrives. Main thread.
    func view(_ peer: PairedPeer) {
        if let window = viewing[peer.peerID]?.window?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard viewing[peer.peerID] == nil else { return }  // already asked
        guard sendRequest(to: peer.peerID) else {
            alert("\(peer.displayName) can't be reached", "It isn't on this network right now, or ClipSync can't find it.")
            return
        }
        if RemoteScreenPreferences.capturesSystemShortcuts, !InputInjector.hasPermission(prompt: false) {
            // Without it the viewer still works, but global shortcuts stay here.
            _ = InputInjector.hasPermission(prompt: true)
        }
        onStateChanged?()
    }

    /// Sends a fresh `screen.request` and arms its answer timeout: 10 s for a
    /// first request, 3 s while reconnecting, so a host that comes back is
    /// picked up within a few seconds rather than after a long wait.
    private func sendRequest(to peerID: String) -> Bool {
        // As many pixels as the biggest panel here — or, for Retina, as the
        // biggest HiDPI desktop. The host scales down to fit, never above its own.
        let retina = RemoteScreenPreferences.requestsRetina
        let size = NSScreen.screens.map { retina ? $0.backingPixelSize : $0.nativePixelSize }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 1920, height: 1080)
        let request = ScreenRequestPayload(requestID: UUID().uuidString.lowercased(),
                                           maxWidth: Int(size.width), maxHeight: Int(size.height),
                                           maxFPS: nil, displayID: RemoteScreenPreferences.preferredDisplay(for: peerID),
                                           originID: identity.peerID)
        guard let data = try? ClipSyncJSON.encoder.encode(request), send?(data, peerID) == true else { return false }
        var entry = viewing[peerID] ?? Viewing(requestID: request.requestID)
        entry.requestID = request.requestID
        entry.timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.requestTimedOut(peerID: peerID, requestID: request.requestID) }
        entry.timeout = timeout
        viewing[peerID] = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + (entry.reconnectUntil == nil ? 10 : 3), execute: timeout)
        pluginLog.info("asked \(peerID, privacy: .public) for its screen at up to \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public)")
        return true
    }

    private func requestTimedOut(peerID: String, requestID: String) {
        guard let entry = viewing[peerID], entry.requestID == requestID, entry.viewer == nil else { return }
        if entry.reconnectUntil != nil {
            attemptReconnect(peerID)
        } else {
            finish(peerID, "\(name(of: peerID)) didn't answer", "Make sure OpenBeam is running on it.")
        }
    }

    private func openViewer(_ offer: ScreenOfferPayload, from peerID: String) {
        guard var entry = viewing[peerID], entry.requestID == offer.requestID, entry.viewer == nil else {
            pluginLog.error("ignoring an offer nobody here asked for")
            return
        }
        entry.timeout?.cancel()
        let name = name(of: peerID)
        var window = entry.window
        let isNew = window == nil
        if window == nil, let screen = NSScreen.bestForRemoteScreen(refreshHz: offer.display.refreshHz) {
            let made = RemoteScreenWindowController(on: screen, title: name,
                                                    aspect: CGSize(width: offer.display.width, height: offer.display.height),
                                                    showsStats: RemoteScreenPreferences.showsStats)
            made.onClose = { [weak self] in self?.windowClosed(peerID: peerID) }
            made.onSelectDisplay = { [weak self, weak made] id in
                guard let self, let sessionID = made?.viewer?.offer.sessionID else { return }
                RemoteScreenPreferences.setPreferredDisplay(id, for: peerID)
                let select = ScreenSelectPayload(sessionID: sessionID, displayID: id, originID: self.identity.peerID)
                if let data = try? ClipSyncJSON.encoder.encode(select) { _ = self.send?(data, peerID) }
            }
            window = made
        }
        guard let window, let device = MTLCreateSystemDefaultDevice(),
              let viewer = RemoteScreenViewer(offer: offer, device: device), window.attach(viewer)
        else {
            entry.window = window
            viewing[peerID] = entry
            finish(peerID, "Couldn't show \(name)'s screen", "This Mac could not set up the viewer.")
            return
        }
        viewer.onStateChange = { [weak self, weak viewer] state in
            guard let self, let viewer, case .ended(let end) = state else { return }
            self.viewerEnded(peerID: peerID, viewer: viewer, end: end)
        }
        entry.viewer = viewer
        entry.window = window
        entry.reconnectUntil = nil
        viewing[peerID] = entry
        if isNew {
            window.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            if RemoteScreenPreferences.opensFullScreen { window.window?.toggleFullScreen(nil) }
        }
        viewer.start()
        onStateChanged?()
    }

    /// A session closed here needs nothing more; one the host ended on purpose
    /// closes the window; anything else is something to recover from.
    private func viewerEnded(peerID: String, viewer: RemoteScreenViewer, end: RemoteScreenViewer.End) {
        guard var entry = viewing[peerID], entry.viewer === viewer else { return }
        entry.viewer = nil
        entry.window?.detach()
        switch end {
        case .closed:
            viewing[peerID] = entry
            return
        case .hostStopped(let reason) where reason.isFinal:
            viewing[peerID] = entry
            finish(peerID, "\(name(of: peerID))'s screen closed", Self.describe(reason))
            return
        case .hostStopped, .failed:
            break
        }
        pluginLog.info("session with \(peerID, privacy: .public) dropped (\(String(describing: end), privacy: .public)); reconnecting")
        entry.reconnectUntil = Date().addingTimeInterval(Self.reconnectWindow)
        viewing[peerID] = entry
        entry.window?.showStatus("Reconnecting to \(name(of: peerID))…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attemptReconnect(peerID) }
        onStateChanged?()
    }

    /// Asks again, and keeps asking every couple of seconds while the peer is
    /// unreachable, until the reconnect window runs out.
    private func attemptReconnect(_ peerID: String) {
        guard let entry = viewing[peerID], entry.viewer == nil, let until = entry.reconnectUntil else { return }
        guard Date() < until else {
            finish(peerID, "Lost \(name(of: peerID))'s screen", "It could not be reached again. It may be asleep or off this network.")
            return
        }
        if !sendRequest(to: peerID) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.attemptReconnect(peerID) }
        }
    }

    /// The user closed the window: end everything for that peer, quietly.
    private func windowClosed(peerID: String) {
        guard let entry = viewing.removeValue(forKey: peerID) else { return }
        entry.timeout?.cancel()
        entry.viewer?.stop(.closed)
        onStateChanged?()
    }

    /// Ends viewing `peerID` for good, closing its window, and says why.
    private func finish(_ peerID: String, _ title: String, _ message: String) {
        guard let entry = viewing.removeValue(forKey: peerID) else { return }
        entry.timeout?.cancel()
        entry.viewer?.stop(.closed)
        entry.window?.onClose = nil
        entry.window?.close()
        onStateChanged?()
        alert(title, message)
    }

    private func name(of peerID: String) -> String {
        identity.paired(peerID: peerID)?.displayName ?? "The other Mac"
    }

    // MARK: - Inbound payloads

    /// A `screen.*` payload from `peerID`, whose identity ClipSync already verified.
    func handleInbound(_ data: Data, kind: String, from peerID: String) {
        let decoder = ClipSyncJSON.decoder
        switch kind {
        case "screen.request":
            guard let request = try? decoder.decode(ScreenRequestPayload.self, from: data) else { return }
            answer(request, from: peerID)
        case "screen.offer":
            guard let offer = try? decoder.decode(ScreenOfferPayload.self, from: data) else { return }
            DispatchQueue.main.async { self.openViewer(offer, from: peerID) }
        case "screen.decline":
            guard let decline = try? decoder.decode(ScreenDeclinePayload.self, from: data) else { return }
            DispatchQueue.main.async { self.declined(decline, by: peerID) }
        case "screen.stop":
            guard let stop = try? decoder.decode(ScreenStopPayload.self, from: data) else { return }
            stopped(stop, by: peerID)
        case "screen.displays":
            guard let list = try? decoder.decode(ScreenDisplaysPayload.self, from: data) else { return }
            DispatchQueue.main.async {
                guard let entry = self.viewing[peerID], entry.viewer?.offer.sessionID == list.sessionID else { return }
                entry.window?.updateDisplays(list.displays, current: list.current)
            }
        case "screen.select":
            guard let select = try? decoder.decode(ScreenSelectPayload.self, from: data) else { return }
            hostedSession(peerID: peerID, sessionID: select.sessionID)?.select(display: select.displayID)
        default:
            break
        }
    }

    private func declined(_ decline: ScreenDeclinePayload, by peerID: String) {
        guard let entry = viewing[peerID], entry.requestID == decline.requestID else { return }
        entry.timeout?.cancel()
        let name = name(of: peerID)
        switch decline.reason {
        case "not_allowed":
            finish(peerID, "\(name) doesn't allow control",
                   "On \(name), open OpenBeam Settings → Remote Screen and turn on control for this Mac.")
        case "busy":
            finish(peerID, "\(name) is already being controlled", "Only one Mac can control it at a time.")
        case "needs_screen_recording":
            finish(peerID, "\(name) needs Screen Recording permission",
                   "On \(name), allow OpenBeam in System Settings → Privacy & Security → Screen & System Audio Recording.")
        case "needs_accessibility":
            finish(peerID, "\(name) needs Accessibility permission",
                   "On \(name), allow OpenBeam in System Settings → Privacy & Security → Accessibility.")
        default:
            finish(peerID, "\(name) declined", "It could not start sharing its screen.")
        }
    }

    private func stopped(_ stop: ScreenStopPayload, by peerID: String) {
        hostedSession(peerID: peerID, sessionID: stop.sessionID)?.end(.other)
        DispatchQueue.main.async {
            guard let viewer = self.viewing[peerID]?.viewer, viewer.offer.sessionID == stop.sessionID else { return }
            viewer.stop(.hostStopped(RemoteScreenHost.EndReason(rawValue: stop.reason) ?? .other))
        }
    }

    /// The session this Mac hosts for `peerID`, if it is the one named.
    private func hostedSession(peerID: String, sessionID: Data? = nil) -> RemoteScreenHost? {
        lock.lock()
        defer { lock.unlock() }
        guard let hosting, hosting.peerID == peerID, sessionID.map({ $0 == hosting.session.sessionID }) ?? true else { return nil }
        return hosting.session
    }

    // MARK: - Hosting

    private func answer(_ request: ScreenRequestPayload, from peerID: String) {
        func decline(_ reason: String) {
            pluginLog.info("declined a request from \(peerID, privacy: .public): \(reason, privacy: .public)")
            let payload = ScreenDeclinePayload(requestID: request.requestID, reason: reason, originID: identity.peerID)
            if let data = try? ClipSyncJSON.encoder.encode(payload) { _ = send?(data, peerID) }
        }
        guard RemoteScreenPreferences.isAllowed(peerID) else { return decline("not_allowed") }
        guard CGPreflightScreenCaptureAccess() else {
            DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
            return decline("needs_screen_recording")
        }
        guard InputInjector.hasPermission(prompt: false) else {
            DispatchQueue.main.async { _ = InputInjector.hasPermission(prompt: true) }
            return decline("needs_accessibility")
        }

        lock.lock()
        let previous = hosting
        lock.unlock()
        if let previous {
            // The same viewer asking again has most likely lost its last session
            // (a crash, a closed lid); it replaces it. Anyone else waits.
            guard previous.peerID == peerID else { return decline("busy") }
            previous.session.end(.other)
        }

        let display = CGMainDisplayID()
        let session = RemoteScreenHost(inputSink: InputInjector(display: display))
        session.onEnded = { [weak self, weak session] reason in
            guard let self, let session else { return }
            self.hostEnded(session, reason: reason, peerID: peerID)
        }
        session.onDisplaysChanged = { [weak self, weak session] displays, current in
            guard let self, let session else { return }
            let list = ScreenDisplaysPayload(sessionID: session.sessionID, displays: displays, current: current,
                                             originID: self.identity.peerID)
            if let data = try? ClipSyncJSON.encoder.encode(list) { _ = self.send?(data, peerID) }
        }
        do {
            let offer = try session.open(request: request, hostPeerID: identity.peerID, display: display)
            lock.lock()
            hosting = (peerID, session)
            lock.unlock()
            guard let data = try? ClipSyncJSON.encoder.encode(offer), send?(data, peerID) == true else {
                session.end(.error)
                return
            }
            pluginLog.info("offered this screen to \(peerID, privacy: .public)")
            DispatchQueue.main.async { self.onStateChanged?() }
        } catch {
            pluginLog.error("could not open a session: \(String(describing: error), privacy: .public)")
            decline("other")
        }
    }

    private func hostEnded(_ session: RemoteScreenHost, reason: RemoteScreenHost.EndReason, peerID: String) {
        lock.lock()
        let current = hosting?.session === session
        if current { hosting = nil }
        lock.unlock()
        guard current else { return }
        let stop = ScreenStopPayload(sessionID: session.sessionID, reason: reason.rawValue, originID: identity.peerID)
        if let data = try? ClipSyncJSON.encoder.encode(stop) { _ = send?(data, peerID) }
        DispatchQueue.main.async { self.onStateChanged?() }
    }

    /// Ends the session this Mac hosts, from the host's own side.
    func stopHosting() {
        lock.lock()
        let session = hosting?.session
        lock.unlock()
        session?.end(.user)
    }

    /// Call after the user changes whether `peerID` may control this Mac.
    func accessChanged(for peerID: String) {
        guard !RemoteScreenPreferences.isAllowed(peerID) else { return }
        hostedSession(peerID: peerID)?.end(.revoked)
    }

    /// Call when a peer is unpaired: it loses control, and its screen closes here.
    func peerForgotten(_ peerID: String) {
        RemoteScreenPreferences.setAllowed(false, peerID: peerID)
        accessChanged(for: peerID)
        DispatchQueue.main.async {
            self.finish(peerID, "\(self.name(of: peerID))'s screen closed", "That Mac is no longer paired with this one.")
        }
    }

    // MARK: - Messages

    private static func describe(_ reason: RemoteScreenHost.EndReason) -> String {
        switch reason {
        case .user: return "It was stopped on the other Mac."
        case .revoked: return "The other Mac no longer allows control from this one."
        case .displayLost: return "The other Mac's display went away — it may have gone to sleep."
        case .error, .other: return "The connection ended."
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The desktop's own pixels in its current mode: 6192×2592 for a HiDPI
    /// desktop that looks like 3096×1296.
    var backingPixelSize: CGSize {
        CGSize(width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor)
    }

    /// The panel's own pixels — what a remote screen should fill — whatever
    /// scaled mode the desktop runs in.
    var nativePixelSize: CGSize {
        let fallback = backingPixelSize
        guard let id = displayID,
              let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode]
        else { return fallback }
        let kDisplayModeNativeFlag: UInt32 = 0x0200_0000
        if let native = modes.first(where: { $0.ioFlags & kDisplayModeNativeFlag != 0 }) {
            return CGSize(width: native.pixelWidth, height: native.pixelHeight)
        }
        return fallback
    }
}
