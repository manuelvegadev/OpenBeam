//
//  SharePlugin.swift
//  OpenBeam
//
//  File transfer over the encrypted ClipSync channel. Sends file URLs found
//  on the local pasteboard as `share.begin` + `share.chunk*` + `share.end`;
//  receives the same and writes the assembled files into a per-peer cache,
//  then puts the resulting URLs on the local pasteboard.
//

import AppKit
import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "com.openbeam.clipsync", category: "share")

final class SharePlugin: @unchecked Sendable {

    private let identity: ClipSyncIdentity
    private weak var clipboardPlugin: ClipboardPlugin?
    private let preferences: ClipSyncPreferences
    private let queue: DispatchQueue
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Broadcast a payload to every paired+ready connection.
    var broadcast: ((Data) -> Void)?

    private struct State {
        var inflight: [String: Inbound] = [:]      // transferID -> assembly state
        var lastBroadcastFingerprint: String = ""
        var lastAppliedFingerprint: String = ""
    }

    private struct Inbound {
        let originID: String
        let files: [ShareFileMeta]
        let directory: URL
        /// Carried from `share.begin` — decides whether the far end wanted a
        /// file on the clipboard or a picture to paste.
        let paste: String?
        var fileIndex: Int = 0
        var bytesWritten: Int64 = 0
        var fileHandle: FileHandle?
        var fileURLs: [URL] = []
    }

    private static let cacheRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OpenBeam/clipsync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(identity: ClipSyncIdentity,
         clipboardPlugin: ClipboardPlugin,
         preferences: ClipSyncPreferences,
         queue: DispatchQueue) {
        self.identity = identity
        self.clipboardPlugin = clipboardPlugin
        self.preferences = preferences
        self.queue = queue
        clipboardPlugin.onFileURLs = { [weak self] urls, _ in
            self?.queue.async { self?.broadcastFiles(urls) }
        }
        clipboardPlugin.onImage = { [weak self] png in
            self?.queue.async { self?.broadcastImage(png) }
        }
        pruneCache()
    }

    // MARK: - Outbound

    private func broadcastFiles(_ urls: [URL]) {
        guard preferences.syncsFiles else {
            print("[OpenBeam] ClipSync share: file sync is off — not sending \(urls.count) file(s)")
            return
        }
        guard urls.count <= ClipSync.maxShareFileCount else {
            print("[OpenBeam] ClipSync share: \(urls.count) files exceeds cap \(ClipSync.maxShareFileCount)")
            return
        }

        // Stat + hash files. Skip if any missing or total exceeds cap.
        let cap = preferences.maxTransferBytes
        var metas: [ShareFileMeta] = []
        var total: Int64 = 0
        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  let size = attrs[.size] as? NSNumber,
                  let kind = attrs[.type] as? FileAttributeType,
                  kind == .typeRegular else {
                print("[OpenBeam] ClipSync share: skipping unreadable URL \(url.path)")
                return
            }
            total &+= size.int64Value
            if total > cap {
                print("[OpenBeam] ClipSync share: total \(total) B exceeds cap \(cap) — skipping")
                return
            }
            guard let sha = Self.sha256Hex(of: resolved) else {
                print("[OpenBeam] ClipSync share: hash failed for \(url.path)")
                return
            }
            metas.append(ShareFileMeta(name: resolved.lastPathComponent, size: size.int64Value, sha256: sha))
        }

        let fingerprint = metas.map { "\($0.name)|\($0.size)|\($0.sha256)" }.joined(separator: ",")
        let shouldSend: Bool = lock.withLock { s in
            if s.lastBroadcastFingerprint == fingerprint { return false }
            s.lastBroadcastFingerprint = fingerprint
            return true
        }
        guard shouldSend else { return }

        let transferID = UUID().uuidString.lowercased()
        let begin = ShareBeginPayload(
            kind: "share.begin",
            transferID: transferID,
            files: metas,
            totalBytes: total,
            sentAt: Int64(Date().timeIntervalSince1970 * 1000),
            originID: identity.peerID
        )
        guard let beginData = try? ClipSyncJSON.encoder.encode(begin) else { return }
        broadcast?(beginData)

