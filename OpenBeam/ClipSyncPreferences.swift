//
//  ClipSyncPreferences.swift
//  OpenBeam
//
//  The user-settable half of ClipSync's limits: what the Clipboard settings
//  pane writes and the plugins read. The protocol caps in `ClipSync` are the
//  ceiling — a preference only ever tightens one, never raises it, because a
//  peer speaking v1 refuses anything above the cap regardless of what this
//  machine would like to send.
//
//  Values are read straight from UserDefaults on each access rather than
//  cached: they change when someone clicks a control in settings, and the
//  readers are a 0.4 s pasteboard tick and the start of a transfer.
//

import Foundation

final class ClipSyncPreferences: @unchecked Sendable {

    /// The sizes settings offers, smallest first. The largest of each is the
    /// protocol's own cap, so "the most this can do" is always an option.
    static let textByteChoices = [16 * 1024, 64 * 1024, ClipSync.maxTextBytes]
    static let transferByteChoices = [10 * 1024 * 1024, 50 * 1024 * 1024, ClipSync.maxShareTotalBytes]

    private enum Key {
        static let enabled = "com.openbeam.clipsync.enabled"
        static let syncsFiles = "com.openbeam.clipsync.syncsFiles"
        static let syncsImages = "com.openbeam.clipsync.syncsImages"
        static let maxTextBytes = "com.openbeam.clipsync.maxTextBytes"
        static let maxTransferBytes = "com.openbeam.clipsync.maxTransferBytes"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether syncing is on, or nil if the user has never said. The manager
    /// resolves nil on launch (historically: on if anything is paired), so the
    /// absence of an answer stays distinguishable from a deliberate "off".
    /// Only the read is tri-state — nothing in the app un-answers the question.
    var enabled: Bool? { defaults.object(forKey: Key.enabled) as? Bool }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Key.enabled)
    }

    /// Whether copying a picture broadcasts it. Off leaves text and files alone.
    var syncsImages: Bool {
        get { defaults.object(forKey: Key.syncsImages) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.syncsImages) }
    }

    /// Whether copying files broadcasts them. Off leaves text syncing alone.
    var syncsFiles: Bool {
        get { defaults.object(forKey: Key.syncsFiles) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.syncsFiles) }
    }

    /// Largest clipboard text this machine will send, in UTF-8 bytes.
    var maxTextBytes: Int {
        get { Self.snap(defaults.object(forKey: Key.maxTextBytes) as? Int,
                        to: Self.textByteChoices,
                        ceiling: ClipSync.maxTextBytes) }
        set { defaults.set(newValue, forKey: Key.maxTextBytes) }
    }

    /// Largest file transfer this machine will send or accept, in bytes.
    var maxTransferBytes: Int {
        get { Self.snap(defaults.object(forKey: Key.maxTransferBytes) as? Int,
                        to: Self.transferByteChoices,
                        ceiling: ClipSync.maxShareTotalBytes) }
        set { defaults.set(newValue, forKey: Key.maxTransferBytes) }
    }

    /// Settings only ever writes one of `choices`, but defaults are a file
    /// anyone can edit. Every read snaps to the nearest offered size at or
    /// below the stored value, and `ceiling` — the protocol's own cap, named
    /// rather than inferred from where it sits in the array — is both the
    /// default and the most any edit can buy.
    private static func snap(_ value: Int?, to choices: [Int], ceiling: Int) -> Int {
        guard let value, value < ceiling else { return ceiling }
        return choices.last { $0 <= value } ?? choices[0]
    }
}
