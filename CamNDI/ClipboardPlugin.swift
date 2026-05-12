//
//  ClipboardPlugin.swift
//  Open Beam
//
//  Pasteboard polling + text-clipboard send/receive. Owns the shared
//  PasteboardWatcher (a 0.4s timer that hops to main); SharePlugin subscribes
//  to file-URL events via `onFileURLs`.
//

import AppKit
import CryptoKit
import Foundation
import os

/// Snapshot of the pasteboard at one tick, classified into the highest-priority
/// content type present (file URLs > text).
enum PasteboardSnapshot {
    case fileURLs([URL])
    case text(String)
    case empty
}

final class PasteboardWatcher: @unchecked Sendable {

    var onChange: ((PasteboardSnapshot, Int) -> Void)?    // snapshot + changeCount

    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue
    private let lock = OSAllocatedUnfairLock(initialState: Int(-1))
    private(set) var lastSeenChangeCount: Int = -1

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.4, repeating: 0.4)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Tell the watcher we just wrote to the pasteboard ourselves; it should
    /// not treat the resulting bump as a change-to-broadcast.
    func ackOwnWrite(changeCount: Int) {
        lock.withLock { $0 = changeCount }
    }

    private func poll() {
        // Pasteboard reads are documented main-thread.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            let cc = pb.changeCount
            let last: Int = self.lock.withLock { $0 }
            guard cc != last else { return }
            self.lock.withLock { $0 = cc }

            let snap = Self.snapshot(of: pb)
            // Hop back to the io queue to dispatch the callback.
            self.queue.async {
                self.onChange?(snap, cc)
            }
        }
    }

    private static func snapshot(of pb: NSPasteboard) -> PasteboardSnapshot {
        // Files first — readObjects(forClasses:options:) returns nil if no items match.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .fileURLs(urls)
        }
        if let s = pb.string(forType: .string) {
            return .text(s)
        }
        return .empty
    }
}

// MARK: - ClipboardPlugin (text)

final class ClipboardPlugin: @unchecked Sendable {

    let watcher: PasteboardWatcher
    private let identity: ClipSyncIdentity

    /// Called by manager to broadcast a payload on every paired+open connection.
    var broadcast: ((Data) -> Void)?

    /// Called when the watcher sees file URLs — SharePlugin handles this.
    var onFileURLs: (([URL], Int) -> Void)?

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var lastBroadcastHash: String = ""
        var lastAppliedHash: String = ""
        var lastWriteChangeCount: Int = -1
    }

    init(identity: ClipSyncIdentity, queue: DispatchQueue) {
        self.identity = identity
        self.watcher = PasteboardWatcher(queue: queue)
        self.watcher.onChange = { [weak self] snap, cc in
            self?.handle(snapshot: snap, changeCount: cc)
        }
    }

    func start() { watcher.start() }
    func stop() { watcher.stop() }

    /// Call once per new connection: send the current clipboard as a snapshot.
    func sendSnapshot(over send: @escaping (Data) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            // Files ignored for snapshot — share plugin handles those on change only.
            guard let s = pb.string(forType: .string), !s.isEmpty else { return }
            guard let payload = self.makeTextPayload(s, kind: "clipboard.text.snapshot") else { return }
            send(payload)
        }
    }

    /// Inbound payload from a connection. Called on the io queue.
    func handleInbound(payloadData: Data) {
        guard let payload = try? ClipSyncJSON.decoder.decode(ClipboardTextPayload.self, from: payloadData) else { return }
        guard payload.kind == "clipboard.text" || payload.kind == "clipboard.text.snapshot" else { return }
        guard payload.originID != identity.peerID else { return }    // own-loop guard
        let body = payload.body
        let utf8 = Data(body.utf8)
        guard utf8.count <= ClipSync.maxTextBytes else { return }

        let hash = Self.hashHex(utf8)
        let alreadyApplied: Bool = lock.withLock { s in
            if s.lastAppliedHash == hash || s.lastBroadcastHash == hash { return true }
            return false
        }
        if alreadyApplied { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body, forType: .string)
            let cc = pb.changeCount
            self.lock.withLock {
                $0.lastAppliedHash = hash
                $0.lastWriteChangeCount = cc
            }
            self.watcher.ackOwnWrite(changeCount: cc)
        }
    }

    // MARK: - Outbound

    private func handle(snapshot: PasteboardSnapshot, changeCount: Int) {
        switch snapshot {
        case .text(let s):
            broadcastText(s)
        case .fileURLs(let urls):
            onFileURLs?(urls, changeCount)
        case .empty:
            break
        }
    }

    private func broadcastText(_ s: String) {
        let utf8 = Data(s.utf8)
        guard !utf8.isEmpty, utf8.count <= ClipSync.maxTextBytes else {
            if utf8.count > ClipSync.maxTextBytes {
                print("[Open Beam] ClipSync: skipping text \(utf8.count) B (cap \(ClipSync.maxTextBytes))")
            }
            return
        }
        let hash = Self.hashHex(utf8)
        let shouldSend: Bool = lock.withLock { s in
            if s.lastBroadcastHash == hash || s.lastAppliedHash == hash { return false }
            s.lastBroadcastHash = hash
            return true
        }
        guard shouldSend else { return }
        guard let payload = makeTextPayload(s, kind: "clipboard.text") else { return }
        broadcast?(payload)
    }

    private func makeTextPayload(_ body: String, kind: String) -> Data? {
        let utf8 = Data(body.utf8)
        let payload = ClipboardTextPayload(
            kind: kind,
            body: body,
            sentAt: Int64(Date().timeIntervalSince1970 * 1000),
            originID: identity.peerID,
            contentHash: Self.hashHex(utf8)
        )
        return try? ClipSyncJSON.encoder.encode(payload)
    }

    private static func hashHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