        // Stream chunks file-by-file.
        for (fileIndex, url) in urls.enumerated() {
            let resolved = url.resolvingSymlinksInPath()
            guard let handle = try? FileHandle(forReadingFrom: resolved) else {
                let cancel = ShareCancelPayload(kind: "share.cancel", transferID: transferID, reason: "io_error")
                if let d = try? ClipSyncJSON.encoder.encode(cancel) { broadcast?(d) }
                return
            }
            defer { try? handle.close() }

            let fileSize = metas[fileIndex].size
            let totalChunks = Int((fileSize + Int64(ClipSync.maxChunkPlaintextBytes) - 1) / Int64(ClipSync.maxChunkPlaintextBytes))
            var chunkIndex = 0
            while true {
                let chunk = (try? handle.read(upToCount: ClipSync.maxChunkPlaintextBytes)) ?? Data()
                if chunk.isEmpty { break }
                let payload = ShareChunkPayload(
                    kind: "share.chunk",
                    transferID: transferID,
                    fileIndex: fileIndex,
                    chunkIndex: chunkIndex,
                    totalChunks: max(1, totalChunks),
                    data: chunk
                )
                guard let d = try? ClipSyncJSON.encoder.encode(payload) else { return }
                broadcast?(d)
                chunkIndex += 1
            }
        }

