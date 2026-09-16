//
//  ClipSyncPairing.swift
//  OpenBeam
//
//  KDE-Connect-style pairing UX. The connection-handshake math (verification
//  code, fingerprint) lives in ClipSyncConnection; this file owns the window
//  the user reads.
//
//  Both ends show the *same* window. Pairing is one conversation across two
//  machines — the whole point is comparing a six-digit code between them — so a
//  system alert on one side and a custom panel on the other made the two halves
//  look like unrelated events. One layout, one code, one fingerprint; only the
//  buttons differ, because only one side has something to decide.
//

import AppKit
import Foundation
import os

final class ClipSyncPairing: @unchecked Sendable {

    enum Decision { case accept, reject(String /* reason */) }

    /// What came back to the side that asked.
    enum Outcome {
        case accepted
        case rejected(String)   // reason from the peer
        case failed             // connection dropped before an answer
    }

    /// Panels on screen, keyed by the connection they belong to. Usually one;
    /// two when both users press Pair at the same moment, in which case this
    /// machine is both asking and answering.
    @MainActor
    private(set) static var panels: [ObjectIdentifier: PairingPanel] = [:]

    /// This machine asked. Shows the code the other device is being asked to
    /// confirm, and a way out while it waits.
    @MainActor
    static func presentAsking(token: ObjectIdentifier,
                              displayName: String,
                              verificationCode: String,
                              fingerprint: String,
                              onCancel: @escaping () -> Void) {
        present(PairingPanel(token: token,
                             kind: .asking(onCancel: onCancel),
                             displayName: displayName,
                             verificationCode: verificationCode,
                             fingerprint: fingerprint))
    }

    /// The other machine asked. Same window, with the decision on it.
    @MainActor
    static func presentAnswering(token: ObjectIdentifier,
                                 displayName: String,
                                 verificationCode: String,
                                 fingerprint: String,
                                 decide: @escaping (Decision) -> Void) {
        present(PairingPanel(token: token,
                             kind: .answering(decide: decide),
                             displayName: displayName,
                             verificationCode: verificationCode,
                             fingerprint: fingerprint))
    }

    @MainActor
    private static func present(_ panel: PairingPanel) {
        panels[panel.token]?.close()
        panels[panel.token] = panel
        panel.show(cascade: panels.count - 1)
    }

    /// Tell the panel for `token` how its pairing ended. Anything from another
    /// connection is ignored, so a late close can't wipe the window a second
    /// attempt just put up.
    @MainActor
    static func resolve(token: ObjectIdentifier, outcome: Outcome) {
        panels[token]?.finish(outcome: outcome)
    }

    @MainActor
    static func forget(_ panel: PairingPanel) {
        if panels[panel.token] === panel { panels.removeValue(forKey: panel.token) }
    }
}

/// The pairing window. Non-modal on purpose: on a simultaneous pair this
/// machine may have one of each on screen, and a modal would block the other.
@MainActor
final class PairingPanel: NSObject, NSWindowDelegate {

    enum Kind {
        /// We asked; the other device answers. We can only wait or give up.
        case asking(onCancel: () -> Void)
        /// The other device asked; this user answers.
        case answering(decide: (ClipSyncPairing.Decision) -> Void)
    }

    /// Wide enough for a 47-character fingerprint on two lines.
    private static let width: CGFloat = 400

    let token: ObjectIdentifier

    private let kind: Kind
    private let displayName: String
    private let panel: NSPanel
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let primary = NSButton()      // Accept, or Close once it's over
    private let secondary = NSButton()    // Reject / Cancel
    private var timeout: Timer?
    private var answered = false
    private var closed = false

