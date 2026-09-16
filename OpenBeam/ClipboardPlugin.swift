//
//  ClipboardPlugin.swift
//  OpenBeam
//
//  Pasteboard polling + text-clipboard send/receive. Owns the shared
//  PasteboardWatcher (a 0.4s timer that hops to main); SharePlugin subscribes
//  to file-URL events via `onFileURLs`.
//

import AppKit
import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "com.openbeam.clipsync", category: "clipboard")

/// Snapshot of the pasteboard at one tick, classified into the highest-priority
/// content type present (file URLs > image > text).
///
/// An image outranks text because the pasteboard usually carries both when the
/// image is the point: copying a picture in a browser leaves its address as a
/// string beside it, and syncing that address instead of the picture is not
/// what anyone meant by copy.
enum PasteboardSnapshot {
    case fileURLs([URL])
    case image(Data)            // PNG bytes
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
        if let png = pngOnPasteboard(pb) {
            return .image(png)
        }
        if let s = pb.string(forType: .string) {
            return .text(s)
        }
        return .empty
    }

    /// PNG is what goes on the wire: a screenshot arrives as PNG already, and
    /// the TIFF an app may offer alongside it is the same picture uncompressed —
    /// tens of megabytes of it for a Retina screen.
    private static func pngOnPasteboard(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - ClipboardPlugin (text)

final class ClipboardPlugin: @unchecked Sendable {

    let watcher: PasteboardWatcher
    private let identity: ClipSyncIdentity
    private let preferences: ClipSyncPreferences

    /// Called by manager to broadcast a payload on every paired+open connection.
    var broadcast: ((Data) -> Void)?

    /// Called when the watcher sees file URLs — SharePlugin handles this.
    var onFileURLs: (([URL], Int) -> Void)?

    /// Called when the watcher sees an image (PNG bytes) — SharePlugin carries
    /// it, since a picture needs the same chunking a file does.
    var onImage: ((Data) -> Void)?

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var lastBroadcastHash: String = ""
        var lastAppliedHash: String = ""
        var lastWriteChangeCount: Int = -1
    }

    init(identity: ClipSyncIdentity, preferences: ClipSyncPreferences, queue: DispatchQueue) {
        self.identity = identity
        self.preferences = preferences
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
            guard let s = pb.string(forType: .string),
                  let sendable = self.sendableText(s),
                  let payload = self.makeTextPayload(s, hash: sendable.hash, kind: "clipboard.text.snapshot")
            else { return }
            send(payload)
        }
    }

    /// Inbound payload from a connection. Called on the io queue.
    func handleInbound(payloadData: Data) {
        do {
            let payload = try ClipSyncJSON.decoder.decode(ClipboardTextPayload.self, from: payloadData)
            guard payload.kind == "clipboard.text" || payload.kind == "clipboard.text.snapshot" else {
                log.error("inbound text: unexpected kind=\(payload.kind, privacy: .public)")
                return
            }
            guard payload.originID != identity.peerID else {
                log.info("inbound text: dropping own-origin payload")
                return
            }
            let body = payload.body
            let utf8 = Data(body.utf8)
            guard utf8.count <= ClipSync.maxTextBytes else {
                log.error("inbound text: payload size \(utf8.count, privacy: .public) exceeds cap")
                return
            }

            let hash = Self.hashHex(utf8)
            let alreadyApplied: Bool = lock.withLock { s in
                if s.lastAppliedHash == hash || s.lastBroadcastHash == hash { return true }
                return false
            }
            if alreadyApplied {
                log.info("inbound text: skipping (already applied or just broadcast); hash=\(hash.prefix(12), privacy: .public)")
                return
            }

            log.info("inbound text: applying \(utf8.count, privacy: .public) bytes from \(payload.originID.prefix(8), privacy: .public) (kind=\(payload.kind, privacy: .public))")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                let ok = pb.setString(body, forType: .string)
                let cc = pb.changeCount
                self.lock.withLock {
                    $0.lastAppliedHash = hash
                    $0.lastWriteChangeCount = cc
                }
                self.watcher.ackOwnWrite(changeCount: cc)
                log.info("inbound text: pasteboard write \(ok ? "OK" : "FAILED", privacy: .public), changeCount=\(cc, privacy: .public)")
            }
        } catch {
            log.error("inbound text: decode failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Outbound

    private func handle(snapshot: PasteboardSnapshot, changeCount: Int) {
        switch snapshot {
        case .text(let s):
            print("[OpenBeam] ClipSync: pasteboard text change cc=\(changeCount)")
            broadcastText(s)
        case .fileURLs(let urls):
            print("[OpenBeam] ClipSync: pasteboard files change cc=\(changeCount) count=\(urls.count)")
            onFileURLs?(urls, changeCount)
        case .image(let png):
            log.info("pasteboard image change cc=\(changeCount, privacy: .public), \(png.count, privacy: .public) B PNG")
            onImage?(png)
        case .empty:
            print("[OpenBeam] ClipSync: pasteboard change cc=\(changeCount) (empty/unsupported type)")
        }
    }

    /// The one gate every outbound text passes: empty is nothing to say, over
    /// the user's cap is left alone. Returns the size and hash it had to
    /// compute anyway, so nothing downstream walks the string again.
    private func sendableText(_ s: String) -> (size: Int, hash: String)? {
        let utf8 = Data(s.utf8)
        let cap = preferences.maxTextBytes
        guard !utf8.isEmpty else { return nil }
        guard utf8.count <= cap else {
            log.info("skipping text \(utf8.count, privacy: .public) B (cap \(cap, privacy: .public))")
            return nil
        }
        return (utf8.count, Self.hashHex(utf8))
    }

    private func broadcastText(_ s: String) {
        guard let (size, hash) = sendableText(s) else { return }
        let shouldSend: Bool = lock.withLock { s in
            if s.lastBroadcastHash == hash || s.lastAppliedHash == hash { return false }
            s.lastBroadcastHash = hash
            return true
        }
        guard shouldSend else {
            print("[OpenBeam] ClipSync: text dedup skip (hash matches recent broadcast/apply)")
            return
        }
        guard let payload = makeTextPayload(s, hash: hash, kind: "clipboard.text") else { return }
        log.info("broadcasting text \(size, privacy: .public) B")
        broadcast?(payload)
    }

    /// `hash` comes from `sendableText`, which already walked these bytes.
    private func makeTextPayload(_ body: String, hash: String, kind: String) -> Data? {
        let payload = ClipboardTextPayload(
            kind: kind,
            body: body,
            sentAt: Int64(Date().timeIntervalSince1970 * 1000),
            originID: identity.peerID,
            contentHash: hash
        )
        return try? ClipSyncJSON.encoder.encode(payload)
    }

    private static func hashHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
