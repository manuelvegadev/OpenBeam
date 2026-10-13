//
//  RemoteScreenTestHarness.swift
//  OpenBeam
//
//  Debug builds only. Stands in for ClipSync until the control plane is wired in:
//    -RemoteScreenTestHost                runs nothing but a host, and writes each
//                                         session's offer where a viewer can pick it up
//    -RemoteScreenTestViewer <offer.json> runs nothing but a viewer window for that offer
//    -RemoteScreenFullscreen              (viewer) opens straight into fullscreen
//    -RemoteScreenSyntheticMouse          (viewer) circles the host's pointer at 120 Hz,
//                                         to measure input→photon without a hand on the mouse
//    -RemoteScreenTestReconnect           (viewer) when a session ends, waits for the host's
//                                         next offer and attaches it to the same window, as
//                                         the plugin does — which frees the old session's view
//

#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import Metal
import os

private let harnessLog = Logger(subsystem: "com.openbeam.remotescreen", category: "test-harness")

enum RemoteScreenTestHarness {
    private static var host: RemoteScreenHost?
    private static var viewer: RemoteScreenViewer?
    private static var viewerWindow: RemoteScreenWindowController?

    static var offerURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenBeam/remote-screen-test-offer.json")
    }

    /// Starts the harness if the launch arguments ask for it; returns whether it did.
    static func runIfRequested() -> Bool {
        if runViewerIfRequested() { return true }
        guard CommandLine.arguments.contains("-RemoteScreenTestHost") else { return false }
        if !CGPreflightScreenCaptureAccess() {
            harnessLog.error("no Screen Recording permission; asking")
            CGRequestScreenCaptureAccess()
        }
        if !InputInjector.hasPermission(prompt: true) {
            harnessLog.error("no Accessibility permission; input will not be injected")
        }
        openSession()
        return true
    }

    /// One session at a time; a new one is offered as soon as the last ends.
    private static func openSession() {
        let session = RemoteScreenHost(inputSink: InputInjector(display: CGMainDisplayID()))
        session.onEnded = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openSession() }
        }
        let request = ScreenRequestPayload(requestID: UUID().uuidString.lowercased(),
                                           maxWidth: 3440, maxHeight: 1440, maxFPS: nil,
                                           originID: "test-viewer")
        do {
            let offer = try session.open(request: request, hostPeerID: "test-host")
            let data = try ClipSyncJSON.encoder.encode(offer)
            try FileManager.default.createDirectory(at: offerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: offerURL.path, contents: data, attributes: [.posixPermissions: 0o600])
            host = session
            harnessLog.info("offer written to \(offerURL.path, privacy: .public)")
        } catch {
            harnessLog.error("could not open a session: \(String(describing: error), privacy: .public)")
        }
    }

    /// Logs the session's states and, given an offer path, reconnects when it ends.
    private static func observe(_ session: RemoteScreenViewer, reconnectFrom offerPath: String?, device: MTLDevice) {
        let sessionID = session.offer.sessionID
        session.onStateChange = { state in
            harnessLog.info("viewer: \(String(describing: state), privacy: .public)")
            if case .ended = state, let offerPath { reconnect(offerPath: offerPath, after: sessionID, device: device) }
        }
    }

    /// Polls for an offer with a new session ID, then attaches it to the window.
    private static func reconnect(offerPath: String, after previous: Data, device: MTLDevice) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: offerPath)),
                  let offer = try? ClipSyncJSON.decoder.decode(ScreenOfferPayload.self, from: data),
                  offer.sessionID != previous,
                  let session = RemoteScreenViewer(offer: offer, device: device),
                  let window = viewerWindow
            else { return reconnect(offerPath: offerPath, after: previous, device: device) }
            guard window.attach(session) else {
                harnessLog.error("reconnect: could not attach")
                return
            }
            observe(session, reconnectFrom: offerPath, device: device)
            viewer = session
            harnessLog.info("reconnect: attached session \(offer.sessionID.hex, privacy: .public)")
            session.start()
        }
    }

    private static func runViewerIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-RemoteScreenTestViewer"), i + 1 < args.count else { return false }
        do {
            let offer = try ClipSyncJSON.decoder.decode(ScreenOfferPayload.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
            guard let device = MTLCreateSystemDefaultDevice(),
                  let session = RemoteScreenViewer(offer: offer, device: device),
                  let screen = NSScreen.bestForRemoteScreen(refreshHz: offer.display.refreshHz)
            else {
                harnessLog.error("could not set up a viewer")
                return true
            }
            let window = RemoteScreenWindowController(on: screen, title: offer.display.name,
                                                      aspect: CGSize(width: offer.display.width, height: offer.display.height),
                                                      showsStats: true)
            guard window.attach(session) else {
                harnessLog.error("could not set up a viewer")
                return true
            }
            observe(session, reconnectFrom: args.contains("-RemoteScreenTestReconnect") ? args[i + 1] : nil, device: device)
            NSApp.setActivationPolicy(.regular)
            window.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            if args.contains("-RemoteScreenFullscreen") { window.window?.toggleFullScreen(nil) }
            session.start()
            if args.contains("-RemoteScreenSyntheticMouse") {
                Thread.detachNewThread {
                    var t = 0.0
                    while true {
                        t += 1.0 / 120
                        session.send(InputEventMessage(kind: .move, x: 0.5 + 0.15 * cos(t * .pi), y: 0.5 + 0.3 * sin(t * .pi)))
                        usleep(8_333)
                    }
                }
            }
            viewer = session
            viewerWindow = window
        } catch {
            harnessLog.error("cannot read the offer: \(String(describing: error), privacy: .public)")
        }
        return true
    }
}
#endif