        let end = ShareEndPayload(kind: "share.end", transferID: transferID)
        if let d = try? ClipSyncJSON.encoder.encode(end) { broadcast?(d) }
    }

    /// Send a pasteboard image as a one-file transfer marked `paste: "image"`.
    /// It rides the file path because the problem is the same — a picture does
    /// not fit in one frame — and only the far end's last step differs.
    private func broadcastImage(_ png: Data) {
        guard preferences.syncsImages else {
            print("[OpenBeam] ClipSync image: image sync is off — not sending \(png.count) B")
            return
        }
        guard png.count <= preferences.maxTransferBytes else {
            print("[OpenBeam] ClipSync image: \(png.count) B exceeds cap \(preferences.maxTransferBytes) — skipping")
            return
        }

        let sha = Self.sha256Hex(of: png)
        let fingerprint = "image|\(png.count)|\(sha)"
        let shouldSend: Bool = lock.withLock { s in
            // Also skips a picture this machine has just been handed, so the
            // two do not bounce one screenshot back and forth.
            if s.lastBroadcastFingerprint == fingerprint || s.lastAppliedFingerprint == fingerprint { return false }
            s.lastBroadcastFingerprint = fingerprint
            return true
        }
        guard shouldSend else { return }

        let transferID = UUID().uuidString.lowercased()
        let meta = ShareFileMeta(name: "clipboard.png", size: Int64(png.count), sha256: sha)
        let begin = ShareBeginPayload(
            kind: "share.begin",
            transferID: transferID,
            files: [meta],
            totalBytes: Int64(png.count),
            sentAt: Int64(Date().timeIntervalSince1970 * 1000),
            originID: identity.peerID,
            paste: "image"
        )
        guard let beginData = try? ClipSyncJSON.encoder.encode(begin) else { return }
        print("[OpenBeam] ClipSync image: broadcasting \(png.count) B PNG")
        broadcast?(beginData)

        let chunkSize = ClipSync.maxChunkPlaintextBytes
        let totalChunks = max(1, (png.count + chunkSize - 1) / chunkSize)
        for chunkIndex in 0..<totalChunks {
            let start = png.startIndex + chunkIndex * chunkSize
            let end = min(start + chunkSize, png.endIndex)
            let payload = ShareChunkPayload(
                kind: "share.chunk",
                transferID: transferID,
                fileIndex: 0,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                data: png[start..<end]
            )
            guard let d = try? ClipSyncJSON.encoder.encode(payload) else { return }
            broadcast?(d)
        }

        let endFrame = ShareEndPayload(kind: "share.end", transferID: transferID)
        if let d = try? ClipSyncJSON.encoder.encode(endFrame) { broadcast?(d) }
    }

    // MARK: - Inbound

    func handleInbound(payloadData: Data, kind: String) {
        switch kind {
        case "share.begin":  handleBegin(payloadData)
        case "share.chunk":  handleChunk(payloadData)
        case "share.end":    handleEnd(payloadData)
        case "share.cancel": handleCancel(payloadData)
        default: break
        }
    }

    private func handleBegin(_ data: Data) {
        guard let begin = try? ClipSyncJSON.decoder.decode(ShareBeginPayload.self, from: data) else { return }
        guard begin.originID != identity.peerID else { return }
        let wantsImage = begin.paste == "image"
        guard wantsImage ? preferences.syncsImages : preferences.syncsFiles else {
            sendCancel(transferID: begin.transferID, reason: "user"); return
        }
        guard begin.files.count <= ClipSync.maxShareFileCount else {
            sendCancel(transferID: begin.transferID, reason: "limit_exceeded"); return
        }
        guard begin.totalBytes <= preferences.maxTransferBytes else {
            sendCancel(transferID: begin.transferID, reason: "limit_exceeded"); return
        }

        // Validate file names — basename only, no path traversal.
        for f in begin.files {
            if f.name.contains("/") || f.name.contains("\\") || f.name == ".." || f.name == "." {
                sendCancel(transferID: begin.transferID, reason: "other"); return
            }
        }

        let dir = Self.cacheRoot
            .appendingPathComponent(begin.originID, isDirectory: true)
            .appendingPathComponent(begin.transferID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            sendCancel(transferID: begin.transferID, reason: "io_error"); return
        }

        lock.withLock {
            $0.inflight[begin.transferID] = Inbound(
                originID: begin.originID,
                files: begin.files,
                directory: dir,
                paste: begin.paste
            )
        }
    }

    private func handleChunk(_ data: Data) {
        guard let chunk = try? ClipSyncJSON.decoder.decode(ShareChunkPayload.self, from: data) else { return }

        // Mutate inflight under lock; do file IO inside the closure since it's sequential per transfer.
        lock.withLock { state in
            guard var inb = state.inflight[chunk.transferID] else { return }

            // Sequential file ordering check.
            if chunk.fileIndex < inb.fileIndex {
                return    // late chunk, ignore
            }
            if chunk.fileIndex > inb.fileIndex {
                // Close previous file (it should already be done) and open the next.
                inb.fileHandle?.closeFile()
                inb.fileHandle = nil
                inb.fileIndex = chunk.fileIndex
                inb.bytesWritten = 0
            }

            // Open file if needed.
            if inb.fileHandle == nil {
                let target = inb.directory.appendingPathComponent(inb.files[inb.fileIndex].name)
                FileManager.default.createFile(atPath: target.path, contents: nil)
                guard let h = try? FileHandle(forWritingTo: target) else {
                    state.inflight.removeValue(forKey: chunk.transferID)
                    self.sendCancel(transferID: chunk.transferID, reason: "io_error")
                    return
                }
                inb.fileHandle = h
                inb.fileURLs.append(target)
            }

            // Write the chunk.
            do {
                try inb.fileHandle?.write(contentsOf: chunk.data)
                inb.bytesWritten &+= Int64(chunk.data.count)
            } catch {
                inb.fileHandle?.closeFile()
                state.inflight.removeValue(forKey: chunk.transferID)
                self.sendCancel(transferID: chunk.transferID, reason: "io_error")
                return
            }

            // If we've written the whole current file, close handle for next chunk to open the next file.
            if inb.bytesWritten >= inb.files[inb.fileIndex].size {
                inb.fileHandle?.closeFile()
                inb.fileHandle = nil
            }

            state.inflight[chunk.transferID] = inb
        }
    }

    private func handleEnd(_ data: Data) {
        guard let end = try? ClipSyncJSON.decoder.decode(ShareEndPayload.self, from: data) else { return }
        let toCommit: Inbound? = lock.withLock {
            let v = $0.inflight[end.transferID]
            $0.inflight.removeValue(forKey: end.transferID)
            return v
        }
        guard let inb = toCommit else { return }

        // Verify SHA-256 per file.
        for (i, meta) in inb.files.enumerated() {
            guard i < inb.fileURLs.count else {
                sendCancel(transferID: end.transferID, reason: "hash_mismatch"); return
            }
            guard let sha = Self.sha256Hex(of: inb.fileURLs[i]), sha == meta.sha256 else {
                sendCancel(transferID: end.transferID, reason: "hash_mismatch")
                try? FileManager.default.removeItem(at: inb.directory)
                return
            }
        }

        if inb.paste == "image", let url = inb.fileURLs.first {
            commitImage(at: url, transferID: end.transferID, directory: inb.directory)
            return
        }

        // Commit: write URLs to pasteboard on main.
        let urls = inb.fileURLs
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            let cc = pb.changeCount
            self.clipboardPlugin?.watcher.ackOwnWrite(changeCount: cc)
        }
    }

    /// Put a received picture on the clipboard and drop the file it arrived in:
    /// this is clipboard content, not a download, so nothing should be left in
    /// the cache for a week.
    private func commitImage(at url: URL, transferID: String, directory: URL) {
        guard let png = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        try? FileManager.default.removeItem(at: directory)

        let fingerprint = "image|\(png.count)|\(Self.sha256Hex(of: png))"
        lock.withLock { $0.lastAppliedFingerprint = fingerprint }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            // A TIFF beside it, because plenty of apps ask for that and nothing
            // else. Built here rather than sent, so the wire stays compressed.
            if let rep = NSBitmapImageRep(data: png),
               let tiff = rep.representation(using: .tiff, properties: [:]) {
                item.setData(tiff, forType: .tiff)
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([item])
            let cc = pb.changeCount
            self.clipboardPlugin?.watcher.ackOwnWrite(changeCount: cc)
            log.info("inbound image: \(png.count, privacy: .public) B on the pasteboard, changeCount=\(cc, privacy: .public)")
        }
    }

    private func handleCancel(_ data: Data) {
        guard let c = try? ClipSyncJSON.decoder.decode(ShareCancelPayload.self, from: data) else { return }
        let removed: Inbound? = lock.withLock {
            let v = $0.inflight[c.transferID]
            $0.inflight.removeValue(forKey: c.transferID)
            return v
        }
        if let removed {
            try? FileManager.default.removeItem(at: removed.directory)
        }
    }

    private func sendCancel(transferID: String, reason: String) {
        let c = ShareCancelPayload(kind: "share.cancel", transferID: transferID, reason: reason)
        if let d = try? ClipSyncJSON.encoder.encode(c) { broadcast?(d) }
    }

    // MARK: - Cache pruning

    private func pruneCache() {
        let fm = FileManager.default
        let root = Self.cacheRoot
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        guard let peerDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }

        // First pass: drop entries older than 7 days.
        for peerDir in peerDirs {
            guard let transfers = try? fm.contentsOfDirectory(at: peerDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for t in transfers {
                if let mtime = try? t.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   mtime < cutoff {
                    try? fm.removeItem(at: t)
                }
            }
        }

        // Second pass: if total cache > 1 GB, evict oldest first.
        var totalSize: Int64 = 0
        var entries: [(URL, Date, Int64)] = []
        if let walker = fm.enumerator(at: root,
                                      includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]) {
            for case let url as URL in walker {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true {
                    let size = Int64(v?.totalFileAllocatedSize ?? 0)
                    let mtime = v?.contentModificationDate ?? .distantPast
                    totalSize &+= size
                    entries.append((url, mtime, size))
                }
            }
        }
        let oneGB: Int64 = 1024 * 1024 * 1024
        if totalSize > oneGB {
            entries.sort { $0.1 < $1.1 }
            for (url, _, size) in entries {
                if totalSize <= oneGB { break }
                try? fm.removeItem(at: url)
                totalSize &-= size
            }
        }
    }

    // MARK: - Helpers

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let data = try? h.read(upToCount: 1 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
