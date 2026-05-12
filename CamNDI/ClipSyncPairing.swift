//
//  ClipSyncPairing.swift
//  CamNDI
//
//  KDE-Connect-style pairing UX. The connection-handshake math (verification
//  code, fingerprint) lives in ClipSyncConnection; this file owns only the
//  user-facing NSAlert with a 30s auto-reject timer.
//

import AppKit
import Foundation
import os

final class ClipSyncPairing: @unchecked Sendable {

    enum Decision { case accept, reject(String /* reason */) }

    /// Show the accept/reject dialog for an inbound pair request. The completion
    /// fires on the **main queue**.
    @MainActor
    static func presentInboundDialog(displayName: String,
                                     verificationCode: String,
                                     fingerprint: String,
                                     completion: @escaping (Decision) -> Void) {
        // Activate the app so the modal comes forward even when the menu is closed.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Pair with \"\(displayName)\"?"
        alert.informativeText = """
            Verification code: \(verificationCode)

            Confirm this code matches what's shown on the other device.

            Fingerprint:
            \(fingerprint)
            """
        alert.addButton(withTitle: "Reject")
        alert.addButton(withTitle: "Accept")
        alert.alertStyle = .informational

        // Auto-reject after 30 seconds. abortModal() makes runModal() return .abort.
        var fired = false
        let timer = Timer.scheduledTimer(withTimeInterval: ClipSync.pairDialogTimeoutSeconds, repeats: false) { _ in
            fired = true
            NSApp.abortModal()
        }

        let response = alert.runModal()
        timer.invalidate()

        if fired || response == .abort {
            completion(.reject("timeout"))
            return
        }
        switch response {
        case .alertSecondButtonReturn:
            completion(.accept)
        default:
            completion(.reject("user"))
        }
    }
}