    init(token: ObjectIdentifier,
         kind: Kind,
         displayName: String,
         verificationCode: String,
         fingerprint: String) {
        self.token = token
        self.kind = kind
        self.displayName = displayName
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
        super.init()

        panel.title = "Pair"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let title = NSTextField(labelWithString: "Pair with “\(displayName)”")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let code = NSTextField(labelWithString: verificationCode)
        code.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        code.alignment = .center

        // Same sentence on both machines, pointing at the other screen.
        let hint = NSTextField(wrappingLabelWithString: isAnswering
            ? "Check that “\(displayName)” is showing this same code, then accept below."
            : "Check that “\(displayName)” is showing this same code, then accept there.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let fingerprintLabel = NSTextField(wrappingLabelWithString: "Fingerprint: \(fingerprint)")
        fingerprintLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        fingerprintLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        status.preferredMaxLayoutWidth = Self.width - 60
        if isAnswering {
            spinner.isHidden = true
            status.stringValue = "“\(displayName)” is waiting for an answer."
        } else {
            spinner.startAnimation(nil)
            status.stringValue = "Waiting for “\(displayName)” to accept…"
        }

        let statusRow = NSStackView(views: [spinner, status])
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 6

        secondary.title = isAnswering ? "Reject" : "Cancel"
        secondary.bezelStyle = .rounded
        secondary.target = self
        secondary.action = #selector(secondaryPressed)
        secondary.keyEquivalent = "\u{1b}"    // Escape

        primary.title = "Accept"
        primary.bezelStyle = .rounded
        primary.target = self
        primary.action = #selector(primaryPressed)
        primary.keyEquivalent = "\r"
        primary.isHidden = !isAnswering       // the asking side has nothing to accept

        let buttonRow = NSStackView(views: [NSView(), secondary, primary])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [title, code, hint, fingerprintLabel, statusRow, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            code.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            fingerprintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    private var isAnswering: Bool {
        if case .answering = kind { return true }
        return false
    }

    /// `cascade` offsets the second window of a simultaneous pair so it doesn't
    /// land exactly on top of the first.
    func show(cascade: Int) {
        panel.center()
        if cascade > 0 {
            let origin = panel.frame.origin
            panel.setFrameOrigin(NSPoint(x: origin.x + CGFloat(cascade) * 28,
                                         y: origin.y - CGFloat(cascade) * 28))
        }
        // Deferred one hop for the reason SettingsWindowController documents:
        // the status menu is still tearing down its event tracking, and
        // activating inside that leaves the window behind the menu. The guard
        // matters: a peer that answers instantly — the re-pair path does, with
        // no human in the way — resolves and closes this panel before the hop
        // runs, and ordering a closed window front would put an orphan back on
        // screen, still saying it was waiting.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }

        // Both ends run the same 30 s clock, so neither is left waiting on a
        // machine that has already given up.
        timeout = Timer.scheduledTimer(withTimeInterval: ClipSync.pairDialogTimeoutSeconds,
                                       repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.answered else { return }
                self.answer(.reject("timeout"))
                if self.isAnswering {
                    self.close()
                } else {
                    self.finish(outcome: .rejected("timeout"))
                }
            }
        }
    }

    /// Say no on the way out. Closing a pairing window you never answered is a
    /// refusal on the answering side and a withdrawal on the asking one, which
    /// is the same message on the wire either way: stop waiting.
    private func answer(_ decision: ClipSyncPairing.Decision) {
        guard !answered else { return }
        answered = true
        switch kind {
        case .asking(let onCancel):
            onCancel()
        case .answering(let decide):
            decide(decision)
        }
    }

    /// Swap the waiting state for the outcome. The window stays up so a reject
    /// or a dropped connection is something the user reads, not something they
    /// have to infer from a peer that never appears under Paired.
    func finish(outcome: ClipSyncPairing.Outcome) {
        // Nothing left to decide once the pairing is over, however it ended.
        answered = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true

        // The answering side has already read its own decision on screen; when
        // its peer disappears there is nothing more to tell it.
        guard !isAnswering else { return close() }

        switch outcome {
        case .accepted:
            // Nothing to read: the peer moving into the Paired list is the
            // confirmation.
            return close()
        case .rejected(let reason) where reason == "timeout":
            status.stringValue = "“\(displayName)” didn't answer in time."
        case .rejected:
            status.stringValue = "“\(displayName)” declined."
        case .failed:
            status.stringValue = "The connection to “\(displayName)” dropped."
        }
        primary.isHidden = true
        secondary.title = "Close"
        secondary.keyEquivalent = "\r"
    }

    /// The one way out, whichever way the user or the peer took it.
    func close() {
        answer(.reject("user"))         // no-op once answered
        closed = true
        timeout?.invalidate()
        timeout = nil
        panel.delegate = nil            // no second pass through windowWillClose
        ClipSyncPairing.forget(self)
        panel.close()
    }

    @objc private func primaryPressed() {
        answer(.accept)
        close()
    }

    @objc private func secondaryPressed() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }
}
